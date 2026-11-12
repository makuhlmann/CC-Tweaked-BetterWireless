-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The small files the network's programs and services keep, and keys written as hexadecimal digits.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

It needs nothing else, so the `net` API (which can't use `require` until it has started) can load it with `dofile`.

@local
]]

--- Where secure connections keep the certificate authorities this computer trusts.
local TRUSTED = "/.net/trust"
--- Where this computer keeps its certificate, if it has one.
local CERTIFICATE = "/.net/certificate"
--- Where secure connections keep the keys they've seen for other computers.
local KNOWN_HOSTS = "/.net/known_hosts"

--- Keys and other bytes written as hexadecimal digits.
local hex = {}

--- Write bytes as hexadecimal digits, in lower case.
--
-- @tparam string bytes The bytes.
-- @treturn string The digits, two for each byte.
function hex.encode(bytes)
    return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

--- Read hexadecimal digits as bytes.
--
-- @param text The digits, which may be anything.
-- @tparam[opt] number length How many bytes there must be, if it matters (32 for a key).
-- @treturn string|nil The bytes, or `nil` if the text isn't that.
function hex.decode(text, length)
    if type(text) ~= "string" or #text % 2 ~= 0 or text:find("[^%x]") then return nil end
    if length and #text ~= length * 2 then return nil end
    return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

--- Whether text is a key: 64 hexadecimal digits.
--
-- @param text The text, which may be anything.
-- @treturn boolean Whether it's a key.
function hex.is_key(text)
    return type(text) == "string" and #text == 64 and not text:find("[^%x]")
end

--- Read a table from a file, as `textutils.serialise` wrote it.
--
-- @tparam string path The file.
-- @treturn table What's in it, or an empty table if there's no such file, or it doesn't hold a table.
local function read_table(path)
    local file = fs.open(path, "r")
    if not file then return {} end
    local value = textutils.unserialise(file.readAll() or "")
    file.close()
    return type(value) == "table" and value or {}
end

--- Write a table to a file, replacing what's there.
--
-- @tparam string path The file.
-- @tparam table value The table.
-- @throws If the file can't be written.
local function write_table(path, value)
    local file, err = fs.open(path, "w")
    if not file then error(err, 2) end
    file.write(textutils.serialise(value))
    file.close()
end

return {
    TRUSTED = TRUSTED,
    CERTIFICATE = CERTIFICATE,
    KNOWN_HOSTS = KNOWN_HOSTS,
    hex = hex,
    read_table = read_table,
    write_table = write_table,
}
