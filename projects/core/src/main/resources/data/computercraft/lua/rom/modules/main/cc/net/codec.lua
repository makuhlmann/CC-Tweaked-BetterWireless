-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Turn Lua values into bytes and back, for encrypting, signing or storing them.

Encryption and signatures work on bytes, but programs deal in Lua values. This writes values as bytes in a way which
only depends on the value: a table's keys are written in order (numbers, then strings, then `false` and `true`), so the
same table always gives the same bytes, however it was built. That matters for signatures, which must be checked
against exactly the bytes that were signed.

Strings, numbers, booleans and tables of them can be written. Functions, tables used as keys, and tables which contain
themselves can't.

@module cc.net.codec
@usage Write a table as bytes, and read it back.

```lua
local codec = require "cc.net.codec"
local bytes = codec.encode({ name = "bank", balance = 100 })
print(codec.decode(bytes).balance) -- 100
```
]]

local expect = require "cc.expect".expect

local NIL, FALSE, TRUE, NUMBER, NAN, STRING, TABLE = "\0", "\1", "\2", "\3", "\4", "\5", "\6"

-- How deeply tables may nest. Decoding is limited too, so bytes from someone else can't overflow the stack.
local MAX_DEPTH = 64

-- The order keys are written in: numbers, then strings, then false and true.
local KEY_RANKS = { number = 1, string = 2, boolean = 3 }
local function key_order(a, b)
    local rank_a, rank_b = KEY_RANKS[type(a)], KEY_RANKS[type(b)]
    if rank_a ~= rank_b then return rank_a < rank_b end
    if rank_a == 3 then return not a and b end
    return a < b
end

local function encode_value(value, out, depth, open)
    local kind = type(value)
    if kind == "nil" then
        out[#out + 1] = NIL
    elseif kind == "boolean" then
        out[#out + 1] = value and TRUE or FALSE
    elseif kind == "number" then
        if value ~= value then
            out[#out + 1] = NAN
        else
            -- -0 and 0 are the same value, so write them the same way.
            if value == 0 then value = 0 end
            out[#out + 1] = NUMBER .. string.pack("<d", value)
        end
    elseif kind == "string" then
        out[#out + 1] = STRING .. string.pack("<s4", value)
    elseif kind == "table" then
        if open[value] then error("Can't encode a table which contains itself", 0) end
        if depth >= MAX_DEPTH then error("Tables are nested too deeply", 0) end
        open[value] = true

        local keys = {}
        for key in pairs(value) do
            if not KEY_RANKS[type(key)] then error("Can't encode a table with a " .. type(key) .. " as a key", 0) end
            keys[#keys + 1] = key
        end
        table.sort(keys, key_order)
        out[#out + 1] = TABLE .. string.pack("<I4", #keys)
        for _, key in ipairs(keys) do
            encode_value(key, out, depth + 1, open)
            encode_value(value[key], out, depth + 1, open)
        end

        open[value] = nil
    else
        error("Can't encode a " .. kind, 0)
    end
end

--[[- Write a value as bytes.

@param value The value: `nil`, a boolean, number or string, or a table of them.
@treturn string The bytes.
@throws If the value can't be written: it contains a function, a table used as a key, or a table which contains itself,
or tables nested more than 64 deep.
]]
local function encode(value)
    local out = {}
    encode_value(value, out, 0, {})
    return table.concat(out)
end

local function decode_value(bytes, position, depth)
    local tag = bytes:sub(position, position)
    position = position + 1
    if tag == NIL then
        return nil, position
    elseif tag == FALSE then
        return false, position
    elseif tag == TRUE then
        return true, position
    elseif tag == NAN then
        return 0 / 0, position
    elseif tag == NUMBER then
        if position + 7 > #bytes then error("truncated", 0) end
        return string.unpack("<d", bytes, position)
    elseif tag == STRING then
        if position + 3 > #bytes then error("truncated", 0) end
        local length = string.unpack("<I4", bytes, position)
        if position + 3 + length > #bytes then error("truncated", 0) end
        return bytes:sub(position + 4, position + 3 + length), position + 4 + length
    elseif tag == TABLE then
        if depth >= MAX_DEPTH then error("too deep", 0) end
        if position + 3 > #bytes then error("truncated", 0) end
        local count = string.unpack("<I4", bytes, position)
        position = position + 4
        -- Every entry takes at least two bytes, so a huge count is a lie.
        if count * 2 > #bytes - position + 1 then error("truncated", 0) end

        local result = {}
        for _ = 1, count do
            local key, value
            key, position = decode_value(bytes, position, depth + 1)
            if not KEY_RANKS[type(key)] or key ~= key or result[key] ~= nil then error("bad key", 0) end
            value, position = decode_value(bytes, position, depth + 1)
            result[key] = value
        end
        return result, position
    else
        error("bad tag", 0)
    end
end

--[[- Read a value written by [`encode`].

@tparam string bytes The bytes.
@return[1] The value.
@treturn[2] nil If the bytes aren't a value written by [`encode`].
@treturn[2] string An error message.
]]
local function decode(bytes)
    expect(1, bytes, "string")
    local ok, value, position = pcall(decode_value, bytes, 1, 0)
    if not ok or position ~= #bytes + 1 then return nil, "Invalid data" end
    return value
end

return {
    encode = encode,
    decode = decode,
}
