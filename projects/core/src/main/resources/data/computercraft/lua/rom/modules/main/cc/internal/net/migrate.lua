-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Moving `dnsd` and `dhcpd` to their files in /etc, from how they were set up before: the arguments their services
were started with, their settings (`dnsd.forward`, and `dhcpd.lease`, `dhcpd.dns`, `dhcpd.domain` and
`dhcpd.gateway`), and the leases dhcpd kept in `/.dhcpd`. Each program does this once, when it has no file in /etc yet.

This module, and what calls it, can go once every computer has moved.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local address = require "cc.net.address"
local conf = require "cc.internal.net.conf"

local LEGACY_LEASES = "/.dhcpd"

--[[- The arguments a service was started with before, after `run`: how dnsd and dhcpd were told what to do.

@tparam string name The service, `"dnsd"` or `"dhcpd"`.
@treturn { string... } The arguments, which may be none.
]]
local function service_words(name)
    local info = service.status(name)
    local words, after = {}, false
    for word in ((info and info.command) or ""):gmatch("%S+") do
        if after then words[#words + 1] = word elseif word == "run" then after = true end
    end
    return words
end

-- The zones dnsd was told to answer for, each with its file if it has one: the zones, each maybe followed by its file
-- (a path, or a .txt file), and otherwise in /zones.
local function legacy_zones(words)
    local zones, seen = {}, {}
    for _, word in ipairs(words) do
        if word:find("/", 1, true) or word:sub(-4):lower() == ".txt" then
            local last = zones[#zones]
            if last and not last.given then last.file, last.given = word, true end
        else
            local zone = word:lower():gsub("%.$", "")
            if conf.is_zone(zone) and not seen[zone] then
                seen[zone] = true
                zones[#zones + 1] = { zone = zone, file = "/zones/" .. zone .. ".txt" }
            end
        end
    end
    for _, zone in ipairs(zones) do
        local path = zone.file:sub(1, 1) == "/" and zone.file or "/" .. zone.file
        -- A zone without its file yet keeps its names in /etc/dnsd.zones from now on.
        zone.file, zone.given = fs.exists(path) and not fs.isDir(path) and path or nil, nil
    end
    return zones
end

-- Addresses in a setting, separated by commas or spaces.
local function addresses(text)
    local result = {}
    for value in (text or ""):gmatch("[^,%s]+") do
        local addr, prefix = address.parse(value)
        if addr and not prefix then result[#result + 1] = addr end
    end
    return result
end

--[[- Write dnsd's files in /etc, from how it was set up before, or as they are at first if it wasn't.

@tparam[opt] { string... } words The arguments dnsd was run with before, if it was: by default, those its service was
started with.
@treturn boolean Whether there was anything to move.
]]
local function dnsd(words)
    if not words or not words[1] then words = service_words("dnsd") end
    local zones = legacy_zones(words)
    local forward = settings.get("dnsd.forward")
    local moved = zones[1] ~= nil or forward ~= nil

    local upstream
    if forward == "none" then
        upstream = {}
    elseif forward and forward ~= "" then
        upstream = addresses(forward)
    elseif zones[1] then
        -- dnsd forwarded to net.dns when it wasn't told otherwise.
        upstream = addresses(settings.get("net.dns"))
    end
    if not zones[1] then zones = { { zone = "home" } } end

    conf.write(conf.DNSD_CONF, conf.dnsd_default { zones = zones, upstream = upstream })
    if not fs.exists(conf.DNSD_ZONES) then
        local in_file = {}
        for _, zone in ipairs(zones) do
            if not zone.file then in_file[#in_file + 1] = zone.zone end
        end
        conf.write(conf.DNSD_ZONES, conf.zones_default(in_file))
    end
    if forward ~= nil then
        settings.unset("dnsd.forward")
        settings.save()
    end
    return moved
end

-- The zones dnsd answers for on this computer, if it runs here: from its file, or how it was started before.
local function dnsd_zones()
    local text = conf.read(conf.DNSD_CONF)
    local result = {}
    if text then
        for _, zone in ipairs(conf.dnsd(text).zones) do result[#result + 1] = zone.zone end
    elseif service.status("dnsd") then
        for _, zone in ipairs(legacy_zones(service_words("dnsd"))) do result[#result + 1] = zone.zone end
    end
    return result
end

--[[- Write dhcpd's file in /etc, from how it was set up before, or as it is at first if it wasn't: then it hands out
addresses on the first interface with a fixed address, if there is one.

@tparam[opt] { string... } words The arguments dhcpd was run with before, if it was: by default, those its service was
started with.
@treturn boolean Whether there was anything to move.
]]
local function dhcpd(words)
    if not words or not words[1] then words = service_words("dhcpd") end
    local names = { "dhcpd.lease", "dhcpd.dns", "dhcpd.domain", "dhcpd.gateway" }
    local moved = words[1] ~= nil
    for _, name in ipairs(names) do
        if settings.get(name) ~= nil then moved = true end
    end

    local interface = words[1]
    if not interface then
        -- The first interface (by name) with a fixed address.
        local found = {}
        for _, info in ipairs(net.interfaces()) do
            if info.config == "static" and info.address then found[#found + 1] = info.name end
        end
        table.sort(found)
        interface = found[1]
    end
    local range
    if words[2] then range = { words[2], words[3] or words[2] } end
    if words[2] and not words[3] then
        -- Only the first was given: a hundred addresses from it, as before.
        local number, addr = tonumber(words[2]), address.parse(words[2])
        if number then
            range[2] = tostring(number + 99)
        elseif addr then
            range[2] = address.format(math.min(addr + 99, 0xFFFFFFFE))
        end
    end

    local lease = tonumber(settings.get("dhcpd.lease"))
    local domain = settings.get("dhcpd.domain")
    domain = type(domain) == "string" and domain:lower():gsub("%.$", "") or nil
    if domain and not conf.is_zone(domain) then domain = nil end
    local gateway = settings.get("dhcpd.gateway")
    local update
    -- dnsd found the names of dhcpd's clients itself, when it ran on the same computer: now dhcpd tells it.
    local zones = dnsd_zones()
    if zones[1] then
        local zone = zones[1]
        for _, each in ipairs(zones) do
            if each == domain then zone = each end
        end
        update = { server = address.parse("127.0.0.1"), zone = zone ~= domain and zone or nil }
    end

    conf.write(conf.DHCPD_CONF, conf.dhcpd_default {
        interface = interface, range = range,
        lease = lease and lease % 1 == 0 and lease >= 30 and lease <= 7 * 24 * 3600 and lease or nil,
        gateway = type(gateway) == "string" and addresses(gateway)[1] or nil,
        dns = addresses(settings.get("dhcpd.dns")), domain = domain, update = update,
    })

    -- Clients keep their addresses.
    local old = interface and fs.combine(LEGACY_LEASES, interface .. ".leases")
    if old and fs.exists(old) and not fs.exists(conf.DHCPD_LEASES) then fs.copy(old, conf.DHCPD_LEASES) end

    local changed = false
    for _, name in ipairs(names) do
        if settings.get(name) ~= nil then
            settings.unset(name)
            changed = true
        end
    end
    if changed then settings.save() end
    return moved
end

return { dnsd = dnsd, dhcpd = dhcpd, service_words = service_words }
