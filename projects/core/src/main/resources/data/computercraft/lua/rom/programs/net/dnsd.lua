-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DNS server for one zone, which runs in the background as a service ("dnsd start home"), or in the foreground
-- ("dnsd run home") until Ctrl+T.

local dns = require "cc.internal.net.dns"
local cli = require "cc.internal.service_cli"

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " start <zone> [zone file]")
    print(name .. " start")
    print(name .. " stop")
    print(name .. " status")
    print(name .. " run <zone> [zone file]")
end

-- The zone, and its file, from the arguments from `first` on: nil if they don't make sense. The file is found from the
-- current directory, if one is given, and /zones otherwise.
local function read_args(first)
    if #args < first or #args > first + 1 then return nil end
    local zone = dns.normalise(args[first])
    if zone == "" then return nil end
    return zone, args[first + 1] and shell.resolve(args[first + 1]) or fs.combine("zones", zone .. ".txt")
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
    local zone, file = read_args(command == "start" and 2 or 1)
    if not zone then
        usage()
        return
    end
    -- Services run from the root, so the file is given by its full path.
    cli.add("dnsd", { "/" .. shell.getRunningProgram(), "run", zone, "/" .. file }, ('"%s stop"'):format(name))
    return
end

local zone, zone_file
if command == "run" then zone, zone_file = read_args(2) end
if not zone then
    usage()
    return
end

-- When a file last changed, and its size: when neither has, what was read from it last time is still right.
local function stamp(path)
    local ok, attributes = pcall(fs.attributes, path)
    if not ok or type(attributes) ~= "table" then return nil end
    return ("%s:%s"):format(attributes.modified, attributes.size)
end

-- The zone file, read again whenever it changes, so changes still apply straight away. What's wrong with it is
-- printed once, not for every question.
local zone_records, zone_stamp = {}, false
local function records()
    local now = stamp(zone_file)
    if now == zone_stamp then return zone_records end
    zone_stamp, zone_records = now, {}
    local handle = now and fs.open(zone_file, "r")
    if not handle then return zone_records end
    local result, errors = dns.parse_zone(handle.readAll() or "")
    handle.close()
    for _, err in ipairs(errors) do printError(zone_file .. ": " .. err) end
    zone_records = result
    return result
end

-- Computers which got their address from a DHCP server on this computer can be found by name too. Each file of leases
-- is read again only when it changes. A lease without a name or an expiry (from a file changed by hand) is passed by.
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

local socket, err = net.udp.open(dns.DNS_PORT)
if not socket then
    printError("Cannot start the DNS server: " .. err)
    return
end

if not fs.exists(zone_file) then print(("No zone file at %s yet: only DHCP clients have names."):format(zone_file)) end
print(("Answering for %s."):format(zone))
if not service.current() then print("Press Ctrl+T to stop.") end

local ok, result = pcall(function()
    while true do
        local question, from, port = socket:receive()
        local answer = dns.server(zone, records(), leases):handle(question)
        if answer then socket:send(from, port, answer) end
    end
end)
socket:close()
if not ok and result ~= "Terminated" then error(result, 0) end
