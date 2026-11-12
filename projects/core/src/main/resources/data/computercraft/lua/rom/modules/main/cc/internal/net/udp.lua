-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Datagram sockets, for the network stack: like UDP, messages without connections, which may be lost.
[`cc.internal.net.stack`] gives its stacks these methods.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local address = require "cc.net.address"
local net_message = require "cc.internal.net.message"
local is_broadcast = require "cc.internal.net.routing".is_broadcast

--- The first of the ports picked for sockets which don't ask for one.
local EPHEMERAL_FIRST = 49152
--- The last of them.
local EPHEMERAL_LAST = 65535
local MAX_QUEUED_DATAGRAMS = 32

-- What an ICMP error says, in words: the stack's, given to `install`.
local describe_error

local Udp = {}

--[[- Open a datagram socket.

Datagrams sent to the socket's port are queued on the socket (at most 32, after which more are dropped), and a
`net_datagram` event is queued with the port when the queue stops being empty. Alternatively, a handler is called
straight away, which the stack's own services use.

@tparam[opt] number port The port, or `nil` for any free port from 49152 up.
@tparam[opt] function(data:any, from:number, port:number, interface:string|nil) handler Called for each datagram.
@tparam[opt] { size = number, encoded = number } limits How big datagrams sent from the socket may be: as big as
programs may send, by default. The stack's own tunnels carry programs' messages, so need more room
([`cc.internal.net.message`]'s `TUNNEL`).
@treturn[1] table The socket.
@treturn[2] nil If the port is in use.
@treturn[2] string An error message.
]]
function Udp:udp_open(port, handler, limits)
    if port then
        if self.udp[port] then return nil, "Port " .. port .. " is in use" end
    else
        for _ = EPHEMERAL_FIRST, EPHEMERAL_LAST do
            local candidate = self.next_port
            self.next_port = candidate >= EPHEMERAL_LAST and EPHEMERAL_FIRST or candidate + 1
            if not self.udp[candidate] then
                port = candidate
                break
            end
        end
        if not port then return nil, "No free ports" end
    end

    local socket = { port = port, queue = {}, handler = handler, limits = limits }
    self.udp[port] = socket
    return socket
end

--- Close a datagram socket.
--
-- @tparam table socket The socket.
function Udp:udp_close(socket)
    if self.udp[socket.port] == socket then self.udp[socket.port] = nil end
    socket.closed = true
end

--[[- Send a datagram.

@tparam table socket The socket to send from.
@tparam number dst Where to send it. The broadcast address reaches everyone on every interface, or with `name`, on one.
@tparam number port The port to send it to.
@param data The data: nothing, or a value which crosses every kind of link (see [`cc.internal.net.message`]).
@tparam[opt] string name For broadcasts, the interface to send on.
@treturn[1] true If it was sent.
@treturn[2] nil If it couldn't be.
@treturn[2] string Why not.
]]
function Udp:udp_send(socket, dst, port, data, name)
    -- A datagram some link on its way can't carry would be lost every time, and nobody told. Say so now instead.
    if data ~= nil then
        local ok, err = net_message.check(data, socket.limits)
        if not ok then return nil, err end
    end

    local body = { sp = socket.port, dp = port, data = data }
    if dst == address.BROADCAST and name then
        if not self:send_broadcast(name, "udp", body) then return nil, "No interface named '" .. name .. "'" end
        return true
    end

    local ok, err = self:send(dst, "udp", body)
    if not ok then return nil, err end
    return true
end

function Udp:receive_udp(packet, interface)
    local body = packet.body
    if type(body) ~= "table" or type(body.sp) ~= "number" or type(body.dp) ~= "number" then return end

    local socket = self.udp[body.dp]
    if not socket then
        if not is_broadcast(interface, packet.dst) then self:send_error(packet, "unreachable", "port") end
        return
    end

    local name = interface and interface.name
    if socket.handler then return socket.handler(body.data, packet.src, body.sp, name) end

    local queue = socket.queue
    if #queue >= MAX_QUEUED_DATAGRAMS then return end
    queue[#queue + 1] = { data = body.data, from = packet.src, port = body.sp, interface = name }
    if #queue == 1 then self.wake("net_datagram", socket.port) end
end

function Udp:udp_error(orig, message)
    local socket = type(orig.sp) == "number" and self.udp[orig.sp]
    if socket and socket.on_error then socket.on_error(describe_error(message), orig.dst) end
end

--- Give a stack's class the methods here.
--
-- @tparam table Stack The class.
-- @tparam function describe The stack's way to say what an ICMP error means.
local function install(Stack, describe)
    describe_error = describe
    for name, method in pairs(Udp) do Stack[name] = method end
end

return {
    EPHEMERAL_FIRST = EPHEMERAL_FIRST,
    EPHEMERAL_LAST = EPHEMERAL_LAST,
    install = install,
}
