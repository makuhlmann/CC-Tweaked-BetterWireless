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

-- How long a phone has to confirm its attach.
local ATTACH_TIMEOUT = 10

local Core = {}
Core.__index = Core

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

--[[- Start a cellular core on a network stack.

@tparam {
    stack = table, crypto = table, network = string,
    operator = { public = string, exchange = function(public:string):string },
    prefix = string, subscribers = table, secret = string,
    on_event? = function(event:string, ...:any),
} options The stack (with forwarding on, so phones' packets reach the network); the `crypto` API; the network's name;
the operator's X25519 key; the operator's network for phones' addresses (such as `"10.64.0.0/16"`), whose first
address the gateway takes; the subscribers, by SIM key (hexadecimal) to `{ id, number, barred? }`; a secret only the core
knows, for tunnel keys; and a function told about attaches and handovers, for logging.
@treturn table The core.
]]
local function new(options)
    local network_address, prefix = address.parse(options.prefix)
    if not network_address or not prefix or prefix > 30 then error("Invalid prefix " .. tostring(options.prefix), 2) end

    local self = setmetatable({
        stack = options.stack, crypto = options.crypto, network = options.network, operator = options.operator,
        subscribers = options.subscribers, secret = options.secret, on_event = options.on_event or function() end,
        network_address = address.network(network_address, prefix), prefix = prefix,
        next_host = 2,
        towers = {}, sessions = {}, by_teid = {}, by_address = {}, pending = {},
    }, Core)

    -- The gateway: everything for phones goes down their tunnels.
    local stack = self.stack
    stack:add_virtual_interface("cellular", "gateway", function(packet, next_hop) self:downlink(packet, next_hop) end)
    stack:set_address("cellular", self.network_address + 1, prefix)

    self.socket = assert(stack:udp_open(common.TUNNEL_PORT, function(data, from) self:uplink(data, from) end))
    return self
end

--[[- Add a cell. Its control messages come to [`Core:control`], and its tunnel is sealed with the key returned.

@tparam number id The cell's computer ID.
@tparam number cell_address The cell's address, for its tunnel.
@tparam function(message:table) send Sends a control message to the cell.
@treturn string The key for the cell's tunnel.
]]
function Core:add_tower(id, cell_address, send)
    local key = common.tunnel_key(self.crypto, self.secret, id)
    self.towers[id] = {
        id = id, address = cell_address, send = send,
        sealer = common.new_sealer(self.crypto, key, common.DOWNLINK, common.UPLINK),
    }
    return key
end

function Core:send(tower_id, message)
    local tower = self.towers[tower_id]
    if tower then tower.send(message) end
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

    if op == "attach" and type(message.phone) == "number" and type(message.handshake) == "string" then
        self:attach(tower, message.phone, message.handshake)
    elseif op == "attach_complete" and type(message.phone) == "number" then
        self:attach_complete(tower, message.phone, message.data)
    elseif op == "handover" and type(message.teid) == "number" and type(message.target) == "number" then
        self:handover(tower, message.teid, message.target)
    elseif op == "path_switch" and type(message.teid) == "number" then
        self:path_switch(tower, message.teid)
    end
end

function Core:attach(tower, phone, message)
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
    self.pending[key] = pending
    self.stack:schedule(ATTACH_TIMEOUT, function()
        if self.pending[key] == pending then self.pending[key] = nil end
    end)
    self:send(tower.id, { op = "attach_reply", phone = phone, handshake = reply })
end

function Core:attach_complete(tower, phone, data)
    local key = tower.id .. ":" .. phone
    local pending = self.pending[key]
    if not pending or type(data) ~= "string" then return end
    local plaintext = pending.receive:decrypt(data)
    local confirm = plaintext and codec.decode(plaintext)
    if type(confirm) ~= "table" or confirm.complete ~= true then return end
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
    session.teid = math.random(1, 0x7FFFFFFF)
    session.secret, session.phone, session.cell = pending.secret, phone, tower.id
    self.by_teid[session.teid] = session

    self:send(tower.id, {
        op = "context", phone = phone, teid = session.teid, address = session.address,
        key = common.cell_key(self.crypto, session.secret, tower.id),
    })
    self.on_event("attached", pending.sim, address.format(session.address), tower.id)
end

function Core:handover(tower, teid, target_id)
    local session = self.by_teid[teid]
    local target = self.towers[target_id]
    if not session or session.cell ~= tower.id or not target or target_id == tower.id then return end

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
    self.on_event("handover", session.sim, old, tower.id)
end

-- A packet for a phone: send it down the tunnel to its cell.
function Core:downlink(packet, next_hop)
    local session = self.by_address[next_hop]
    local tower = session and session.teid and self.towers[session.cell]
    if not tower then return end
    local sealed = tower.sealer:seal({ teid = session.teid, packet = codec.encode(packet) })
    if sealed then self.stack:udp_send(self.socket, tower.address, common.CELL_TUNNEL_PORT, sealed) end
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
-- @treturn { table... } Each phone's SIM key, address and cell.
function Core:info()
    local result = {}
    for sim, session in pairs(self.sessions) do
        result[#result + 1] = { sim = sim, address = address.format(session.address), cell = session.cell }
    end
    table.sort(result, function(a, b) return a.address < b.address end)
    return result
end

return {
    new = new,
    PROLOGUE = PROLOGUE,
}
