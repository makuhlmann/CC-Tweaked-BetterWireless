-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DHCP server for one interface, which may register its clients' names at a DNS server. Its settings are in
-- /etc/dhcpd.conf. It runs in the background as a service ("dhcpd start"), or in the foreground ("dhcpd run") until
-- Ctrl+T.

local address = require "cc.net.address"
local dhcp = require "cc.internal.net.dhcp"
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
    print(("Its settings are in %s."):format(conf.DHCPD_CONF))
end

-- Write dhcpd's file in /etc the first time, from how it was set up before (with these arguments, or its
-- service's), if it was.
local function first_time(words)
    if fs.exists(conf.DHCPD_CONF) then return end
    if migrate.dhcpd(words) then
        print(("Moved dhcpd's settings to %s."):format(conf.DHCPD_CONF))
    else
        print(("Wrote %s. Check the interface and addresses there."):format(conf.DHCPD_CONF))
    end
end

local command = args[1]
local how_to_stop = ('"%s stop"'):format(name)
if command == "stop" and #args == 1 then
    cli.stop("dhcpd", "dhcpd isn't running here.")
    return
elseif command == "status" and #args == 1 then
    cli.status("dhcpd", ('dhcpd isn\'t set up here: start it with "%s start".'):format(name))
    return
elseif command == "start" and #args == 1 then
    first_time()
    cli.add("dhcpd", command_words, how_to_stop)
    return
elseif command == "restart" and #args == 1 then
    first_time()
    cli.restart("dhcpd", command_words, how_to_stop)
    return
elseif command ~= "run" then
    usage()
    return
end

-- Run. A service started before dhcpd had its file in /etc says how it was set up: it's written from that.
if args[2] then
    first_time({ table.unpack(args, 2) })
    print(("dhcpd's settings are in %s now. \"dhcpd start\" starts it without the arguments it was given before.")
        :format(conf.DHCPD_CONF))
else
    first_time()
end

local function stop(text)
    printError(text)
    printError("dhcpd won't start until its settings make sense.")
end

local config, config_errors = conf.dhcpd(conf.read(conf.DHCPD_CONF) or "")
if config_errors[1] then
    for _, err in ipairs(config_errors) do printError(conf.DHCPD_CONF .. ": " .. err) end
    return stop(("Change them in %s."):format(conf.DHCPD_CONF))
end

-- The interface: by name, or by its address.
local interface = config.interface
if not interface then
    for _, info in ipairs(net.interfaces()) do
        if info.address and address.parse(info.address) == config.address then interface = info.name end
    end
    if not interface then return stop(("No interface has the address %s."):format(address.format(config.address))) end
end
local own = net.getAddress(interface)
if not own then
    return stop(("%s has no address. Give it a fixed one first, for example with ifconfig."):format(interface))
end
local server_address, prefix = address.parse(own)
local network = address.network(server_address, prefix)
local broadcast = address.broadcast(server_address, prefix)
local function within(addr) return address.contains(network, prefix, addr) and addr ~= network and addr < broadcast end

-- The range: addresses, or numbers within the network. By default, .100 to .199.
local range = config.range or { first = 100, last = 199, numbers = true }
local first, last = range.first, range.last
if range.numbers then first, last = network + first, network + last end
if not within(first) or not within(last) then
    return stop(("The range must be within %s."):format(address.format(network, prefix)))
end
for id, addr in pairs(config.hosts) do
    if not within(addr) or addr == server_address then
        return stop(("Computer %d's address must be within %s, and not dhcpd's own."):format(id, address.format(network, prefix)))
    end
end

-- Leases are kept in a file, so clients keep their addresses when the server restarts.
local leases = files.read_table(conf.DHCPD_LEASES)
local function save()
    local ok, err = pcall(files.write_table, conf.DHCPD_LEASES, leases)
    if not ok then printError("Cannot save the leases: " .. tostring(err)) end
end

local function clock() return os.epoch("utc") / 1000 end

local server = dhcp.server {
    address = server_address, prefix = prefix, first = first, last = last, lease = config.lease,
    dns = config.dns, domain = config.domain, gateway = config.gateway, hosts = config.hosts,
    clock = clock, leases = leases,
    -- Don't hand out addresses which computers with fixed addresses are using.
    in_use = function(addr) return net.ping(address.format(addr), 0.5) ~= nil end,
}

local socket, err = net.udp.open(dhcp.SERVER_PORT)
if not socket then
    printError("Cannot start the DHCP server: " .. err)
    return
end

-- Registering clients' names at a DNS server, in the background: an update waits until the one before it is
-- answered.
local updater, update_socket
local queue = {}
local update = config.update
local update_zone = update and (update.zone or config.domain)
if update and not update_zone then
    printError("Clients' names aren't registered: say in which zone, with update-zone (or domain).")
elseif update then
    update_socket = assert(net.udp.open())
    updater = dns.updater {
        zone = update_zone, key = update.key, epoch = function() return os.epoch("utc") end, log = print,
        send = function(make, done)
            queue[#queue + 1] = { make = make, done = done }
            os.queueEvent("dhcpd_update")
        end,
    }
end
local function owner(client) return "computer " .. client end

-- Register a client's name for its lease, or delete the name it had.
local function registered(client, before, after)
    if not updater then return end
    local old = type(before) == "table" and before.hostname
    local new = type(after) == "table" and type(after.hostname) == "string" and address.is_valid(after.address) and after
    if old and (not new or new.hostname ~= old) then updater:delete(old, owner(client)) end
    if new then updater:set(new.hostname, new.address, math.max(1, new.expires - clock()), owner(client)) end
end

print(("Handing out %s to %s on %s."):format(address.format(first), address.format(last), interface))
if updater then
    print(("Registering clients' names in %s at %s."):format(update_zone, address.format(update.server)))
    -- Clients' names last as long as their leases, so those there are now are registered again.
    for client, lease in pairs(leases) do
        if type(client) == "number" and type(lease) == "table" and type(lease.expires) == "number" and lease.expires > clock() then
            registered(client, nil, lease)
        end
    end
end
if not service.current() then print("Press Ctrl+T to stop.") end

local loops = {
    function()
        while true do
            local message, _, _, received_on = socket:receive()
            if received_on == interface then
                local client = type(message) == "table" and message.client
                local before = leases[client]
                local reply, changed, log = server:handle(message)
                if log then print(log) end
                if reply then socket:send("255.255.255.255", dhcp.CLIENT_PORT, reply, interface) end
                if changed then
                    save()
                    registered(client, before, leases[client])
                end
            end
        end
    end,
}
-- Updates for the DNS server, one at a time, each tried a few times.
if updater then
    loops[2] = function()
        local target = address.format(update.server)
        while true do
            local item = table.remove(queue, 1)
            if not item then
                os.pullEvent("dhcpd_update")
            else
                local answer, why
                for _ = 1, dns.UPDATE_ATTEMPTS do
                    local message = item.make()
                    update_socket:send(target, dns.DNS_PORT, message)
                    local deadline = os.clock() + dns.UPDATE_TIMEOUT
                    while not answer and os.clock() < deadline do
                        local reply = update_socket:receive(math.max(0, deadline - os.clock()))
                        if type(reply) == "table" and reply.id == message.id then answer = reply end
                    end
                    if answer then break end
                    why = "No answer"
                end
                item.done(answer, why)
            end
        end
    end
end
local ok, result = pcall(parallel.waitForAny, table.unpack(loops))
socket:close()
if update_socket then update_socket:close() end
if not ok and result ~= "Terminated" then error(result, 0) end
