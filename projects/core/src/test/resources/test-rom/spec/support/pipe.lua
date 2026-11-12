-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Two ends of a connection between computers, for testing what uses the net API's secure connections: they send,
receive, close and abort as those do, and wait (by yielding) as they do.

Each end's peer is the other: `a` says who the first end is to the second (`key` and `address`), and `b` who the second
is to the first. Messages are copied on the way, as they would be.

A message, or word that the other end has closed, arrives at once, unless `options` says otherwise:

 - `deliver(side, fn)` delivers something to one end (1 is the first, 2 the second) by calling `fn` once it has
   arrived.
 - `changed(side)` is called when something an end waits for has happened: something arrived, or the connection was
   dropped.
 - `wake_at(side, seconds)` is called when an end starts waiting with a time limit, to wake it once the time is up.
]]

local codec = require "cc.net.codec"

local function copy(value) return codec.decode(codec.encode(value)) end

return function(clock, a, b, options)
    options = options or {}
    local deliver = options.deliver or function(_, fn) fn() end
    local changed = options.changed or function() end
    local wake_at = options.wake_at or function() end
    -- Whether the connection was dropped; what has arrived at each end; whether each end has closed; and whether each
    -- end has heard the other close.
    local shared, inboxes, closed, ended = {}, { {}, {} }, {}, {}

    local function side(me, other, peer)
        return {
            send = function(_, value)
                if shared.aborted or closed[me] then return nil, "Connection closed" end
                local message = copy(value)
                deliver(other, function()
                    if shared.aborted then return end
                    table.insert(inboxes[other], message)
                    changed(other)
                end)
                return true
            end,
            receive = function(_, timeout)
                local deadline = timeout and clock() + timeout
                if timeout then wake_at(me, timeout) end
                while true do
                    if inboxes[me][1] then return table.remove(inboxes[me], 1) end
                    if shared.aborted then return nil, "Connection reset" end
                    if ended[me] then return nil end
                    if deadline and clock() >= deadline then return nil, "Timed out" end
                    coroutine.yield()
                end
            end,
            close = function()
                if closed[me] then return end
                closed[me] = true
                -- After what was sent before.
                deliver(other, function()
                    ended[other] = true
                    changed(other)
                end)
            end,
            abort = function()
                if shared.aborted then return end
                shared.aborted = true
                changed(1)
                changed(2)
            end,
            getPeerKey = function() return peer.key end,
            getPeer = function() return peer.address, 2123 end,
            is_gone = function() return shared.aborted or closed[me] or ended[me] end,
        }
    end
    return side(1, 2, b), side(2, 1, a)
end
