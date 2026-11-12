-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local dns = require "cc.internal.net.dns"

local args = { ... }
if #args < 1 or #args > 2 then
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usage: " .. name .. " <zone> [zone file]")
    return
end

local zone = dns.normalise(args[1])
local zone_file = shell.resolve(args[2] or fs.combine("/zones", zone .. ".txt"))

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
print(("Answering for %s. Press Ctrl+T to stop."):format(zone))

local ok, result = pcall(function()
    while true do
        local question, from, port = socket:receive()
        local answer = dns.server(zone, records(), leases):handle(question)
        if answer then socket:send(from, port, answer) end
    end
end)
socket:close()
if not ok and result ~= "Terminated" then error(result, 0) end
