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

Roaming: a core can carry the phones of another network (a partner) at its own cells. To the phones' own core (their
home), the core carrying them (the visited one) is one big cell: it passes on their handshakes, which only the home core
can answer, and their packets go through a tunnel to the home core's gateway, so a roaming phone keeps its address.
`add_tower` takes a visited core at the home core, and `add_partner` a home core at the visited one.

A partner may be one the home network's phones treat as home (like an equivalent network in LTE): for national roaming
between two operators, or for a network which has a core but no cells of its own (a full MVNO), whose phones only ever
use partners' cells. Phones which may not roam may use those. Phones activate through a partner's cell too, where their
own network has none.

Messages between networks: each network may have a number prefix, and cores of networks which agree to (peers) pass
messages between their phones, over a secure connection between them, apart from any roaming agreement. A number of
another network's phone is that network's prefix followed by the number there (`6660042`); our own network's numbers
may be written that way too. A number which is no subscriber's, and starts with no prefix we know, isn't reachable.

A message for another network goes to its core, which says whether it has taken it (or why not), and the phone hears
that. If that core can't be reached, or doesn't answer soon, we keep the message, tell the phone we have it, and send it
again until that core takes it: if it then refuses it, or never takes it, the sender gets a message saying so. The other
network's phone sees the message from our prefix and the sender's number, so an answer finds its way back. `add_peer`
takes a connection to another network's core.

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

-- How many phones of other networks may be attached here, or attaching, at once.
local MAX_VISITORS, MAX_ROAM_PENDING = 256, 256

-- How long another network's core has to say whether it has taken a message before the phone is told we have it, and
-- how often to send it again until that core does, in seconds.
local PEER_TIMEOUT, PEER_RETRY = 20, 30

-- How many messages may wait for other networks' cores, in all, and how many messages from each other network's core
-- to remember, to tell when one comes twice.
local MAX_HELD, MAX_PEER_SEEN = 1000, 256

-- What a phone's message is while another network's core hasn't said whether it has taken it.
local PENDING = {}

local is_id = common.is_id

local Core = {}
Core.__index = Core

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

--[[- Start a cellular core on a network stack.

@tparam {
    stack = table, crypto = table, network = string,
    operator = { public = string, exchange = function(public:string):string }, signing = string,
    prefix = string, subscribers = table, secret? = string, tunnel_key? = function(cell:number):string,
    codes? = table, epoch = function():number, number_prefix? = string,
    on_event? = function(event:string, ...:any),
} options The stack (with forwarding on, so phones' packets reach the network); the `crypto` API; the network's name;
the operator's X25519 key, and its Ed25519 signing key's public half (which phones check cells' certificates with); the
operator's network for phones' addresses (such as `"10.64.0.0/16"`), whose first address the gateway takes; the
subscribers, by SIM key (hexadecimal) to `{ id, number, barred? }`; a secret only the core knows, for tunnel keys (or a
function giving a cell's tunnel key, so the secret can stay in the enclave); activation codes, by their first group, as
`add_code` makes them; the time, as `os.epoch("utc")` gives; the network's number prefix, which other networks'
phones reach ours by, if it has one; and a function told about attaches, handovers and so on, for logging and saving.
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
        -- Roaming. At home: the networks whose cells our phones may use, by name, to their signing keys. Visited:
        -- the networks whose phones we carry; those phones, by our tunnel ID for them, by their network and its
        -- tunnel ID, and by network and phone; and phones still attaching, by cell and phone, and network and phone.
        partner_keys = {}, partners = {}, visitors = {}, visitor_count = 0, visitors_by_home = {}, visitors_by_phone = {},
        roam_pending = {}, roam_pending_count = 0,
        -- Messages between networks: our number prefix; the networks we exchange messages with, by name (each with
        -- its number prefix and the connections to its core, if any); and messages for them which their cores haven't
        -- taken yet, by the ID we gave them.
        number_prefix = options.number_prefix, peers = {}, held = {}, held_count = 0,
    }, Core)

    -- The gateway: everything for phones goes down their tunnels.
    local stack = self.stack
    stack:add_virtual_interface("cellular", "gateway", function(packet, next_hop) self:downlink(packet, next_hop) end)
    stack:set_address("cellular", self.network_address + 1, prefix)

    -- Tunnels carry phones' packets whole, so need more room than programs' datagrams.
    self.socket = assert(stack:udp_open(common.TUNNEL_PORT, function(data, from) self:uplink(data, from) end, common.TUNNEL_LIMITS))
    -- Packets for other networks' phones here, from their own cores.
    self.roam_socket = assert(stack:udp_open(common.ROAM_TUNNEL_PORT, function(data, from) self:roam_downlink(data, from) end, common.TUNNEL_LIMITS))
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

The core of a network which carries our phones (a roaming partner) is added the same way: to us it's one big cell,
which says which of its own cells each phone is at.

@tparam number id The cell's computer ID.
@tparam number cell_address The cell's address, for its tunnel.
@tparam function(message:table) send Sends a control message to the cell.
@tparam[opt] string partner For another network's core, that network's name.
@treturn string The key for the cell's tunnel.
]]
function Core:add_tower(id, cell_address, send, partner)
    local key = self.make_tunnel_key(id)
    self.towers[id] = {
        id = id, address = cell_address, send = send, partner = partner,
        port = partner and common.ROAM_TUNNEL_PORT or common.CELL_TUNNEL_PORT,
        sealer = common.new_sealer(self.crypto, key, common.DOWNLINK, common.UPLINK),
    }
    self:update_paths()
    return key
end

--[[- Set the networks whose cells our phones may use: our roaming partners. Phones are told when they attach (and when
they're activated), and only believe cells with a certificate from one of these keys.

@tparam { [string] = { signing = string, home? = boolean } } partners Each network's name, its operator's Ed25519
signing key, and whether our phones treat it as home.
]]
function Core:set_partner_keys(partners)
    self.partner_keys = partners
end

-- The partners, as phones are told of them: each network's name and signing key, and whether it's as good as home.
function Core:partner_list()
    local partners = {}
    for network, partner in pairs(self.partner_keys) do
        partners[#partners + 1] = { network = network, signing = partner.signing, home = partner.home == true or nil }
    end
    table.sort(partners, function(a, b) return a.network < b.network end)
    return partners
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
    self:detach(sim)
end

--[[- Forget a phone's session: its cell forgets it, and it attaches again if it may. A subscriber who has been barred
is refused when their phone tries.

@tparam string sim The subscriber's SIM key, as hexadecimal digits.
]]
function Core:detach(sim)
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
    for _, visitor in pairs(self.visitors) do self:send(visitor.cell, { op = "release", teid = visitor.teid }) end
    self.partners, self.visitors, self.visitor_count, self.visitors_by_home, self.visitors_by_phone = {}, {}, 0, {}, {}
    self.roam_pending, self.roam_pending_count = {}, 0
    self.peers, self.held, self.held_count = {}, {}, 0
    self.stack:cancel(self.retry_timer)
    self.stack:udp_close(self.socket)
    self.stack:udp_close(self.roam_socket)
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
    -- A phone of another network at one of our cells: its own network's core decides.
    if not tower.partner and self:carry(tower, message) then return end

    if op == "attach" and is_id(message.phone) and type(message.handshake) == "string" then
        self:attach(tower, message.phone, message.handshake, message.cell)
    elseif op == "attach_complete" and is_id(message.phone) then
        self:attach_complete(tower, message.phone, message.data)
    elseif op == "handover" and is_id(message.teid) and is_id(message.target) then
        self:handover(tower, message.teid, message.target)
    elseif op == "path_switch" and is_id(message.teid) then
        self:path_switch(tower, message.teid, message.cell)
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
        partners = self:partner_list(),
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

    -- The phone sends a message until we say we have it, so it may come more than once. While another network's core
    -- hasn't answered for it, there's nothing to say yet.
    session.sent = session.sent or { order = {} }
    local sent = session.sent
    if sent[id] == PENDING then return end
    if sent[id] ~= nil then return self:sms_sent(session, id, sent[id] == true, sent[id] ~= true and sent[id] or nil) end
    sent[id] = PENDING
    sent.order[#sent.order + 1] = id
    if #sent.order > MAX_SENT then sent[table.remove(sent.order, 1)] = nil end

    local network, number = self:find_number(to)
    if network == false then return self:message_done(session, id, false, "Destination not reachable") end
    if network then return self:send_to_peer(session, sender, id, network, number, text) end
    local message, reason = self:keep_message(sender.number, number, text, to)
    self:message_done(session, id, message ~= nil, reason)
    if message then self:deliver(message) end
end

-- Say what became of a message a phone sent, and remember it, as the phone may send it again.
function Core:message_done(session, id, ok, reason)
    local sent = session.sent
    if sent and sent[id] == PENDING then sent[id] = ok or reason end
    self:sms_sent(session, id, ok, reason)
end

-- Whether one of our subscribers has a number.
function Core:has_number(number)
    for _, subscriber in pairs(self.subscribers) do
        if subscriber.number == number then return true end
    end
    return false
end

--[[ Find which network a number is: ours (`nil`, and the number here), another's (its name, and the number there), or
none we can reach (`false`).

A number is ours if one of our subscribers has it. Otherwise it's a network's number prefix followed by the number
there: ours, or that of a network we exchange messages with. The longest prefix which fits wins. A network with no
prefix, which exchanges messages with nobody, takes every number for one of its own.
]]
function Core:find_number(to)
    if self:has_number(to) then return nil, to end
    local network, length = nil, 0
    local own = self.number_prefix
    if own and to:sub(1, #own) == own then length = #own end
    for name, peer in pairs(self.peers) do
        if #peer.prefix > length and to:sub(1, #peer.prefix) == peer.prefix then network, length = name, #peer.prefix end
    end
    if length > 0 then return network, to:sub(length + 1) end
    if not own and next(self.peers) == nil then return nil, to end
    return false
end

--[[ Keep a message for one of our subscribers, until their phone is attached and says it has it.

@treturn[1] table The message, to deliver.
@treturn[2] nil If it can't be kept.
@treturn[2] string Why not, naming the number as it was written (`shown`).
]]
function Core:keep_message(from, to, text, shown)
    if not self:has_number(to) then return nil, "Nobody has the number " .. shown end
    self:expire_messages()
    local waiting = 0
    for _, message in ipairs(self.messages) do
        if message.to == to then waiting = waiting + 1 end
    end
    if waiting >= MAX_MAILBOX or #self.messages >= MAX_MESSAGES then return nil, "Too many messages are waiting for " .. shown end

    self.next_message = self.next_message + 1
    local message = { id = self.next_message, from = from, to = to, text = text, expires = self.epoch() + MESSAGE_LIFETIME }
    self.messages[#self.messages + 1] = message
    self.on_event("message", from, to)
    return message
end

-- Pass a message on to another network's core, keeping it until that core takes it. The phone hears how it went once
-- that core says, or, if it can't be reached or doesn't say soon, that we have the message.
function Core:send_to_peer(session, sender, id, network, number, text)
    if not self.number_prefix then
        return self:message_done(session, id, false, "This network has no number prefix, so can't reach others")
    elseif self.held_count >= MAX_HELD then
        return self:message_done(session, id, false, "Too many messages are waiting for other networks")
    end
    local prefix = self.peers[network].prefix
    self.next_message = self.next_message + 1
    local held = {
        id = self.next_message, network = network, sim = session.sim, phone_message = id, sender = sender.number,
        from = self.number_prefix .. sender.number, to = number, shown = prefix .. number, text = text,
        since = self.stack.clock(), expires = self.epoch() + MESSAGE_LIFETIME,
    }
    self.held[held.id] = held
    self.held_count = self.held_count + 1
    self.on_event("message", sender.number, held.shown)
    -- Its core isn't connected: we have the message, and send it once it is.
    if not self:pass_on(held) then self:message_held(held) end
end

-- Send a message to its network's core, if that's connected. Returns whether it was sent.
function Core:pass_on(held)
    local peer = self.peers[held.network]
    local send = peer and peer.links[#peer.links]
    if not send then return false end
    held.sent = self.stack.clock()
    send({ op = "sms", id = held.id, from = held.from, to = held.to, text = held.text })
    return true
end

-- Tell a phone we have its message for another network, which we send when we can.
function Core:message_held(held)
    if held.told then return end
    held.told = true
    local session = self.sessions[held.sim]
    if session then self:message_done(session, held.phone_message, true) end
end

-- What became of a message for another network: tell its sender. If their phone was told we had it, and it wasn't
-- delivered after all, they get a message from us saying why.
function Core:release(held, ok, reason)
    if self.held[held.id] ~= held then return end
    self.held[held.id] = nil
    self.held_count = self.held_count - 1
    if not held.told then
        local session = self.sessions[held.sim]
        if session then self:message_done(session, held.phone_message, ok, reason) end
    elseif not ok then
        local notice = ("Not delivered to %s: %s"):format(held.shown, reason)
        local message = self:keep_message(self.network, held.sender, notice:sub(1, 1000), held.sender)
        if message then self:deliver(message) end
    end
end

-- Messages for other networks: send them again now and then until their cores take them, tell senders who have waited
-- a while that we have theirs, and give up on those kept too long.
function Core:retry_held()
    local now, epoch = self.stack.clock(), self.epoch()
    for _, held in pairs(self.held) do
        if held.expires <= epoch then
            self:release(held, false, ("%s couldn't be reached"):format(held.network))
        else
            if not held.told and now - held.since >= PEER_TIMEOUT then self:message_held(held) end
            if not held.sent or now - held.sent >= PEER_RETRY then self:pass_on(held) end
        end
    end
end

--[[- Describe the messages waiting for other networks' cores.

@treturn { [string] = number } How many wait for each network.
]]
function Core:held_info()
    local result = {}
    for _, held in pairs(self.held) do result[held.network] = (result[held.network] or 0) + 1 end
    return result
end

--[[- Set our number prefix: other networks' phones reach ours at the prefix followed by their number. Networks we
exchange messages with heard the old one when they connected, so connect to them again.

@tparam string|nil prefix The prefix, digits only, or `nil` for none.
]]
function Core:set_number_prefix(prefix)
    self.number_prefix = prefix
end

--[[- Exchange messages with another network's phones. Messages for its numbers are kept until its core is
connected.

@tparam string network The other network's name.
@tparam string prefix Its number prefix.
]]
function Core:know_peer(network, prefix)
    local peer = self.peers[network]
    if not peer then
        peer = { links = {} }
        self.peers[network] = peer
    end
    peer.prefix = prefix
end

--[[- Exchange messages with another network's phones, over a connection to its core. There may be more than one
connection (each core may have connected to the other): messages go over the newest. Messages kept for its phones go
now.

@tparam string network The other network's name.
@tparam string prefix Its number prefix.
@tparam function(message:table) send Sends its core a message.
]]
function Core:add_peer(network, prefix, send)
    self:know_peer(network, prefix)
    local links = self.peers[network].links
    links[#links + 1] = send
    for _, held in pairs(self.held) do
        if held.network == network then self:pass_on(held) end
    end
end

--[[- Stop exchanging messages with another network. Its numbers can't be reached any more, and the senders of messages
kept for it are told they weren't delivered.

@tparam string network The other network's name.
]]
function Core:forget_peer(network)
    self.peers[network] = nil
    for _, held in pairs(self.held) do
        if held.network == network then self:release(held, false, ("%s is no longer reachable"):format(network)) end
    end
end

--[[- Forget a connection to another network's core, once it has gone. While there are none, messages for its phones
are kept until there is one.

@tparam string network The other network's name.
@tparam function send The function [`Core:add_peer`] was given.
]]
function Core:remove_peer(network, send)
    local peer = self.peers[network]
    if not peer then return end
    for i, link in ipairs(peer.links) do
        if link == send then
            table.remove(peer.links, i)
            break
        end
    end
end

--[[- Handle a message from the core of a network we exchange messages with: a message for one of our phones, or
whether one we passed on was taken.

@tparam string network The other network's name.
@param message The message.
@tparam function(message:table) send Sends that core a message, over the connection this came on.
]]
function Core:peer_control(network, message, send)
    local peer = self.peers[network]
    if not peer or type(message) ~= "table" or not is_id(message.id) then return end
    if message.op == "sms" then
        local id, from, to, text = message.id, message.from, message.to, message.text
        local function reply(ok, reason) send({ op = "sms_reply", id = id, ok = ok, error = reason }) end
        -- That core sends a message until we answer, so it may come more than once.
        local seen = peer.seen
        if not seen then
            seen = { order = {} }
            peer.seen = seen
        end
        if seen[id] ~= nil then return reply(seen[id] == true, seen[id] ~= true and seen[id] or nil) end

        local ok, reason
        -- A network only speaks for its own phones.
        if type(from) ~= "string" or #from > 32 or self:find_number(from) ~= network
            or type(to) ~= "string" or #to < 1 or #to > 32 or type(text) ~= "string" or #text > 1000 then
            ok, reason = false, "That message can't be sent"
        end
        local kept
        if ok == nil then
            kept, reason = self:keep_message(from, to, text, (self.number_prefix or "") .. to)
            ok = kept ~= nil
        end
        seen[id] = ok or reason
        seen.order[#seen.order + 1] = id
        if #seen.order > MAX_PEER_SEEN then seen[table.remove(seen.order, 1)] = nil end
        reply(ok, reason)
        if kept then self:deliver(kept) end
    elseif message.op == "sms_reply" then
        local held = self.held[message.id]
        if not held or held.network ~= network then return end
        local ok = message.ok == true
        self:release(held, ok, not ok and (type(message.error) == "string" and message.error:sub(1, 100) or "Not delivered") or nil)
    end
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
    self:retry_held()
    if not self.messages[1] then return end
    self:expire_messages()
    local sessions = self:sessions_by_number()
    for _, message in ipairs(self.messages) do self:deliver(message, sessions) end
end

function Core:attach(tower, phone, message, visited_cell)
    if tower.partner then
        -- Roaming: the other network's core says which of its cells the phone is at.
        if not is_id(visited_cell) then return end
    else
        -- A relay's phone can't reach us through a cell which reaches us through the relay, or is too far away.
        visited_cell = nil
        local refused = self:refuse(phone, tower.id)
        if refused then return self:send(tower.id, { op = "reject", phone = phone, reason = refused }) end
    end
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
    -- A partner our phones treat as home isn't roaming.
    local partner = tower.partner and self.partner_keys[tower.partner]
    if tower.partner and subscriber.roaming == false and not (partner and partner.home) then
        return self:send(tower.id, { op = "reject", phone = phone, reason = "This subscription doesn't include roaming" })
    end

    -- Tell the phone which other networks it may use, and the keys their cells are certified with. Only the phone
    -- can read this, and only we could have written it.
    local reply = handshake:write(codec.encode({
        v = 1, id = subscriber.id, number = subscriber.number, partners = self:partner_list(), numbers = self.number_prefix,
    }))
    if not reply then return end
    local _, receive = handshake:split()
    -- Nothing is given out until the phone confirms, as the first message alone could be a recording.
    local key = tower.id .. ":" .. phone
    local pending = { sim = sim, receive = receive, secret = handshake.ck, phone = phone, cell = visited_cell }
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
    session.secret, session.phone, session.cell, session.handover = pending.secret, phone, tower.id, nil
    -- When roaming, the cell of the other network the phone is at: its key with the phone is for that cell.
    session.visited_cell = pending.cell
    self.by_teid[session.teid] = session

    self:send(tower.id, {
        op = "context", phone = phone, teid = session.teid, address = session.address, cell = pending.cell,
        key = common.cell_key(self.crypto, session.secret, pending.cell or tower.id),
    })
    self:update_paths()
    self.on_event("attached", pending.sim, address.format(session.address), pending.cell or tower.id, tower.partner)

    -- Anything waiting for this phone can go now.
    local subscriber = self.subscribers[pending.sim]
    for _, message in ipairs(self.messages) do
        if subscriber and message.to == subscriber.number then self:deliver(message, { [message.to] = session }) end
    end
end

function Core:handover(tower, teid, target_id)
    local session = self.by_teid[teid]
    if not session or session.cell ~= tower.id then return end
    if tower.partner then
        -- Between two cells of the network a phone is roaming on. That network's core does the rest: all it needs
        -- from us is the key the phone will share with the new cell.
        self:send(tower.id, {
            op = "context", phone = session.phone, teid = teid, address = session.address, handover = true, cell = target_id,
            key = common.cell_key(self.crypto, session.secret, target_id),
        })
        return self:send(tower.id, { op = "handover_go", teid = teid, target = target_id })
    end
    local target = self.towers[target_id]
    -- Phones don't hand over to another network's cells: they attach again there.
    if not target or target.partner or target_id == tower.id then return end
    if self:refuse(session.phone, target_id) then return end

    session.handover = target_id
    self:send(target_id, {
        op = "context", phone = session.phone, teid = teid, address = session.address, handover = true,
        key = common.cell_key(self.crypto, session.secret, target_id),
    })
    self:send(tower.id, { op = "handover_go", teid = teid, target = target_id })
end

function Core:path_switch(tower, teid, visited_cell)
    local session = self.by_teid[teid]
    if tower.partner then
        -- The network a phone is roaming on has moved it to another of its cells.
        if session and session.cell == tower.id and is_id(visited_cell) then
            local old = session.visited_cell
            session.visited_cell = visited_cell
            self.on_event("handover", session.sim, old, visited_cell)
        end
        return
    end
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
        local ok, err = self.stack:udp_send(self.socket, tower.address, tower.port, sealed)
        if not ok then self.stack.log("Core couldn't tunnel a packet to cell #" .. tower.id .. ": " .. tostring(err)) end
    end
end

-- A packet from a phone, up a tunnel from its cell.
function Core:uplink(data, from)
    for _, tower in pairs(self.towers) do
        if tower.address == from then
            local inner = tower.sealer:open(data)
            if type(inner) ~= "table" or type(inner.packet) ~= "string" then return end
            local session = self.by_teid[inner.teid]
            if not session then
                -- Another network's phone, at one of our cells: on to its own core's gateway.
                local visitor = not tower.partner and self.visitors[inner.teid]
                if visitor and visitor.cell == tower.id then self:roam_uplink(visitor, inner.packet) end
                return
            end
            local packet = session.cell == tower.id and codec.decode(inner.packet)
            -- A phone may only send from its own address.
            if type(packet) == "table" and packet.src == session.address then self.stack:inject("cellular", packet) end
            return
        end
    end
end

--[[- Carry another network's phones: add its core, which we have connected to. To that core, we're one big cell (see
[`Core:add_tower`]).

@tparam string network The other network's name.
@tparam { address = number, tunnel_key = string, send = function(message:table) } options The other core's address;
the key it gave us for the tunnel to it; and a way to send it control messages.
]]
function Core:add_partner(network, options)
    self:remove_partner(network)
    self.partners[network] = {
        network = network, address = options.address, send = options.send,
        sealer = common.new_sealer(self.crypto, options.tunnel_key, common.UPLINK, common.DOWNLINK),
    }
end

--[[- Stop carrying another network's phones: those here lose service until they find another cell.

@tparam string network The other network's name.
@tparam[opt] function send The function [`Core:add_partner`] was given. If the network has been added again since,
with another, the new one is kept.
]]
function Core:remove_partner(network, send)
    local partner = self.partners[network]
    if not partner or (send ~= nil and partner.send ~= send) then return end
    self.partners[network] = nil
    local gone = {}
    for _, visitor in pairs(self.visitors) do
        if visitor.network == network then gone[#gone + 1] = visitor end
    end
    for _, visitor in ipairs(gone) do self:forget_visitor(visitor) end
end

-- Forget another network's phone, telling the cells which know of it.
function Core:forget_visitor(visitor)
    if self.visitors[visitor.teid] ~= visitor then return end
    self.visitors[visitor.teid] = nil
    self.visitor_count = self.visitor_count - 1
    local key = visitor.network .. ":" .. visitor.home_teid
    if self.visitors_by_home[key] == visitor then self.visitors_by_home[key] = nil end
    key = visitor.network .. ":" .. visitor.phone
    if self.visitors_by_phone[key] == visitor then self.visitors_by_phone[key] = nil end
    self:send(visitor.cell, { op = "release", teid = visitor.teid })
    if visitor.handover then self:send(visitor.handover, { op = "release", teid = visitor.teid }) end
end

-- Remember which cell a phone of another network is attaching at, for a moment, so its core's answers find it.
function Core:remember_roamer(network, phone, cell)
    local now = self.stack.clock()
    if self.roam_pending_count >= MAX_ROAM_PENDING then
        for key, pending in pairs(self.roam_pending) do
            if pending.expires <= now then
                self.roam_pending[key] = nil
                self.roam_pending_count = self.roam_pending_count - 1
            end
        end
        if self.roam_pending_count >= MAX_ROAM_PENDING then return false end
    end
    local pending = { network = network, phone = phone, cell = cell, expires = now + ATTACH_TIMEOUT }
    for _, key in ipairs { network .. ":" .. phone, cell .. "@" .. phone } do
        if not self.roam_pending[key] then self.roam_pending_count = self.roam_pending_count + 1 end
        self.roam_pending[key] = pending
    end
    return true
end

function Core:roamer(key)
    local pending = self.roam_pending[key]
    if pending and pending.expires > self.stack.clock() then return pending end
end

--[[- Handle a control message from one of our cells which is about another network's phone, by passing it to that
network's core.

@tparam table tower The cell.
@tparam table message The message.
@treturn boolean Whether it was about another network's phone.
]]
function Core:carry(tower, message)
    local op = message.op
    if op == "attach" then
        local network = message.network
        if network == nil or network == self.network then return false end
        if not is_id(message.phone) or type(message.handshake) ~= "string" then return true end
        local partner = common.is_network(network) and self.partners[network]
        if not partner then
            self:send(tower.id, { op = "reject", phone = message.phone, reason = ("%s doesn't carry phones of that network"):format(self.network) })
        elseif self:remember_roamer(network, message.phone, tower.id) then
            partner.send({ op = "attach", phone = message.phone, handshake = message.handshake, cell = tower.id })
        end
        return true
    elseif op == "attach_complete" then
        if not is_id(message.phone) or type(message.data) ~= "string" then return false end
        local pending = self:roamer(tower.id .. "@" .. message.phone)
        local partner = pending and self.partners[pending.network]
        if not partner then return false end
        partner.send({ op = "attach_complete", phone = message.phone, data = message.data, cell = tower.id })
        -- Unless one of our own phones is attaching under the same ID, that was all.
        return self.pending[tower.id .. ":" .. message.phone] == nil
    elseif op == "activate" then
        -- A phone of a network with no cells here (or none at all) activating: its own core decides, as for attaches.
        local network = message.network
        if network == nil or network == self.network then return false end
        if not is_id(message.phone) or type(message.tag) ~= "string" or type(message.handshake) ~= "string" then return true end
        local partner = common.is_network(network) and self.partners[network]
        if not partner then
            self:send(tower.id, { op = "reject", phone = message.phone, reason = ("%s doesn't carry phones of that network"):format(self.network) })
        elseif self:remember_roamer(network, message.phone, tower.id) then
            partner.send({ op = "activate", phone = message.phone, tag = message.tag, handshake = message.handshake, cell = tower.id })
        end
        return true
    elseif op == "activate_finish" then
        if not is_id(message.phone) or type(message.handshake) ~= "string" then return false end
        local pending = self:roamer(tower.id .. "@" .. message.phone)
        local partner = pending and self.partners[pending.network]
        if not partner then return false end
        partner.send({ op = "activate_finish", phone = message.phone, handshake = message.handshake, cell = tower.id })
        -- Unless one of our own phones is activating under the same ID, that was all.
        return self.activating[tower.id .. ":" .. message.phone] == nil
    end

    -- Everything else is by tunnel ID: ours for a phone of ours, or one we made up for a visitor.
    local visitor = is_id(message.teid) and self.visitors[message.teid]
    if not visitor then return false end
    local partner = self.partners[visitor.network]
    if not partner then return true end
    if op == "path_switch" then
        if visitor.handover ~= tower.id then return true end
        local old = visitor.cell
        visitor.cell, visitor.handover = tower.id, nil
        self:send(old, { op = "release", teid = visitor.teid })
        partner.send({ op = "path_switch", teid = visitor.home_teid, cell = tower.id })
    elseif visitor.cell ~= tower.id then
        return true
    elseif op == "handover" then
        -- To another of our cells. The phone's own core makes the key for it.
        local target = is_id(message.target) and self.towers[message.target]
        if target and not target.partner and target.id ~= tower.id then
            partner.send({ op = "handover", teid = visitor.home_teid, target = target.id })
        end
    elseif op == "sms" then
        partner.send({ op = "sms", teid = visitor.home_teid, id = message.id, to = message.to, text = message.text })
    elseif op == "sms_ack" then
        partner.send({ op = "sms_ack", teid = visitor.home_teid, id = message.id })
    end
    return true
end

--[[- Handle a control message from the core of a network whose phones we carry. It sends us what it would send a cell,
and we pass it on to the cell the phone is at.

@tparam string network The other network's name.
@param message The message.
]]
function Core:partner_control(network, message)
    local partner = self.partners[network]
    if not partner or type(message) ~= "table" then return end
    local op = message.op

    if (op == "attach_reply" or op == "reject" or op == "activate_reply" or op == "activate_accept") and is_id(message.phone) then
        local pending = self:roamer(network .. ":" .. message.phone)
        if pending then
            self:send(pending.cell, {
                op = op, phone = message.phone, handshake = type(message.handshake) == "string" and message.handshake or nil,
                reason = type(message.reason) == "string" and message.reason:sub(1, 100) or nil,
                data = type(message.data) == "string" and message.data or nil,
            })
        end
    elseif op == "context" and is_id(message.phone) and is_id(message.teid) and is_id(message.cell)
        and type(message.key) == "string" and #message.key == 32 then
        local tower = self.towers[message.cell]
        if not tower or tower.partner then return end
        if message.handover then
            -- One of the phones we carry is moving to another of our cells.
            local visitor = self.visitors_by_home[network .. ":" .. message.teid]
            if not visitor or visitor.cell == tower.id then return end
            if visitor.handover and visitor.handover ~= tower.id then self:send(visitor.handover, { op = "release", teid = visitor.teid }) end
            visitor.handover = tower.id
            return self:send(tower.id, {
                op = "context", phone = visitor.phone, teid = visitor.teid, address = message.address, key = message.key,
                handover = true,
            })
        end

        -- A phone has attached. Its core's answer is for the cell we passed its request on from.
        local pending = self:roamer(network .. ":" .. message.phone)
        if not pending or pending.cell ~= tower.id then return end
        local old = self.visitors_by_phone[network .. ":" .. message.phone]
        if old then
            -- Attaching again, at the same cell or another: the cell's new context for the phone replaces the old.
            if old.cell == tower.id then old.cell = nil end
            self:forget_visitor(old)
        end
        if self.visitor_count >= MAX_VISITORS then
            -- Nothing says when a visitor has left for good (it may just have walked out of range), so when there's
            -- no room, the one which attached longest ago makes way. If it's still here, it finds out, and attaches
            -- again.
            local oldest
            for _, other in pairs(self.visitors) do
                if not oldest or other.order < oldest.order then oldest = other end
            end
            self:forget_visitor(oldest)
        end
        self.visitor_order = (self.visitor_order or 0) + 1
        local visitor = {
            network = network, home_teid = message.teid, phone = message.phone, cell = tower.id, address = message.address,
            order = self.visitor_order,
        }
        repeat visitor.teid = math.random(1, 0x7FFFFFFF) until not self.by_teid[visitor.teid] and not self.visitors[visitor.teid]
        self.visitors[visitor.teid] = visitor
        self.visitor_count = self.visitor_count + 1
        self.visitors_by_home[network .. ":" .. visitor.home_teid] = visitor
        self.visitors_by_phone[network .. ":" .. visitor.phone] = visitor
        self:send(tower.id, { op = "context", phone = visitor.phone, teid = visitor.teid, address = message.address, key = message.key })
        self.on_event("visitor", network, tower.id)
    elseif is_id(message.teid) then
        local visitor = self.visitors_by_home[network .. ":" .. message.teid]
        if not visitor then return end
        if op == "release" then
            self:forget_visitor(visitor)
        elseif op == "handover_go" and is_id(message.target) then
            self:send(visitor.cell, { op = "handover_go", teid = visitor.teid, target = message.target })
        elseif op == "sms" then
            self:send(visitor.cell, { op = "sms", teid = visitor.teid, id = message.id, from = message.from, text = message.text })
        elseif op == "sms_sent" then
            self:send(visitor.cell, { op = "sms_sent", teid = visitor.teid, id = message.id, ok = message.ok, error = message.error })
        end
    end
end

-- A packet from another network's phone here: up the tunnel to its own core's gateway.
function Core:roam_uplink(visitor, packet)
    local partner = self.partners[visitor.network]
    if not partner then return end
    local sealed = partner.sealer:seal({ teid = visitor.home_teid, packet = packet })
    if sealed then
        local ok, err = self.stack:udp_send(self.roam_socket, partner.address, common.TUNNEL_PORT, sealed)
        if not ok then self.stack.log(("Core couldn't tunnel a packet to the core of %s: %s"):format(visitor.network, tostring(err))) end
    end
end

-- A packet for another network's phone here, down the tunnel from its own core's gateway: on to its cell.
function Core:roam_downlink(data, from)
    for network, partner in pairs(self.partners) do
        if partner.address == from then
            local inner = partner.sealer:open(data)
            if type(inner) ~= "table" or not is_id(inner.teid) or type(inner.packet) ~= "string" then return end
            local visitor = self.visitors_by_home[network .. ":" .. inner.teid]
            local tower = visitor and self.towers[visitor.cell]
            if not tower then return end
            local sealed = tower.sealer:seal({ teid = visitor.teid, packet = inner.packet })
            if sealed then
                local ok, err = self.stack:udp_send(self.socket, tower.address, tower.port, sealed)
                if not ok then self.stack.log("Core couldn't tunnel a packet to cell #" .. tower.id .. ": " .. tostring(err)) end
            end
            return
        end
    end
end

--- Describe the phones of other networks which are here.
--
-- @treturn { table... } Each phone's network, its address, and the cell it's at.
function Core:visitor_info()
    local result = {}
    for _, visitor in pairs(self.visitors) do
        result[#result + 1] = {
            network = visitor.network, cell = visitor.cell,
            address = type(visitor.address) == "number" and address.is_valid(visitor.address) and address.format(visitor.address) or nil,
        }
    end
    table.sort(result, function(a, b) return a.network < b.network or (a.network == b.network and a.cell < b.cell) end)
    return result
end

--- Describe the phones with sessions.
--
-- @treturn { table... } Each phone's SIM key, address and cell, and whether it's attached now.
function Core:info()
    local result = {}
    for sim, session in pairs(self.sessions) do
        local tower = session.teid and self.towers[session.cell]
        result[#result + 1] = {
            sim = sim, address = address.format(session.address), cell = session.visited_cell or session.cell,
            attached = tower ~= nil, roaming = tower and tower.partner or nil,
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
