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

local KEY_KINDS = { number = true, string = true, boolean = true }

--[[- Check a value can be sent: it isn't `nil`, isn't too big, and is something [`cc.net.codec`] can encode.

Sizes are estimated the same way modems do, and worked out as the codec would encode them.

@param value The value.
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

return {
    check = check_message,
    MAX_MESSAGE = MAX_MESSAGE,
    MAX_DEPTH = MAX_DEPTH,
}
