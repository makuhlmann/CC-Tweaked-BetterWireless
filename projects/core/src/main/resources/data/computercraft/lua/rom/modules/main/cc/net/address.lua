-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Parse, format and compare network addresses, as used by the [`net`] API.

Network addresses are 32-bit numbers, written as four numbers from 0 to 255 separated by dots, such as `10.0.0.1`. An
address can be followed by a prefix length, such as `10.0.0.1/24`. This says how many of its leading bits name the
network (here `10.0.0.0`), with the rest naming one computer on it.

@module cc.net.address
@usage Find the network and broadcast address of an address.

```lua
local address = require "cc.net.address"
local addr, prefix = address.parse("10.0.0.17/24")
print(address.format(address.network(addr, prefix))) -- 10.0.0.0
print(address.format(address.broadcast(addr, prefix))) -- 10.0.0.255
```
]]

local expect = require "cc.expect".expect
local band, bnot, lshift, extract = bit32.band, bit32.bnot, bit32.lshift, bit32.extract

--- The address of every computer on the local network.
local BROADCAST = 0xFFFFFFFF

--- The unspecified address, used by computers which don't have an address yet.
local ANY = 0

--- Get the network mask for a prefix length.
--
-- @tparam number prefix The prefix length, from 0 to 32.
-- @treturn number The mask, with the first `prefix` bits set.
local function mask(prefix)
    expect(1, prefix, "number")
    if prefix <= 0 then return 0 end
    if prefix >= 32 then return 0xFFFFFFFF end
    return lshift(0xFFFFFFFF, 32 - prefix)
end

--- Parse an address, with an optional prefix length.
--
-- @tparam string text The address, such as `"10.0.0.1"` or `"10.0.0.1/24"`.
-- @treturn[1] number The address.
-- @treturn[1] number|nil The prefix length, if one was given.
-- @treturn[2] nil If the address is invalid.
-- @treturn[2] string Why it is invalid.
local function parse(text)
    expect(1, text, "string")
    local a, b, c, d, rest = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then return nil, "Invalid address '" .. text .. "'" end

    local prefix
    if rest ~= "" then
        prefix = rest:match("^/(%d+)$")
        prefix = tonumber(prefix)
        if not prefix or prefix > 32 then return nil, "Invalid prefix length in '" .. text .. "'" end
    end

    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil, "Invalid address '" .. text .. "'" end
    return ((a * 256 + b) * 256 + c) * 256 + d, prefix
end

--- Format an address as text.
--
-- @tparam number address The address.
-- @tparam[opt] number prefix A prefix length to add.
-- @treturn string The address, such as `"10.0.0.1"` or `"10.0.0.1/24"`.
local function format(address, prefix)
    expect(1, address, "number")
    expect(2, prefix, "number", "nil")
    local text = ("%d.%d.%d.%d"):format(
        extract(address, 24, 8), extract(address, 16, 8), extract(address, 8, 8), extract(address, 0, 8)
    )
    if prefix then text = text .. "/" .. prefix end
    return text
end

--- Get the network part of an address.
--
-- @tparam number address The address.
-- @tparam number prefix The prefix length.
-- @treturn number The network's address.
local function network(address, prefix)
    expect(1, address, "number")
    return band(address, mask(prefix))
end

--- Get the broadcast address of a network: the last address on it, which reaches every computer on it.
--
-- @tparam number address Any address on the network.
-- @tparam number prefix The prefix length.
-- @treturn number The broadcast address.
local function broadcast(address, prefix)
    expect(1, address, "number")
    local m = mask(prefix)
    return band(address, m) + band(bnot(m), 0xFFFFFFFF)
end

--- Check whether an address is on a network.
--
-- @tparam number network_address Any address on the network.
-- @tparam number prefix The network's prefix length.
-- @tparam number address The address to check.
-- @treturn boolean Whether the address is on the network.
local function contains(network_address, prefix, address)
    expect(1, network_address, "number")
    expect(3, address, "number")
    local m = mask(prefix)
    return band(network_address, m) == band(address, m)
end

--- Check whether an address refers to this computer (`127.0.0.0/8`).
--
-- @tparam number address The address.
-- @treturn boolean Whether it is a loopback address.
local function is_loopback(address)
    expect(1, address, "number")
    return extract(address, 24, 8) == 127
end

--- Check whether a value is an address at all: a whole number from 0 to 2^32 - 1. Use this on addresses from other
-- computers, which may be anything.
--
-- @param value The value.
-- @treturn boolean Whether it is an address.
local function is_valid(value)
    return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFFFFFFFF
end

--- Check whether an address is a link-local one (`169.254.0.0/16`), which computers give themselves when there's no
-- DHCP server. These only mean something on their own link, so routers don't forward them.
--
-- @tparam number address The address.
-- @treturn boolean Whether it is a link-local address.
local function is_link_local(address)
    expect(1, address, "number")
    return extract(address, 16, 16) == 0xA9FE
end

return {
    BROADCAST = BROADCAST,
    ANY = ANY,
    mask = mask,
    parse = parse,
    format = format,
    network = network,
    broadcast = broadcast,
    contains = contains,
    is_loopback = is_loopback,
    is_valid = is_valid,
    is_link_local = is_link_local,
}
