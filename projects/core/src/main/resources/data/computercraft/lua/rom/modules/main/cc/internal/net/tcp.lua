-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Connections: Lua values delivered in order and exactly once, much like TCP.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use `net.tcp` instead.

A connection carries messages, not bytes: any Lua value [`cc.net.codec`] can encode, which is what encrypted links and
secure connections can carry. Each segment is a packet with `proto = "tcp"` and a body of:

```lua
{
    sp = 49211, dp = 22,  -- source and destination ports
    flags = "A",          -- any of S (open), A (ack is valid), F (close), R (reset), K (please acknowledge)
    seq = 1042,           -- this segment's sequence number
    ack = 977,            -- the next sequence number expected from the other side
    win = 12,             -- how many more messages, from ack on, the sender of this segment will take
    sack = { 979, 980 },  -- messages after ack which have already arrived, if any
    data = "...",         -- the message, if any
    ts = 1234.5,          -- when this was sent, by the sender's clock, if it uses up a sequence number
    echo = 1230.25,       -- the ts of the segment this one answers, if it had one
}
```

A segment uses up a sequence number if it opens (S) or closes (F) the connection, or carries a message (`data` isn't
`nil`). Others, like plain acknowledgements, don't. Sequence numbers start at a random number and never wrap: Lua's
numbers count exactly far beyond what any connection could send.

Lost segments are found by timeouts, and sooner by duplicate acknowledgements and the `sack` list, so a lossy radio
link doesn't stall a connection. Timeouts follow the round trip time, which `ts` and `echo` measure: whatever answers a
segment at once sends its `ts` back, so the time is right even for segments which were sent more than once. How many
messages are in flight is limited by both the receiver's window and a congestion window, which grows while everything
gets through and shrinks when messages are lost.

The stack queues these events for programs: `net_connection` (port) when a listening port has a connection to accept,
`net_data` (connection ID) when there's something new to receive (a message, or the end), `net_sent` (connection ID)
when a connection can take more messages (it just opened, or messages were acknowledged), and `net_closed` (connection
ID, reason) when it's gone.

@local
]]

local address = require "cc.net.address"
local describe_error = require "cc.internal.net.stack".describe_error

--- How big one message may be, as the modem estimates it. Radio messages are limited to 64 KiB, and the headers need a
-- little room.
local MAX_MESSAGE = 60 * 1024

-- How big one message may be once `cc.net.codec` has encoded it, as an encrypted link does. That's a little bigger than
-- the modem's estimate for some values (a string takes 3 bytes more), and must still fit in a radio message.
local MAX_ENCODED = 61 * 1024

--- How deeply tables in a message may nest. `cc.net.codec` takes tables 64 deep, and on an encrypted link a message is
-- encoded inside a segment, a packet and a frame.
local MAX_DEPTH = 60

local KEY_KINDS = { number = true, string = true, boolean = true }

--- How many messages a receiver holds (waiting to be received, or arrived early).
local WINDOW = 16
-- How many messages a program may queue to send, or have in flight, before `send` waits.
local SEND_BUFFER = 32

-- Connections waiting to be accepted on a listening port, connections per computer, and entries in a `sack` list.
local BACKLOG = 8
local MAX_CONNECTIONS = 128
local MAX_SACK = 16

-- Retransmission timeouts (RFC 6298), in seconds. Opening a connection is retried fewer times.
local INITIAL_RTO, MIN_RTO, MAX_RTO = 1, 0.25, 30
local MAX_RETRIES, MAX_SYN_RETRIES = 8, 5

-- Congestion control: the window starts at 2 messages, doubles each round trip up to a threshold, and then grows by one
-- each round trip.
local INITIAL_CWND, INITIAL_SSTHRESH, MAX_CWND = 2, WINDOW, 64

-- After this long without hearing anything, check the other side is still there, every so often, a few times.
local KEEPALIVE_IDLE, KEEPALIVE_INTERVAL, KEEPALIVE_PROBES = 60, 10, 5

-- How long a closed connection lingers, answering stray segments.
local TIME_WAIT = 5

local EPHEMERAL_FIRST, EPHEMERAL_LAST = 49152, 65535

local function is_integer(value, min, max)
    return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

local function is_seq(value) return is_integer(value, 0, 2 ^ 53) end
local function is_finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function is_port(value) return is_integer(value, 1, 65535) end

local function key(local_addr, local_port, remote_addr, remote_port)
    return ("%d:%d>%d:%d"):format(local_addr, local_port, remote_addr, remote_port)
end

--[[- Check a message can be sent: it isn't `nil`, isn't too big, and is something [`cc.net.codec`] can encode.

A modem can send more than that (tables which contain themselves, and tables as keys), but an encrypted link can't, and
a connection can't tell whether there's one on its way. A message one link carries and another drops would end the
connection long after it was sent, so such messages are refused here, where the program can be told why.

Sizes are estimated the same way modems do, and worked out as the codec would encode them.

@param value The message.
@treturn[1] true If it can be sent.
@treturn[2] nil If it can't.
@treturn[2] string Why not.
]]
local function check_message(value)
    if value == nil then return nil, "Can't send nil" end

    -- The tables we're inside. A table may appear twice, but not inside itself.
    local open, size, encoded = {}, 0, 0
    local function add(v, depth)
        local kind = type(v)
        if kind == "string" then
            size, encoded = size + #v + 2, encoded + #v + 5
        elseif kind == "number" then
            size, encoded = size + 8, encoded + 9
        elseif kind == "boolean" then
            size, encoded = size + 1, encoded + 1
        elseif kind == "table" then
            if open[v] then error("Can't send a table which contains itself", 0) end
            if depth >= MAX_DEPTH then error("Can't send tables nested more than " .. MAX_DEPTH .. " deep", 0) end
            open[v] = true
            size, encoded = size + 2, encoded + 5
            for k, x in pairs(v) do
                if not KEY_KINDS[type(k)] then error("Can't send a table with a " .. type(k) .. " as a key", 0) end
                size = size + 2
                add(k, depth + 1)
                add(x, depth + 1)
            end
            open[v] = nil
        else
            error("Can't send a " .. kind, 0)
        end
        if size > MAX_MESSAGE or encoded > MAX_ENCODED then error("Message too large", 0) end
    end

    local ok, err = pcall(add, value, 0)
    if not ok then
        if type(err) ~= "string" or not (err:find("^Can't send") or err == "Message too large") then err = "Message too complex to send" end
        return nil, err
    end
    return true
end

local Connection = {}
Connection.__index = Connection

local Listener = {}
Listener.__index = Listener

local receive, on_error

--- Get the connections on a stack, setting up connections the first time.
--
-- @tparam table stack The network stack.
-- @treturn table Its connections and listening ports.
local function registry(stack)
    local tcp = stack.tcp
    if tcp then return tcp end

    tcp = {
        connections = {}, by_id = {}, listeners = {}, count = 0, next_id = 0, ports = {},
        -- Start somewhere different each time. A computer which has just restarted would otherwise use the ports its
        -- old connections had, which the other sides may still think are open.
        next_port = math.random(EPHEMERAL_FIRST, EPHEMERAL_LAST),
    }
    stack.tcp = tcp
    stack.protocols.tcp = function(packet, interface) return receive(stack, packet, interface) end
    stack.error_handlers.tcp = function(orig, message) return on_error(stack, orig, message) end
    -- Connections from an address we no longer have can't go on.
    stack.address_lost.tcp = function(addr)
        local lost = {}
        for _, connection in pairs(tcp.connections) do
            if connection.local_addr == addr then lost[#lost + 1] = connection end
        end
        for _, connection in ipairs(lost) do connection:fail("Address lost") end
    end
    return tcp
end

local function new_connection(stack, local_addr, local_port, remote_addr, remote_port)
    local tcp = registry(stack)
    tcp.next_id = tcp.next_id + 1
    local iss = math.random(0, 0x7FFFFFFF)
    local self = setmetatable({
        stack = stack, id = tcp.next_id,
        local_addr = local_addr, local_port = local_port, remote_addr = remote_addr, remote_port = remote_port,
        key = key(local_addr, local_port, remote_addr, remote_port),
        state = "closed",

        -- Sending. Sequence numbers from snd_una to snd_nxt - 1 are in flight, in `unacked`. Messages waiting to be
        -- sent are in `queue`.
        iss = iss, snd_una = iss, snd_nxt = iss, snd_edge = iss + 1,
        queue = {}, unacked = {},
        cwnd = INITIAL_CWND, ssthresh = INITIAL_SSTHRESH, rto = INITIAL_RTO, retries = 0, dupacks = 0,
        closing = false, fin_acked = false,

        -- Receiving. Messages which arrive early are held until the gap before them fills; in-order ones go to the
        -- inbox for the program.
        held = {}, held_count = 0, inbox = {}, peer_closed = false, last_window = WINDOW,
        last_heard = stack.clock(), probes = 0,
    }, Connection)
    tcp.connections[self.key] = self
    tcp.by_id[self.id] = self
    tcp.count = tcp.count + 1
    tcp.ports[local_port] = (tcp.ports[local_port] or 0) + 1
    return self
end

--- How many more messages we can take, from the next one expected.
function Connection:window()
    return math.max(0, WINDOW - #self.inbox)
end

function Connection:wake(event, ...)
    self.stack.wake(event, self.id, ...)
end

-- Send a segment. Every segment but the first acknowledges what we've received. Timed segments say when they were
-- sent, and the first segment sent in answer to one sends that back.
function Connection:segment(flags, seq, data, timed)
    local body = { sp = self.local_port, dp = self.remote_port, flags = flags, seq = seq, data = data }
    if timed then body.ts = self.stack.clock() end
    if self.echo then body.echo, self.echo = self.echo, nil end
    if self.rcv_nxt then
        body.flags, body.ack, body.win = flags .. "A", self.rcv_nxt, self:window()
        self.last_window = body.win
        if self.held_count > 0 then
            local sack = {}
            for held in pairs(self.held) do sack[#sack + 1] = held end
            table.sort(sack)
            for i = MAX_SACK + 1, #sack do sack[i] = nil end
            body.sack = sack
        end
    end
    self.stack:send(self.remote_addr, "tcp", body, { src = self.local_addr })
end

function Connection:send_ack(flags)
    self:segment(flags or "", self.snd_nxt)
end

-- Send (or resend) the message with a sequence number.
function Connection:transmit(seq)
    local message = self.unacked[seq]
    if message.syn then
        self:segment("S", seq, nil, true)
    elseif message.fin then
        self:segment("F", seq, nil, true)
    else
        self:segment("", seq, message.data, true)
    end
    if not self.rto_timer then self:arm_timer() end
end

function Connection:arm_timer()
    self.stack:cancel(self.rto_timer)
    self.rto_timer = self.stack:schedule(self.rto, function()
        self.rto_timer = nil
        self:on_timeout()
    end)
end

-- Send queued messages, as far as the windows allow.
function Connection:try_send()
    if self.state ~= "established" then return end
    local limit = math.min(self.snd_edge, self.snd_una + math.floor(self.cwnd))
    while self.queue[1] and self.snd_nxt < limit do
        local item = table.remove(self.queue, 1)
        local seq = self.snd_nxt
        self.snd_nxt = seq + 1
        self.unacked[seq] = item
        self:transmit(seq)
    end

    -- The receiver has no room, and nothing is in flight to tell us when it does: ask now and then.
    if self.queue[1] and self.snd_nxt == self.snd_una and self.snd_nxt >= self.snd_edge and not self.rto_timer then
        self:arm_timer()
    end
end

-- Resend the first message in flight which hasn't arrived.
function Connection:retransmit_first()
    for seq = self.snd_una, self.snd_nxt - 1 do
        local message = self.unacked[seq]
        if message and not message.sacked then return self:transmit(seq) end
    end
end

function Connection:on_timeout()
    if self.snd_una >= self.snd_nxt then
        -- Nothing in flight: the receiver's window is closed, so ask it whether it has room yet.
        if self.queue[1] and self.state == "established" then
            self.retries = self.retries + 1
            if self.retries > MAX_RETRIES then return self:fail("Timed out") end
            self.rto = math.min(MAX_RTO, self.rto * 2)
            self:send_ack("K")
            self:arm_timer()
        end
        return
    end

    self.retries = self.retries + 1
    local limit = self.state == "established" and MAX_RETRIES or MAX_SYN_RETRIES
    if self.retries > limit then return self:fail("Timed out") end

    -- Assume everything in flight was lost, apart from what arrived out of order, and start again slowly.
    self.rto = math.min(MAX_RTO, self.rto * 2)
    self.ssthresh = math.max(2, math.floor((self.snd_nxt - self.snd_una) / 2))
    self.cwnd, self.dupacks, self.recover = 1, 0, self.snd_nxt - 1
    self:retransmit_first()
    self:arm_timer()
end

-- The connection is open: start sending, and tell whoever's waiting.
function Connection:established()
    self.state = "established"
    self:arm_keepalive()
    if self.listener then
        local listener = self.listener
        listener.pending = listener.pending - 1
        if listener.closed then return self:abort() end
        listener.queue[#listener.queue + 1] = self
        self.stack.wake("net_connection", listener.port)
    end
    self:wake("net_sent")
    self:try_send()
end

function Connection:arm_keepalive()
    self.stack:cancel(self.keepalive_timer)
    local idle = self.stack.clock() - self.last_heard
    -- Check again at least a second later: rounding can leave a tiny time left, which would make the timer fire at once
    -- for ever.
    local delay = idle >= KEEPALIVE_IDLE and KEEPALIVE_INTERVAL or math.max(1, KEEPALIVE_IDLE - idle)
    self.keepalive_timer = self.stack:schedule(delay, function()
        self.keepalive_timer = nil
        if self.state ~= "established" then return end
        if self.stack.clock() - self.last_heard >= KEEPALIVE_IDLE then
            if self.probes >= KEEPALIVE_PROBES then return self:fail("Timed out") end
            self.probes = self.probes + 1
            self:send_ack("K")
        end
        self:arm_keepalive()
    end)
end

-- Handle an acknowledgement: forget what arrived, measure the round trip, and adjust the congestion window.
function Connection:process_ack(segment, carries)
    local ack = segment.ack
    if ack < self.snd_una then return end
    -- With the same acknowledgement, the window only grows: a smaller one is from an older segment, overtaken.
    if ack > self.snd_una then
        self.snd_edge = ack + segment.win
    else
        self.snd_edge = math.max(self.snd_edge, ack + segment.win)
    end

    -- Measure the round trip, if this answers a segment of ours at once: it then says when that segment was sent.
    -- Working it out from which message was acknowledged goes wrong when messages are sent twice, or wait at the
    -- other side for a gap before them to fill, and one bad measurement of half a minute takes a long time to forget.
    local now, echo = self.stack.clock(), segment.echo
    if type(echo) == "number" and echo <= now and now - echo <= MAX_RTO then
        local sample = now - echo
        if not self.srtt then
            self.srtt, self.rttvar = sample, sample / 2
        else
            self.rttvar = 0.75 * self.rttvar + 0.25 * math.abs(self.srtt - sample)
            self.srtt = 0.875 * self.srtt + 0.125 * sample
        end
        self.rto = math.max(MIN_RTO, math.min(MAX_RTO, self.srtt + 4 * self.rttvar))
    end

    if type(segment.sack) == "table" then
        for i = 1, math.min(#segment.sack, MAX_SACK) do
            local seq = segment.sack[i]
            local message = is_seq(seq) and seq > ack and self.unacked[seq]
            if message then message.sacked = true end
        end
    end

    local newly = ack - self.snd_una
    if newly > 0 then
        for seq = self.snd_una, ack - 1 do
            local message = self.unacked[seq]
            if message then
                if message.fin then self.fin_acked = true end
                self.unacked[seq] = nil
            end
        end
        self.snd_una, self.retries, self.dupacks = ack, 0, 0

        -- Something got through, so stop waiting longer and longer.
        if self.srtt then
            self.rto = math.max(MIN_RTO, math.min(MAX_RTO, self.srtt + 4 * self.rttvar))
        else
            -- Nothing has been measured (the other side doesn't say when our segments were sent). Come back down
            -- gradually, or a connection which began badly would wait half a minute for every message lost later.
            self.rto = math.max(INITIAL_RTO, self.rto / 2)
        end

        if self.recover and ack <= self.recover then
            -- Still recovering from a loss, and the next gap is now first: resend it straight away.
            self:retransmit_first()
        else
            self.recover = nil
            if self.cwnd < self.ssthresh then
                self.cwnd = self.cwnd + newly
            else
                self.cwnd = self.cwnd + newly / self.cwnd
            end
            self.cwnd = math.min(self.cwnd, MAX_CWND)
        end

        if self.snd_una < self.snd_nxt then
            self:arm_timer()
        elseif not self.queue[1] then
            self.stack:cancel(self.rto_timer)
            self.rto_timer = nil
        end
        if self.waiting_to_send and self:can_send() then
            self.waiting_to_send = false
            self:wake("net_sent")
        end
    elseif not carries and ack == self.snd_una and self.snd_una < self.snd_nxt then
        -- The same acknowledgement again: something after the first message in flight arrived, but not it. Three of
        -- these mean it was lost. With only a few messages in flight and nothing new to send, fewer will ever come, so
        -- fewer are enough (RFC 5827).
        self.dupacks = self.dupacks + 1
        local in_flight = self.snd_nxt - self.snd_una
        local threshold = 3
        local limit = math.min(self.snd_edge, self.snd_una + math.floor(self.cwnd))
        if not self.queue[1] or self.snd_nxt >= limit then threshold = math.max(1, math.min(3, in_flight - 1)) end
        if self.dupacks == threshold and not self.recover then
            self.ssthresh = math.max(2, math.floor((self.snd_nxt - self.snd_una) / 2))
            self.cwnd, self.recover = self.ssthresh, self.snd_nxt - 1
            self:retransmit_first()
        end
    end

    -- An answer to a window probe: the other side is there, even if it has no room yet.
    if self.snd_una == self.snd_nxt then self.retries = 0 end

    self:check_closed()
    self:try_send()
end

-- Handle a message or close from the other side.
function Connection:receive_message(segment, fin)
    local offset = segment.seq - self.rcv_nxt
    if offset >= 0 and offset < self:window() and not self.held[segment.seq] and not self.peer_closed then
        self.held[segment.seq] = { data = segment.data, fin = fin }
        self.held_count = self.held_count + 1

        local was_empty = #self.inbox == 0
        while self.held[self.rcv_nxt] do
            local message = self.held[self.rcv_nxt]
            self.held[self.rcv_nxt] = nil
            self.held_count = self.held_count - 1
            self.rcv_nxt = self.rcv_nxt + 1
            if message.fin then
                -- Nothing can come after the end.
                self.peer_closed, self.held, self.held_count = true, {}, 0
                self:wake("net_data")
                break
            end
            self.inbox[#self.inbox + 1] = { value = message.data }
        end
        if was_empty and #self.inbox > 0 then self:wake("net_data") end
    end

    -- Acknowledge everything, even duplicates (our earlier acknowledgement may have been lost) and messages we had no
    -- room for (so the sender learns our window).
    self:send_ack()
    self:check_closed()
end

-- Once both sides have closed and everything has been acknowledged, linger a moment for stray segments, then go.
function Connection:check_closed()
    if self.state == "established" and self.peer_closed and self.fin_acked then
        self.state = "time_wait"
        self.stack:cancel(self.rto_timer)
        self.stack:cancel(self.keepalive_timer)
        self.rto_timer, self.keepalive_timer = nil, nil
        self.stack:schedule(TIME_WAIT, function() self:remove() end)
        -- Say it's closed once everything which arrived has been received, so nobody stops reading too early.
        if #self.inbox == 0 then self:wake("net_closed") else self.close_pending = true end
    end
end

function Connection:on_segment(segment, flags)
    if flags.R then
        -- Only believe a reset which knows where the connection is up to, so others can't reset it blindly. While
        -- opening, that means acknowledging our open exactly.
        if self.state == "syn_sent" or self.state == "syn_received" then
            if flags.A and segment.ack == self.iss + 1 then
                self:fail(self.state == "syn_sent" and "Connection refused" or "Connection reset")
            end
        elseif segment.seq >= self.rcv_nxt and segment.seq < self.rcv_nxt + WINDOW then
            self:fail("Connection reset")
        end
        return
    end

    if self.state == "syn_sent" then
        if flags.S and flags.A and segment.ack == self.iss + 1 then
            self.rcv_nxt, self.last_heard = segment.seq + 1, self.stack.clock()
            self:process_ack(segment, false)
            self:send_ack()
            self:established()
        elseif flags.A and segment.ack ~= self.iss + 1 then
            -- An acknowledgement of something we never sent: the other side still has a connection from these ports,
            -- from before we restarted. It's reset like any other connection we don't know of, so our open gets
            -- through when we next try.
            return "stray"
        end
        return
    end

    if flags.S then
        if self.rcv_nxt == segment.seq + 1 then
            -- The other side didn't hear our answer to its open, so answer again.
            if self.state == "syn_received" then self:transmit(self.iss) else self:send_ack() end
        elseif self.stack:may_report(self.remote_addr) then
            -- An open which isn't the one this connection began with. The other side may have restarted, and be
            -- using the same port again, so say where we think we're up to. If it has forgotten this connection, it
            -- answers with a reset, and its next try gets through. (If it hasn't, someone else made the open up, and
            -- our acknowledgement does no harm.)
            self:send_ack()
        end
        return
    end

    -- Everything after opening acknowledges something, and can't acknowledge what we never sent.
    if not flags.A or segment.ack > self.snd_nxt then return end
    self.last_heard, self.probes = self.stack.clock(), 0
    if self.state == "time_wait" then
        if flags.F or segment.data ~= nil then self:send_ack() end
        return
    end

    local carries = segment.data ~= nil or flags.F
    if self.state == "syn_received" then
        if segment.ack < self.iss + 1 then return end
        self:process_ack(segment, carries)
        self:established()
    else
        self:process_ack(segment, carries)
    end
    if self.state ~= "established" then return end

    if carries then
        self:receive_message(segment, flags.F)
    elseif flags.K then
        self:send_ack()
    end
end

function Connection:can_send()
    return self.state == "established" and not self.closing and #self.queue + (self.snd_nxt - self.snd_una) < SEND_BUFFER
end

--[[- Queue a message to send.

@param value The message.
@treturn[1] true If it was queued.
@treturn[2] nil If it wasn't.
@treturn[2] string Why not: `"Full"` if the program should wait for `net_sent` and try again, or an error.
]]
function Connection:send(value)
    -- Still opening, or no room: wait. Only then check the message, as a program which is waiting tries again often.
    if self.state == "syn_sent" or self.state == "syn_received" then
        self.waiting_to_send = true
        return nil, "Full"
    end
    if self.state ~= "established" or self.closing then return nil, self.error or "Connection closed" end
    if not self:can_send() then
        self.waiting_to_send = true
        return nil, "Full"
    end
    local ok, err = check_message(value)
    if not ok then return nil, err end

    self.queue[#self.queue + 1] = { data = value }
    self:try_send()
    return true
end

--[[- Take the next message which has arrived.

@treturn[1] true If there was one.
@return[1] The message.
@treturn[2] false If there wasn't.
@treturn[2] string|nil `nil` if more may come, `"closed"` if the other side has closed, or why the connection failed.
]]
function Connection:take()
    local item = table.remove(self.inbox, 1)
    if item then
        -- If our window had nearly closed, tell the sender it's open again.
        if self.state == "established" and self.last_window < WINDOW / 4 and self:window() >= WINDOW / 2 then
            self:send_ack()
        end
        if self.close_pending and #self.inbox == 0 then
            self.close_pending = false
            self:wake("net_closed")
        end
        return true, item.value
    end
    if self.error then return false, self.error end
    if self.peer_closed or self.state == "closed" then return false, "closed" end
    return false, nil
end

--- Close our side: once everything queued has been sent, tell the other side there's nothing more. Messages can still
-- arrive until the other side closes too.
function Connection:close()
    if self.state == "syn_sent" or self.state == "syn_received" then return self:abort() end
    if self.state ~= "established" or self.closing then return end
    self.closing = true
    self.queue[#self.queue + 1] = { fin = true }
    self:try_send()
end

--- Drop the connection at once, telling the other side.
function Connection:abort()
    if self.state == "closed" then return end
    if self.state ~= "syn_sent" then
        self.stack:send(self.remote_addr, "tcp", {
            sp = self.local_port, dp = self.remote_port, flags = "R", seq = self.snd_nxt,
        }, { src = self.local_addr })
    end
    self:fail("Connection closed")
end

-- The connection has failed (or been aborted): tell the program, and forget it.
function Connection:fail(reason)
    if self.state == "closed" then return end
    self.error = self.error or reason
    self:remove()
    self:wake("net_data")
    self:wake("net_closed", reason)
end

function Connection:remove()
    local previous = self.state
    self.state = "closed"
    self.stack:cancel(self.rto_timer)
    self.stack:cancel(self.keepalive_timer)
    self.rto_timer, self.keepalive_timer = nil, nil
    if previous == "closed" then return end

    local tcp = registry(self.stack)
    if tcp.connections[self.key] == self then
        tcp.connections[self.key] = nil
        tcp.by_id[self.id] = nil
        tcp.count = tcp.count - 1
        tcp.ports[self.local_port] = tcp.ports[self.local_port] - 1
        if tcp.ports[self.local_port] <= 0 then tcp.ports[self.local_port] = nil end
    end

    -- A connection nobody accepted yet leaves its listener's queue.
    local listener = self.listener
    if listener and not self.accepted then
        if previous == "syn_received" then
            listener.pending = listener.pending - 1
        else
            for i, queued in ipairs(listener.queue) do
                if queued == self then
                    table.remove(listener.queue, i)
                    break
                end
            end
        end
    end
end

--- Describe the connection.
--
-- @treturn table Its state, addresses and ports, and how much is queued and in flight.
function Connection:info()
    return {
        id = self.id, state = self.state, local_address = self.local_addr, local_port = self.local_port,
        remote_address = self.remote_addr, remote_port = self.remote_port,
        queued = #self.queue, in_flight = self.snd_nxt - self.snd_una, received = #self.inbox,
        rtt = self.srtt, cwnd = self.cwnd,
    }
end

-- A segment arrived for a connection which doesn't exist: tell the sender, unless it's a reset itself. Resets are
-- rate-limited like ICMP errors, so a flood of segments doesn't make us flood back.
local function reset(stack, packet, segment, flags)
    if flags.R or not stack:may_report(packet.src) then return end
    -- The reset acknowledges the segment, so a connection still opening (which only believes resets acknowledging its
    -- open) is reset too: say, one whose other side gave up waiting.
    local length = (flags.S and 1 or 0) + (flags.F and 1 or 0) + (segment.data ~= nil and 1 or 0)
    stack:send(packet.src, "tcp", {
        sp = segment.dp, dp = segment.sp, flags = "RA", seq = flags.A and segment.ack or 0, ack = segment.seq + length, win = 0,
    }, { src = packet.dst })
end

local function parse_flags(text)
    local flags = {}
    for i = 1, #text do
        local flag = text:sub(i, i)
        if not ("SAFRK"):find(flag, 1, true) then return nil end
        flags[flag] = true
    end
    return flags
end

function receive(stack, packet, interface)
    local segment = packet.body
    if type(segment) ~= "table" or not is_port(segment.sp) or not is_port(segment.dp) or type(segment.flags) ~= "string"
        or #segment.flags > 5 or not is_seq(segment.seq) then
        return
    end
    -- Connections are between two computers: never to or from a broadcast address.
    if packet.dst == address.BROADCAST or packet.src == address.ANY or packet.src == address.BROADCAST
        or (interface and packet.dst == interface.broadcast_address) then
        return
    end

    local flags = parse_flags(segment.flags)
    if not flags or (flags.A and (not is_seq(segment.ack) or not is_integer(segment.win, 0, 1024))) then return end
    if flags.F and segment.data ~= nil then return end

    local tcp = registry(stack)
    local connection = tcp.connections[key(packet.dst, segment.dp, packet.src, segment.sp)]
    if connection then
        -- Whatever we send straight away in answer says when this segment was sent, to measure the round trip.
        connection.echo = is_finite(segment.ts) and segment.ts or nil
        local result = connection:on_segment(segment, flags)
        connection.echo = nil
        if result == "stray" then reset(stack, packet, segment, flags) end
        return
    end

    local listener = tcp.listeners[segment.dp]
    if flags.S and not flags.A and listener then return listener:incoming(packet, segment) end
    reset(stack, packet, segment, flags)
end

function on_error(stack, orig, message)
    if not address.is_valid(orig.src) or not address.is_valid(orig.dst) or not is_port(orig.sp) or not is_port(orig.dp) then
        return
    end
    -- Only give up while opening: once open, the retries decide.
    local connection = registry(stack).connections[key(orig.src, orig.sp, orig.dst, orig.dp)]
    if connection and connection.state == "syn_sent" then
        local reason = describe_error(message)
        if reason == "Port unreachable" then reason = "Connection refused" end
        connection:fail(reason)
    end
end

--- Someone wants to connect.
function Listener:incoming(packet, segment)
    local tcp = registry(self.stack)
    if self.closed then return end
    if self.pending + #self.queue >= BACKLOG or tcp.count >= MAX_CONNECTIONS then
        -- Too many waiting already. A connection which is still opening, and whose other side didn't answer the first
        -- time, makes way: whoever asked for it may not exist, and a few of those every minute would otherwise keep
        -- everyone else out for good. Failing that, ignore this one. The other side tries again, and by then there
        -- may be room.
        local stale
        for _, connection in pairs(tcp.connections) do
            if connection.listener == self and connection.state == "syn_received" and connection.retries > 0
                and (not stale or connection.id < stale.id) then
                stale = connection
            end
        end
        if not stale then return end
        stale:remove()
    end

    local connection = new_connection(self.stack, packet.dst, self.port, packet.src, segment.sp)
    connection.state, connection.listener = "syn_received", self
    connection.rcv_nxt = segment.seq + 1
    connection.unacked[connection.iss] = { syn = true }
    connection.snd_nxt = connection.iss + 1
    self.pending = self.pending + 1
    connection.echo = is_finite(segment.ts) and segment.ts or nil
    connection:transmit(connection.iss)
    connection.echo = nil
end

--- Take the next connection waiting to be accepted.
--
-- @treturn table|nil The connection, or `nil` if there's none.
function Listener:accept()
    local connection = table.remove(self.queue, 1)
    if connection then connection.accepted = true end
    return connection
end

--- Stop listening. Connections not yet accepted are reset.
function Listener:close()
    if self.closed then return end
    self.closed = true
    local tcp = registry(self.stack)
    if tcp.listeners[self.port] == self then tcp.listeners[self.port] = nil end
    local queue = self.queue
    self.queue = {}
    for _, connection in ipairs(queue) do connection:abort() end
end

--[[- Listen for connections on a port.

@tparam table stack The network stack.
@tparam number port The port.
@treturn[1] table The listener.
@treturn[2] nil If the port is in use.
@treturn[2] string Why not.
]]
local function listen(stack, port)
    if not is_port(port) then return nil, "Ports must be whole numbers from 1 to 65535" end
    local tcp = registry(stack)
    if tcp.listeners[port] then return nil, "Port " .. port .. " is in use" end
    local listener = setmetatable({ stack = stack, port = port, queue = {}, pending = 0, closed = false }, Listener)
    tcp.listeners[port] = listener
    return listener
end

--[[- Start opening a connection. It's open once its state is `"established"`, or has failed once it's `"closed"`.

@tparam table stack The network stack.
@tparam number dst The address to connect to.
@tparam number port The port to connect to.
@treturn[1] table The connection.
@treturn[2] nil If it can't even be started.
@treturn[2] string Why not.
]]
local function connect(stack, dst, port)
    if not address.is_valid(dst) or not is_port(port) then return nil, "Invalid address or port" end
    if dst == address.BROADCAST or dst == address.ANY then return nil, "Can't connect to a broadcast address" end

    local local_addr = dst
    if not stack:is_local(dst) then
        local interface = stack:route(dst)
        if not interface then return nil, "Network unreachable" end
        if dst == interface.broadcast_address then return nil, "Can't connect to a broadcast address" end
        local_addr = interface.address
    end

    local tcp = registry(stack)
    if tcp.count >= MAX_CONNECTIONS then return nil, "Too many connections" end
    local local_port
    for _ = EPHEMERAL_FIRST, EPHEMERAL_LAST do
        local candidate = tcp.next_port
        tcp.next_port = candidate >= EPHEMERAL_LAST and EPHEMERAL_FIRST or candidate + 1
        if not tcp.ports[candidate] and not tcp.listeners[candidate] then
            local_port = candidate
            break
        end
    end
    if not local_port then return nil, "No free ports" end

    local connection = new_connection(stack, local_addr, local_port, dst, port)
    connection.state = "syn_sent"
    connection.unacked[connection.iss] = { syn = true }
    connection.snd_nxt = connection.iss + 1
    connection:transmit(connection.iss)
    return connection
end

--- Find a connection by its ID.
--
-- @tparam table stack The network stack.
-- @tparam number id The connection's ID.
-- @treturn table|nil The connection.
local function get(stack, id)
    return registry(stack).by_id[id]
end

--- Describe every connection and listening port.
--
-- @tparam table stack The network stack.
-- @treturn { table... } The connections.
-- @treturn { number... } The listening ports.
local function info(stack)
    local tcp, connections, ports = registry(stack), {}, {}
    for _, connection in pairs(tcp.connections) do connections[#connections + 1] = connection:info() end
    table.sort(connections, function(a, b) return a.id < b.id end)
    for port in pairs(tcp.listeners) do ports[#ports + 1] = port end
    table.sort(ports)
    return connections, ports
end

return {
    connect = connect,
    listen = listen,
    get = get,
    info = info,
    check_message = check_message,
    attach = registry,
    WINDOW = WINDOW,
    MAX_MESSAGE = MAX_MESSAGE,
    MAX_DEPTH = MAX_DEPTH,
}
