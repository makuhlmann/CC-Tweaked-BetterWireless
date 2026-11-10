-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cellular network's core: the controller (attach and handover), the subscriber database, and the gateway (phones'
addresses, and tunnels to their cells).

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cellcore` program instead.

Phones attach with a `Noise_IK` handshake with the operator's key, which cells relay. Once the phone confirms, the core
gives it an address from the operator's network (the same one each time it attaches), and tells the cell the key it
shares with the phone. The gateway is a virtual interface for the operator's network: packets for a phone go down a
sealed tunnel to the phone's cell, and packets from phones come up tunnels into the network.

Handover goes through the core, like LTE's S1 handover: the phone's cell asks for it, the core gives the target cell
the phone's context, the phone moves, and the target cell asks the core to switch the phone's tunnel to it.

@local
]]

local address = require "cc.net.address"
local codec = require "cc.net.codec"
local noise = require "cc.internal.net.noise"
local common = require "cc.internal.net.cell.common"

--- What both sides of an attach agree on, followed by the network's name.
local PROLOGUE = "cc-net cell attach 1\0"

--- What both sides of an activation agree on, followed by the network's name.
local ACTIVATE_PROLOGUE = "cc-net cell activate 1\0"

-- How long an activation code lasts, in milliseconds, and how many wrong tries it takes.
local CODE_LIFETIME = 24 * 60 * 60 * 1000
local CODE_TRIES = 3

-- How often to try delivering messages again, in seconds.
local MESSAGE_RETRY = 10

-- How long a phone has to confirm its attach, or finish activating, in seconds.
local ATTACH_TIMEOUT = 10
local ACTIVATE_TIMEOUT = 30

-- How many attaches (or activations) may be under way for one phone at one cell, and how many activations in all.
-- Anyone can send a request which says it's from a phone, and it mustn't take the place of the phone's own.
local MAX_ATTEMPTS, MAX_ACTIVATING = 4, 64

-- Messages waiting for phones: how many in all, how many for one number, and how long they're kept, in milliseconds.
local MAX_MESSAGES, MAX_MAILBOX, MESSAGE_LIFETIME = 1000, 50, 7 * 24 * 60 * 60 * 1000

-- How many of the messages each phone sent to remember, to tell when one comes twice.
local MAX_SENT = 64

local is_id = common.is_id

local Core = {}
Core.__index = Core

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

--[[- Start a cellular core on a network stack.

@tparam {
    stack = table, crypto = table, network = string,
    operator = { public = string, exchange = function(public:string):string }, signing = string,
    prefix = string, subscribers = table, secret? = string, tunnel_key? = function(cell:number):string,
    codes? = table, epoch = function():number,
    on_event? = function(event:string, ...:any),
} options The stack (with forwarding on, so phones' packets reach the network); the `crypto` API; the network's name;
the operator's X25519 key, and its Ed25519 signing key's public half (which phones check cells' certificates with); the
operator's network for phones' addresses (such as `"10.64.0.0/16"`), whose first address the gateway takes; the
subscribers, by SIM key (hexadecimal) to `{ id, number, barred? }`; a secret only the core knows, for tunnel keys (or a
function giving a cell's tunnel key, so the secret can stay in the enclave); activation codes, by their first group, as
`add_code` makes them; the time, as `os.epoch("utc")` gives; and a function told about attaches, handovers and so
on, for logging and saving.
@treturn table The core.
]]
local function new(options)
    local network_address, prefix = address.parse(options.prefix)
    if not network_address or not prefix or prefix > 30 then error("Invalid prefix " .. tostring(options.prefix), 2) end

    local self = setmetatable({
        stack = options.stack, crypto = options.crypto, network = options.network, operator = options.operator,
        signing = options.signing, codes = options.codes or {}, messages = {},
        activating = {}, activating_count = 0, activating_order = {},
        -- Messages are numbered from a different place each time the core starts, so a phone which remembers the
        -- ones it has had doesn't take a new one for an old one.
        next_message = math.random(1, 0x7FFFFFFF) * 0x100000,
        epoch = options.epoch,
        make_tunnel_key = options.tunnel_key or function(cell) return common.tunnel_key(options.crypto, options.secret, cell) end,
        subscribers = options.subscribers, secret = options.secret, on_event = options.on_event or function() end,
        network_address = address.network(network_address, prefix), prefix = prefix,
        next_host = 2,
        towers = {}, sessions = {}, by_teid = {}, by_address = {}, pending = {},
    }, Core)

    -- The gateway: everything for phones goes down their tunnels.
    local stack = self.stack
    stack:add_virtual_interface("cellular", "gateway", function(packet, next_hop) self:downlink(packet, next_hop) end)
    stack:set_address("cellular", self.network_address + 1, prefix)

    -- Tunnels carry phones' packets whole, so need more room than programs' datagrams.
    self.socket = assert(stack:udp_open(common.TUNNEL_PORT, function(data, from) self:uplink(data, from) end, common.TUNNEL_LIMITS))
    self.retry_timer = stack:schedule(MESSAGE_RETRY, function() self:retry_messages() end)
    return self
end

--[[- Make an activation code for a subscription. Activating a phone with it gives that phone the subscription, replacing
any SIM it had before.

@tparam string id The subscriber's ID, such as `"ACME-0042"`.
@tparam string number Their phone number.
@treturn string The code, such as `"7Q2M-K4XD-9PRB-T6WN-HJ3C"`.
@treturn string Its first group, which [`Core:control`] looks it up by in `codes`.
]]
function Core:add_code(id, number)
    local code, tag, secret = common.make_code(self.crypto)
    self.codes[tag] = {
        id = id, number = number, key = common.activation_key(self.crypto, secret), tries = 0,
        expires = self.epoch() + CODE_LIFETIME,
    }
    return code, tag
end

--[[- Add a cell. Its control messages come to [`Core:control`], and its tunnel is sealed with the key returned.

@tparam number id The cell's computer ID.
@tparam number cell_address The cell's address, for its tunnel.
@tparam function(message:table) send Sends a control message to the cell.
@treturn string The key for the cell's tunnel.
]]
function Core:add_tower(id, cell_address, send)
    local key = self.make_tunnel_key(id)
    self.towers[id] = {
        id = id, address = cell_address, send = send,
        sealer = common.new_sealer(self.crypto, key, common.DOWNLINK, common.UPLINK),
    }
    self:update_paths()
    return key
end

--[[- Find the relays a cell's backhaul goes through, nearest first.

A relay is a computer which is both a phone of this network and a cell: its cell reaches us through its phone, so its
address is the phone's. Its backhaul goes through the cell its phone uses, which may be a relay too.

@tparam number id The cell's ID.
@treturn { number... } The IDs of the cells its backhaul goes through, which are also the relays' computers.
]]
function Core:path_of(id)
    local path, seen = {}, { [id] = true }
    local tower = self.towers[id]
    -- One more than a path may have, to tell a cell it's too far from us.
    while tower and #path <= common.MAX_PATH do
        local session = self.by_address[tower.address]
        local upstream = session and session.teid and session.cell
        if not upstream or seen[upstream] then break end
        seen[upstream] = true
        path[#path + 1] = upstream
        tower = self.towers[upstream]
    end
    return path
end

-- Whether a phone using a cell would make a loop: the phone's computer is the cell, or a relay its backhaul goes
-- through. (A relay's phone and cell share its computer's ID.)
function Core:would_loop(phone, tower_id)
    if phone == tower_id then return true end
    for _, relay in ipairs(self:path_of(tower_id)) do
        if relay == phone then return true end
    end
    return false
end

--[[- Find why a phone mayn't use a cell, if it mayn't: it would make a loop, or a chain of too many relays.

@tparam number phone The phone's computer's ID.
@tparam number tower_id The cell's ID.
@treturn string|nil Why not, or `nil` if it may.
]]
function Core:refuse(phone, tower_id)
    if self:would_loop(phone, tower_id) then return "That cell is behind this one" end
    -- A relay (whose cell we know) can't go through a cell which is as far from us as a cell may be.
    if self.towers[phone] and #self:path_of(tower_id) >= common.MAX_PATH then return "Too many relays" end
end

-- Tell cells whose path has changed: they advertise it, so relays' phones can avoid cells behind them.
function Core:update_paths()
    for id, tower in pairs(self.towers) do
        local path = self:path_of(id)
        local key = table.concat(path, ",")
        if tower.path ~= key then
            tower.path = key
            tower.send({ op = "path", path = path })
        end
    end
end

--[[- Forget a cell, once it has gone. Its phones lose service until they find another cell.

@tparam number id The cell's ID.
@tparam[opt] function send The function [`Core:add_tower`] was given. If the cell has been added again since, with
another, the new one is kept.
]]
function Core:remove_tower(id, send)
    local tower = self.towers[id]
    if tower and (send == nil or tower.send == send) then
        self.towers[id] = nil
        self:update_paths()
    end
end

function Core:send(tower_id, message)
    local tower = self.towers[tower_id]
    if tower then tower.send(message) end
end

--[[- Remove a subscriber. If their phone is attached, its cell forgets it, and it's refused when it tries again.

@tparam string sim The subscriber's SIM key, as hexadecimal digits.
]]
function Core:remove_subscriber(sim)
    self.subscribers[sim] = nil
    local session = self.sessions[sim]
    if not session then return end
    if session.teid then
        self.by_teid[session.teid] = nil
        if session.cell then self:send(session.cell, { op = "release", teid = session.teid }) end
        if session.handover then self:send(session.handover, { op = "release", teid = session.teid }) end
    end
    self.by_address[session.address] = nil
    self.sessions[sim] = nil
    self:update_paths()
end

--- Stop the core: phones lose service, and the gateway's interface and port are freed, so it can be started again.
function Core:stop()
    for _, tower in pairs(self.towers) do
        for _, session in pairs(self.sessions) do
            if session.teid and session.cell == tower.id then tower.send({ op = "release", teid = session.teid }) end
        end
    end
    self.stack:cancel(self.retry_timer)
    self.stack:udp_close(self.socket)
    self.stack:remove_interface("cellular")
    self.towers, self.sessions, self.by_teid, self.by_address, self.pending = {}, {}, {}, {}, {}
    self.activating, self.activating_count, self.activating_order = {}, 0, {}
end

-- Find or make a phone's session, keeping its address when it attaches again.
function Core:session_for(sim)
    local session = self.sessions[sim]
    if session then return session end

    -- Hosts 2 and up: 1 is the gateway.
    local host_count = 2 ^ (32 - self.prefix) - 2
    local addr
    for _ = 2, host_count do
        local host = self.next_host
        self.next_host = host >= host_count and 2 or host + 1
        local candidate = self.network_address + host
        if not self.by_address[candidate] then
            addr = candidate
            break
        end
    end
    if not addr then return nil end

    session = { sim = sim, address = addr }
    self.sessions[sim] = session
    self.by_address[addr] = session
    return session
end

--[[- Handle a control message from a cell.

@tparam number tower_id The cell's ID.
@param message The message.
]]
function Core:control(tower_id, message)
    local tower = self.towers[tower_id]
    if not tower or type(message) ~= "table" then return end
    local op = message.op

    if op == "attach" and is_id(message.phone) and type(message.handshake) == "string" then
        self:attach(tower, message.phone, message.handshake)
    elseif op == "attach_complete" and is_id(message.phone) then
        self:attach_complete(tower, message.phone, message.data)
    elseif op == "handover" and is_id(message.teid) and is_id(message.target) then
        self:handover(tower, message.teid, message.target)
    elseif op == "path_switch" and is_id(message.teid) then
        self:path_switch(tower, message.teid)
    elseif op == "activate" and is_id(message.phone) and type(message.tag) == "string"
        and type(message.handshake) == "string" then
        self:activate(tower, message.phone, message.tag, message.handshake)
    elseif op == "activate_finish" and is_id(message.phone) and type(message.handshake) == "string" then
        self:activate_finish(tower, message.phone, message.handshake)
    elseif op == "sms" and is_id(message.teid) then
        self:sms(tower, message.teid, message.id, message.to, message.text)
    elseif op == "sms_ack" and is_id(message.teid) then
        self:sms_ack(tower, message.teid, message.id)
    end
end

-- Attaches and activations under way are kept by cell and phone, a few for each: the phone's own request, and any
-- which only say they're the phone's.
local function add_attempt(attempts, key, attempt)
    local list = attempts[key]
    if not list then
        list = {}
        attempts[key] = list
    end
    list[#list + 1] = attempt
    local dropped
    if #list > MAX_ATTEMPTS then dropped = table.remove(list, 1) end
    return dropped
end

local function remove_attempt(attempts, key, attempt)
    local list = attempts[key]
    if not list then return false end
    for i, other in ipairs(list) do
        if other == attempt then
            table.remove(list, i)
            if #list == 0 then attempts[key] = nil end
            return true
        end
    end
    return false
end

-- A phone wants to activate with a code. Nothing is sent which helps anyone without the code.
function Core:activate(tower, phone, tag, message)
    local code = self.codes[tag]
    if type(code) ~= "table" or type(code.key) ~= "string" or code.expires < self.epoch() then return end
    local handshake = noise.new {
        crypto = self.crypto, pattern = "XXpsk3", initiator = false, prologue = ACTIVATE_PROLOGUE .. self.network,
        static = self.operator, psk = code.key,
    }
    if not handshake:read(message) then return end
    local reply = handshake:write(codec.encode({ v = 1 }))
    if not reply then return end

    local key = tower.id .. ":" .. phone
    local activating = { tag = tag, handshake = handshake, key = key }
    self:forget_activation(add_attempt(self.activating, key, activating), true)
    self.activating_count = self.activating_count + 1
    -- Anyone who has heard a code's first group can start as many of these as they like. Only so many are kept: the
    -- oldest goes, as a phone which means it finishes in a moment.
    local order = self.activating_order
    order[#order + 1] = activating
    while self.activating_count > MAX_ACTIVATING and order[1] do self:forget_activation(table.remove(order, 1)) end
    self.stack:schedule(ACTIVATE_TIMEOUT, function() self:forget_activation(activating) end)
    self:send(tower.id, { op = "activate_reply", phone = phone, handshake = reply })
end

-- Forget an activation which is over, or has taken too long.
function Core:forget_activation(activating, removed)
    if not activating or activating.gone then return end
    if not removed then remove_attempt(self.activating, activating.key, activating) end
    activating.gone = true
    self.activating_count = self.activating_count - 1
    local order = self.activating_order
    -- Usually the oldest, at the front.
    for i, other in ipairs(order) do
        if other == activating then
            table.remove(order, i)
            break
        end
    end
end

function Core:activate_finish(tower, phone, message)
    local key = tower.id .. ":" .. phone
    -- The last message only reads if the phone knew the code. It's for one of the activations under way: the others
    -- can't read it, and are left as they were.
    local activating
    for _, candidate in ipairs(self.activating[key] or {}) do
        local handshake = candidate.handshake:clone()
        if handshake:read(message) then
            activating, candidate.handshake = candidate, handshake
            break
        end
    end
    if not activating then
        -- A wrong code. Count it against the code of the newest activation, and forget that one.
        local list = self.activating[key]
        local failed = list and list[#list]
        if not failed then return end
        self:forget_activation(failed)
        local code = self.codes[failed.tag]
        if not code then return end
        code.tries = code.tries + 1
        if code.tries >= CODE_TRIES then self.codes[failed.tag] = nil end
        self.on_event("activation_failed", failed.tag)
        return
    end
    self:forget_activation(activating)
    local code = self.codes[activating.tag]
    if not code then return end
    self.codes[activating.tag] = nil
    self.on_event("code_used", activating.tag)

    -- The subscription moves to this SIM, and any old one stops working.
    local sim = to_hex(activating.handshake.rs)
    for old_sim, subscriber in pairs(self.subscribers) do
        if subscriber.id == code.id then self.subscribers[old_sim] = nil end
    end
    self.subscribers[sim] = { id = code.id, number = code.number }
    self.on_event("activated", sim, code.id, code.number)

    local send = activating.handshake:split()
    local info = codec.encode({
        network = self.network, key = self.operator.public, signing = self.signing, id = code.id, number = code.number,
    })
    self:send(tower.id, { op = "activate_accept", phone = phone, data = send:encrypt(info) })
end

-- Tell a phone what became of a message it sent.
function Core:sms_sent(session, id, ok, reason)
    self:send(session.cell, { op = "sms_sent", teid = session.teid, id = id, ok = ok, error = reason })
end

-- Messages: kept until the phone they're for is attached, and says it has them.
function Core:sms(tower, teid, id, to, text)
    local session = self.by_teid[teid]
    -- Only a phone's own cell speaks for it.
    if not session or session.cell ~= tower.id then return end
    local sender = self.subscribers[session.sim]
    if not sender or not is_id(id) or type(to) ~= "string" or type(text) ~= "string" then return end
    if #text > 1000 or #to > 32 or #to < 1 then return self:sms_sent(session, id, false, "That message can't be sent") end

    -- The phone sends a message until we say we have it, so it may come more than once.
    session.sent = session.sent or { order = {} }
    local sent = session.sent
    if sent[id] ~= nil then return self:sms_sent(session, id, sent[id] == true, sent[id] ~= true and sent[id] or nil) end
    local function done(ok, reason)
        sent[id] = ok or reason
        sent.order[#sent.order + 1] = id
        if #sent.order > MAX_SENT then sent[table.remove(sent.order, 1)] = nil end
        self:sms_sent(session, id, ok, reason)
    end

    local known, waiting = false, 0
    for _, subscriber in pairs(self.subscribers) do
        if subscriber.number == to then known = true end
    end
    if not known then return done(false, "Nobody has the number " .. to) end
    self:expire_messages()
    for _, message in ipairs(self.messages) do
        if message.to == to then waiting = waiting + 1 end
    end
    if waiting >= MAX_MAILBOX or #self.messages >= MAX_MESSAGES then
        return done(false, "Too many messages are waiting for " .. to)
    end

    self.next_message = self.next_message + 1
    local message = { id = self.next_message, from = sender.number, to = to, text = text, expires = self.epoch() + MESSAGE_LIFETIME }
    self.messages[#self.messages + 1] = message
    self.on_event("message", sender.number, to)
    done(true)
    self:deliver(message)
end

-- Forget messages nobody collected in time.
function Core:expire_messages()
    local now, kept = self.epoch(), {}
    for _, message in ipairs(self.messages) do
        if message.expires > now then kept[#kept + 1] = message end
    end
    self.messages = kept
end

-- Find where the phones with numbers are, if they're attached.
function Core:sessions_by_number()
    local result = {}
    for sim, subscriber in pairs(self.subscribers) do
        local session = self.sessions[sim]
        if session and session.teid and type(subscriber.number) == "string" then result[subscriber.number] = session end
    end
    return result
end

function Core:deliver(message, sessions)
    local session = (sessions or self:sessions_by_number())[message.to]
    if session then
        self:send(session.cell, { op = "sms", teid = session.teid, id = message.id, from = message.from, text = message.text })
    end
end

function Core:sms_ack(tower, teid, id)
    local session = self.by_teid[teid]
    local subscriber = session and session.cell == tower.id and self.subscribers[session.sim]
    if not subscriber then return end
    for i, message in ipairs(self.messages) do
        if message.id == id and message.to == subscriber.number then
            table.remove(self.messages, i)
            return
        end
    end
end

function Core:retry_messages()
    self.retry_timer = self.stack:schedule(MESSAGE_RETRY, function() self:retry_messages() end)
    if not self.messages[1] then return end
    self:expire_messages()
    local sessions = self:sessions_by_number()
    for _, message in ipairs(self.messages) do self:deliver(message, sessions) end
end

function Core:attach(tower, phone, message)
    -- A relay's phone can't reach us through a cell which reaches us through the relay, or is too far away.
    local refused = self:refuse(phone, tower.id)
    if refused then return self:send(tower.id, { op = "reject", phone = phone, reason = refused }) end
    local handshake = noise.new {
        crypto = self.crypto, pattern = "IK", initiator = false, prologue = PROLOGUE .. self.network,
        static = self.operator,
    }
    local payload = handshake:read(message)
    if not payload then return end

    local sim = to_hex(handshake.rs)
    local subscriber = self.subscribers[sim]
    if not subscriber or subscriber.barred then
        self.on_event("rejected", sim)
        return self:send(tower.id, { op = "reject", phone = phone, reason = "Not a subscriber of " .. self.network })
    end

    local reply = handshake:write(codec.encode({ v = 1, id = subscriber.id, number = subscriber.number }))
    if not reply then return end
    local _, receive = handshake:split()
    -- Nothing is given out until the phone confirms, as the first message alone could be a recording.
    local key = tower.id .. ":" .. phone
    local pending = { sim = sim, receive = receive, secret = handshake.ck, phone = phone }
    add_attempt(self.pending, key, pending)
    self.stack:schedule(ATTACH_TIMEOUT, function() remove_attempt(self.pending, key, pending) end)
    self:send(tower.id, { op = "attach_reply", phone = phone, handshake = reply })
end

function Core:attach_complete(tower, phone, data)
    local key = tower.id .. ":" .. phone
    if type(data) ~= "string" then return end
    -- The confirmation is for one of the attaches under way: the phone's own, if others only said they were its.
    local pending
    for _, candidate in ipairs(self.pending[key] or {}) do
        local plaintext = candidate.receive:decrypt(data)
        local confirm = plaintext and codec.decode(plaintext)
        if type(confirm) == "table" and confirm.complete == true then
            pending = candidate
            break
        end
    end
    if not pending then return end
    self.pending[key] = nil

    local session = self:session_for(pending.sim)
    if not session then
        return self:send(tower.id, { op = "reject", phone = phone, reason = "No addresses left" })
    end

    -- Attaching again: the old cell forgets the phone.
    if session.teid then
        self.by_teid[session.teid] = nil
        if session.cell and session.cell ~= tower.id then self:send(session.cell, { op = "release", teid = session.teid }) end
    end
    -- Tunnels' IDs are picked at random, and no two phones share one.
    repeat session.teid = math.random(1, 0x7FFFFFFF) until not self.by_teid[session.teid]
    session.secret, session.phone, session.cell = pending.secret, phone, tower.id
    self.by_teid[session.teid] = session

    self:send(tower.id, {
        op = "context", phone = phone, teid = session.teid, address = session.address,
        key = common.cell_key(self.crypto, session.secret, tower.id),
    })
    self:update_paths()
    self.on_event("attached", pending.sim, address.format(session.address), tower.id)

    -- Anything waiting for this phone can go now.
    local subscriber = self.subscribers[pending.sim]
    for _, message in ipairs(self.messages) do
        if subscriber and message.to == subscriber.number then self:deliver(message, { [message.to] = session }) end
    end
end

function Core:handover(tower, teid, target_id)
    local session = self.by_teid[teid]
    local target = self.towers[target_id]
    if not session or session.cell ~= tower.id or not target or target_id == tower.id then return end
    if self:refuse(session.phone, target_id) then return end

    session.handover = target_id
    self:send(target_id, {
        op = "context", phone = session.phone, teid = teid, address = session.address, handover = true,
        key = common.cell_key(self.crypto, session.secret, target_id),
    })
    self:send(tower.id, { op = "handover_go", teid = teid, target = target_id })
end

function Core:path_switch(tower, teid)
    local session = self.by_teid[teid]
    if not session or session.handover ~= tower.id then return end
    local old = session.cell
    session.cell, session.handover = tower.id, nil
    self:send(old, { op = "release", teid = teid })
    self:update_paths()
    self.on_event("handover", session.sim, old, tower.id)
end

-- A packet for a phone: send it down the tunnel to its cell.
function Core:downlink(packet, next_hop)
    local session = self.by_address[next_hop]
    local tower = session and session.teid and self.towers[session.cell]
    if not tower then return end
    local sealed = tower.sealer:seal({ teid = session.teid, packet = codec.encode(packet) })
    if sealed then
        local ok, err = self.stack:udp_send(self.socket, tower.address, common.CELL_TUNNEL_PORT, sealed)
        if not ok then self.stack.log("Core couldn't tunnel a packet to cell #" .. tower.id .. ": " .. tostring(err)) end
    end
end

-- A packet from a phone, up a tunnel from its cell.
function Core:uplink(data, from)
    for _, tower in pairs(self.towers) do
        if tower.address == from then
            local inner = tower.sealer:open(data)
            local session = type(inner) == "table" and self.by_teid[inner.teid]
            local packet = session and session.cell == tower.id and type(inner.packet) == "string" and codec.decode(inner.packet)
            -- A phone may only send from its own address.
            if type(packet) == "table" and packet.src == session.address then self.stack:inject("cellular", packet) end
            return
        end
    end
end

--- Describe the phones with sessions.
--
-- @treturn { table... } Each phone's SIM key, address and cell, and whether it's attached now.
function Core:info()
    local result = {}
    for sim, session in pairs(self.sessions) do
        result[#result + 1] = {
            sim = sim, address = address.format(session.address), cell = session.cell,
            attached = session.teid ~= nil and self.towers[session.cell] ~= nil,
        }
    end
    table.sort(result, function(a, b) return a.address < b.address end)
    return result
end

return {
    new = new,
    PROLOGUE = PROLOGUE,
    ACTIVATE_PROLOGUE = ACTIVATE_PROLOGUE,
}
