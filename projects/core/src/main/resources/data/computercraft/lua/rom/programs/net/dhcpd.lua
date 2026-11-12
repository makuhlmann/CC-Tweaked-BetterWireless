-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"
local dhcp = require "cc.internal.net.dhcp"
local files = require "cc.internal.net.files"

local args = { ... }
if #args < 1 or #args > 3 then
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usage: " .. name .. " <interface> [first address] [last address]")
    return
end

local interface = args[1]
local own = net.getAddress(interface)
if not own then
    printError(interface .. " has no address. Give it a fixed one first, for example with ifconfig.")
    return
end

local server_address, prefix = address.parse(own)
local network = address.network(server_address, prefix)
local broadcast = address.broadcast(server_address, prefix)

-- The range to hand out: either addresses, or numbers within the network. By default, .100 to .199.
local function host(value, default)
    if value == nil then return default end
    if tonumber(value) then return network + tonumber(value) end
    return (address.parse(value))
end

local first = host(args[2], network + 100)
local last = host(args[3], math.min(first + 99, broadcast - 1))
if not first or not last or first > last or not address.contains(network, prefix, first)
    or not address.contains(network, prefix, last) or last >= broadcast then
    printError(("The range must be within %s."):format(address.format(network, prefix)))
    return
end

local dns = {}
for value in (settings.get("dhcpd.dns") or ""):gmatch("[^,%s]+") do
    local addr = address.parse(value)
    if addr then dns[#dns + 1] = addr end
end

-- Leases are kept in a file, so clients keep their addresses when the server restarts.
local lease_file = fs.combine("/.dhcpd", interface .. ".leases")
local leases = files.read_table(lease_file)

local function save()
    local ok, err = pcall(files.write_table, lease_file, leases)
    if not ok then printError("Cannot save the leases: " .. tostring(err)) end
end

local server = dhcp.server {
    address = server_address, prefix = prefix, first = first, last = last,
    lease = tonumber(settings.get("dhcpd.lease")) or 3600,
    dns = dns,
    domain = settings.get("dhcpd.domain"),
    gateway = settings.get("dhcpd.gateway") and address.parse(settings.get("dhcpd.gateway")),
    clock = function() return os.epoch("utc") / 1000 end,
    leases = leases,
    -- Don't hand out addresses which computers with fixed addresses are using.
    in_use = function(addr) return net.ping(address.format(addr), 0.5) ~= nil end,
}

local socket, err = net.udp.open(dhcp.SERVER_PORT)
if not socket then
    printError("Cannot start the DHCP server: " .. err)
    return
end

print(("Handing out %s to %s on %s. Press Ctrl+T to stop."):format(address.format(first), address.format(last), interface))
local ok, result = pcall(function()
    while true do
        local message, _, _, received_on = socket:receive()
        if received_on == interface then
            local reply, changed, log = server:handle(message)
            if log then print(log) end
            if reply then socket:send("255.255.255.255", dhcp.CLIENT_PORT, reply, interface) end
            if changed then save() end
        end
    end
end)
socket:close()
if not ok and result ~= "Terminated" then error(result, 0) end
