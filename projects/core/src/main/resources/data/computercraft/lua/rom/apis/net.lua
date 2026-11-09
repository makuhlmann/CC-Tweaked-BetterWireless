-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A network stack: network addresses, names, datagrams, connections and ping, over any modem.

Every modem becomes a network *interface*. Each interface gets an address, such as `10.0.0.17/24`, and computers on
the same network can then reach each other by address or by name. The stack runs in the background on every computer,
much like [`rednet`].

By default, wired interfaces ask a DHCP server (the `dhcpd` program) for an address. If there isn't one, a computer
gives itself a link-local address in `169.254.0.0/16`, so computers on the same cable can talk with no setup at all.
Wireless and ender interfaces have no address until given one, so idle computers don't fill the airwaves with DHCP
requests: set them to `"dhcp"` or an address to use them. Fixed
addresses are set with the `ifconfig` program, or with [`net.setAddress`]. `ifconfig` saves them in the settings
`net.<interface>.address` (an address such as `"10.0.0.1/24"`, `"dhcp"` or `"none"`).

Every computer has a hostname (the `net.hostname` setting, or its label) and answers to `<hostname>.local`. Other names
are looked up in the `net.hosts` setting, then asked of DNS servers (the `dnsd` program), found through DHCP or the
`net.dns` setting.

Computers on different networks reach each other through routers: computers with several interfaces and
`net.forwarding` on. Hosts send everything they can't reach directly to their gateway (from DHCP, or the `net.gateway`
setting). Routers learn routes from each other with `net.rip`, or are given them with `net.routes`; the `route` program
sets these. `net.firewall` holds rules for which packets a router forwards.

Wired and ender modems are one interface each. A wireless modem is one interface on the short-range high band by default
(channels 1024 and up). Set `net.<name>.band` to `"low"` to use the long-range low band instead (channels below 1024).
An interface on the other band of the same modem can be added by setting `net.<name>:low.address` (or
`net.<name>:high.address`).

Programs talk with datagrams ([`net.udp`]), single messages which may be lost, or connections ([`net.tcp`]), which
deliver messages in order and exactly once, resending any which are lost. [`net.stream`] reads and writes bytes over a
connection, like a file.

> [!WARNING]
> The network stack doesn't encrypt or authenticate anything yet. Anyone can listen to, or pretend to be, any computer.

@module net
@usage Send a message to another computer, and print its reply.

```lua
local socket = net.udp.open()
socket:send("other-computer.local", 7000, "Hello!")
print(socket:receive(5))
socket:close()
```
]]

local expect = dofile("rom/modules/main/cc/expect.lua").expect

local DEFAULT_PREFIX = 24
local CHANNEL_CHECK_INTERVAL = 5
local MAX_ERRORS = 16
local DEFAULT_TIMEOUT = 2
local CONNECT_TIMEOUT = 5

local stack, address, dhcp, dns, rip, connections, streams, running
local rip_instance, rip_config
local add_modem, apply_routing
local errors = {}
local services = {}
local cache = {}

-- Remember an error, rather than printing it over whatever the user is doing.
local function log_error(err)
    if #errors >= MAX_ERRORS then table.remove(errors, 1) end
    errors[#errors + 1] = tostring(err)
end

local function hostname()
    local configured = settings.get("net.hostname")
    return dhcp.clean_hostname(configured) or dhcp.clean_hostname(os.getComputerLabel())
        or "computer-" .. os.getComputerID()
end

local function load()
    if stack then return stack end

    -- APIs can't use require, so make our own, much as the shell does for programs.
    local env = setmetatable({}, { __index = _ENV })
    env.require, env.package = dofile("rom/modules/main/cc/require.lua").make(env, "/")
    address = env.require("cc.net.address")
    dhcp = env.require("cc.internal.net.dhcp")
    dns = env.require("cc.internal.net.dns")
    rip = env.require("cc.internal.net.rip")
    connections = env.require("cc.internal.net.tcp")
    streams = env.require("cc.internal.net.stream")

    settings.define("net.enabled", {
        description = "Run the network stack.",
        default = true,
        type = "boolean",
    })
    settings.define("net.hostname", {
        description = "This computer's name on the network. The computer's label is used if this isn't set.",
        type = "string",
    })
    settings.define("net.dns", {
        description = "DNS servers to use as well as any from DHCP, separated by commas.",
        type = "string",
    })
    settings.define("net.domain", {
        description = "The domain to look names without dots up in, if DHCP doesn't give one.",
        type = "string",
    })
    settings.define("net.hosts", {
        description = "Fixed names, as a table of names to addresses.",
        type = "table",
    })
    settings.define("net.forwarding", {
        description = "Forward packets between networks, making this computer a router.",
        default = false,
        type = "boolean",
    })
    settings.define("net.gateway", {
        description = "The router to send packets for other networks to, if DHCP doesn't give one.",
        type = "string",
    })
    settings.define("net.routes", {
        description = "Fixed routes, as a list of strings such as \"10.5.0.0/16 via 10.4.0.1\".",
        type = "table",
    })
    settings.define("net.rip", {
        description = "Learn routes from other routers, and tell them ours.",
        default = false,
        type = "boolean",
    })
    settings.define("net.rip.default", {
        description = "Tell other routers that this one is the way to everywhere else.",
        default = false,
        type = "boolean",
    })
    settings.define("net.rip.key", {
        description = "A key shared by every router, to sign routing updates and ignore unsigned ones.",
        type = "string",
    })
    settings.define("net.firewall", {
        description = "Rules for which packets a router forwards. Use the firewall program to change them.",
        type = "table",
    })

    stack = env.require("cc.internal.net.stack").new {
        id = os.getComputerID(),
        clock = os.clock,
        transmit = function(modem, channel, reply, frame)
            -- A modem which fails (for instance, because it was just removed) loses the frame, like a real network.
            local ok, err = pcall(peripheral.call, modem, "transmit", channel, reply, frame)
            if not ok then log_error(err) end
        end,
        wake = os.queueEvent,
        log = log_error,
    }
    dns.respond(stack, { hostname = hostname, services = services })
    connections.attach(stack)
    apply_routing()

    for _, name in ipairs(peripheral.getNames()) do add_modem(name) end
    return stack
end

local function open_channels(interface)
    peripheral.call(interface.modem, "open", interface.unicast)
    peripheral.call(interface.modem, "open", interface.broadcast)
end

local function stop_dhcp(name, release)
    local client = stack.dhcp_clients and stack.dhcp_clients[name]
    if client then client:stop(release) end
    stack:remove_routes(function(route) return route.source == "dhcp" and route.interface == name end)
end

-- Parse "10.5.0.0/16 via 10.4.0.1", optionally followed by "metric 3".
local function parse_route(text)
    if type(text) ~= "string" then return nil, "Routes must be strings" end
    local network, gateway, rest = text:match("^%s*(%S+)%s+via%s+(%S+)%s*(.-)%s*$")
    local metric = rest and (rest == "" and 1 or tonumber(rest:match("^metric%s+(%d+)$")))
    local addr, prefix = address.parse(network or "")
    local hop = address.parse(gateway or "")
    if not addr or not prefix or not hop or not metric then
        return nil, ("Invalid route %q: expected something like \"10.5.0.0/16 via 10.4.0.1\""):format(text)
    end
    return { network = addr, prefix = prefix, gateway = hop, metric = metric, source = "static" }
end

local function parse_network(text)
    if text == nil then return nil end
    local addr, prefix = address.parse(text)
    if not addr then error(prefix, 0) end
    return addr, prefix or 32
end

-- Turn the net.firewall setting into rules the stack understands.
local function firewall_rules()
    local rules = {}
    for i, rule in ipairs(settings.get("net.firewall") or {}) do
        local ok, err = pcall(function()
            if type(rule) ~= "table" or (rule.action ~= "allow" and rule.action ~= "deny") then
                error("expected an action of allow or deny", 0)
            end
            local src, src_prefix = parse_network(rule.from)
            local dst, dst_prefix = parse_network(rule.to)
            rules[#rules + 1] = {
                action = rule.action, proto = rule.proto, port = tonumber(rule.port), interface = rule.on,
                src = src, src_prefix = src_prefix, dst = dst, dst_prefix = dst_prefix,
            }
        end)
        if not ok then log_error(("Firewall rule %d: %s"):format(i, err)) end
    end
    return rules
end

-- Apply the routing settings: forwarding, fixed routes, the routing protocol and the firewall.
function apply_routing()
    stack.forwarding = settings.get("net.forwarding") == true

    stack:remove_routes(function(route) return route.source == "static" end)
    local gateway = settings.get("net.gateway")
    if type(gateway) == "string" and address.parse(gateway) then
        stack:add_route { network = 0, prefix = 0, gateway = address.parse(gateway), metric = 1, source = "static" }
    end
    for _, text in ipairs(settings.get("net.routes") or {}) do
        local route, err = parse_route(text)
        if route then stack:add_route(route) else log_error(err) end
    end

    -- Only restart the routing protocol if its own settings changed: restarting forgets every learned route, which
    -- would cut off traffic through this router until it learns them again.
    local enabled, default, key = settings.get("net.rip") == true, settings.get("net.rip.default") == true, settings.get("net.rip.key")
    local config = ("%s/%s/%s"):format(enabled, default, key or "")
    if rip_instance and config == rip_config then
        rip_instance:trigger() -- Fixed routes may have changed.
    else
        if rip_instance then
            rip_instance:stop()
            rip_instance = nil
        end
        rip_config = config
        if enabled and key and not crypto then
            -- Running without the key would accept routes from anyone, which the key is there to stop.
            log_error("Cannot start routing: net.rip.key needs the crypto API, which is disabled.")
        elseif enabled then
            local ok, result = pcall(rip.start, stack, { default = default, key = key, hmac = key and crypto.hmac })
            if ok then rip_instance = result else log_error("Cannot start routing: " .. tostring(result)) end
        end
    end

    stack:set_firewall(firewall_rules())
end

-- Apply an address setting to an interface: "dhcp", "none", or an address. Without a setting, wired interfaces use
-- DHCP, and radios (wireless and ender modems) stay quiet.
local function apply(name, mode)
    if mode == nil then
        local interface = stack.interfaces[name]
        mode = interface and interface.kind == "wired" and "dhcp" or "none"
    end

    if mode == "dhcp" then
        local client = stack.dhcp_clients and stack.dhcp_clients[name]
        if not client then
            stack:set_address(name, nil)
            dhcp.start(stack, name, {
                hostname = hostname,
                on_change = function(client)
                    -- A gateway from DHCP becomes this interface's default route.
                    stack:remove_routes(function(route) return route.source == "dhcp" and route.interface == name end)
                    local gateway = client.lease and client.lease.gateway
                    if gateway then
                        stack:add_route { network = 0, prefix = 0, gateway = gateway, interface = name, metric = 10, source = "dhcp" }
                    end
                    os.queueEvent("net_interface", name, "address")
                end,
            })
        end
        return true
    elseif mode == "none" or mode == "off" then
        stop_dhcp(name, true)
        stack:set_address(name, nil)
        return true
    end

    local addr, prefix = address.parse(mode)
    if not addr then return nil, prefix end
    prefix = prefix or DEFAULT_PREFIX
    if prefix < 1 then return nil, "The prefix length must be from 1 to 32" end
    if addr == 0 or addr >= 0xE0000000 or address.is_loopback(addr) then
        return nil, address.format(addr) .. " can't be a computer's address"
    end
    if prefix <= 30 and (addr == address.network(addr, prefix) or addr == address.broadcast(addr, prefix)) then
        return nil, ("%s is the address of the network itself, or its broadcast address"):format(address.format(addr, prefix))
    end
    stop_dhcp(name, true)
    stack:set_address(name, addr, prefix)
    return true
end

local function add_interface(name, modem, kind, band)
    local interface = stack:add_interface(name, modem, kind, band)
    open_channels(interface)
    local ok, err = apply(name, settings.get("net." .. name .. ".address"))
    if not ok then log_error(("Bad address for %s: %s"):format(name, err)) end
    os.queueEvent("net_interface", name, "up")
end

local function setup_modem(name)
    if not peripheral.hasType(name, "modem") or stack.by_modem[name] then return end

    if not peripheral.call(name, "isWireless") then return add_interface(name, name, "wired", "high") end

    local ok, ender = pcall(peripheral.call, name, "isInterdimensional")
    if ok and ender then return add_interface(name, name, "ender", "high") end

    local primary = settings.get("net." .. name .. ".band") == "low" and "low" or "high"
    add_interface(name, name, "wireless", primary)

    local other = primary == "low" and "high" or "low"
    if settings.get("net." .. name .. ":" .. other .. ".address") ~= nil then
        add_interface(name .. ":" .. other, name, "wireless", other)
    end
end

local function remove_modem(name)
    for _, interface in ipairs(stack:remove_modem(name)) do
        stop_dhcp(interface, false)
        os.queueEvent("net_interface", interface, "down")
    end
end

-- Set up the interfaces for a modem, if `name` is one. Peripherals which claim to be modems but don't behave like ours
-- (such as other mods' modems) are skipped.
function add_modem(name)
    local ok, err = pcall(setup_modem, name)
    if not ok then
        log_error(("Cannot use modem %s: %s"):format(name, tostring(err)))
        stack:remove_modem(name)
    end
end

-- Start something which finishes by calling a callback, then wait for it. The stack's background process does the
-- work, so this just waits for the callback to be called.
local function await(start)
    local done, results = false, nil
    start(function(...)
        done, results = true, table.pack(...)
        os.queueEvent("net_done")
    end)
    while not done do os.pullEvent("net_done") end
    return table.unpack(results, 1, results.n)
end

local function resolver_options()
    local servers, domain = {}, settings.get("net.domain")
    for server in (settings.get("net.dns") or ""):gmatch("[^,%s]+") do
        local addr = address.parse(server)
        if addr then servers[#servers + 1] = addr end
    end
    for _, client in pairs(stack.dhcp_clients or {}) do
        local lease = client.lease
        if lease then
            for _, server in ipairs(lease.dns) do servers[#servers + 1] = server end
            domain = domain or lease.domain
        end
    end

    local hosts = {}
    for name, value in pairs(settings.get("net.hosts") or {}) do
        if type(name) == "string" and type(value) == "string" then hosts[dns.normalise(name)] = value end
    end
    return { hosts = hosts, servers = servers, domain = domain, hostname = hostname(), cache = cache }
end

-- Resolve a name (or address) to a number.
local function resolve_number(name)
    local s = load()
    return await(function(callback) dns.resolve(s, name, resolver_options(), callback) end)
end

--- Run the network stack. This is started when the computer starts, and never returns, so there's no need to call it
-- yourself.
function run()
    if running then error("net is already running", 2) end
    running = true

    -- If this function ever returned or errored, the shell would stop and the computer shut down. So if anything goes
    -- wrong starting up, just do nothing.
    local ok, s = pcall(load)
    if not ok or not settings.get("net.enabled") then
        if not ok then log_error(s) end
        while true do os.pullEventRaw() end
    end

    local timer, timer_at
    local channel_check, channel_check_at = os.startTimer(CHANNEL_CHECK_INTERVAL), os.clock() + CHANNEL_CHECK_INTERVAL

    local function handle(event, a, b, c, d, e, f)
        if event == "modem_message" then
            s:receive(a, b, d, f)
        elseif event == "timer" then
            if a == timer then
                timer, timer_at = nil, nil
                s:tick()
            elseif a == channel_check then
                -- Other programs may close our channels (for instance with closeAll), so reopen them.
                for _, interface in pairs(s.interfaces) do
                    if peripheral.isPresent(interface.modem) then open_channels(interface) end
                end
                channel_check, channel_check_at = os.startTimer(CHANNEL_CHECK_INTERVAL), os.clock() + CHANNEL_CHECK_INTERVAL
            end
        elseif event == "peripheral" then
            add_modem(a)
        elseif event == "peripheral_detach" then
            remove_modem(a)
        end
    end

    while true do
        local ok, err = pcall(function()
            handle(os.pullEventRaw())

            -- Events are lost when a computer's event queue is full, timers included. If one of ours is well overdue,
            -- it isn't coming: start another, or the network stack would stop.
            local now = os.clock()
            if timer_at and now > timer_at + 1 then timer, timer_at = nil, nil end
            if now > channel_check_at + CHANNEL_CHECK_INTERVAL then
                channel_check, channel_check_at = os.startTimer(CHANNEL_CHECK_INTERVAL), now + CHANNEL_CHECK_INTERVAL
            end

            local deadline = s:next_deadline()
            if deadline and (not timer_at or deadline < timer_at) then
                timer_at = deadline
                timer = os.startTimer(math.max(0, deadline - os.clock()))
            end
        end)
        if not ok then log_error(err) end
    end
end

--[[- Get this computer's network interfaces.

@treturn { {
    name = string, kind = string, band = string, address? = string, prefix? = number, config = string,
    dhcp? = string, lease? = number, link_local = boolean,
    duplicate = boolean, id = number, unicast = number, broadcast = number, neighbours = number,
    frames_in = number, frames_out = number, dropped = number
}... } Each interface:

 - `name`: The interface's name, which is usually the modem's peripheral name.
 - `kind`: `"wired"`, `"wireless"` or `"ender"`.
 - `band`: `"high"` or `"low"`. Only meaningful for wireless modems.
 - `address`, `prefix`: The interface's address and prefix length, if it has one.
 - `config`: How the address is set: `"dhcp"`, `"static"` or `"none"`.
 - `dhcp`: For DHCP, what the client is doing: `"discovering"`, `"requesting"`, `"bound"`, `"renewing"` or
   `"link-local"` (no server answered).
 - `lease`: For a DHCP lease, how many seconds are left.
 - `link_local`: Whether the address is a link-local one, chosen without a DHCP server.
 - `duplicate`: Whether another computer is using the same address. The interface isn't used if so.
 - `id`: This computer's ID, which is its address on the link.
 - `unicast`, `broadcast`: The channels the interface listens on.
 - `neighbours`: How many computers it has talked to directly.
 - `frames_in`, `frames_out`, `dropped`: Statistics.
]]
function interfaces()
    local s = load()
    local result = s:interface_info()
    for _, info in ipairs(result) do
        local client = s.dhcp_clients and s.dhcp_clients[info.name]
        if client then
            local state = client:info()
            info.config, info.dhcp, info.lease = "dhcp", state.state, state.expires
        else
            info.config = info.address and "static" or "none"
        end
        local interface = s.interfaces[info.name]
        info.link_local = interface.address ~= nil and address.contains(0xA9FE0000, 16, interface.address)
    end
    return result
end

--[[- Set how an interface gets its address. This lasts until the computer restarts: use `ifconfig` to keep it.

@tparam string interface The interface's name.
@tparam string|nil addr An address and prefix length, such as `"10.0.0.1/24"`; `"dhcp"` to ask a DHCP server; or
`nil` (or `"none"`) for no address. Without a prefix length, `/24` is assumed.
@throws If there is no such interface, or the address is invalid.
]]
function setAddress(interface, addr)
    expect(1, interface, "string")
    expect(2, addr, "string", "nil")
    local s = load()
    if not s.interfaces[interface] then error("No interface named '" .. interface .. "'", 2) end

    if addr == "dhcp" then stop_dhcp(interface, false) end
    local ok, err = apply(interface, addr or "none")
    if not ok then error(err, 2) end
end

--[[- Get an interface's address.

@tparam string interface The interface's name.
@treturn string|nil The address, with its prefix length, such as `"10.0.0.1/24"`.
]]
function getAddress(interface)
    expect(1, interface, "string")
    local found = load().interfaces[interface]
    return found and found.address and address.format(found.address, found.prefix)
end

--- Get this computer's hostname: the `net.hostname` setting, or else its label, made safe for a name.
--
-- @treturn string The hostname. The computer answers to this name followed by `.local`.
function getHostname()
    load()
    return hostname()
end

--[[- Get the computers this one has talked to directly.

@treturn { { interface = string, address = string, id = number, expires = number, signal? = number }... } Each
neighbour's interface, address, computer ID, how many seconds until it's forgotten, and the signal strength of the last
radio message from it.
]]
function neighbours()
    return load():neighbour_info()
end

--[[- Find the address for a name.

Names are looked up in this order: addresses (which are returned as they are), the `net.hosts` setting, this computer's
own name, names ending in `.local` (asked of every computer on the local network), and then DNS servers. A name without
dots is tried in the search domain, then as a `.local` name.

@tparam string name The name, such as `"bank.home"` or `"turtle-7.local"`.
@treturn[1] string The address.
@treturn[2] nil If the name couldn't be found.
@treturn[2] string Why not.
@usage Find another computer's address.

```lua
print(net.resolve("my-friend.local"))
```
]]
function resolve(name)
    expect(1, name, "string")
    local addr, err = resolve_number(name)
    if not addr then return nil, err end
    return address.format(addr)
end

--[[- Offer a service on the local network, so other computers can find it with [`net.lookup`].

@tparam string service The service's name, such as `"chat"`.
@tparam number port The port the service listens on.
]]
function host(service, port)
    expect(1, service, "string")
    expect(2, port, "number")
    load()
    services[dns.normalise(service)] = port
end

--- Stop offering a service.
--
-- @tparam string service The service's name.
function unhost(service)
    expect(1, service, "string")
    load()
    services[dns.normalise(service)] = nil
end

--[[- Find every computer offering a service on the local network.

@tparam string service The service's name.
@tparam[opt=1] number timeout How long to wait for answers, in seconds.
@treturn { { host = string, address = string, port = number }... } Each computer which answered, with its name,
address and the service's port.
@usage Find chat servers.

```lua
for _, server in ipairs(net.lookup("chat")) do print(server.host, server.address, server.port) end
```
]]
function lookup(service, timeout)
    expect(1, service, "string")
    expect(2, timeout, "number", "nil")
    local s = load()
    local results = await(function(callback) dns.lookup(s, service, timeout or 1, callback) end)
    for _, result in ipairs(results) do result.address = address.format(result.address) end
    return results
end

--[[- Get the routing table.

@treturn { { network = string, gateway? = string, interface? = string, metric = number, source = string, expires? = number }... }
Each route: the network it leads to (such as `"10.5.0.0/16"`); the router to send to (or none for our own networks);
the interface; the cost; where it came from (`"connected"`, `"static"`, `"dhcp"` or `"rip"`); and for learned routes, how
many seconds until it's forgotten unless refreshed.
]]
function routes()
    local result = {}
    for i, route in ipairs(load():route_info()) do
        result[i] = {
            network = address.format(route.network, route.prefix),
            gateway = route.gateway and address.format(route.gateway),
            interface = route.interface, metric = route.metric, source = route.source, expires = route.expires,
        }
    end
    return result
end

--- Apply changes to the routing settings (`net.forwarding`, `net.gateway`, `net.routes`, `net.rip` and its options,
-- and `net.firewall`) without restarting.
function reload()
    load()
    apply_routing()
end

--[[- Send an echo request to another computer and wait for its reply.

@tparam string target The computer's name or address. A broadcast address gets the first reply from anyone.
@tparam[opt=2] number timeout How long to wait, in seconds.
@tparam[opt=32] number ttl How many routers the request may pass, from 1 to 255. Lower values find the routers on the way, as
`traceroute` does.
@treturn[1] number The round trip time, in seconds.
@treturn[1] number The reply's remaining time to live.
@treturn[1] string The address the reply came from.
@treturn[2] nil If there was no reply.
@treturn[2] string Why not, such as `"Timed out"`, `"Host unreachable"` or `"TTL expired"`.
@treturn[2] string|nil The address of the router which reported the error, if one did.
@usage Check another computer can be reached.

```lua
local time, err = net.ping("10.0.0.2")
if time then print(("Reply in %d ms"):format(time * 1000)) else print(err) end
```
]]
function ping(target, timeout, ttl)
    expect(1, target, "string")
    expect(2, timeout, "number", "nil")
    expect(3, ttl, "number", "nil")
    if timeout and not (timeout >= 0 and timeout < math.huge) then error("bad argument #2 (invalid timeout)", 2) end
    if ttl and not (ttl % 1 == 0 and ttl >= 1 and ttl <= 255) then
        error("bad argument #3 (TTL must be a whole number from 1 to 255)", 2)
    end
    local s = load()

    local dst, err = resolve_number(target)
    if not dst then return nil, err end

    local id
    id, err = s:echo(dst, nil, ttl)
    if not id then return nil, err end

    local timer = os.startTimer(timeout or DEFAULT_TIMEOUT)
    while true do
        local event, arg = os.pullEvent()
        if event == "net_echo" and arg == id then
            os.cancelTimer(timer)
            local result = s:echo_result(id)
            s:forget_echo(id)
            if result.error then return nil, result.error, result.from and address.format(result.from) end
            return result.rtt, result.ttl, address.format(result.from)
        elseif event == "timer" and arg == timer then
            s:forget_echo(id)
            return nil, "Timed out"
        end
    end
end

local Socket = {}
Socket.__index = Socket

--[[- Send a datagram from this socket. Sending to a name waits while the name is looked up, so do that in a program,
not in something which must not wait.

@tparam string target The name or address to send to. The broadcast address (`255.255.255.255`) reaches every
computer on the local network.
@tparam number port The port to send to.
@param data The data: any value which can be sent through a modem.
@tparam[opt] string interface For broadcasts, the only interface to send on.
@treturn[1] true If it was sent. Datagrams may still be lost.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not.
]]
function Socket:send(target, port, data, interface)
    expect(1, target, "string")
    expect(2, port, "number")
    expect(4, interface, "string", "nil")
    if self.socket.closed then return nil, "Socket is closed" end

    local dst, err = resolve_number(target)
    if not dst then return nil, err end
    return stack:udp_send(self.socket, dst, port, data, interface)
end

--[[- Wait for a datagram to arrive.

@tparam[opt] number timeout How long to wait, in seconds. Waits forever if not given.
@return[1] The datagram's data.
@treturn[1] string The address it came from.
@treturn[1] number The port it came from.
@treturn[1] string The interface it arrived on.
@treturn[2] nil If nothing arrived in time, or the socket is closed.
]]
function Socket:receive(timeout)
    expect(1, timeout, "number", "nil")
    local queue = self.socket.queue
    local timer = timeout and os.startTimer(timeout)
    while true do
        local item = table.remove(queue, 1)
        if item then
            if timer then os.cancelTimer(timer) end
            return item.data, address.format(item.from), item.port, item.interface
        end
        if self.socket.closed then return nil end

        local event, arg = os.pullEvent()
        if event == "timer" and arg == timer then return nil end
    end
end

--- Get the port this socket is bound to.
--
-- @treturn number The port.
function Socket:getPort()
    return self.socket.port
end

--- Close this socket, freeing its port.
function Socket:close()
    stack:udp_close(self.socket)
end

--[[- Datagram sockets, for sending messages without connections. Datagrams may be lost, and nothing tells you if they
are, much like UDP.

@usage A server which echoes back anything it receives on port 7.

```lua
local socket = net.udp.open(7)
while true do
    local data, from, port = socket:receive()
    socket:send(from, port, data)
end
```
]]
udp = {
    --[[- Open a datagram socket. Close it once you're done, so its port is freed.

    @tparam[opt] number port The port to listen on, or `nil` for any free port. Servers usually pick a port; clients
    usually don't.
    @treturn[1] table The socket, with `send`, `receive`, `getPort` and `close` methods.
    @treturn[2] nil If the port is already in use.
    @treturn[2] string An error message.
    ]]
    open = function(port)
        expect(1, port, "number", "nil")
        local socket, err = load():udp_open(port)
        if not socket then return nil, err end
        return setmetatable({ socket = socket }, Socket)
    end,
}

local Connection = {}
Connection.__index = Connection

--[[- Send a message. Waits while the other side is behind, so a fast sender can't swamp a slow receiver.

Any value a modem can send works, up to about 60 KiB. Unlike datagrams and modems, which quietly drop functions,
connections refuse messages containing them. Use [`net.stream`] to send more data than fits in one message.

@param value The message.
@treturn[1] true If it was queued. It's delivered unless the connection fails.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not, such as `"Connection closed"`, `"Connection reset"` or `"Message too large"`.
]]
function Connection:send(value)
    while true do
        local ok, err = self.connection:send(value)
        if ok then return true end
        if err ~= "Full" then return nil, err end
        os.pullEvent()
    end
end

--[[- Wait for the next message.

@tparam[opt] number timeout How long to wait, in seconds. Waits until something arrives if not given.
@return[1] The message.
@treturn[2] nil If the other side has closed, and every message has been received.
@treturn[3] nil If nothing arrived in time, or the connection failed.
@treturn[3] string Why: `"Timed out"`, or what went wrong with the connection, such as `"Connection reset"`.
]]
function Connection:receive(timeout)
    expect(1, timeout, "number", "nil")
    local timer = timeout and os.startTimer(timeout)
    while true do
        local ok, value = self.connection:take()
        if ok or value then
            if timer then os.cancelTimer(timer) end
            if ok then return value end
            if value == "closed" then return nil end
            return nil, value
        end

        local event, arg = os.pullEvent()
        if event == "timer" and arg == timer then return nil, "Timed out" end
    end
end

--- Close our side of the connection. Messages already sent are still delivered, and messages from the other side can
-- still be received until it closes too.
function Connection:close()
    self.connection:close()
end

--- Drop the connection at once, without delivering anything still waiting to be sent.
function Connection:abort()
    self.connection:abort()
end

--- Get the address and port of the other side.
--
-- @treturn string The address.
-- @treturn number The port.
function Connection:getPeer()
    return address.format(self.connection.remote_addr), self.connection.remote_port
end

--- Get the port of our side.
--
-- @treturn number The port.
function Connection:getPort()
    return self.connection.local_port
end

--- Get the connection's ID, which the `net_data`, `net_sent` and `net_closed` events carry.
--
-- @treturn number The ID.
function Connection:getId()
    return self.connection.id
end

--- Check whether the connection is open: messages can be sent, and the other side is there.
--
-- @treturn boolean Whether it's open.
function Connection:isOpen()
    local connection = self.connection
    return connection.state == "established" and not connection.closing
end

local Listener = {}
Listener.__index = Listener

--[[- Wait for a connection.

@tparam[opt] number timeout How long to wait, in seconds. Waits until one comes if not given.
@treturn[1] table The connection, with the same methods as one from `net.tcp.connect`.
@treturn[2] nil If none came in time, or the listener is closed.
@treturn[2] string Why not.
]]
function Listener:accept(timeout)
    expect(1, timeout, "number", "nil")
    local timer = timeout and os.startTimer(timeout)
    while true do
        local connection = self.listener:accept()
        if connection then
            if timer then os.cancelTimer(timer) end
            return setmetatable({ connection = connection }, Connection)
        end
        if self.listener.closed then return nil, "Listener is closed" end

        local event, arg = os.pullEvent()
        if event == "timer" and arg == timer then return nil, "Timed out" end
    end
end

--- Stop listening, freeing the port. Connections already accepted carry on.
function Listener:close()
    self.listener:close()
end

--- Get the port this listener is on.
--
-- @treturn number The port.
function Listener:getPort()
    return self.listener.port
end

--[[- Connections, which deliver messages in order and exactly once, much like TCP.

Messages lost on the way are sent again, and a sender waits when the receiver is behind. Connections stay open until
either side closes them, or until the other side stops answering, which is noticed within about two minutes (or two
more if the connection was idle).

The stack queues events for programs which wait for several things at once: `net_connection` (with the port) when a
listener has a connection to accept; `net_data` (with the connection's ID) when there's something new to receive;
`net_sent` (with the ID) when a connection can take more messages; and `net_closed` (with the ID and, if it failed,
why) when the connection has ended and everything has been received.

@usage A server which sends back whatever it's sent, and a client for it.

```lua
local listener = assert(net.tcp.listen(7))
while true do
    local connection = listener:accept()
    for message in connection.receive, connection do connection:send(message) end
    connection:close()
end
```

```lua
local connection = assert(net.tcp.connect("server.local", 7))
connection:send("Hello!")
print(connection:receive(5))
connection:close()
```
]]
tcp = {
    --[[- Connect to another computer.

    @tparam string target The name or address to connect to.
    @tparam number port The port to connect to.
    @tparam[opt=5] number timeout How long to wait for the other side to answer, in seconds.
    @treturn[1] table The connection, with `send`, `receive`, `close`, `abort`, `getPeer`, `getPort`, `getId` and
    `isOpen` methods.
    @treturn[2] nil If it couldn't connect.
    @treturn[2] string Why not, such as `"Connection refused"` (nothing is listening on that port) or `"Timed out"`.
    ]]
    connect = function(target, port, timeout)
        expect(1, target, "string")
        expect(2, port, "number")
        expect(3, timeout, "number", "nil")
        local s = load()

        local dst, err = resolve_number(target)
        if not dst then return nil, err end
        local connection
        connection, err = connections.connect(s, dst, port)
        if not connection then return nil, err end

        local timer = os.startTimer(timeout or CONNECT_TIMEOUT)
        local ok, result = pcall(function()
            while connection.state == "syn_sent" do
                local event, arg = os.pullEvent()
                if event == "timer" and arg == timer then return "Timed out" end
            end
        end)
        os.cancelTimer(timer)
        -- Give up on the connection if we stopped waiting (or were terminated).
        if not ok or result then connection:abort() end
        if not ok then error(result, 0) end
        if result then return nil, result end
        if connection.state ~= "established" then return nil, connection.error or "Connection failed" end
        return setmetatable({ connection = connection }, Connection)
    end,

    --[[- Listen for connections on a port. Close the listener once you're done, so the port is freed.

    @tparam number port The port.
    @treturn[1] table The listener, with `accept`, `close` and `getPort` methods.
    @treturn[2] nil If the port is in use.
    @treturn[2] string An error message.
    ]]
    listen = function(port)
        expect(1, port, "number")
        local listener, err = connections.listen(load(), port)
        if not listener then return nil, err end
        return setmetatable({ listener = listener }, Listener)
    end,
}

--[[- Read and write bytes over a connection, like a file. Writes are collected and sent in chunks of 16 KiB, so call
`flush` (or `close`) to send the last of them.

Both sides must use streams: a stream only carries text, and is confused by other messages.

@tparam table connection A connection from `net.tcp.connect`, or a listener's `accept`.
@treturn table The stream, with `read`, `readLine`, `readAll`, `write`, `writeLine`, `flush` and `close` methods. Reading
returns `nil` once the other side has closed, and errors if the connection fails.
@usage Send a file.

```lua
local connection = assert(net.tcp.connect("server.local", 115))
local stream = net.stream(connection)
local file = fs.open("data.txt", "rb")
stream.write(file.readAll())
file.close()
stream.close()
```
]]
function stream(connection)
    expect(1, connection, "table")
    if getmetatable(connection) ~= Connection then error("bad argument #1 (expected a connection)", 2) end
    return streams.wrap(connection)
end

--[[- Get the most recent errors in the network stack, for debugging. Errors are kept here rather than printed, so they
don't interrupt other programs.

@treturn { string... } Up to 16 error messages, oldest first.
]]
function getErrors()
    local result = {}
    for i, err in ipairs(errors) do result[i] = err end
    return result
end

--[[- Start or stop capturing frames, for debugging. While capturing, a `net_frame` event is queued for every frame
sent or received. Capturing stops by itself after 30 seconds unless renewed, in case the program using it stops.

The event has the direction (`"in"` or `"out"`), the interface's name, the frame, and for incoming radio frames the
signal strength.

@tparam boolean enabled Whether to capture frames.
]]
function capture(enabled)
    expect(1, enabled, "boolean")
    load():set_capture(enabled)
end
