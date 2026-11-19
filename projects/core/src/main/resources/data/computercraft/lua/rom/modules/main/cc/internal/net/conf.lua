-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The configuration files of the network's servers, in /etc: `dnsd.conf` and `dnsd.zones` for `dnsd`, and
`dhcpd.conf` for `dhcpd`.

A configuration file has a setting on each line: its name, then its values, separated by spaces. `#` starts a comment,
to the end of the line. A zones file has a `[zone]` line before each zone's names, and then a name and an address on
each line, as a zone's own file has.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local address = require "cc.net.address"

--- Where `dnsd` keeps its settings.
local DNSD_CONF = "/etc/dnsd.conf"

--- Where `dnsd` keeps the names in its zones.
local DNSD_ZONES = "/etc/dnsd.zones"

--- Where `dnsd` keeps the names it was told to set, by DHCP servers and cellular cores.
local DNSD_LEASES = "/etc/dnsd.leases"

--- Where `dhcpd` keeps its settings.
local DHCPD_CONF = "/etc/dhcpd.conf"

--- Where `dhcpd` keeps its leases.
local DHCPD_LEASES = "/etc/dhcpd.leases"

-- Leases are at least 30 seconds and at most a week, as clients take them.
local MIN_LEASE, MAX_LEASE = 30, 7 * 24 * 3600

--[[- Read a configuration file's lines.

@tparam string text The file's contents.
@treturn { { line = number, key = string, string... }... } Each line which says something: its number, the setting's
name (in lower case), and its values.
]]
local function parse(text)
    local lines, number = {}, 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        local words = {}
        for word in line:gsub("#.*", ""):gmatch("%S+") do words[#words + 1] = word end
        if words[1] then
            local entry = { line = number, key = words[1]:lower() }
            for i = 2, #words do entry[i - 1] = words[i] end
            lines[#lines + 1] = entry
        end
    end
    return lines
end

--- Read a file, if there is one.
--
-- @tparam string path The file.
-- @treturn string|nil Its contents, or `nil` if it can't be read.
local function read(path)
    if fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local text = handle.readAll() or ""
    handle.close()
    return text
end

--- Write a file, replacing what's there.
--
-- @tparam string path The file.
-- @tparam string text What to write.
-- @throws If it can't be written.
local function write(path, text)
    local handle, err = fs.open(path, "w")
    if not handle then error(err, 2) end
    handle.write(text)
    handle.close()
end

--- Whether text is a zone (or domain): names of lower case letters, digits and dashes, separated by dots.
--
-- @param value The value, which may be anything.
-- @treturn boolean Whether it is.
local function is_zone(value)
    if type(value) ~= "string" or #value < 1 or #value > 253 then return false end
    for label in (value .. "."):gmatch("([^%.]*)%.") do
        if #label > 63 or not label:find("^[%l%d%-]+$") then return false end
    end
    return true
end

--- Whether text is a name within a zone, as a computer's hostname is: one label.
--
-- @param value The value, which may be anything.
-- @treturn boolean Whether it is.
local function is_label(value)
    return type(value) == "string" and #value >= 1 and #value <= 63 and value:find("^[%l%d%-]+$") ~= nil
end

-- A zone as it's written: lower case, without a trailing dot. Nil if it isn't one.
local function zone_of(text)
    local zone = text:lower():gsub("%.$", "")
    return is_zone(zone) and zone or nil
end

-- A server's address: one address, not a network, nor nothing or everyone.
local function server_of(text)
    local addr, prefix = address.parse(text)
    if not addr or prefix or addr == 0 or addr == 0xFFFFFFFF then return nil end
    return addr
end

-- A secret to sign updates with: anything but spaces and #, which a line can't hold.
local function is_secret(value)
    return type(value) == "string" and #value >= 1 and #value <= 128
end

local function problem(errors, entry, text, ...)
    errors[#errors + 1] = ("Line %d: " .. text):format(entry.line, ...)
end

-- Read a line's values as servers' addresses, adding them to a list. Says what's wrong if one isn't.
local function servers(errors, entry, first, list)
    if not entry[first] then return problem(errors, entry, "%s needs at least one server", entry.key) end
    for i = first, #entry do
        local addr = server_of(entry[i])
        if addr then list[#list + 1] = addr else problem(errors, entry, "%s isn't a server's address", entry[i]) end
    end
end

--[[- Read dnsd's settings.

@tparam string text What `/etc/dnsd.conf` says.
@treturn {
    zones = { { zone = string, file? = string }... },
    forward = { { zone = string, servers = { number... } }... },
    upstream = { number... },
    allow = { { network = number, prefix = number }... },
    key? = string,
} The zones it answers for (from their part of the zones file, or a file of their own); the zones it asks other servers
about, and which; the servers it asks about names in none of those; who (besides this computer) may set and delete
names; and the secret updates are signed with, if there is one.
@treturn { string... } What's wrong with it, by line.
]]
local function dnsd(text)
    local config, errors = { zones = {}, forward = {}, upstream = {}, allow = {} }, {}
    local seen = {}
    for _, entry in ipairs(parse(text)) do
        local key = entry.key
        if key == "zone" or key == "forward" then
            local zone = entry[1] and zone_of(entry[1])
            if not zone then
                problem(errors, entry, "%s needs a zone, such as home", key)
            elseif seen[zone] then
                problem(errors, entry, "%s is there twice", zone)
            elseif key == "zone" then
                seen[zone] = true
                if #entry > 2 then
                    problem(errors, entry, "zone takes a zone, and maybe its file")
                else
                    config.zones[#config.zones + 1] = { zone = zone, file = entry[2] }
                end
            else
                seen[zone] = true
                local list = {}
                servers(errors, entry, 2, list)
                config.forward[#config.forward + 1] = { zone = zone, servers = list }
            end
        elseif key == "upstream" then
            servers(errors, entry, 1, config.upstream)
        elseif key == "allow-update" then
            if not entry[1] then problem(errors, entry, "allow-update needs an address or a network") end
            for _, value in ipairs(entry) do
                local addr, prefix = address.parse(value)
                if addr then
                    prefix = prefix or 32
                    config.allow[#config.allow + 1] = { network = address.network(addr, prefix), prefix = prefix }
                else
                    problem(errors, entry, "%s isn't an address or a network", value)
                end
            end
        elseif key == "key" then
            if #entry ~= 1 or not is_secret(entry[1]) then
                problem(errors, entry, "key takes one secret, up to 128 characters, without spaces or #")
            else
                config.key = entry[1]
            end
        else
            problem(errors, entry, "there's no setting called %s", key)
        end
    end
    if not config.zones[1] and not config.forward[1] and not config.upstream[1] and not errors[1] then
        errors[1] = "There's nothing to do: add a zone (such as \"zone home\"), or servers to ask"
    end
    return config, errors
end

--[[- Read the names in dnsd's zones: a `[zone]` line, then a name (`@` for the zone itself) and an address on each line.

@tparam string text What `/etc/dnsd.zones` says.
@treturn { [string] = { [string] = number } } Each zone's names, by name within the zone.
@treturn { string... } What's wrong with it, by line.
]]
local function zones(text)
    local result, errors, current = {}, {}, nil
    local number = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        line = line:gsub("#.*", "")
        local header = line:match("^%s*%[(.-)%]%s*$")
        local name, value = line:match("^%s*(%S+)%s+(%S+)%s*$")
        if header then
            local zone = zone_of(header)
            if zone then
                current = result[zone] or {}
                result[zone] = current
            else
                current = nil
                errors[#errors + 1] = ("Line %d: %s isn't a zone"):format(number, header)
            end
        elseif name then
            local addr, prefix = address.parse(value)
            if not current then
                errors[#errors + 1] = ("Line %d: names come after their zone, such as [home]"):format(number)
            elseif not addr or prefix then
                errors[#errors + 1] = ("Line %d: expected a name and an address"):format(number)
            else
                local key = name:lower():gsub("%.$", "")
                current[key] = addr
            end
        elseif line:find("%S") then
            errors[#errors + 1] = ("Line %d: expected a name and an address"):format(number)
        end
    end
    return result, errors
end

--[[- Read dhcpd's settings.

@tparam string text What `/etc/dhcpd.conf` says.
@treturn {
    interface? = string, address? = number, range? = { first = number, last = number, numbers = boolean },
    lease = number, gateway? = number, dns = { number... }, domain? = string,
    update? = { server = number, zone? = string, key? = string }, hosts = { [number] = number },
} The interface to hand out addresses on, or its address; the range to hand out (addresses, or numbers within the
network); how long leases last; what clients are told; where to register clients' names, if anywhere; and fixed
addresses, by computer ID.
@treturn { string... } What's wrong with it, by line.
]]
local function dhcpd(text)
    local config, errors = { lease = 3600, dns = {}, hosts = {} }, {}
    local update = {}
    local taken = {}
    for _, entry in ipairs(parse(text)) do
        local key, value = entry.key, entry[1]
        local single = #entry == 1
        if key == "interface" then
            if not single then problem(errors, entry, "interface takes the interface's name, such as top")
            else config.interface = value end
        elseif key == "address" then
            local addr = single and server_of(value)
            if not addr then problem(errors, entry, "address takes the address of the interface to use")
            else config.address = addr end
        elseif key == "range" then
            -- Two addresses, or two numbers within the network (as the network is only known once dhcpd has found
            -- its interface).
            local numbers = #entry == 2 and value:find("^%d+$") ~= nil and entry[2]:find("^%d+$") ~= nil
            local first, last
            if numbers then
                first, last = tonumber(value), tonumber(entry[2])
            elseif #entry == 2 then
                first, last = server_of(value), server_of(entry[2])
            end
            if not first or not last then
                problem(errors, entry, "range takes the first and last addresses, such as 10.0.0.100 10.0.0.199, or 100 199")
            elseif first > last then
                problem(errors, entry, "the range's first address comes after its last")
            else
                config.range = { first = first, last = last, numbers = numbers }
            end
        elseif key == "lease" then
            local seconds = single and tonumber(value)
            if not seconds or seconds % 1 ~= 0 or seconds < MIN_LEASE or seconds > MAX_LEASE then
                problem(errors, entry, "lease takes a number of seconds, from %d to %d", MIN_LEASE, MAX_LEASE)
            else
                config.lease = seconds
            end
        elseif key == "gateway" then
            local addr = single and server_of(value)
            if not addr then problem(errors, entry, "gateway takes an address") else config.gateway = addr end
        elseif key == "dns" then
            servers(errors, entry, 1, config.dns)
        elseif key == "domain" then
            local zone = single and zone_of(value)
            if not zone then problem(errors, entry, "domain takes a domain, such as home") else config.domain = zone end
        elseif key == "update-server" then
            local addr = single and server_of(value)
            if not addr then problem(errors, entry, "update-server takes a DNS server's address") else update.server = addr end
        elseif key == "update-zone" then
            local zone = single and zone_of(value)
            if not zone then problem(errors, entry, "update-zone takes a zone, such as home") else update.zone = zone end
        elseif key == "update-key" then
            if not single or not is_secret(value) then
                problem(errors, entry, "update-key takes one secret, up to 128 characters, without spaces or #")
            else
                update.key = value
            end
        elseif key == "host" then
            local id, addr = tonumber(value or ""), entry[2] and server_of(entry[2])
            if #entry ~= 2 or not id or id % 1 ~= 0 or id < 0 or id > 0x7FFFFFFF or not addr then
                problem(errors, entry, "host takes a computer's ID and its address, such as 12 10.0.0.50")
            elseif config.hosts[id] then
                problem(errors, entry, "computer %d has an address already", id)
            elseif taken[addr] then
                problem(errors, entry, "%s is computer %d's already", entry[2], taken[addr])
            else
                config.hosts[id], taken[addr] = addr, id
            end
        else
            problem(errors, entry, "there's no setting called %s", key)
        end
    end
    if config.interface and config.address then
        errors[#errors + 1] = "Give either the interface or its address, not both"
    elseif not config.interface and not config.address and not errors[1] then
        errors[#errors + 1] = "Say which interface to hand out addresses on, such as \"interface top\""
    end
    if update.server then
        config.update = update
    elseif update.zone or update.key then
        errors[#errors + 1] = "update-zone and update-key need update-server, the DNS server to register names at"
    end
    return config, errors
end

--[[- What `/etc/dnsd.conf` says at first.

@tparam[opt] { zones? = { { zone = string, file? = string }... }, upstream? = { number... } } settings What to set
rather than the examples: the zones (by default, `home`), and the servers to ask about other names.
@treturn string The file's contents.
]]
local function dnsd_default(settings)
    settings = settings or {}
    local zone_lines = {}
    for i, zone in ipairs(settings.zones or { { zone = "home" } }) do
        zone_lines[i] = "zone " .. zone.zone .. (zone.file and " " .. zone.file or "")
    end
    local upstream = {}
    for i, addr in ipairs(settings.upstream or {}) do upstream[i] = address.format(addr) end
    return ([[
# dnsd's settings: a setting on each line, its name and then its values, separated by spaces. # starts a comment.
# Changes take effect when dnsd starts again ("dnsd restart").

# The zones dnsd answers for. Their names are in /etc/dnsd.zones, unless a zone has a file of its own after it:
#   zone shop.home /zones/shop.zone
%s

# Zones to ask other DNS servers about, with one or more servers each:
#   forward corp 10.1.0.53 10.1.0.54

# The DNS servers to ask about names in no zone here. With none, they aren't found.
%s

# Who may set and delete names in the zones (as dhcpd and cellcore do), besides this computer: addresses, or networks.
#   allow-update 10.0.0.2 10.0.1.0/24

# A secret every update must be signed with: dhcpd's update-key, and cellcore's hostname key. No spaces or #.
#   key s3cret
]]):format(table.concat(zone_lines, "\n"),
        upstream[1] and "upstream " .. table.concat(upstream, " ") or "#   upstream 10.0.0.2 10.0.0.3")
end

--- What `/etc/dnsd.zones` says at first.
--
-- @tparam { string... } zone_names The zones whose names are in it, which have none yet.
-- @treturn string The file's contents.
local function zones_default(zone_names)
    local sections = {}
    for i, zone in ipairs(zone_names) do sections[i] = ("[%s]\n#   printer 10.0.0.5\n"):format(zone) end
    return ([[
# The names in dnsd's zones: a [zone] line, and then a name and an address on each line. "@" is the zone itself.
# dnsd reads this file again whenever it changes.

%s]]):format(table.concat(sections, "\n"))
end

--[[- What `/etc/dhcpd.conf` says at first.

@tparam[opt] {
    interface? = string, range? = { string, string }, lease? = number, gateway? = number, dns? = { number... },
    domain? = string, update? = { server = number, zone? = string },
} settings What to set rather than the examples.
@treturn string The file's contents.
]]
local function dhcpd_default(settings)
    settings = settings or {}
    local function line(setting, text, example)
        return text and setting .. " " .. text or "#   " .. setting .. " " .. example
    end
    local dns = {}
    for i, addr in ipairs(settings.dns or {}) do dns[i] = address.format(addr) end
    local update = settings.update or {}
    return ([[
# dhcpd's settings: a setting on each line, its name and then its values, separated by spaces. # starts a comment.
# Changes take effect when dhcpd starts again ("dhcpd restart").

# The interface to hand out addresses on, which has a fixed address. Or "address 10.0.0.1": the interface with that
# address.
%s

# The addresses to hand out: from the first to the last, as addresses or numbers within the network (on 10.0.0.0/24,
# 100 is 10.0.0.100).
range %s %s

# How long a lease lasts, in seconds. Clients renew it halfway through.
lease %d

# What clients are told: their gateway, DNS servers (one or more) and domain.
%s
%s
%s

# Register clients' names at a DNS server (dnsd), in a zone (the domain, if not given), with the key it asks for.
%s
%s
#   update-key s3cret

# Fixed addresses, by computer ID: a computer always gets its own, and nobody else does.
#   host 12 10.0.0.50
]]):format(
        settings.interface and "interface " .. settings.interface or "#   interface top",
        settings.range and settings.range[1] or "100", settings.range and settings.range[2] or "199",
        settings.lease or 3600,
        line("gateway", settings.gateway and address.format(settings.gateway), "10.0.0.1"),
        line("dns", dns[1] and table.concat(dns, " "), "10.0.0.1"),
        line("domain", settings.domain, "home"),
        line("update-server", update.server and address.format(update.server), "10.0.0.1"),
        line("update-zone", update.zone, "home")
    )
end

return {
    DNSD_CONF = DNSD_CONF, DNSD_ZONES = DNSD_ZONES, DNSD_LEASES = DNSD_LEASES,
    DHCPD_CONF = DHCPD_CONF, DHCPD_LEASES = DHCPD_LEASES,
    parse = parse, read = read, write = write,
    is_zone = is_zone, is_label = is_label,
    dnsd = dnsd, zones = zones, dhcpd = dhcpd,
    dnsd_default = dnsd_default, zones_default = zones_default, dhcpd_default = dhcpd_default,
}
