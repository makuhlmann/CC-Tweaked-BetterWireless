-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DHCP server for one interface, which runs in the background as a service ("dhcpd start top"), or in the
-- foreground ("dhcpd run top") until Ctrl+T.

local address = require "cc.net.address"
local dhcp = require "cc.internal.net.dhcp"
local files = require "cc.internal.net.files"
local cli = require "cc.internal.service_cli"

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " start <interface> [first address] [last address]")
    print(name .. " start")
    print(name .. " stop")
    print(name .. " status")
    print(name .. " run <interface> [first address] [last address]")
end

-- The interface, its address, and the range to hand out, from the arguments from `first` on. Nil if they don't make
-- sense, with what's wrong, if it's more than how they're typed.
local function read_args(first)
    if #args < first or #args > first + 2 then return nil end
    local interface = args[first]
    local own = net.getAddress(interface)
    if not own then return nil, interface .. " has no address. Give it a fixed one first, for example with ifconfig." end

    local server_address, prefix = address.parse(own)
    local network = address.network(server_address, prefix)
    local broadcast = address.broadcast(server_address, prefix)

    -- The range to hand out: either addresses, or numbers within the network. By default, .100 to .199.
    local function host(value, default)
        if value == nil then return default end
        if tonumber(value) then return network + tonumber(value) end
        return (address.parse(value))
    end

    local range_first = host(args[first + 1], network + 100)
    local range_last = range_first and host(args[first + 2], math.min(range_first + 99, broadcast - 1))
    if not range_first or not range_last or range_first > range_last or not address.contains(network, prefix, range_first)
        or not address.contains(network, prefix, range_last) or range_last >= broadcast then
        return nil, ("The range must be within %s."):format(address.format(network, prefix))
    end
    return { interface = interface, address = server_address, prefix = prefix, first = range_first, last = range_last }
end

-- "dhcpd top" is "dhcpd start top", unless the interface has one of these names: then it's "dhcpd start stop", say.
local COMMANDS = { start = true, stop = true, status = true, run = true }

local command = args[1]
local missing = ("dhcpd isn't set up here: start it with \"%s start <interface>\"."):format(name)
if command == "stop" and #args == 1 then
    cli.stop("dhcpd", "dhcpd isn't running here.")
    return
elseif command == "status" and #args == 1 then
    cli.status("dhcpd", missing)
    return
elseif command == "start" and #args == 1 then
    cli.start("dhcpd", ('"%s stop"'):format(name), missing)
    return
elseif command == "start" or (command ~= nil and not COMMANDS[command]) then
    -- What's wrong is said before anything changes.
    local first = command == "start" and 2 or 1
    local config, err = read_args(first)
    if not config then
        if err then printError(err) else usage() end
        return
    end
    local words = { "/" .. shell.getRunningProgram(), "run" }
    for i = first, #args do words[#words + 1] = args[i] end
    cli.add("dhcpd", words, ('"%s stop"'):format(name))
    return
end

local config, config_err
if command == "run" then config, config_err = read_args(2) end
if not config then
    if config_err then printError(config_err) else usage() end
    return
end
local interface, server_address, prefix = config.interface, config.address, config.prefix
local first, last = config.first, config.last

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

print(("Handing out %s to %s on %s."):format(address.format(first), address.format(last), interface))
if not service.current() then print("Press Ctrl+T to stop.") end
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
