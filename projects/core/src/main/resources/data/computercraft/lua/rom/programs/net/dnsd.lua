-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DNS server for one or more zones, which asks other DNS servers about names in other zones, and lets DHCP servers
-- (and cellular cores) set names in its zones. Its settings are in /etc/dnsd.conf. It runs in the background as a
-- service ("dnsd start"), or in the foreground ("dnsd run") until Ctrl+T.

local address = require "cc.net.address"
local dns = require "cc.internal.net.dns"
local conf = require "cc.internal.net.conf"
local files = require "cc.internal.net.files"
local cli = require "cc.internal.service_cli"
local migrate = require "cc.internal.net.migrate"

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())
local command_words = { "/" .. shell.getRunningProgram(), "run" }

local function usage()
    print("Usages:")
    print(name .. " start")
    print(name .. " stop")
    print(name .. " restart")
    print(name .. " status")
    print(name .. " run")
    print(("Its settings are in %s, and its zones' names in %s."):format(conf.DNSD_CONF, conf.DNSD_ZONES))
end

-- Write dnsd's files in /etc the first time, from how it was set up before (with these arguments, or its service's),
-- if it was.
local function first_time(words)
    if fs.exists(conf.DNSD_CONF) then return end
    if migrate.dnsd(words) then
        print(("Moved dnsd's settings to %s."):format(conf.DNSD_CONF))
    else
        print(("Wrote %s: dnsd answers for the zone home. Change it there."):format(conf.DNSD_CONF))
    end
end

local command = args[1]
local how_to_stop = ('"%s stop"'):format(name)
if command == "stop" and #args == 1 then
    cli.stop("dnsd", "dnsd isn't running here.")
    return
elseif command == "status" and #args == 1 then
    cli.status("dnsd", ('dnsd isn\'t set up here: start it with "%s start".'):format(name))
    return
elseif command == "start" and #args == 1 then
    first_time()
    cli.add("dnsd", command_words, how_to_stop)
    return
elseif command == "restart" and #args == 1 then
    first_time()
    cli.restart("dnsd", command_words, how_to_stop)
    return
elseif command ~= "run" then
    usage()
    return
end

-- Run. A service started before dnsd had its files in /etc says how it was set up: they're written from that.
if args[2] then
    first_time({ table.unpack(args, 2) })
    print(("dnsd's settings are in %s now. \"dnsd start\" starts it without the arguments it was given before.")
        :format(conf.DNSD_CONF))
else
    first_time()
end

local config, config_errors = conf.dnsd(conf.read(conf.DNSD_CONF) or "")
if config_errors[1] then
    for _, err in ipairs(config_errors) do printError(conf.DNSD_CONF .. ": " .. err) end
    printError("dnsd won't start until its settings make sense.")
    return
end

-- When a file last changed, and its size: when neither has, what was read from it last time is still right.
local function stamp(path)
    local ok, attributes = pcall(fs.attributes, path)
    if not ok or type(attributes) ~= "table" then return nil end
    return ("%s:%s"):format(attributes.modified, attributes.size)
end

-- The names in /etc/dnsd.zones, read again whenever it changes, so changes apply straight away. What's wrong with it
-- is printed once, not for every question.
local served = {}
for _, zone in ipairs(config.zones) do served[zone.zone] = true end
local zones_file = { stamp = false, zones = {} }
local function zones_file_records()
    local now = stamp(conf.DNSD_ZONES)
    if now == zones_file.stamp then return zones_file.zones end
    zones_file.stamp, zones_file.zones = now, {}
    local text = now and conf.read(conf.DNSD_ZONES)
    if not text then return zones_file.zones end
    local result, errors = conf.zones(text)
    for _, err in ipairs(errors) do printError(conf.DNSD_ZONES .. ": " .. err) end
    for zone in pairs(result) do
        if not served[zone] then printError(("%s: dnsd doesn't answer for %s"):format(conf.DNSD_ZONES, zone)) end
    end
    zones_file.zones = result
    return result
end

-- A zone with a file of its own reads it again whenever it changes, too.
for _, zone in ipairs(config.zones) do
    if zone.file then zone.file, zone.records, zone.stamp = shell.resolve(zone.file), {}, false end
end
local function records(zone)
    if not zone.file then return zones_file_records()[zone.zone] or {} end
    local now = stamp(zone.file)
    if now == zone.stamp then return zone.records end
    zone.stamp, zone.records = now, {}
    local text = now and conf.read(zone.file)
    if not text then return zone.records end
    local result, errors = dns.parse_zone(text)
    for _, err in ipairs(errors) do printError(zone.file .. ": " .. err) end
    zone.records = result
    return result
end

-- The names DHCP servers (and cellular cores) set, kept across restarts until they expire.
local function clock() return os.epoch("utc") / 1000 end
local names = dns.names(files.read_table(conf.DNSD_LEASES), clock)
local function save()
    local ok, err = pcall(files.write_table, conf.DNSD_LEASES, names:save())
    if not ok then printError("Cannot save the names: " .. tostring(err)) end
end

-- This computer's own addresses: it never forwards to itself, and may always set names.
local function own_addresses()
    local own = { [address.parse("127.0.0.1")] = true }
    for _, interface in ipairs(net.interfaces()) do
        local addr = interface.address and address.parse(interface.address)
        if addr then own[addr] = true end
    end
    return own
end

local function others(servers)
    local own, result = own_addresses(), {}
    for _, addr in ipairs(servers) do
        if not own[addr] then result[#result + 1] = addr end
    end
    return result
end

-- The zones as they are now: those dnsd answers for, and those it asks other servers about.
local function servers()
    local result = {}
    for _, zone in ipairs(config.zones) do
        result[#result + 1] = dns.server(zone.zone, records(zone), function() return names:lookup(zone.zone) end)
    end
    for _, zone in ipairs(config.forward) do
        result[#result + 1] = dns.forward(zone.zone, others(zone.servers))
    end
    return result
end

-- Whether a computer may set and delete names: this one, and those allow-update names.
local function allowed(addr)
    if not addr then return false end
    if own_addresses()[addr] then return true end
    for _, entry in ipairs(config.allow) do
        if address.contains(entry.network, entry.prefix, addr) then return true end
    end
    return false
end

local function list(words)
    if #words == 1 then return words[1] end
    return table.concat(words, ", ", 1, #words - 1) .. " and " .. words[#words]
end

local function formatted(addresses)
    local result = {}
    for i, addr in ipairs(addresses) do result[i] = address.format(addr) end
    return list(result)
end

local socket, err = net.udp.open(dns.DNS_PORT)
if not socket then
    printError("Cannot start the DNS server: " .. err)
    return
end
-- Questions forwarded to other servers go from a socket of their own, which their answers come back to.
local upstream = assert(net.udp.open())

local zone_names = {}
for i, zone in ipairs(config.zones) do
    zone_names[i] = zone.zone
    if zone.file and not fs.exists(zone.file) then
        print(("No file at %s yet: %s has no names but those set by updates."):format(zone.file, zone.zone))
    end
end
if zone_names[1] then
    print(("Answering for %s."):format(list(zone_names)))
else
    print("Answering for no zones of its own.")
end
for _, zone in ipairs(config.forward) do
    print(("Asking %s about %s."):format(formatted(zone.servers), zone.zone))
end
if config.upstream[1] then print(("Asking %s about other names."):format(formatted(config.upstream))) end
if config.key then print("Updates must be signed with the key.") end
if not service.current() then print("Press Ctrl+T to stop.") end

local relay = dns.relay { zones = {}, forward = function() return others(config.upstream) end, clock = os.clock }
local seen = {}

local function send(items)
    for _, item in ipairs(items) do
        if item.client then
            socket:send(item.client.address, item.client.port, item.answer)
        else
            upstream:send(address.format(item.server), dns.DNS_PORT, item.question)
            os.queueEvent("dnsd_forwarded")
        end
    end
end

local ok, result = pcall(parallel.waitForAny,
    -- Questions and updates from clients.
    function()
        while true do
            local message, from, port = socket:receive()
            local zones = servers()
            if type(message) == "table" and message.op == "update" then
                local answer, changed, log = dns.handle_update(message, {
                    zones = zones, names = names, allowed = allowed(address.parse(tostring(from))), key = config.key,
                    epoch = os.epoch("utc"), seen = seen, from = tostring(from),
                })
                if log then print(log) end
                if changed then save() end
                if answer then socket:send(from, port, answer) end
            else
                relay.zones = zones
                send(relay:question(message, { address = from, port = port }))
            end
        end
    end,
    -- Answers from the servers questions were forwarded to.
    function()
        while true do
            local answer, from = upstream:receive()
            if answer ~= nil then send(relay:answer(answer, address.parse(from))) end
        end
    end,
    -- Servers which don't answer in time: looked at often while questions are forwarded, and not at all otherwise.
    function()
        while true do
            if relay:busy() then
                sleep(0.1)
                send(relay:expire())
            else
                os.pullEvent("dnsd_forwarded")
            end
        end
    end,
    -- Names which have expired are forgotten now and again.
    function()
        while true do
            sleep(300)
            if names:prune() then save() end
        end
    end
)
socket:close()
upstream:close()
if not ok and result ~= "Terminated" then error(result, 0) end
