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

-- The zone file is read for every question, so changes apply straight away.
local function records()
    if not fs.exists(zone_file) then return {} end
    local handle = fs.open(zone_file, "r")
    local result, errors = dns.parse_zone(handle.readAll())
    handle.close()
    for _, err in ipairs(errors) do printError(zone_file .. ": " .. err) end
    return result
end

-- Computers which got their address from a DHCP server on this computer can be found by name too.
local function leases()
    local result, now = {}, os.epoch("utc") / 1000
    if not fs.isDir("/.dhcpd") then return result end
    for _, file in ipairs(fs.list("/.dhcpd")) do
        local handle = fs.open(fs.combine("/.dhcpd", file), "r")
        local contents = textutils.unserialise(handle.readAll()) or {}
        handle.close()
        for _, lease in pairs(contents) do
            if type(lease) == "table" and lease.hostname and lease.expires > now then result[lease.hostname] = lease.address end
        end
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
