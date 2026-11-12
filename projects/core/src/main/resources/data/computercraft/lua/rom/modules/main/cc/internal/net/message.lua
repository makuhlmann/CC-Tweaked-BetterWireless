-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What programs may send: the values a connection's message or a datagram may hold.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the [`net`] API instead.

A modem sends any table, however it's built, and quietly leaves out functions. But a link may be encrypted, and then
every frame is encoded with [`cc.net.codec`], which can't encode tables which contain themselves or tables used as
keys. Radio messages are also limited in size. Whoever sends something can't tell which links it will cross, and what
one link carries and another drops would be lost every time without anyone being told. So the stack takes the same
values everywhere: those which cross every link.

@local
]]

--- How big one value may be, as the modem estimates it. Radio messages are limited to 64 KiB, and the headers need a
-- little room.
local MAX_MESSAGE = 60 * 1024

-- How big one value may be once `cc.net.codec` has encoded it, as an encrypted link does. That's a little bigger than
-- the modem's estimate for some values (a string takes 3 bytes more), and must still fit in a radio message.
local MAX_ENCODED = 61 * 1024

--- How deeply tables in a value may nest. `cc.net.codec` takes tables 64 deep, and on an encrypted link a value is
-- encoded inside a segment or datagram, a packet and a frame.
local MAX_DEPTH = 60

--- The limits for what programs send.
local PROGRAM = {
    --- The largest size, as the modem estimates it.
    size = MAX_MESSAGE,
    --- The largest size once encoded.
    encoded = MAX_ENCODED,
}

--- The limits for the stack's own tunnels, such as those between cells and a cellular network's core. A tunnel
-- carries a program's message with headers around it, so it needs more room, and only leaves enough for its own packet
-- and frame headers: a radio message is limited to 64 KiB.
local TUNNEL = {
    --- The largest size, as the modem estimates it.
    size = 64 * 1024 - 512,
    --- The largest size once encoded.
    encoded = 64 * 1024 - 512,
}

local KEY_KINDS = { number = true, string = true, boolean = true }

-- Add up a value's size, as the modem estimates it and once encoded, failing if it can't be sent or grows too big.
local function walk(value, max_size, max_encoded)
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
        if size > max_size or encoded > max_encoded then error("Message too large", 0) end
    end

    local ok, err = pcall(add, value, 0)
    if not ok then
        if type(err) ~= "string" or not (err:find("^Can't send") or err == "Message too large") then err = "Message too complex to send" end
        return nil, err
    end
    return size, encoded
end

--[[- Check a value can be sent: it isn't `nil`, isn't too big, and is something [`cc.net.codec`] can encode.

Sizes are estimated the same way modems do, and worked out as the codec would encode them.

@param value The value.
@tparam[opt] { size = number, encoded = number } limits The largest size, as the modem estimates it and once encoded:
what programs may send (`PROGRAM`) by default.
@treturn[1] true If it can be sent.
@treturn[2] nil If it can't.
@treturn[2] string Why not.
]]
local function check_message(value, limits)
    if value == nil then return nil, "Can't send nil" end
    limits = limits or PROGRAM
    local ok, err = walk(value, limits.size, limits.encoded)
    if not ok then return nil, err end
    return true
end

--[[- Measure how big a value is: as the modem estimates it, and once encoded.

@param value The value, which may be any size.
@treturn[1] number Its size, as the modem estimates it.
@treturn[1] number Its size once encoded.
@treturn[2] nil If it can't be sent at all.
@treturn[2] string Why not.
]]
local function measure(value)
    if value == nil then return nil, "Can't send nil" end
    return walk(value, math.huge, math.huge)
end

return {
    check = check_message,
    -- Only tests use this.
    measure = measure,
    MAX_MESSAGE = MAX_MESSAGE,
    MAX_DEPTH = MAX_DEPTH,
    PROGRAM = PROGRAM,
    TUNNEL = TUNNEL,
}
