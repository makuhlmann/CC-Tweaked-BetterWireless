-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The core of the network stack: interfaces, neighbour discovery, packets and ICMP.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the [`net`] API instead.

A stack has no side effects of its own. It sends frames, reads the time and wakes programs up through functions passed
to [`new`], so tests can connect several stacks together without any modems.

@local
]]

local expect = require "cc.expect".expect
local address = require "cc.net.address"
local link = require "cc.internal.net.link"
local routing = require "cc.internal.net.routing"
local udp = require "cc.internal.net.udp"
local timers = require "cc.internal.net.timers"

--- The version of the frame and packet formats. Frames from other versions are ignored.
local VERSION = 1

--- The ID frames are sent to when they're for every computer on a link.
local BROADCAST_ID = -1

local DEFAULT_TTL = 32

-- Neighbour discovery.
local NEIGHBOUR_LIFETIME = 300
local RESOLVE_INTERVAL = 1
local RESOLVE_ATTEMPTS = 3
local MAX_WAITING = 4

-- How many neighbours an interface remembers, and how many it looks for at once. However many addresses a flood of
-- packets comes from or goes to, it can't use more memory, or send more neighbour discovery broadcasts, than this.
local MAX_NEIGHBOURS = 512
local MAX_RESOLVING = 64

-- How often we may send an error to the same computer, in seconds, and to how many computers in that time.
local ERROR_INTERVAL = 0.5
local MAX_ERROR_TARGETS = 256

-- The most time to live a packet may have. Packets with more, or with a time which isn't a whole number, are dropped:
-- they could go round a routing loop for ever.
local MAX_TTL = 255

-- A computer which has only just taken an address (within this many seconds) gives it up if someone else already has
-- it. One which has had it longer defends it, by telling everyone again, at most once a second.
local PROBATION = 3
local DEFEND_INTERVAL = 1

-- How long an echo request is remembered, in seconds, and how many replies a series of them keeps until they're taken.
local ECHO_LIFETIME, MAX_ECHO_REPLIES = 60, 64

-- How long frame capture lasts unless renewed, in seconds.
local CAPTURE_LIFETIME = 30

-- Routes and the firewall are in their own module (as are datagram sockets and timers).
local INFINITY, usable, is_broadcast = routing.INFINITY, routing.usable, routing.is_broadcast

-- Datagram ports. Ports from 49152 up are handed out to sockets which don't ask for one.
local EPHEMERAL_FIRST = udp.EPHEMERAL_FIRST

-- Channels: low band channels are 0-1023, high band channels are above that. Wired modems use the high band plan,
-- though bands mean nothing to them. Ender modems are radios, with both bands, like wireless ones.
local LOW_UNICAST, LOW_BROADCAST = 1000, 1000
local HIGH_BASE, HIGH_UNICAST, HIGH_BROADCAST = 1024, 60000, 61024

--- Get the channels used by a computer on a band.
--
-- @tparam number id The computer's ID.
-- @tparam string band `"low"` or `"high"`.
-- @treturn number The computer's unicast channel.
-- @treturn number The broadcast channel.
local function channels(id, band)
    if band == "low" then return id % LOW_UNICAST, LOW_BROADCAST end
    return HIGH_BASE + id % HIGH_UNICAST, HIGH_BROADCAST
end

local function band_of(channel)
    return channel < HIGH_BASE and "low" or "high"
end

local ERRORS = {
    unreachable = {
        net = "Network unreachable",
        host = "Host unreachable",
        port = "Port unreachable",
        proto = "Protocol unreachable",
        admin = "Prohibited",
    },
    time_exceeded = "TTL expired",
}

--- Describe an ICMP error message.
--
-- @tparam table message The ICMP message.
-- @treturn string A description of the error.
local function describe_error(message)
    local kind = ERRORS[message.type]
    if type(kind) == "table" then return kind[message.code] or "Unreachable" end
    return kind or "Unknown error"
end

local Stack = {}
Stack.__index = Stack

--[[- Create a new stack.

@tparam {
    id = number,
    clock = function():number,
    transmit = function(modem:string, channel:number, reply:number, frame:table),
    wake = function(event:string, ...:any),
    log? = function(message:string),
} options The computer's ID, a clock in seconds, how to send a frame, how to queue an event, and where to report
errors in timers and handlers.
@treturn table The new stack.
]]
local function new(options)
    expect(1, options, "table")
    local self = setmetatable({
        id = options.id,
        clock = options.clock,
        crypto = options.crypto,
        epoch = options.epoch or function() return options.clock() * 1000 end,
        _transmit = options.transmit,
        wake = options.wake,
        log = options.log or function() end,

        interfaces = {},
        by_modem = {},
        protocols = {},
        error_handlers = {},
        address_lost = {},
        frame_handlers = {},
        unsealed = {},

        next_packet = 0,
        next_echo = 0,
        echoes = {},
        last_error = {},
        last_error_count = 0,
        capture_until = nil,
        wake_pending = false,

        inbox = {},
        delivering = false,

        timers = timers.new(),
        udp = {},
        next_port = EPHEMERAL_FIRST,

        routes = {},
        forwarding = false,
        firewall = nil,
        forwarded = 0,
    }, Stack)

    self.protocols.udp = function(packet, interface) return self:receive_udp(packet, interface) end
    self.error_handlers.udp = function(orig, message, from) return self:udp_error(orig, message, from) end
    return self
end

--- Add an interface.
--
-- @tparam string name The interface's name.
-- @tparam string modem The modem's peripheral name.
-- @tparam string kind `"wired"`, `"wireless"` or `"ender"`.
-- @tparam string band `"low"` or `"high"`.
-- @treturn table The interface. Its `unicast` and `broadcast` channels must be opened on the modem.
function Stack:add_interface(name, modem, kind, band)
    if kind ~= "wireless" and kind ~= "ender" then band = "high" end
    local unicast, broadcast = channels(self.id, band)
    local interface = {
        name = name, modem = modem, kind = kind, band = band,
        unicast = unicast, broadcast = broadcast,
        neighbours = {}, waiting = {}, neighbour_count = 0, waiting_count = 0,
        stats = { frames_in = 0, frames_out = 0, dropped = 0 },
    }
    self.interfaces[name] = interface
    self.by_modem[modem] = self.by_modem[modem] or {}
    self.by_modem[modem][band] = interface
    return interface
end

--[[- Add a virtual interface: one with no modem. Packets it sends go to a function, and packets it receives are given
to [`Stack:inject`]. Point-to-point links which aren't modems, such as a phone's link to its cell, or a gateway's link
to every phone through tunnels, are virtual interfaces.

They don't do neighbour discovery or broadcasts, and routers don't exchange routes over them, though the networks on
them are still advertised elsewhere.

@tparam string name The interface's name.
@tparam string kind What sort of link it is, such as `"cell"`.
@tparam function(packet:table, next_hop:number) send Sends a packet, to the computer with the address `next_hop`.
@treturn table The interface.
]]
function Stack:add_virtual_interface(name, kind, send)
    if self.interfaces[name] then error("There's already an interface named '" .. name .. "'", 2) end
    local interface = {
        name = name, kind = kind, virtual = true, send_packet = send, no_rip = true,
        neighbours = {}, waiting = {}, neighbour_count = 0, waiting_count = 0,
        stats = { frames_in = 0, frames_out = 0, dropped = 0 },
    }
    self.interfaces[name] = interface
    return interface
end

--- Remove an interface by name, such as a virtual one. Its address is no longer ours.
--
-- @tparam string name The interface's name.
function Stack:remove_interface(name)
    local interface = self.interfaces[name]
    if not interface then return end
    self.interfaces[name] = nil
    if interface.modem and self.by_modem[interface.modem] then self.by_modem[interface.modem][interface.band] = nil end
    if interface.address then self:lose_address(interface.address) end
end

--[[- A packet arrived on a virtual interface.

@tparam string name The interface's name.
@param packet The packet.
]]
function Stack:inject(name, packet)
    local interface = self.interfaces[name]
    if not interface then return end
    interface.stats.frames_in = interface.stats.frames_in + 1
    -- There's no neighbour on a virtual link to learn about, so treat it as forwarded.
    self:receive_packet(interface, nil, packet, nil, true)
end

--[[- Handle frames of a new type, such as `"cell"`. Several handlers may share a type (a computer may be a phone and a
cell, say): each is called with every frame, and ignores those which aren't for it.

@tparam string kind The frame type.
@tparam function(interface:table, src:number, body:any, signal:number|nil, dst:number) handler Called with each frame of
this type: the interface it arrived on, the sending computer's ID, the frame's body, the signal strength, and who it was
sent to (our ID, or `-1` for everyone).
@tparam[opt] boolean unsealed Whether frames of this type are sent and accepted unencrypted, even on an encrypted link.
Only for frames which protect themselves.
@treturn function The handler, to stop it with [`Stack:off_frame`].
]]
function Stack:on_frame(kind, handler, unsealed)
    if type(handler) ~= "function" then error("bad argument #2 (function expected)", 2) end
    local handlers = self.frame_handlers[kind]
    if not handlers then
        handlers = {}
        self.frame_handlers[kind] = handlers
    end
    handlers[#handlers + 1] = handler
    if unsealed then self.unsealed[kind] = true end
    return handler
end

--[[- Stop handling frames with a handler given to [`Stack:on_frame`].

@tparam string kind The frame type.
@tparam function handler The handler.
]]
function Stack:off_frame(kind, handler)
    local handlers = self.frame_handlers[kind]
    if not handlers then return end
    for i = #handlers, 1, -1 do
        if handlers[i] == handler then table.remove(handlers, i) end
    end
    if #handlers == 0 then
        self.frame_handlers[kind] = nil
        self.unsealed[kind] = nil
    end
end

--[[- Send a frame of a type handled by [`Stack:on_frame`].

@tparam string name The interface to send on.
@tparam number id The computer to send it to, or `-1` for everyone on the link.
@tparam string kind The frame type.
@param body The frame's body.
@treturn boolean Whether there is such an interface.
]]
function Stack:send_frame(name, id, kind, body)
    local interface = self.interfaces[name]
    if not interface then return false end
    self:transmit(interface, id, kind, body)
    return true
end

--- Remove every interface using a modem.
--
-- @tparam string modem The modem's peripheral name.
-- @treturn { string... } The names of the interfaces removed.
function Stack:remove_modem(modem)
    local removed = {}
    for _, interface in pairs(self.by_modem[modem] or {}) do
        self.interfaces[interface.name] = nil
        removed[#removed + 1] = interface.name
        if interface.address then self:lose_address(interface.address) end
    end
    self.by_modem[modem] = nil
    table.sort(removed)
    return removed
end

--- Set or clear an interface's address.
--
-- @tparam string name The interface's name.
-- @tparam number|nil addr The address, or `nil` to remove it.
-- @tparam[opt] number prefix The prefix length, from 1 to 32.
function Stack:set_address(name, addr, prefix)
    local interface = self.interfaces[name]
    if not interface then error("No interface named '" .. name .. "'", 2) end
    if addr ~= nil and (not address.is_valid(addr) or type(prefix) ~= "number" or prefix % 1 ~= 0 or prefix < 1 or prefix > 32) then
        error(("Invalid address %s/%s"):format(tostring(addr), tostring(prefix)), 2)
    end
    if interface.address and interface.address ~= addr then self:lose_address(interface.address) end

    interface.address, interface.prefix, interface.duplicate = addr, addr and prefix, false
    interface.neighbours, interface.waiting, interface.neighbour_count, interface.waiting_count = {}, {}, 0, 0
    interface.address_since, interface.defended = self.clock(), nil
    if addr then
        interface.network = address.network(addr, prefix)
        interface.broadcast_address = prefix < 31 and address.broadcast(addr, prefix) or nil
        -- Tell everyone, which also finds out whether anyone else already uses this address.
        self:transmit(interface, BROADCAST_ID, "nd", { op = "is", addr = addr })
    else
        interface.network, interface.broadcast_address = nil, nil
    end
end

--- An address is no longer ours: tell anything using it, such as connections.
--
-- @tparam number addr The address.
function Stack:lose_address(addr)
    for _, handler in pairs(self.address_lost) do handler(addr) end
end

--- Send a frame on an interface.
--
-- @tparam table interface The interface.
-- @tparam number id The receiving computer's ID, or `-1` for everyone.
-- @tparam string kind The frame's type.
-- @param body The frame's body.
-- @tparam[opt] boolean forwarded Whether this is a packet from another computer, which we're forwarding.
function Stack:transmit(interface, id, kind, body, forwarded)
    -- Virtual interfaces have no frames: their packets go through send_on.
    if interface.virtual then return end
    local channel = interface.broadcast
    if id ~= BROADCAST_ID then channel = channels(id, interface.band) end
    local frame = { net = VERSION, src = self.id, dst = id, type = kind, body = body, fwd = forwarded or nil }
    if self:capturing() then self.wake("net_frame", "out", interface.name, frame) end

    -- On an encrypted link, everything but who it's from and to is sealed, except frames which protect themselves.
    if interface.link and not self.unsealed[kind] then
        local sealed = link.seal(interface.link, self.id, id, kind, body, forwarded)
        if not sealed then
            interface.stats.dropped = interface.stats.dropped + 1
            return
        end
        frame = { net = VERSION, src = self.id, dst = id, type = "sealed", body = sealed }
    end

    interface.stats.frames_out = interface.stats.frames_out + 1
    self._transmit(interface.modem, channel, interface.unicast, frame)
end

--[[- Encrypt everything sent on an interface, and only accept frames encrypted with the same key.

Set this before the interface's address, so its first announcement is encrypted too.

@tparam string name The interface's name.
@tparam string|false|nil key The key (see `cc.internal.net.link`); `false` to send and accept nothing, for an
interface which should be encrypted but can't be; or `nil` to stop encrypting.
]]
function Stack:set_link_key(name, key)
    local interface = self.interfaces[name]
    if not interface then error("No interface named '" .. name .. "'", 2) end
    if key == nil then
        interface.link = nil
    else
        interface.link = link.new(key and self.crypto, key or nil, self.epoch)
    end
end

--- Whether frames are being captured, for `netdump`.
--
-- @treturn boolean Whether frames are being captured.
function Stack:capturing()
    return self.capture_until ~= nil and self.clock() < self.capture_until
end

--- Start or stop capturing frames. Capture stops by itself after a while unless renewed.
--
-- @tparam boolean enabled Whether to capture frames.
function Stack:set_capture(enabled)
    self.capture_until = enabled and self.clock() + CAPTURE_LIFETIME or nil
end

--- Handle a frame received by a modem.
--
-- @tparam string modem The modem's peripheral name.
-- @tparam number channel The channel the frame arrived on.
-- @param frame The frame.
-- @tparam[opt] number signal The signal strength, for radio messages.
function Stack:receive(modem, channel, frame, signal)
    if type(frame) ~= "table" or frame.net ~= VERSION then return end

    local bands = self.by_modem[modem]
    local interface = bands and bands[band_of(channel)]
    if not interface or (channel ~= interface.unicast and channel ~= interface.broadcast) then return end

    -- Senders are computers' IDs: whole numbers. Anything else (NaN, say) would trip up whatever keeps track of them.
    local src, dst = frame.src, frame.dst
    if type(src) ~= "number" or src % 1 ~= 0 or src < 0 or src > 2 ^ 53 or src == self.id
        or (dst ~= self.id and dst ~= BROADCAST_ID) then
        return
    end

    local kind, body, forwarded = frame.type, frame.body, frame.fwd == true
    if self.unsealed[kind] then
        -- Frames which protect themselves are taken as they are, on any link.
        forwarded = false
    elseif interface.link or kind == "sealed" then
        -- On an encrypted link, only frames sealed with our key count. Elsewhere, sealed frames mean nothing.
        if interface.link and kind == "sealed" then kind, body, forwarded = link.open(interface.link, src, dst, body) else kind = nil end
        if not kind then
            interface.stats.dropped = interface.stats.dropped + 1
            -- Still show it to netdump, so a wrong passphrase doesn't just look like silence.
            if self:capturing() then self.wake("net_frame", "in", interface.name, frame, signal) end
            return
        end
    end

    interface.stats.frames_in = interface.stats.frames_in + 1
    if self:capturing() then
        self.wake("net_frame", "in", interface.name, { net = VERSION, src = src, dst = dst, type = kind, body = body, fwd = forwarded or nil }, signal)
    end

    if kind == "nd" then
        self:receive_nd(interface, src, body, signal)
    elseif kind == "ip" then
        self:receive_packet(interface, src, body, signal, forwarded)
    else
        local handlers = self.frame_handlers[kind]
        if handlers then
            -- A handler may start or stop others, so go through a copy.
            for _, handler in ipairs({ table.unpack(handlers) }) do
                local ok, err = pcall(handler, interface, src, body, signal, dst)
                if not ok then self.log(err) end
            end
        end
    end
end

--- Remember which computer has an address, and send anything that was waiting for it.
--
-- @tparam table interface The interface the computer is on.
-- @tparam number addr The computer's address.
-- @tparam number id The computer's ID.
-- @tparam[opt] number signal The signal strength of its last frame.
function Stack:learn(interface, addr, id, signal)
    if not interface.address or not address.is_valid(addr) or addr == interface.address or addr == interface.broadcast_address
        or not address.contains(interface.network, interface.prefix, addr) then
        return
    end

    local neighbour = interface.neighbours[addr]
    if not neighbour then
        if interface.neighbour_count >= MAX_NEIGHBOURS then self:forget_neighbours(interface) end
        neighbour = {}
        interface.neighbours[addr] = neighbour
        interface.neighbour_count = interface.neighbour_count + 1
    end
    neighbour.id, neighbour.expires = id, self.clock() + NEIGHBOUR_LIFETIME
    if type(signal) == "number" then neighbour.signal = signal end

    local waiting = interface.waiting[addr]
    if waiting then
        interface.waiting[addr] = nil
        interface.waiting_count = interface.waiting_count - 1
        for _, item in ipairs(waiting.packets) do self:transmit(interface, id, "ip", item.packet, item.forwarded) end
    end
end

--- Make room in a full neighbour table: forget neighbours we haven't heard from in a while, and if that's not enough,
-- the quarter we heard from longest ago.
--
-- @tparam table interface The interface.
function Stack:forget_neighbours(interface)
    local now, entries = self.clock(), {}
    for addr, neighbour in pairs(interface.neighbours) do
        if neighbour.expires <= now then
            interface.neighbours[addr] = nil
        else
            entries[#entries + 1] = { addr = addr, expires = neighbour.expires }
        end
    end
    local forget = 0
    if #entries >= MAX_NEIGHBOURS then
        table.sort(entries, function(a, b) return a.expires < b.expires end)
        forget = math.floor(#entries / 4)
        for i = 1, forget do interface.neighbours[entries[i].addr] = nil end
    end
    interface.neighbour_count = #entries - forget
end

function Stack:receive_nd(interface, src, body, signal)
    if type(body) ~= "table" or type(body.addr) ~= "number" then return end
    if type(body.from) == "number" then self:learn(interface, body.from, src, signal) end

    if body.op == "who" then
        if interface.address and body.addr == interface.address and not interface.duplicate then
            self:transmit(interface, src, "nd", { op = "is", addr = interface.address })
        end
    elseif body.op == "is" then
        if interface.address and body.addr == interface.address then
            self:address_conflict(interface)
        else
            self:learn(interface, body.addr, src, signal)
        end
    end
end

--- Someone else says they have one of our addresses. If we only just took it, give it up: it's theirs. If we've had
-- it a while, defend it by telling everyone it's ours, so one computer can't take another's address away. (A computer
-- which took it at the same time as us gives it up too.)
--
-- @tparam table interface The interface with the address.
function Stack:address_conflict(interface)
    if interface.duplicate then return end
    local now = self.clock()
    if now - interface.address_since < PROBATION then
        interface.duplicate = true
        self.wake("net_interface", interface.name, "duplicate")
    elseif not interface.defended or now - interface.defended >= DEFEND_INTERVAL then
        interface.defended = now
        self:transmit(interface, BROADCAST_ID, "nd", { op = "is", addr = interface.address })
        self.wake("net_interface", interface.name, "conflict")
    end
end

--- Whether an address belongs to this computer.
--
-- @tparam number addr The address.
-- @treturn boolean Whether this computer has this address.
function Stack:is_local(addr)
    if address.is_loopback(addr) then return true end
    for _, interface in pairs(self.interfaces) do
        if interface.address == addr then return true end
    end
    return false
end

--- Forward a packet which isn't for us, if we're a router.
--
-- @tparam table packet The packet.
-- @tparam table interface The interface it arrived on.
function Stack:forward(packet, interface)
    -- Link-local addresses only mean something on their own link.
    if address.is_link_local(packet.src) or address.is_link_local(packet.dst) then
        interface.stats.dropped = interface.stats.dropped + 1
        return
    end

    packet.ttl = packet.ttl - 1
    if packet.ttl <= 0 then return self:send_error(packet, "time_exceeded", nil, interface) end
    if not self:firewall_allows(packet, interface) then return self:send_error(packet, "unreachable", "admin", interface) end

    local out, next_hop = self:route(packet.dst)
    if not out then return self:send_error(packet, "unreachable", "net", interface) end
    if packet.dst == out.broadcast_address then
        -- Like real routers, don't broadcast to a whole network for someone on another: it makes floods too easy.
        interface.stats.dropped = interface.stats.dropped + 1
        return
    end

    self.forwarded = self.forwarded + 1
    self:send_on(out, next_hop, packet, true)
end

function Stack:receive_packet(interface, src, packet, signal, forwarded)
    if type(packet) ~= "table" or packet.v ~= VERSION or not address.is_valid(packet.src) or not address.is_valid(packet.dst)
        or type(packet.ttl) ~= "number" or packet.ttl % 1 ~= 0 or packet.ttl < 0 or packet.ttl > MAX_TTL
        or type(packet.proto) ~= "string" then
        return
    end

    -- Every packet tells us where its sender is, which saves asking later. But not packets a router forwarded: their
    -- sender lives somewhere else, even when its address is on this link (as when a router sends a packet back out the
    -- way it came). learn() also only accepts addresses on this interface's own network.
    if not forwarded then self:learn(interface, packet.src, src, signal) end

    if self:is_local(packet.dst) or is_broadcast(interface, packet.dst) then
        self:deliver(packet, interface)
    elseif self.forwarding and packet.src ~= address.ANY and not address.is_loopback(packet.dst) then
        self:forward(packet, interface)
    else
        -- Hosts don't forward packets.
        interface.stats.dropped = interface.stats.dropped + 1
    end
end

--- Deliver a packet to this computer. Packets are queued, so a packet sent to ourselves while handling another doesn't
-- recurse.
--
-- @tparam table packet The packet.
-- @tparam[opt] table interface The interface it arrived on, or `nil` for packets from this computer.
function Stack:deliver(packet, interface)
    local inbox = self.inbox
    inbox[#inbox + 1] = { packet, interface }
    if self.delivering then return end

    -- A handler which fails doesn't stop the packets behind it, as a timer which fails doesn't stop the others.
    self.delivering = true
    while #inbox > 0 do
        local item = table.remove(inbox, 1)
        local ok, err = pcall(self.dispatch, self, item[1], item[2])
        if not ok then self.log(err) end
    end
    self.delivering = false
end

function Stack:dispatch(packet, interface)
    if packet.proto == "icmp" then return self:receive_icmp(packet) end

    local handler = self.protocols[packet.proto]
    if handler then return handler(packet, interface) end

    if not is_broadcast(interface, packet.dst) then self:send_error(packet, "unreachable", "proto") end
end

--[[- Send a packet from this computer.

@tparam number dst Where to send it.
@tparam string proto The protocol, such as `"icmp"`.
@param body The packet's body.
@tparam[opt] { ttl? = number, src? = number } options The time to live, and the source address to use rather than the
outgoing interface's (routers report errors from the interface the packet arrived on).
@treturn[1] table The packet.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not.
]]
function Stack:send(dst, proto, body, options)
    local ttl = options and options.ttl
    if type(ttl) ~= "number" or ttl ~= ttl then ttl = DEFAULT_TTL end
    ttl = math.max(1, math.min(MAX_TTL, math.floor(ttl)))
    self.next_packet = self.next_packet + 1
    local packet = { v = VERSION, dst = dst, ttl = ttl, proto = proto, id = self.next_packet, body = body }

    if self:is_local(dst) then
        packet.src = dst
        self:deliver(packet, nil)
        return packet
    end

    if dst == address.BROADCAST then
        local sent = false
        for _, interface in pairs(self.interfaces) do
            if interface.address and not interface.duplicate then
                local copy = { v = VERSION, src = interface.address, dst = dst, ttl = ttl, proto = proto, id = packet.id, body = body }
                self:transmit(interface, BROADCAST_ID, "ip", copy)
                sent = true
            end
        end
        if not sent then return nil, "No interface has an address" end
        return packet
    end

    local interface, next_hop = self:route(dst)
    if not interface then return nil, "Network unreachable" end

    packet.src = options and options.src or interface.address
    self:send_on(interface, next_hop, packet)
    return packet
end

--- Send a packet to a computer on an interface's network, finding its ID first if need be.
--
-- @tparam table interface The interface.
-- @tparam number next_hop The address of the computer to hand the packet to.
-- @tparam table packet The packet.
-- @tparam[opt] boolean forwarded Whether the packet is from another computer, which we're forwarding.
function Stack:send_on(interface, next_hop, packet, forwarded)
    if interface.virtual then
        if is_broadcast(interface, next_hop) then return end
        interface.stats.frames_out = interface.stats.frames_out + 1
        local ok, err = pcall(interface.send_packet, packet, next_hop)
        if not ok then self.log(err) end
        return
    end

    if is_broadcast(interface, next_hop) then
        return self:transmit(interface, BROADCAST_ID, "ip", packet, forwarded)
    end

    local neighbour = interface.neighbours[next_hop]
    if neighbour and neighbour.expires > self.clock() then
        return self:transmit(interface, neighbour.id, "ip", packet, forwarded)
    end

    local waiting = interface.waiting[next_hop]
    if not waiting then
        if interface.waiting_count >= MAX_RESOLVING then
            -- Looking for too many computers at once, which is probably a flood. Don't add to it.
            interface.stats.dropped = interface.stats.dropped + 1
            return self:send_error(packet, "unreachable", "host")
        end
        waiting = { packets = {}, attempts = 0 }
        interface.waiting[next_hop] = waiting
        interface.waiting_count = interface.waiting_count + 1
        self:resolve(interface, next_hop, waiting)
    end
    if #waiting.packets < MAX_WAITING then waiting.packets[#waiting.packets + 1] = { packet = packet, forwarded = forwarded } end
end

function Stack:resolve(interface, addr, waiting)
    waiting.attempts = waiting.attempts + 1
    waiting.deadline = self.clock() + RESOLVE_INTERVAL
    self:transmit(interface, BROADCAST_ID, "nd", { op = "who", addr = addr, from = interface.address })
    self:request_wakeup()
end

--- Make sure whoever calls [`Stack:tick`] notices a new deadline. The background process may be waiting for something
-- else, so it needs an event. But one is enough until it next calls [`Stack:next_deadline`]: an event for every timer
-- could fill the computer's event queue (which holds 256), and lose other events.
function Stack:request_wakeup()
    if self.wake_pending then return end
    self.wake_pending = true
    self.wake("net_wakeup")
end

--- Get the time at which [`Stack:tick`] next needs calling.
--
-- @treturn number|nil The time, or `nil` if nothing is waiting.
function Stack:next_deadline()
    self.wake_pending = false
    local next_timer = self.timers:peek()
    local deadline = next_timer and next_timer.time
    for _, interface in pairs(self.interfaces) do
        for _, waiting in pairs(interface.waiting) do
            if not deadline or waiting.deadline < deadline then deadline = waiting.deadline end
        end
    end
    return deadline
end

--- Do anything which is due: run timers, retry neighbour discovery, and give up on neighbours which don't answer.
function Stack:tick()
    local now = self.clock()

    -- Timers due at the same time run in the order they were set, so things which were queued stay in order. Those
    -- set while this runs wait for the next tick, even if they're due now.
    local last = self.timers:last_set()
    while true do
        local timer = self.timers:pop_due(now, last)
        if not timer then break end
        local ok, err = pcall(timer.fn)
        if not ok then self.log(err) end
    end
    for _, interface in pairs(self.interfaces) do
        for addr, waiting in pairs(interface.waiting) do
            if waiting.deadline <= now then
                if waiting.attempts >= RESOLVE_ATTEMPTS then
                    interface.waiting[addr] = nil
                    interface.waiting_count = interface.waiting_count - 1
                    for _, item in ipairs(waiting.packets) do self:send_error(item.packet, "unreachable", "host") end
                else
                    self:resolve(interface, addr, waiting)
                end
            end
        end
    end
end

local function summarise(packet)
    local summary = { src = packet.src, dst = packet.dst, proto = packet.proto, id = packet.id }
    local body = packet.body
    if packet.proto == "icmp" and type(body) == "table" and body.type == "echo" then
        summary.echo, summary.seq = body.id, body.seq
    end
    if type(body) == "table" and type(body.sp) == "number" then summary.sp, summary.dp = body.sp, body.dp end
    return summary
end

--- Report that a packet couldn't be delivered, with an ICMP error to its sender.
--
-- @tparam table packet The packet.
-- @tparam string kind `"unreachable"` or `"time_exceeded"`.
-- @tparam[opt] string code The kind of unreachable.
-- @tparam[opt] table interface The interface the packet arrived on, whose address the error comes from.
function Stack:send_error(packet, kind, code, interface)
    -- Never report errors about errors, about broadcasts, or to nobody.
    local body = packet.body
    if packet.proto == "icmp" and (type(body) ~= "table" or (body.type ~= "echo" and body.type ~= "echo_reply")) then return end
    if packet.dst == address.BROADCAST or packet.src == address.ANY or packet.src == address.BROADCAST then return end
    if not self:may_report(packet.src) then return end

    self:send(packet.src, "icmp", { type = kind, code = code, orig = summarise(packet) }, {
        src = interface and interface.address,
    })
end

--- Check whether we may tell a computer that something it sent went wrong (with an ICMP error, or a connection
-- reset), and note that we're doing so. Each computer gets at most one report each half second, and at most 256
-- computers in that time, so a flood of bad packets can't make us send a flood of reports.
--
-- @tparam number addr The computer's address.
-- @treturn boolean Whether to send the report.
function Stack:may_report(addr)
    if self:is_local(addr) then return true end

    local now, last = self.clock(), self.last_error[addr]
    if last and now - last < ERROR_INTERVAL then return false end
    if not last then
        if self.last_error_count >= MAX_ERROR_TARGETS then self:forget_errors(now) end
        -- Still too many: errors are being sent to many computers at once, probably because of a flood.
        if self.last_error_count >= MAX_ERROR_TARGETS then return false end
        self.last_error_count = self.last_error_count + 1
    end
    self.last_error[addr] = now
    return true
end

--- Forget which computers we sent errors to, except in the last half second.
--
-- @tparam number now The time.
function Stack:forget_errors(now)
    local kept, count = {}, 0
    for addr, time in pairs(self.last_error) do
        if now - time < ERROR_INTERVAL then
            kept[addr] = time
            count = count + 1
        end
    end
    self.last_error, self.last_error_count = kept, count
end

function Stack:receive_icmp(packet)
    local message = packet.body
    if type(message) ~= "table" then return end

    if message.type == "echo" then
        if packet.src ~= address.ANY then
            self:send(packet.src, "icmp", { type = "echo_reply", id = message.id, seq = message.seq, data = message.data })
        end
    elseif message.type == "echo_reply" then
        local echo = self.echoes[message.id]
        local series = echo and echo.series
        if series then
            local seq = message.seq
            local sent = type(seq) == "number" and series.sent[seq]
            if sent then
                local duplicate = series.answered[seq] == true
                series.answered[seq] = true
                self:echo_heard(message.id, {
                    seq = seq, rtt = self.clock() - sent, ttl = packet.ttl, from = packet.src, duplicate = duplicate,
                })
            end
        elseif echo and not echo.done then
            echo.done, echo.rtt, echo.ttl, echo.from = true, self.clock() - echo.sent, packet.ttl, packet.src
            self.wake("net_echo", message.id)
        end
    elseif message.type == "unreachable" or message.type == "time_exceeded" then
        local orig = message.orig
        if type(orig) ~= "table" then return end

        local echo = orig.echo and self.echoes[orig.echo]
        if echo and echo.series then
            local seq = orig.seq
            if type(seq) == "number" and echo.series.sent[seq] then
                self:echo_heard(orig.echo, { seq = seq, error = describe_error(message), from = packet.src })
            end
        elseif echo and not echo.done then
            echo.done, echo.error, echo.from = true, describe_error(message), packet.src
            self.wake("net_echo", orig.echo)
        end

        local handler = self.error_handlers[orig.proto]
        if handler then handler(orig, message, packet.src) end
    end
end

--- Run a function after a delay. Timers only run when [`Stack:tick`] is called.
--
-- @tparam number delay The delay, in seconds.
-- @tparam function fn The function to run.
-- @treturn table The timer, to pass to [`Stack:cancel`].
function Stack:schedule(delay, fn)
    if type(delay) ~= "number" or delay ~= delay or delay == math.huge or delay == -math.huge then
        error("Invalid delay " .. tostring(delay), 2)
    end
    local timer = self.timers:add(self.clock() + math.max(0, delay), fn)
    self:request_wakeup()
    return timer
end

--- Count the timers waiting to run.
--
-- @treturn number How many.
function Stack:timer_count()
    return self.timers:count()
end

--- Cancel a timer.
--
-- @tparam table|nil timer The timer, or `nil` to do nothing.
function Stack:cancel(timer)
    if timer then self.timers:cancel(timer) end
end

--[[- Send a packet to everyone on one interface's link. Unlike [`Stack:send`], this works on interfaces without an
address, for instance to ask for one.

@tparam string name The interface's name.
@tparam string proto The protocol.
@param body The packet's body.
@treturn boolean Whether there is such an interface.
]]
function Stack:send_broadcast(name, proto, body)
    local interface = self.interfaces[name]
    if not interface then return false end

    self.next_packet = self.next_packet + 1
    self:transmit(interface, BROADCAST_ID, "ip", {
        v = VERSION, src = interface.address or address.ANY, dst = address.BROADCAST, ttl = DEFAULT_TTL,
        proto = proto, id = self.next_packet, body = body,
    })
    return true
end

--[[- Send an echo request (a ping).

When the reply (or an error) arrives, a `net_echo` event is queued with the request's ID. Then use [`Stack:echo_result`]
to see what happened, and [`Stack:forget_echo`] once done.

@tparam number dst Where to send it.
@param[opt] data Data to send, which comes back in the reply.
@tparam[opt] number ttl The time to live. Small values find the routers on the way, for `traceroute`.
@treturn[1] number The request's ID.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not.
]]
function Stack:echo(dst, data, ttl)
    local id = self:add_echo({ done = false })
    local ok, err = self:send(dst, "icmp", { type = "echo", id = id, seq = 1, data = data }, { ttl = ttl })
    if not ok then
        self.echoes[id] = nil
        return nil, err
    end
    return id
end

-- Remember an echo request (or a series of them), forgetting ones which have had nothing sent for a long time.
function Stack:add_echo(echo)
    local now = self.clock()
    for id, other in pairs(self.echoes) do
        if now - other.sent > ECHO_LIFETIME then self.echoes[id] = nil end
    end
    self.next_echo = self.next_echo + 1
    echo.sent = now
    self.echoes[self.next_echo] = echo
    return self.next_echo
end

--[[- Start a series of echo requests, as `ping` sends. Each [`Stack:echo_next`] sends the next, with the next sequence
number, and every reply to one is kept until [`Stack:echo_take`] takes it: one which comes late, out of order or more
than once too, until the request is a minute old. So are errors about them, from routers which couldn't pass them on.
A `net_echo` event with the series' ID is queued whenever one comes. [`Stack:forget_echo`] ends the series, and a
series which sends nothing for a minute ends too.

@treturn number The series' ID.
]]
function Stack:echo_series()
    return self:add_echo({ series = { next = 0, sent = {}, answered = {}, replies = {} } })
end

--[[- Send the next echo request of a series.

@tparam number id The series' ID.
@tparam number dst Where to send it.
@tparam[opt] number ttl The time to live.
@treturn[1] number The request's sequence number: 1 for the first, and so on. A request which couldn't be sent still
uses one up, as `ping`'s do.
@treturn[1] string|nil Why it couldn't be sent, if it couldn't.
@treturn[2] nil If there's no such series.
]]
function Stack:echo_next(id, dst, ttl)
    local echo = self.echoes[id]
    local series = echo and echo.series
    if not series then return nil end

    local now = self.clock()
    echo.sent = now
    for seq, sent in pairs(series.sent) do
        if now - sent > ECHO_LIFETIME then series.sent[seq], series.answered[seq] = nil, nil end
    end

    series.next = series.next + 1
    local seq = series.next
    series.sent[seq] = now
    local ok, err = self:send(dst, "icmp", { type = "echo", id = id, seq = seq }, { ttl = ttl })
    if not ok then
        series.sent[seq] = nil
        return seq, err
    end
    return seq
end

-- Keep a reply to (or an error about) one of a series of echo requests until it's taken. If too many are waiting, the
-- program has stopped taking them, so the rest are dropped.
function Stack:echo_heard(id, reply)
    local replies = self.echoes[id].series.replies
    if #replies >= MAX_ECHO_REPLIES then return end
    replies[#replies + 1] = reply
    self.wake("net_echo", id)
end

--[[- Take the oldest reply to a series of echo requests which hasn't been taken yet.

@tparam number id The series' ID.
@treturn table|nil The reply: `seq`, the request's sequence number; and either `rtt` (the round trip time, in
seconds), `ttl`, `from`, and `duplicate` (whether that request was answered before), or `error` and `from` (the router
which reported it). Nothing if no reply is waiting.
]]
function Stack:echo_take(id)
    local echo = self.echoes[id]
    local series = echo and echo.series
    if not series then return nil end
    return table.remove(series.replies, 1)
end

--- Get the state of an echo request.
--
-- @tparam number id The request's ID.
-- @treturn table|nil `done`, and then either `rtt`, `ttl` and `from`, or `error`.
function Stack:echo_result(id)
    return self.echoes[id]
end

--- Forget an echo request, or end a series of them.
--
-- @tparam number id The request's (or the series') ID.
function Stack:forget_echo(id)
    self.echoes[id] = nil
end

--- Describe the interfaces.
--
-- @treturn { table... } A description of each interface, sorted by name.
--- Forward packets for other computers (as a router does), or not.
--
-- @tparam boolean enabled Whether to.
function Stack:set_forwarding(enabled)
    self.forwarding = enabled == true
end

--- Whether a modem has interfaces on it.
--
-- @tparam string modem The modem's peripheral name.
-- @treturn boolean Whether it has.
function Stack:has_modem(modem)
    return self.by_modem[modem] ~= nil
end

function Stack:interface_info()
    local result = {}
    for _, interface in pairs(self.interfaces) do
        -- Those which haven't expired, as `neighbour_info` lists them.
        local neighbours, now = 0, self.clock()
        for _, neighbour in pairs(interface.neighbours) do
            if neighbour.expires > now then neighbours = neighbours + 1 end
        end
        result[#result + 1] = {
            name = interface.name, modem = interface.modem, kind = interface.kind, band = interface.band,
            id = self.id, unicast = interface.unicast, broadcast = interface.broadcast,
            address = interface.address and address.format(interface.address),
            prefix = interface.prefix, duplicate = interface.duplicate, neighbours = neighbours,
            frames_in = interface.stats.frames_in, frames_out = interface.stats.frames_out, dropped = interface.stats.dropped,
        }
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

--- Describe the neighbours: the computers this one has talked to directly.
--
-- @treturn { table... } Each neighbour's interface, address, ID, how long until it's forgotten, and signal strength.
function Stack:neighbour_info()
    local result, now = {}, self.clock()
    for _, interface in pairs(self.interfaces) do
        for addr, neighbour in pairs(interface.neighbours) do
            if neighbour.expires > now then
                result[#result + 1] = {
                    interface = interface.name, address = address.format(addr), id = neighbour.id,
                    expires = neighbour.expires - now, signal = neighbour.signal,
                }
            end
        end
    end
    table.sort(result, function(a, b) return a.interface < b.interface or (a.interface == b.interface and a.address < b.address) end)
    return result
end

routing.install(Stack)
udp.install(Stack, describe_error)

return {
    new = new,
    -- Only tests use this.
    channels = channels,
    describe_error = describe_error,
    --- A route metric meaning "can't get there" (from [`cc.internal.net.routing`]).
    INFINITY = INFINITY,
    --- The first of the ports picked for sockets which don't ask for one (from [`cc.internal.net.udp`]).
    EPHEMERAL_FIRST = udp.EPHEMERAL_FIRST,
    --- The last of them.
    EPHEMERAL_LAST = udp.EPHEMERAL_LAST,
    --- Whether an interface can be used (from [`cc.internal.net.routing`]).
    usable = usable,
    VERSION = VERSION,
    BROADCAST_ID = BROADCAST_ID,
}
