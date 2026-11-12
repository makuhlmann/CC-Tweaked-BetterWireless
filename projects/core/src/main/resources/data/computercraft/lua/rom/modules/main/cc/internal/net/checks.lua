-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Checks on values which come from others, or from settings, before the network uses them.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

It needs nothing else, so the `net` API (which can't use `require` until it has started) can load it with `dofile`.

@local
]]

--- Whether a value is a whole number in a range.
--
-- @param value The value, which may be anything.
-- @tparam number min The smallest it may be.
-- @tparam number max The largest it may be.
-- @treturn boolean Whether it is.
local function is_integer(value, min, max)
    return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

--- Whether a value is a port: a whole number from 1 to 65535.
--
-- @param value The value, which may be anything.
-- @treturn boolean Whether it is.
local function is_port(value)
    return is_integer(value, 1, 65535)
end

--- What to say when something which should be a port isn't.
local PORT_ERROR = "Ports must be whole numbers from 1 to 65535"

local PROTOCOLS = { udp = true, tcp = true, icmp = true }

--- Whether a value is a protocol a firewall rule may name: `"udp"`, `"tcp"` or `"icmp"`.
--
-- @param value The value, which may be anything.
-- @treturn boolean Whether it is.
local function is_protocol(value)
    return PROTOCOLS[value] == true
end

return {
    is_integer = is_integer,
    is_port = is_port,
    PORT_ERROR = PORT_ERROR,
    is_protocol = is_protocol,
}
