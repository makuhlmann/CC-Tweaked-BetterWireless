-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DNS server for one or more zones, which forwards questions about names in other zones to other DNS servers. It runs
-- in the background as a service ("dnsd start home"), or in the foreground ("dnsd run home") until Ctrl+T.

local address = require "cc.net.address"
local dns = require "cc.internal.net.dns"
local cli = require "cc.internal.service_cli"

settings.define("dnsd.forward", {
    description = "DNS servers dnsd forwards questions about names outside its zones to, separated by commas. "
        .. "If unset, those in net.dns. \"none\" forwards nothing.",
    type = "string",
})

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " start <zone> [zone file]...")
    print(name .. " start")
    print(name .. " stop")
    print(name .. " status")
    print(name .. " run <zone> [zone file]...")
end

-- Whether an argument is a zone file, rather than a zone: it's a path, or a .txt file.
local function is_file(word)
    return word:find("/", 1, true) ~= nil or word:sub(-4):lower() == ".txt"
end

-- The zones, and their files, from the arguments from `first` on: each zone may be followed by its file, found from the
-- current directory, or else is in /zones. Nil if they don't make sense, with what's wrong if it's more than how
-- they're typed.
local function read_args(first)
    local zones, seen = {}, {}
    for i = first, #args do
        local word = args[i]
        if is_file(word) then
            local last = zones[#zones]
            if not last or last.given then return nil end
            last.file, last.given = shell.resolve(word), true
        else
            local zone = dns.normalise(word)
            if zone == "" then return nil end
            if seen[zone] then return nil, ("%s is there twice."):format(zone) end
            seen[zone] = true
            zones[#zones + 1] = { zone = zone, file = fs.combine("zones", zone .. ".txt") }
        end
    end
    if not zones[1] then return nil end
    return zones
end

-- "dnsd home" is "dnsd start home", unless the zone has one of these names: then it's "dnsd start stop", say.
local COMMANDS = { start = true, stop = true, status = true, run = true }

local command = args[1]
local missing = ("dnsd isn't set up here: start it with \"%s start <zone>\"."):format(name)
if command == "stop" and #args == 1 then
    cli.stop("dnsd", "dnsd isn't running here.")
    return
elseif command == "status" and #args == 1 then
    cli.status("dnsd", missing)
    return
elseif command == "start" and #args == 1 then
    cli.start("dnsd", ('"%s stop"'):format(name), missing)
    return
elseif command == "start" or (command ~= nil and not COMMANDS[command]) then
    local zones, err = read_args(command == "start" and 2 or 1)
    if not zones then
        if err then printError(err) else usage() end
        return
    end
    -- Services run from the root, so each file is given by its full path.
    local words = { "/" .. shell.getRunningProgram(), "run" }
    for _, zone in ipairs(zones) do
        words[#words + 1] = zone.zone
        words[#words + 1] = "/" .. zone.file
    end
    cli.add("dnsd", words, ('"%s stop"'):format(name))
    return
end

local zones, zones_err
if command == "run" then zones, zones_err = read_args(2) end
if not zones then
    if zones_err then printError(zones_err) else usage() end
    return
end

-- When a file last changed, and its size: when neither has, what was read from it last time is still right.
local function stamp(path)
    local ok, attributes = pcall(fs.attributes, path)
    if not ok or type(attributes) ~= "table" then return nil end
    return ("%s:%s"):format(attributes.modified, attributes.size)
end

-- Each zone's file, read again whenever it changes, so changes still apply straight away. What's wrong with one is
-- printed once, not for every question.
for _, zone in ipairs(zones) do
    zone.records, zone.stamp = {}, false
end
local function records(zone)
    local now = stamp(zone.file)
    if now == zone.stamp then return zone.records end
    zone.stamp, zone.records = now, {}
    local handle = now and fs.open(zone.file, "r")
    if not handle then return zone.records end
    local result, errors = dns.parse_zone(handle.readAll() or "")
    handle.close()
    for _, err in ipairs(errors) do printError(zone.file .. ": " .. err) end
    zone.records = result
    return result
end

-- Computers which got their address from a DHCP server on this computer can be found by name too, in the zone the
-- server gives them (dhcpd.domain), or else the first. Each file of leases is read again only when it changes. A lease
-- without a name or an expiry (from a file changed by hand) is passed by.
local lease_files = {}
local function leases()
    local result, now = {}, os.epoch("utc") / 1000
    if not fs.isDir("/.dhcpd") then return result end
    local present = {}
    for _, file in ipairs(fs.list("/.dhcpd")) do
        local path = fs.combine("/.dhcpd", file)
        present[path] = true
        local file_stamp, cached = stamp(path), lease_files[path]
        if not cached or cached.stamp ~= file_stamp then
            local contents
            local handle = fs.open(path, "r")
            if handle then
                contents = textutils.unserialise(handle.readAll() or "")
                handle.close()
            end
            cached = { stamp = file_stamp, contents = type(contents) == "table" and contents or {} }
            lease_files[path] = cached
        end
        for _, lease in pairs(cached.contents) do
            if type(lease) == "table" and type(lease.hostname) == "string" and type(lease.expires) == "number"
                and lease.expires > now then
                result[lease.hostname] = lease.address
            end
        end
    end
    for path in pairs(lease_files) do
        if not present[path] then lease_files[path] = nil end
    end
    return result
end

local function lease_zone()
    local domain = dns.normalise(settings.get("dhcpd.domain") or "")
    for _, zone in ipairs(zones) do
        if zone.zone == domain then return zone.zone end
    end
    return zones[1].zone
end

-- The zones as they are now.
local function servers()
    local result, with_leases = {}, lease_zone()
    for i, zone in ipairs(zones) do
        result[i] = dns.server(zone.zone, records(zone), zone.zone == with_leases and leases or nil)
    end
    return result
end

-- The DNS servers to forward to: dnsd.forward, or else net.dns, but never this computer itself.
local function forward_to()
    local setting = settings.get("dnsd.forward")
    if setting == "none" then return {} end
    if setting == nil or setting == "" then setting = settings.get("net.dns") or "" end

    local own = { [address.parse("127.0.0.1")] = true }
    for _, interface in ipairs(net.interfaces()) do
        local addr = interface.address and address.parse(interface.address)
        if addr then own[addr] = true end
    end
    local result = {}
    for value in setting:gmatch("[^,%s]+") do
        local addr = address.parse(value)
        if addr and not own[addr] then result[#result + 1] = addr end
    end
    return result
end

local function list(words)
    if #words == 1 then return words[1] end
    return table.concat(words, ", ", 1, #words - 1) .. " and " .. words[#words]
end

local socket, err = net.udp.open(dns.DNS_PORT)
if not socket then
    printError("Cannot start the DNS server: " .. err)
    return
end
-- Questions forwarded to other servers go from a socket of their own, which their answers come back to.
local upstream = assert(net.udp.open())

local names = {}
for i, zone in ipairs(zones) do
    names[i] = zone.zone
    if not fs.exists(zone.file) then
        print(("No zone file at %s yet: %s."):format(zone.file,
            zone.zone == lease_zone() and "only DHCP clients have names" or "it has no names"))
    end
end
print(("Answering for %s."):format(list(names)))
local forwarding = forward_to()
if forwarding[1] then
    for i, addr in ipairs(forwarding) do forwarding[i] = address.format(addr) end
    print(("Forwarding other names to %s."):format(list(forwarding)))
end
if not service.current() then print("Press Ctrl+T to stop.") end

local relay = dns.relay { zones = {}, forward = forward_to, clock = os.clock }

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
    -- Questions from clients.
    function()
        while true do
            local question, from, port = socket:receive()
            relay.zones = servers()
            send(relay:question(question, { address = from, port = port }))
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
    end
)
socket:close()
upstream:close()
if not ok and result ~= "Terminated" then error(result, 0) end
