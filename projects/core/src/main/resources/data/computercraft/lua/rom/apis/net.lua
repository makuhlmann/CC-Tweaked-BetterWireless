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

A wired modem is one interface. A wireless or ender modem is one interface on the short-range high band by default
(channels 1024 and up). Set `net.<name>.band` to `"low"` to use the long-range low band instead (channels below 1024).
An interface on the other band of the same modem can be added by setting `net.<name>:low.address` (or
`net.<name>:high.address`).

Programs talk with datagrams ([`net.udp`]), single messages which may be lost, or connections ([`net.tcp`]), which
deliver messages in order and exactly once, resending any which are lost. [`net.stream`] reads and writes bytes over a
connection, like a file.

> [!WARNING]
> Datagrams and plain connections aren't encrypted or authenticated: anyone in range can read them, or pretend to be
> any computer. Use secure connections ([`net.secure`]) for anything which matters.

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
local files = dofile("rom/modules/main/cc/internal/net/files.lua")
local checks = dofile("rom/modules/main/cc/internal/net/checks.lua")

local DEFAULT_PREFIX = 24
local CHANNEL_CHECK_INTERVAL = 5
local MAX_ERRORS = 16
local DEFAULT_TIMEOUT = 2
local PORT_ERROR = checks.PORT_ERROR
local CONNECT_TIMEOUT = 5
local HANDSHAKE_TIMEOUT = 5

-- Where secure connections keep what they know.
local KNOWN_HOSTS, TRUSTED, CERTIFICATE = files.KNOWN_HOSTS, files.TRUSTED, files.CERTIFICATE

local stack, address, dhcp, dns, rip, connections, streams, secure_connections, certificates, links, running
local rip_instance, rip_config
local add_modem, apply_routing, start_phone, start_cellular, env_require
local errors = {}
local services = {}
local cache = {}

-- Services which run in the background process, such as a cellular network's core, by name. Each has a `resume`
-- method, which is passed every event.
local background = {}
-- Whether a "net_cell" event, which wakes services, is queued already.
local cell_wake_queued = false

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
    env_require = env.require
    address = env.require("cc.net.address")
    dhcp = env.require("cc.internal.net.dhcp")
    dns = env.require("cc.internal.net.dns")
    rip = env.require("cc.internal.net.rip")
    connections = env.require("cc.internal.net.tcp")
    streams = env.require("cc.internal.net.stream")
    secure_connections = env.require("cc.internal.net.secure")
    links = env.require("cc.internal.net.link")
    certificates = env.require("cc.internal.net.certificate")

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
        epoch = function() return os.epoch("utc") end,
        crypto = crypto,
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
    pcall(start_phone)
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
            -- The setting may have been changed by hand, so check what the firewall program would.
            if rule.proto ~= nil and not checks.is_protocol(rule.proto) then error("expected a protocol of udp, tcp or icmp", 0) end
            local port = rule.port ~= nil and tonumber(rule.port) or nil
            if rule.port ~= nil and not checks.is_port(port) then error(PORT_ERROR, 0) end
            if rule.on ~= nil and type(rule.on) ~= "string" then error("expected an interface's name", 0) end
            local src, src_prefix = parse_network(rule.from)
            local dst, dst_prefix = parse_network(rule.to)
            rules[#rules + 1] = {
                action = rule.action, proto = rule.proto, port = port, interface = rule.on,
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
            local ok, result = pcall(rip.start, stack, {
                default = default, key = key, hmac = key and crypto.hmac, equals = key and crypto.equals,
            })
            if ok then rip_instance = result else log_error("Cannot start routing: " .. tostring(result)) end
        end
    end

    stack:set_firewall(firewall_rules())
end

-- Check that a timeout, if there is one, can be waited for: a number of seconds which isn't negative, infinite or NaN.
-- Call it after `expect`, from the function the timeout was given to.
local function check_timeout(index, timeout)
    if timeout ~= nil and not (timeout >= 0 and timeout < math.huge) then
        error(("bad argument #%d (invalid timeout)"):format(index), 3)
    end
end

local is_port = checks.is_port

-- Apply an address setting to an interface: "dhcp", "none", or an address. Without a setting, wired interfaces use
-- DHCP, and radios (wireless and ender modems) stay quiet.
local function apply_mode(name, mode)
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
    local usable, why = address.check_host(addr, prefix)
    if not usable then return nil, why end
    stop_dhcp(name, true)
    stack:set_address(name, addr, prefix)
    return true
end

-- Apply an address setting (see `apply_mode`), and say so with a `net_interface` event if the address changed. DHCP
-- says so itself when it gets one.
local function apply(name, mode)
    local interface = stack.interfaces[name]
    local before, before_prefix = interface and interface.address, interface and interface.prefix
    local ok, err = apply_mode(name, mode)
    if ok and interface and (interface.address ~= before or interface.prefix ~= before_prefix) then
        os.queueEvent("net_interface", name, "address")
    end
    return ok, err
end

-- Encrypt an interface with its passphrase, if it has one. If it should be encrypted but can't be, it sends and accepts
-- nothing, rather than sending in the clear.
local function apply_passphrase(name, passphrase)
    if passphrase == nil then
        stack:set_link_key(name, nil)
    elseif type(passphrase) ~= "string" or passphrase == "" then
        log_error(("The passphrase for %s must be text"):format(name))
        stack:set_link_key(name, false)
    elseif not crypto then
        log_error(("%s has a passphrase, but the crypto API is turned off, so it can't be used"):format(name))
        stack:set_link_key(name, false)
    else
        stack:set_link_key(name, links.derive(crypto, passphrase))
    end
end

local function add_interface(name, modem, kind, band)
    local interface = stack:add_interface(name, modem, kind, band)
    open_channels(interface)
    -- Before the address, so the first announcement is encrypted too.
    apply_passphrase(name, settings.get("net." .. name .. ".psk"))
    local ok, err = apply(name, settings.get("net." .. name .. ".address"))
    if not ok then log_error(("Bad address for %s: %s"):format(name, err)) end
    os.queueEvent("net_interface", name, "up")
end

local function setup_modem(name)
    if not peripheral.hasType(name, "modem") or stack.by_modem[name] then return end

    if not peripheral.call(name, "isWireless") then return add_interface(name, name, "wired", "high") end

    -- Ender modems are radios with both bands too, whose signal also appears in other dimensions.
    local ok, ender = pcall(peripheral.call, name, "isInterdimensional")
    local kind = ok and ender and "ender" or "wireless"

    local primary = settings.get("net." .. name .. ".band") == "low" and "low" or "high"
    add_interface(name, name, kind, primary)

    local other = primary == "low" and "high" or "low"
    if settings.get("net." .. name .. ":" .. other .. ".address") ~= nil then
        add_interface(name .. ":" .. other, name, kind, other)
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
    -- A phone whose modem was missing can start now.
    if start_phone then
        ok, err = pcall(start_phone)
        if not ok then log_error(err) end
    end
end

-- Start something which finishes by calling a callback, then wait for it. The stack's background process does the
-- work, so this just waits for the callback to be called. If it's called at once, there's nothing to wait for, and no
-- event is queued: one which nobody pulled would take a place in the event queue.
local function await(start)
    local done, waiting, results = false, false, nil
    start(function(...)
        done, results = true, table.pack(...)
        if waiting then os.queueEvent("net_done") end
    end)
    waiting = true
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

-- Resolve a name (or address) to a number. An address needs no looking up, which matters for datagrams: each one sent
-- to an address would otherwise read the settings and every DHCP lease first.
local function resolve_number(name)
    local s = load()
    local literal = address.parse(dns.normalise(name))
    if literal then return literal end
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

    -- Start a cellular network's core, and a cell, if this computer is one.
    local started, start_err = pcall(start_cellular)
    if not started then log_error(start_err) end

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
                    -- Virtual interfaces have no modem.
                    if interface.modem and peripheral.isPresent(interface.modem) then open_channels(interface) end
                end
                channel_check, channel_check_at = os.startTimer(CHANNEL_CHECK_INTERVAL), os.clock() + CHANNEL_CHECK_INTERVAL
            end
        elseif event == "net_cell" then
            cell_wake_queued = false
        elseif event == "peripheral" then
            add_modem(a)
        elseif event == "peripheral_detach" then
            remove_modem(a)
        end
    end

    while true do
        local event = table.pack(os.pullEventRaw())
        local ok, err = pcall(function()
            handle(table.unpack(event, 1, event.n))

            -- Then the services, which may use the network as programs do. One may stop itself, or start another.
            local services = {}
            for _, service in pairs(background) do services[#services + 1] = service end
            for _, service in ipairs(services) do
                local service_ok, service_err = pcall(service.resume, service, table.unpack(event, 1, event.n))
                if not service_ok then log_error(service_err) end
            end

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

--[[- Encrypt everything sent on an interface with a passphrase, and only accept what's encrypted with the same one.
Every computer on the link needs the same passphrase, much like a Wi-Fi password. This keeps others off the network,
but anyone with the passphrase can read everything sent with it, so use secure connections for anything sensitive.

To keep it when the computer restarts, set `net.<interface>.psk` too (the `ifconfig` program does both).

@tparam string interface The interface's name.
@tparam string|nil passphrase The passphrase, or `nil` to stop encrypting.
@throws If there is no such interface.
]]
function setPassphrase(interface, passphrase)
    expect(1, interface, "string")
    expect(2, passphrase, "string", "nil")
    local s = load()
    local found = s.interfaces[interface]
    if not found then error("No interface named '" .. interface .. "'", 2) end

    apply_passphrase(interface, passphrase)
    -- Announce our address again, so the computers which share the passphrase hear it.
    if found.address then s:set_address(interface, found.address, found.prefix) end
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
    if not is_port(port) then error("bad argument #2 (" .. PORT_ERROR .. ")", 2) end
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
    check_timeout(2, timeout)
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
    check_timeout(2, timeout)
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

local Pinger = {}
Pinger.__index = Pinger

--[[- Send the next echo request.

@treturn[1] number Its sequence number: 1 for the first, and so on.
@treturn[1] string|nil Why it couldn't be sent, if it couldn't, such as `"Network unreachable"`. A request which
couldn't be sent still uses up a sequence number, so that the next one says how many were tried.
@treturn[2] nil If the pinger is closed (or sent nothing for a minute, so was closed).
@treturn[2] string Why not.
]]
function Pinger:send()
    local seq, err = load():echo_next(self.id, self.address, self.ttl)
    if not seq then return nil, "Pinger is closed" end
    return seq, err
end

--[[- Wait for the next reply to any of the requests sent, or the next error about one.

@tparam[opt] number timeout How long to wait, in seconds. Waits forever if not given.
@treturn[1] table The reply: `seq`, the sequence number of the request it answers; `from`, the address it came from;
and either `time` (the round trip time, in seconds), `ttl` (its remaining time to live) and `duplicate` (whether that
request was answered before), or `error`, such as `"Host unreachable"` or `"TTL expired"`, from a router on the way.
@treturn[2] nil If nothing came in time, or the pinger is closed.
]]
function Pinger:receive(timeout)
    expect(1, timeout, "number", "nil")
    check_timeout(1, timeout)
    local s = load()
    local timer = timeout and os.startTimer(timeout)
    while true do
        local reply = s:echo_take(self.id)
        if reply then
            if timer then os.cancelTimer(timer) end
            return {
                seq = reply.seq, from = address.format(reply.from), time = reply.rtt, ttl = reply.ttl,
                duplicate = reply.duplicate, error = reply.error,
            }
        end
        if not s:echo_result(self.id) then
            if timer then os.cancelTimer(timer) end
            return nil
        end

        local event, arg = os.pullEvent()
        if event == "timer" and arg == timer then return nil end
    end
end

--- Get the address the requests go to.
--
-- @treturn string The address.
function Pinger:getAddress()
    return address.format(self.address)
end

--- Close the pinger: replies which come after are ignored.
function Pinger:close()
    load():forget_echo(self.id)
end

--[[- Ping another computer again and again, as the `ping` program does. Each `send` sends an echo request with the next
sequence number, and `receive` waits for the next reply. Unlike [`net.ping`], nothing times out: replies which come
late, out of order or more than once are all received, as they show how the network is doing. Close the pinger once
done with it.

@tparam string target The computer's name or address. A broadcast address gets replies from everyone, each after the
first marked as a duplicate.
@tparam[opt=32] number ttl How many routers the requests may pass, from 1 to 255.
@treturn[1] table The pinger, with `send`, `receive`, `getAddress` and `close` methods.
@treturn[2] nil If the name couldn't be looked up.
@treturn[2] string Why not, such as `"Name not found"`.
@usage Ping a computer three times, a second apart, and show each reply.

```lua
local pinger = assert(net.pinger("10.0.0.2"))
for _ = 1, 3 do
    pinger:send()
    local reply = pinger:receive(1)
    if reply and reply.time then
        print(("Reply to %d in %d ms"):format(reply.seq, reply.time * 1000))
    elseif reply then
        print(("%d: %s"):format(reply.seq, reply.error))
    end
end
pinger:close()
```
]]
function pinger(target, ttl)
    expect(1, target, "string")
    expect(2, ttl, "number", "nil")
    if ttl and not (ttl % 1 == 0 and ttl >= 1 and ttl <= 255) then
        error("bad argument #2 (TTL must be a whole number from 1 to 255)", 2)
    end
    local s = load()

    local dst, err = resolve_number(target)
    if not dst then return nil, err end
    return setmetatable({ id = s:echo_series(), address = dst, ttl = ttl }, Pinger)
end

local Socket = {}
Socket.__index = Socket

--[[- Send a datagram from this socket. Sending to a name waits while the name is looked up, so do that in a program,
not in something which must not wait.

@tparam string target The name or address to send to. The broadcast address (`255.255.255.255`) reaches every
computer on the local network.
@tparam number port The port to send to.
@param data The data: the same values a connection's messages may be (see [`net.tcp`]'s `send`), or nothing.
@tparam[opt] string interface For broadcasts, the only interface to send on.
@treturn[1] true If it was sent. Datagrams may still be lost.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not, such as `"Network unreachable"` or `"Can't send a function"`.
]]
function Socket:send(target, port, data, interface)
    expect(1, target, "string")
    expect(2, port, "number")
    expect(4, interface, "string", "nil")
    if self.socket.closed then return nil, "Socket is closed" end
    if not is_port(port) then return nil, PORT_ERROR end

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
@treturn[2] string Why not: `"Timed out"` or `"Socket is closed"`.
]]
function Socket:receive(timeout)
    expect(1, timeout, "number", "nil")
    check_timeout(1, timeout)
    local queue = self.socket.queue
    local timer = timeout and os.startTimer(timeout)
    while true do
        local item = table.remove(queue, 1)
        if item then
            if timer then os.cancelTimer(timer) end
            return item.data, address.format(item.from), item.port, item.interface
        end
        if self.socket.closed then
            if timer then os.cancelTimer(timer) end
            return nil, "Socket is closed"
        end

        local event, arg = os.pullEvent()
        if event == "timer" and arg == timer then return nil, "Timed out" end
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
    @treturn[2] nil If the port is already in use, or isn't a port.
    @treturn[2] string An error message.
    ]]
    open = function(port)
        expect(1, port, "number", "nil")
        if port ~= nil and not is_port(port) then return nil, PORT_ERROR end
        local socket, err = load():udp_open(port)
        if not socket then return nil, err end
        return setmetatable({ socket = socket }, Socket)
    end,
}

local Connection = {}
Connection.__index = Connection

--[[- Send a message. Waits while the other side is behind, so a fast sender can't swamp a slow receiver.

Any value [`cc.net.codec`] can encode works, up to about 60 KiB: strings, numbers, booleans, and tables of them up to 60
deep. Modems quietly drop functions from what they send. Connections and datagrams don't: a message which can't be
sent whole is refused, and the connection carries on. That goes for functions, tables which contain themselves, and
tables used as keys, which encrypted links couldn't carry. Use [`net.stream`] to send more data than fits in one
message.

@param value The message.
@treturn[1] true If it was queued. It's delivered unless the connection fails.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not, such as `"Connection closed"`, `"Connection reset"`, `"Message too large"` or
`"Can't send a table which contains itself"`.
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
    check_timeout(1, timeout)
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
    check_timeout(1, timeout)
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
        check_timeout(3, timeout)
        if not is_port(port) then return nil, PORT_ERROR end
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
        -- Load the network stack first: until then (as when a startup program listens), the TCP module isn't loaded.
        local network = load()
        local listener, err = connections.listen(network, port)
        if not listener then return nil, err end
        return setmetatable({ listener = listener }, Listener)
    end,
}

local to_hex, from_hex, read_table = files.hex.encode, files.hex.decode, files.read_table

-- What's been read from files which are read often (see `read_cached`), by key.
local file_cache = {}

-- Write one of the small tables kept in /.net, and forget what was read of it.
local function write_table(path, value)
    files.write_table(path, value)
    for key, entry in pairs(file_cache) do
        if entry.path == path then file_cache[key] = nil end
    end
end

-- Read something from a file, or give what was read last time if the file hasn't changed since (by its modification
-- time and size). Our own writes forget it at once. `net.cell.info`, which the status bar and the menus call often,
-- reads its files so.
local function read_cached(key, path, read)
    local ok, attributes = pcall(fs.attributes, path)
    local stamp = ok and type(attributes) == "table" and ("%s:%s"):format(attributes.modified, attributes.size) or "none"
    local entry = file_cache[key]
    if entry and entry.stamp == stamp then return entry.value end
    local value = read()
    file_cache[key] = { path = path, stamp = stamp, value = value }
    return value
end

local function require_crypto()
    if not crypto or not enclave then
        error("Secure connections need the crypto and enclave APIs, which are turned off on this server", 3)
    end
end

-- This computer's key for secure connections. It lives in the enclave, so it can't be copied.
local function identity()
    require_crypto()
    local public = enclave.publicKey("net.identity") or enclave.generate("net.identity", "x25519")
    return { public = public, exchange = function(peer) return enclave.exchange("net.identity", peer) end }
end

--[[- Get this computer's key for secure connections, which other computers see when it connects to them.

@treturn string The key, as 64 hexadecimal digits.
]]
function getIdentity()
    return to_hex(identity().public)
end

--[[- Get a short fingerprint of a key, for people to compare.

@tparam string key The key, as 64 hexadecimal digits.
@treturn string The fingerprint, such as `"3f9a 0c41 77d2 e810 5b6e"`.
@throws If the key isn't a key.
]]
function fingerprint(key)
    expect(1, key, "string")
    local bytes = #key == 64 and from_hex(key)
    if not bytes then error("bad argument #1 (expected a key: 64 hexadecimal digits)", 2) end
    require_crypto()
    return to_hex(crypto.sha256(bytes)):sub(1, 20):gsub("(....)", "%1 "):sub(1, -2)
end

--[[- Get the authorities this computer trusts to issue certificates (in `/.net/trust`).

@treturn { [string] = string } Each authority's key (as hexadecimal digits), and a description.
]]
function trusted()
    local result = {}
    for key, label in pairs(read_table(TRUSTED)) do
        if from_hex(key) and #key == 64 then result[key:lower()] = tostring(label) end
    end
    return result
end

--[[- Get the keys this computer has seen for other computers, when connecting securely (in `/.net/known_hosts`).

@treturn { [string] = string } Each name, and its key as hexadecimal digits. Entries which aren't a name and a key
(in a file which was changed by hand, say) are left out, as [`net.trusted`] does.
]]
function knownHosts()
    local result = {}
    for name, key in pairs(read_table(KNOWN_HOSTS)) do
        if type(name) == "string" and type(key) == "string" and #key == 64 and from_hex(key) then
            result[name] = key:lower()
        end
    end
    return result
end

--[[- Forget the key this computer has seen for a name, so the next secure connection to it learns a new one. Use this
when a computer's key changed for a good reason, such as the computer being replaced.

@tparam string name The name.
@treturn boolean Whether a key was forgotten.
]]
function forgetHost(name)
    expect(1, name, "string")
    load()
    local hosts = read_table(KNOWN_HOSTS)
    name = dns.normalise(name)
    if hosts[name] == nil then return false end
    hosts[name] = nil
    write_table(KNOWN_HOSTS, hosts)
    return true
end

local SecureConnection = setmetatable({}, { __index = Connection })
SecureConnection.__index = SecureConnection

--[[- Send a message, encrypted. Any value [`cc.net.codec`] can encode works, up to about 60 KiB.

@param value The message.
@treturn[1] true If it was sent.
@treturn[2] nil If it couldn't be sent.
@treturn[2] string Why not.
]]
function SecureConnection:send(value)
    return self.session:send(value)
end

--[[- Wait for the next message.

@tparam[opt] number timeout How long to wait, in seconds.
@return[1] The message.
@treturn[2] nil If the other side has closed, and every message has been received.
@treturn[3] nil If nothing arrived in time, or the connection failed.
@treturn[3] string Why: `"Timed out"`, `"Message was tampered with"`, `"Connection closed unexpectedly"` (someone may
have cut it short), or what went wrong with the connection.
]]
function SecureConnection:receive(timeout)
    expect(1, timeout, "number", "nil")
    check_timeout(1, timeout)
    return self.session:receive(timeout)
end

--- Close our side of the connection, telling the other side we're done.
function SecureConnection:close()
    self.session:close()
end

--- Drop the connection at once.
function SecureConnection:abort()
    self.session:abort()
end

--- Get the other side's key.
--
-- @treturn string|nil The key, as 64 hexadecimal digits, or `nil` if it didn't say who it is.
function SecureConnection:getPeerKey()
    return self.session.peer_key and to_hex(self.session.peer_key)
end

--- Get the name the other side's certificate vouches for, if it had one this computer trusts.
--
-- @treturn string|nil The name.
function SecureConnection:getPeerName()
    return self.peer_name
end

--[[- Get how we know the other side is who it says it is.

@treturn string|nil `"certificate"` (a trusted authority vouches for it), `"pinned"` (its key was the one asked for),
`"known"` (it had the same key last time), `"new"` (it's the first connection to this name, so its key was learnt now),
or `nil` for the server's side of a connection.
]]
function SecureConnection:getTrust()
    return self.trust
end

local function wrap_session(connection, session, extra)
    local result = setmetatable({ connection = connection.connection, plain = connection, session = session }, SecureConnection)
    for k, v in pairs(extra or {}) do result[k] = v end
    return result
end

local SecureListener = {}
SecureListener.__index = SecureListener

--[[- Wait for a secure connection. Connections which fail their handshake are dropped, and waiting carries on.

While a client does its handshake, others wait: one which stalls holds them up for up to 5 seconds.

@tparam[opt] number timeout How long to wait, in seconds. Waits until one comes if not given.
@treturn[1] table The connection, with the same methods as one from [`net.secure.connect`].
@treturn[2] nil If none came in time, or the listener is closed.
@treturn[2] string Why not.
]]
function SecureListener:accept(timeout)
    expect(1, timeout, "number", "nil")
    check_timeout(1, timeout)
    local deadline = timeout and os.clock() + timeout
    while true do
        local remaining = deadline and math.max(0, deadline - os.clock())
        local connection, err = self.listener:accept(remaining)
        if not connection then return nil, err end

        local session, handshake_err = secure_connections.server(connection, {
            crypto = crypto, static = self.identity, certificate = self.certificate, timeout = HANDSHAKE_TIMEOUT,
            anonymous = self.anonymous,
        })
        if session then return wrap_session(connection, session) end
        log_error(("Secure connection from %s failed: %s"):format(connection:getPeer(), handshake_err))
    end
end

--- Stop listening, freeing the port.
function SecureListener:close()
    self.listener:close()
end

--- Get the port this listener is on.
--
-- @treturn number The port.
function SecureListener:getPort()
    return self.listener:getPort()
end

--[[- Secure connections: like [`net.tcp`], but encrypted, and both sides know who they're talking to.

Each computer has a key, kept in its enclave so it can't be copied. When a client connects, it checks the server is who
it should be, in this order:

 1. If the client gave the server's key (`options.key`), it must match.
 2. If the server has a certificate from an authority the client trusts (see the `netkeys` program), it must be for
    the name the client asked for.
 3. Otherwise the client remembers the server's key the first time it connects to a name (in `/.net/known_hosts`), and
    refuses to connect if the key is ever different, as SSH does. Someone pretending to be the server on the very first
    connection would go unnoticed, so check the fingerprint (`getPeerKey` and [`net.fingerprint`]) when it matters.

The server learns the client's key too, which it can check against a list of keys it allows.

Messages are encrypted and authenticated: anything changed, replayed or cut short on the way is noticed, and ends the
connection. They may hold the same values as any connection's.

@usage Connect to a server, and print its key's fingerprint.

```lua
local connection = assert(net.secure.connect("bank.spawn", 443))
print(net.fingerprint(connection:getPeerKey()))
```
]]
secure = {
    --[[- Connect securely to another computer.

    @tparam string target The name or address to connect to.
    @tparam number port The port to connect to.
    @tparam[opt] {
        timeout? = number, key? = string, trust? = string, anonymous? = boolean,
    } options How long to wait for each step, in seconds (5 by default); the server's key, as hexadecimal digits, if
    it's known; `"certificate"` to only accept a server with a trusted certificate; and whether to connect without
    saying who we are (which needs the server's key, given or known).
    @treturn[1] table The connection, with the same methods as one from `net.tcp.connect`, and `getPeerKey`,
    `getPeerName` and `getTrust`.
    @treturn[2] nil If it couldn't connect.
    @treturn[2] string Why not.
    ]]
    connect = function(target, port, options)
        expect(1, target, "string")
        expect(2, port, "number")
        expect(3, options, "table", "nil")
        options = options or {}
        local timeout = options.timeout
        if timeout ~= nil and (type(timeout) ~= "number" or not (timeout >= 0 and timeout < math.huge)) then
            error("bad option timeout (invalid timeout)", 2)
        end
        if options.trust ~= nil and options.trust ~= "certificate" then
            error("bad option trust (expected \"certificate\" or nothing)", 2)
        end
        if not is_port(port) then return nil, PORT_ERROR end
        require_crypto()
        load()

        local name = dns.normalise(target)
        local pinned = options.key and from_hex(options.key)
        if options.key and (not pinned or #pinned ~= 32) then error("bad option key (expected 64 hexadecimal digits)", 2) end
        local remote_static
        if options.anonymous then
            remote_static = pinned or from_hex(read_table(KNOWN_HOSTS)[name] or "")
            if not remote_static or #remote_static ~= 32 then return nil, "Connecting anonymously needs the server's key" end
        end

        local connection, err = tcp.connect(target, port, options.timeout)
        if not connection then return nil, err end

        local trust, peer_name
        local function verify(key, info)
            if pinned then
                if not crypto.equals(key, pinned) then return nil, "The server's key isn't the one given" end
                trust = "pinned"
                return true
            end

            local problem = "has no certificate"
            local certificate = info.certificate and certificates.decode(info.certificate)
            if certificate then
                local ok, reason = certificates.verify(crypto, certificate, {
                    name = name, key = key, now = os.epoch("utc"), trusted = (function()
                        local result = {}
                        for authority in pairs(trusted()) do result[from_hex(authority)] = true end
                        return result
                    end)(),
                })
                if ok then
                    trust, peer_name = "certificate", certificate.name
                    return true
                end
                problem = reason
            end
            if options.trust == "certificate" then return nil, "The server's certificate " .. problem end

            local hosts = read_table(KNOWN_HOSTS)
            local known = hosts[name]
            if known == nil then
                hosts[name] = to_hex(key)
                write_table(KNOWN_HOSTS, hosts)
                trust = "new"
            elseif known ~= to_hex(key) then
                return nil, ("The key for %s has changed! Something may be pretending to be it. If you know why it " ..
                    "changed, forget the old key with 'netkeys forget %s'."):format(name, name)
            else
                trust = "known"
            end
            return true
        end

        local session
        session, err = secure_connections.client(connection, {
            crypto = crypto, static = not options.anonymous and identity() or nil,
            pattern = options.anonymous and "NK" or "XX", remote_static = remote_static,
            timeout = options.timeout or HANDSHAKE_TIMEOUT, verify = verify,
        })
        if not session then return nil, err end
        return wrap_session(connection, session, { trust = trust or "pinned", peer_name = peer_name })
    end,

    --[[- Listen for secure connections on a port.

    @tparam number port The port.
    @tparam[opt] { anonymous? = boolean } options Whether to accept clients which don't say who they are.
    @treturn[1] table The listener, with `accept`, `close` and `getPort` methods.
    @treturn[2] nil If the port is in use.
    @treturn[2] string An error message.
    ]]
    listen = function(port, options)
        expect(1, port, "number")
        expect(2, options, "table", "nil")
        require_crypto()
        local own = identity()
        local listener, err = tcp.listen(port)
        if not listener then return nil, err end

        -- Offer our certificate, if we have one.
        local certificate
        local file = fs.open(CERTIFICATE, "rb")
        if file then
            certificate = file.readAll()
            file.close()
        end
        return setmetatable({
            listener = listener, identity = own, certificate = certificate, anonymous = options and options.anonymous,
        }, SecureListener)
    end,
}

-- Cellular networks. A phone runs in the background, once the computer has a SIM.
local SIM_FILE = "/.net/sim"
local INBOX_FILE = "/.net/messages"
-- What the user has chosen: `off` (cell service is turned off) and `network` (the only network to use).
local PHONE_FILE = "/.net/phone"
local MAX_INBOX = 100
local phone_instance

-- Messages received and sent, oldest first. Each has a number, `n`, which stays the same as others come and go.
local function read_messages()
    local list, last = {}, 0
    for _, message in ipairs(read_table(INBOX_FILE)) do
        if type(message) == "table" and type(message.text) == "string" then
            list[#list + 1] = message
            if type(message.n) == "number" and message.n > last then last = message.n end
        end
    end
    -- Messages kept by older versions have no numbers.
    for _, message in ipairs(list) do
        if type(message.n) ~= "number" then
            last = last + 1
            message.n = last
        end
    end
    return list, last
end

local function add_message(message)
    local list, last = read_messages()
    message.n = last + 1
    list[#list + 1] = message
    while #list > MAX_INBOX do table.remove(list, 1) end
    write_table(INBOX_FILE, list)
    return message.n
end

-- Change the stored messages a test picks. Returns how many there were.
local function change_messages(test, change)
    local list = read_messages()
    local count = 0
    for i = #list, 1, -1 do
        if test(list[i]) then
            count = count + 1
            if change(list[i]) == false then table.remove(list, i) end
        end
    end
    if count > 0 then write_table(INBOX_FILE, list) end
    return count
end

local function sim_key()
    require_crypto()
    local public = enclave.publicKey("sim") or enclave.generate("sim", "x25519")
    return { public = public, exchange = function(peer) return enclave.exchange("sim", peer) end }
end

-- Cellular radio uses a wireless modem's low band, for range: find (or make) an interface on it. An ender modem will
-- do too: it's a weaker radio, which also reaches cells and phones where its signal appears in other dimensions.
local RADIO_KINDS = { wireless = true, ender = true }
local function cell_interface()
    local names = {}
    for name in pairs(stack.interfaces) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local interface = stack.interfaces[name]
        if RADIO_KINDS[interface.kind] and interface.band == "low" then return name end
    end
    for _, name in ipairs(names) do
        local interface = stack.interfaces[name]
        if RADIO_KINDS[interface.kind] and interface.band == "high" and not stack.interfaces[interface.modem .. ":low"] then
            add_interface(interface.modem .. ":low", interface.modem, interface.kind, "low")
            return interface.modem .. ":low"
        end
    end
end

local function new_phone(operator, partners, equivalent)
    -- A computer may be a phone and a cell at once: a relay, whose cell reaches the core through its phone.
    local name = cell_interface()
    if not name then return nil, "This needs a wireless modem" end
    local cell = env_require("cc.internal.net.cell.phone")
    local chosen = read_table(PHONE_FILE)
    phone_instance = cell.new {
        stack = stack, crypto = crypto, interface = name, epoch = function() return os.epoch("utc") end,
        sim = sim_key(), operator = operator, partners = partners, equivalent = equivalent,
        selection = type(chosen.network) == "string" and chosen.network or nil,
        -- The operator says which other networks the phone may use (and which it treats as home): remember them, for
        -- when it starts out of reach of its own.
        on_partners = function(list, equivalent)
            local sim = read_table(SIM_FILE)
            sim.roaming, sim.equivalent = {}, {}
            for network, signing in pairs(list) do sim.roaming[network] = to_hex(signing) end
            for network in pairs(equivalent or {}) do sim.equivalent[network] = true end
            write_table(SIM_FILE, sim)
        end,
        -- With a cell on this computer, this phone may be its backhaul.
        relay = function() return background.cell ~= nil end,
        on_change = function(phone) os.queueEvent("cell_state", phone.state) end,
        on_sent = function(id, ok, reason)
            change_messages(function(message) return message.id == id and message.status == "sending" end, function(message)
                message.status, message.error = ok and "sent" or "failed", reason
            end)
            os.queueEvent("cell_sent", id, ok, reason)
        end,
        on_message = function(from, text)
            add_message({ from = from, text = text, time = os.epoch("utc"), read = false })
            os.queueEvent("cell_message", from, text)
        end,
        on_activated = function(info)
            write_table(SIM_FILE, {
                network = info.network, key = to_hex(info.key), signing = to_hex(info.signing), id = info.id,
                number = info.number,
            })
        end,
    }
    return phone_instance
end

-- Start the phone, if this computer has been activated on a network.
function start_phone()
    if phone_instance or not crypto or not enclave then return end
    if read_table(PHONE_FILE).off then return end
    local sim = read_table(SIM_FILE)
    local key, signing = from_hex(sim.key), from_hex(sim.signing)
    if type(sim.network) ~= "string" or not key or not signing then return end
    local partners, equivalent = {}, {}
    for network, partner in pairs(type(sim.roaming) == "table" and sim.roaming or {}) do
        local partner_key = from_hex(partner)
        if type(network) == "string" and partner_key and #partner_key == 32 then partners[network] = partner_key end
    end
    for network in pairs(type(sim.equivalent) == "table" and sim.equivalent or {}) do
        if partners[network] then equivalent[network] = true end
    end
    new_phone({ network = sim.network, key = key, signing = signing }, partners, equivalent)
end

local CORE_CONFIG, CELL_CONFIG = "/.cell/config", "/.cell/cell"
local CONTROL_PORT = 2123

-- Services queue an event to wake their tasks. One at a time is enough, and many would fill the event queue.
local function cell_wake()
    if cell_wake_queued then return end
    cell_wake_queued = true
    os.queueEvent("net_cell")
end

-- Start a network's core: its controller, subscriber database and gateway.
local function new_core(options)
    local public = enclave.publicKey("cell.operator") or enclave.generate("cell.operator", "x25519")
    local signing = enclave.publicKey("cell.signing") or enclave.generate("cell.signing", "ed25519")
    if not enclave.list()["cell.secret"] then enclave.generate("cell.secret", "secret") end
    -- Phones' packets go through this computer. Keep the setting on too, or reloading the network settings (such as
    -- with the route program) would turn forwarding off again.
    if not settings.get("net.forwarding") then
        settings.set("net.forwarding", true)
        settings.save()
    end
    stack.forwarding = true
    return env_require("cc.internal.net.cell.core").new {
        stack = stack, crypto = crypto, network = options.network, prefix = options.prefix,
        operator = { public = public, exchange = function(peer) return enclave.exchange("cell.operator", peer) end },
        signing = signing, subscribers = options.subscribers, codes = options.codes, number_prefix = options.number_prefix,
        tunnel_key = function(cell) return enclave.hmac("cell.secret", "tunnel key " .. cell) end,
        epoch = function() return os.epoch("utc") end, on_event = options.on_event,
    }
end

-- Run the core in the background.
local function start_core_service()
    if background.core then return true end
    require_crypto()
    load()
    -- The background process may not have started yet (as when startup.lua runs), but it will, unless it's turned off.
    if not settings.get("net.enabled") then return nil, "The network stack is turned off" end
    local signing = enclave.publicKey("cell.signing") or enclave.generate("cell.signing", "ed25519")
    local service, err = env_require("cc.internal.net.cell.core_service").new {
        dir = "/.cell", identity = getIdentity(), fingerprint = fingerprint,
        listen = function() return secure.listen(CONTROL_PORT) end,
        start_core = new_core,
        signing = signing, sign = function(data) return enclave.sign("cell.signing", data) end,
        clock = os.clock, epoch = function() return os.epoch("utc") end, wake = cell_wake,
        -- To carry other networks' phones (roaming), the core connects to their cores.
        id = os.getComputerID(), connect = function(core) return secure.connect(core, CONTROL_PORT) end, sleep = sleep,
        -- An administrator may stop the core, or start it afresh, from anywhere.
        stop = function() cell.stopCore() end,
        restart = function()
            if background.core then
                background.core:stop()
                background.core = nil
            end
            local ok, restart_err = start_core_service()
            if not ok then log_error("Cannot start the cellular core again: " .. tostring(restart_err)) end
        end,
    }
    if not service then return nil, err end
    -- The core must keep running when nobody is nearby.
    pcall(os.setKeepLoaded, true)
    background.core = service
    return true
end

-- The cores a cell connects to, from its settings. Older versions kept only one.
local function cell_cores(config)
    local cores = {}
    for _, core in ipairs(type(config.cores) == "table" and config.cores or {}) do
        if type(core) == "string" then cores[#cores + 1] = core end
    end
    if not cores[1] and type(config.core) == "string" then cores[1] = config.core end
    return cores[1] and cores or nil
end

-- Run a cell in the background: one cell, which serves the network of each core it reaches.
local function start_cell_service(config)
    if background.cell then return true end
    require_crypto()
    load()
    if not settings.get("net.enabled") then return nil, "The network stack is turned off" end
    if not cell_interface() then return nil, "A cell needs a wireless modem" end
    local signing = enclave.publicKey("cell.tower") or enclave.generate("cell.tower", "ed25519")
    local tower
    background.cell = env_require("cc.internal.net.cell.cell_service").new {
        cores = config.cores, area = config.area, id = os.getComputerID(), identity = getIdentity(),
        fingerprint = fingerprint, signing = to_hex(signing),
        connect = function(core) return secure.connect(core, CONTROL_PORT) end,
        start_tower = function(welcome, control)
            local name = cell_interface()
            if not name then error("A cell needs a wireless modem", 0) end
            if not tower or tower.stopped then
                tower = env_require("cc.internal.net.cell.tower").new {
                    stack = stack, crypto = crypto, interface = name, area = welcome.area,
                    sign = function(data) return enclave.sign("cell.tower", data) end,
                    epoch = function() return os.epoch("utc") end,
                    -- A relay reaches a core through this computer's phone, so it can only serve that core's network
                    -- while the phone has service. Otherwise its phones would stay, with nowhere for their packets to go.
                    can_serve = function(core)
                        if not phone_instance or phone_instance.state == "attached" then return true end
                        local interface = stack:route(core)
                        return not (interface and interface.name == "cell")
                    end,
                }
            end
            return tower:add_network(welcome.network, {
                certificate = welcome.certificate, core = address.parse(welcome.core), tunnel_key = welcome.tunnel_key,
                control = control,
            })
        end,
        sleep = sleep, wake = cell_wake,
    }
    -- Cells must keep running when nobody is nearby.
    pcall(os.setKeepLoaded, true)
    return true
end

-- Start the core and the cell, if this computer is set up as either, when the computer starts.
function start_cellular()
    if not crypto or not enclave then return end
    local core = read_table(CORE_CONFIG)
    if type(core.network) == "string" and core.enabled ~= false then
        local ok, err = start_core_service()
        if not ok then log_error("Cannot start the cellular core: " .. tostring(err)) end
    end
    local cell = read_table(CELL_CONFIG)
    local cores = cell_cores(cell)
    if cores and cell.enabled ~= false then
        local ok, err = start_cell_service({ cores = cores, area = cell.area })
        if not ok then log_error("Cannot start the cell: " .. tostring(err)) end
    end
end

local Manager = {}
Manager.__index = Manager

--[[- Send the core a request, and wait for its answer.

@tparam table request The request: `op`, and whatever else that operation takes.
@tparam[opt=15] number timeout How long to wait for the answer, in seconds.
@treturn[1] table The core's answer.
@treturn[2] nil If the core refused, didn't answer, or was lost.
@treturn[2] string Why.
]]
function Manager:request(request, timeout)
    expect(1, request, "table")
    expect(2, timeout, "number", "nil")
    check_timeout(2, timeout)
    if self.closed then return nil, "Closed" end
    local sent, err = self.connection:send(request)
    if not sent then return nil, "Lost the core: " .. tostring(err) end
    local reply, receive_err = self.connection:receive(timeout or 15)
    if type(reply) ~= "table" then return nil, "The core didn't answer: " .. tostring(receive_err or "it hung up") end
    if reply.error ~= nil then return nil, tostring(reply.error) end
    return reply
end

--- Get everything about the network: its cells, the computers allowed in and waiting, its subscribers, roaming, and
-- the networks it exchanges messages with.
--
-- @treturn[1] table `network`, `prefix`, `number_prefix`, `cells`, `allowed`, `waiting`, `subscribers`, `partners`,
-- `carrying`, `peers`, and how many `messages` and activation `codes` are waiting.
-- @treturn[2] nil If it couldn't be had.
-- @treturn[2] string Why not.
function Manager:status() return self:request({ op = "status" }) end

--- Get the core's log.
--
-- @tparam[opt] number after Only lines after the one with this number.
-- @treturn[1] table `lines` (each with `n`, `time` and `text`), and `last`, the number of the last line.
-- @treturn[2] nil If it couldn't be had.
-- @treturn[2] string Why not.
function Manager:log(after)
    expect(1, after, "number", "nil")
    return self:request({ op = "log", after = after })
end

--- Make an activation code for a subscriber.
--
-- @tparam string id The subscriber's ID, such as `"ACME-0042"`.
-- @tparam string number Their phone number.
-- @treturn[1] string The code, which works once, for a day.
-- @treturn[2] nil If it couldn't be made.
-- @treturn[2] string Why not.
function Manager:add(id, number)
    expect(1, id, "string")
    expect(2, number, "string")
    local reply, err = self:request({ op = "add", id = id, number = number })
    if not reply then return nil, err end
    return reply.code
end

--- Remove a subscriber, and any codes for them which haven't been used.
--
-- @tparam string subscriber Their ID or number.
-- @treturn[1] table How many subscribers were `removed`, and how many `codes`.
-- @treturn[2] nil If there's nobody to remove.
-- @treturn[2] string Why not.
function Manager:remove(subscriber)
    expect(1, subscriber, "string")
    return self:request({ op = "remove", subscriber = subscriber })
end

--- Change a subscriber: bar them (their phone is cut off, and refused), or say whether they may roam.
--
-- @tparam string subscriber Their ID or number.
-- @tparam { barred? = boolean, roaming? = boolean } changes What to change.
-- @treturn[1] table The subscriber's `id` and `number`, and whether they're `barred` and may use `roaming`.
-- @treturn[2] nil If it couldn't be done.
-- @treturn[2] string Why not.
function Manager:set(subscriber, changes)
    expect(1, subscriber, "string")
    expect(2, changes, "table")
    return self:request({ op = "set", subscriber = subscriber, barred = changes.barred, roaming = changes.roaming })
end

--- Allow a computer in: a cell, another network's core (to carry this network's phones, or to exchange messages with
-- them, or both), or a computer to manage this one. Check its fingerprint
-- (in `status().waiting`) against the one the computer shows first.
--
-- @tparam string key The computer's key, as 64 hexadecimal digits.
-- @tparam[opt] string label What to call it.
-- @treturn[1] table Its `role`, `id`, `label` and `fingerprint`.
-- @treturn[2] nil If it couldn't be allowed.
-- @treturn[2] string Why not.
function Manager:allow(key, label)
    expect(1, key, "string")
    expect(2, label, "string", "nil")
    return self:request({ op = "allow", key = key, label = label })
end

--- Refuse a computer from now on, dropping any connections it has.
--
-- @tparam string key The computer's key, as 64 hexadecimal digits.
-- @treturn[1] table Its `id`, if that's known.
-- @treturn[2] nil If it couldn't be refused.
-- @treturn[2] string Why not.
function Manager:deny(key)
    expect(1, key, "string")
    return self:request({ op = "deny", key = key })
end

--- Carry another network's phones at this network's cells, by connecting to that network's core, which must allow it.
--
-- @tparam string network The other network's name.
-- @tparam string core Its core's name or address.
-- @treturn[1] table The `id` and `fingerprint` of this core's computer, for the other core's administrator.
-- @treturn[2] nil If it couldn't be set up.
-- @treturn[2] string Why not.
function Manager:carry(network, core)
    expect(1, network, "string")
    expect(2, core, "string")
    return self:request({ op = "carry", network = network, core = core })
end

--- Say whether this network's phones treat a partner (a network which carries them) as home: they aren't roaming
-- there, use its cells as readily as this network's own, and may use it even if they mayn't roam. This is for national
-- roaming, and for a network with no cells of its own (a full MVNO). Phones hear of it when they next attach.
--
-- @tparam string network The partner's name.
-- @tparam boolean home Whether phones treat it as home.
-- @treturn[1] table The partner's `network`, and whether it's now `home`.
-- @treturn[2] nil If it isn't a partner.
-- @treturn[2] string Why not.
function Manager:partner(network, home)
    expect(1, network, "string")
    expect(2, home, "boolean")
    return self:request({ op = "partner", network = network, home = home })
end

--- Stop carrying another network's phones.
--
-- @tparam string network The other network's name.
-- @treturn[1] table If it was stopped.
-- @treturn[2] nil If it wasn't.
-- @treturn[2] string Why not.
function Manager:uncarry(network)
    expect(1, network, "string")
    return self:request({ op = "uncarry", network = network })
end

--- Set this network's number prefix. Other networks' phones send messages to this network's at the prefix followed by
-- their number (`5550042`), once the networks exchange messages (see `Manager:peer`).
--
-- @tparam string prefix The prefix: 1 to 8 digits.
-- @treturn[1] table The new `prefix`.
-- @treturn[2] nil If it couldn't be set.
-- @treturn[2] string Why not.
function Manager:numbers(prefix)
    expect(1, prefix, "string")
    return self:request({ op = "numbers", prefix = prefix })
end

--- Exchange messages with another network's phones, by connecting to that network's core, which must allow it. This
-- is apart from roaming. Both networks need a number prefix.
--
-- @tparam string network The other network's name.
-- @tparam string core Its core's name or address.
-- @treturn[1] table The `id` and `fingerprint` of this core's computer, for the other core's administrator.
-- @treturn[2] nil If it couldn't be set up.
-- @treturn[2] string Why not.
function Manager:peer(network, core)
    expect(1, network, "string")
    expect(2, core, "string")
    return self:request({ op = "peer", network = network, core = core })
end

--- Stop connecting to another network's core to exchange messages. (Its core ends it by refusing this one's.)
--
-- @tparam string network The other network's name.
-- @treturn[1] table If it was stopped.
-- @treturn[2] nil If it wasn't.
-- @treturn[2] string Why not.
function Manager:unpeer(network)
    expect(1, network, "string")
    return self:request({ op = "unpeer", network = network })
end

--- Stop the core. It can only be started again on its own computer. This closes the manager.
--
-- @treturn[1] true If it's stopping.
-- @treturn[2] nil If it isn't.
-- @treturn[2] string Why not.
function Manager:stop()
    local reply, err = self:request({ op = "stop" })
    if not reply then return nil, err end
    self:close()
    return true
end

--- Start the core afresh, as if its computer had restarted: cells and phones lose it for a moment, and phones get
-- new addresses. This closes the manager.
--
-- @treturn[1] true If it's starting again.
-- @treturn[2] nil If it isn't.
-- @treturn[2] string Why not.
function Manager:restart()
    local reply, err = self:request({ op = "restart" })
    if not reply then return nil, err end
    self:close()
    return true
end

--- Hang up. Do this once done, so the core isn't left waiting.
function Manager:close()
    if self.closed then return end
    self.closed = true
    self.connection:close()
end

--[[- Cellular networks: pocket computers as phones, which keep their address and connections while moving between cells.

A phone needs a SIM, activated on a network with a code from its administrator (`cell activate`, or
`net.cell.activate`). Then it finds the strongest cell of its network, attaches, and gets an address, with a default route through the cell.
It moves between cells by itself. Phones can send each other messages by number, which the network keeps until the phone
they're for is reachable.

Cells run `celld`, and the network's core runs `cellcore`. Both run in the stack's background process, so the computer
can be used for other things, and start again when it does.

The stack queues `cell_state` (with the phone's state) when it attaches or loses service, `cell_message` (with the
sender's number and the text) when a message arrives, `cell_sent` (with a message's ID, whether the network took it,
and why not) for each message sent, and `cell_messages` whenever the messages it keeps change in another way: one was
read or deleted, say.
]]
cell = {
    --[[- Get the phone's state.

    @treturn table `state` (`"none"` with no SIM, `"off"` when cell service is turned off, `"inactive"`, `"activating"`,
    `"searching"`, `"attaching"`, `"attached"` or `"rejected"`); `network`, the SIM's own; `subscriber` (`id` and
    `number`, and `full`, the number other networks' phones reach it at, once it has attached, if its network has a
    number prefix); `cell`, the cell it's using; `address`; `cells`, the cells it may use which it hears, strongest first, each
    with `id` and `signal`; `networks`, the names of the networks around; why it was rejected or activation failed
    (`rejected`, `activation_error`);

     - `enabled`: whether cell service is turned on (see `net.cell.setEnabled`);
     - `signal` and `serving_network`: the signal strength (dBm) and network of the cell it's using, when attached;
     - `roaming`: whether that's another network than the SIM's own (and not one it treats as its own);
     - `partners` and `equivalent`: the networks the SIM's own has agreements with, as sets of names, and those of them
       the phone treats as its own network (it isn't roaming there);
     - `selection`: `"auto"`, or the only network it has been told to use (see `net.cell.setNetwork`);
     - `newer`: whether it heard a cell (or core) lately which speaks a newer version of the network than it does,
       which may be why a phone which is searching finds no cell it can use;
     - `unread`: how many messages haven't been read;

     - `heard`: every cell it has heard in the last 30 seconds, of any network, the ones heard in the last few seconds
       first, then strongest first. Each has `id`, `network`, `signal` (dBm), `area`, `load` (0 to 1), `age` (seconds
       since it was last heard), `serving` (whether the phone uses it), and `verified`: for cells of the phone's own
       network, whether their system information came from the operator (`false` may mean a fake cell), or `nil` for
       other networks;
     - `events`: the last 20 things which happened, oldest first. Each has `kind` and `time` (as `os.epoch("utc")`
       gives it): `"activated"` (with `network`), `"activation_failed"` (`reason`), `"attached"` (`cell`),
       `"handover"` (`from` and `to`), `"lost"` (`cell`) or `"rejected"` (`reason`).

    A computer without a SIM only hears cells once it listens, with `net.cell.listen` (or tries to activate).
    ]]
    info = function()
        load()
        local sim = read_cached(SIM_FILE, SIM_FILE, function() return read_table(SIM_FILE) end)
        local chosen = read_cached(PHONE_FILE, PHONE_FILE, function() return read_table(PHONE_FILE) end)
        local off = chosen.off == true and type(sim.network) == "string"
        local info
        if phone_instance then
            info = phone_instance:info()
            info.address = info.address and address.format(info.address)
        else
            info = { state = "none", network = sim.network }
        end
        if off then info.state = "off" end
        if not info.partners then
            info.partners, info.equivalent = {}, {}
            for network in pairs(type(sim.roaming) == "table" and sim.roaming or {}) do info.partners[network] = true end
            for network in pairs(type(sim.equivalent) == "table" and sim.equivalent or {}) do
                if info.partners[network] then info.equivalent[network] = true end
            end
        end
        if not info.subscriber and sim.id then info.subscriber = { id = sim.id, number = sim.number } end
        info.enabled = not off
        info.selection = type(chosen.network) == "string" and chosen.network or "auto"
        info.roaming = info.roaming == true
        info.newer = info.newer == true
        info.unread = read_cached("unread", INBOX_FILE, function()
            local unread = 0
            for _, message in ipairs(read_messages()) do
                if message.from and message.read == false then unread = unread + 1 end
            end
            return unread
        end)
        for _, cell in ipairs(info.heard or {}) do
            if cell.serving then info.signal, info.serving_network = cell.signal, cell.network end
        end
        return info
    end,

    --[[- Listen for cells, so `net.cell.info` lists them (`heard`) and the networks around, on a computer which isn't
    activated yet. A phone which is activated listens already. This is for the `cell` program's monitor.

    @treturn[1] true If it's listening.
    @treturn[2] nil If it can't.
    @treturn[2] string Why not.
    ]]
    listen = function()
        require_crypto()
        load()
        if phone_instance then return true end
        local phone, err = new_phone(nil)
        if not phone then return nil, err end
        return true
    end,

    --[[- Activate this computer's SIM on a network, with a code from the network's administrator. Activating again, with
    a new code, moves a subscription to this computer.

    @tparam string network The network's name, as `net.cell.info().networks` lists them.
    @tparam string code The activation code, such as `"7Q2M-K4XD-9PRB-T6WN-HJ3C"`.
    @treturn[1] true If activation started. `cell_state` events say how it goes: `"searching"` once it worked.
    @treturn[2] nil If it couldn't start.
    @treturn[2] string Why not.
    ]]
    activate = function(network, code)
        expect(1, network, "string")
        expect(2, code, "string")
        require_crypto()
        load()
        if phone_instance and phone_instance.state ~= "inactive" and phone_instance.state ~= "rejected" then
            phone_instance:stop()
            phone_instance = nil
        end
        -- Activating turns cell service on.
        local chosen = read_table(PHONE_FILE)
        if chosen.off then
            chosen.off = nil
            write_table(PHONE_FILE, chosen)
        end
        if not phone_instance then
            local ok, err = new_phone(nil)
            if not ok then return nil, err end
        end
        return phone_instance:activate(network, code)
    end,

    --[[- Send a message to another phone by its number. A phone of another network which exchanges messages with this
    one has a number such as `6660042`: that network's number prefix, followed by its number there. If that network's
    core can't be reached, the network keeps the message, says it has it, and sends it on once it can (and if it isn't
    delivered after all, a message from the network says so). A number with no prefix the network knows isn't
    reachable.

    The phone sends it until the network says it has it, so a lost radio frame doesn't lose the message. A `cell_sent`
    event says how that went: the message's ID and `true`, or `false` and why not (nobody has that number, say). The
    network then keeps it until the phone it's for is reachable.

    @tparam string number The number.
    @tparam string text The message, up to 1000 characters.
    @treturn[1] true If it's being sent. It's listed by `net.cell.messages`, with how it's getting on.
    @treturn[1] number The message's ID, which the `cell_sent` event has.
    @treturn[2] nil If it couldn't be sent.
    @treturn[2] string Why not.
    ]]
    send = function(number, text)
        expect(1, number, "string")
        expect(2, text, "string")
        load()
        if not phone_instance then return nil, read_table(PHONE_FILE).off and "Cell service is turned off" or "No SIM" end
        local ok, id = phone_instance:send_message(number, text)
        if not ok then return nil, id end
        add_message({ to = number, text = text, time = os.epoch("utc"), id = id, status = "sending" })
        os.queueEvent("cell_messages")
        return true, id
    end,

    --[[- Get the messages this phone has received and sent, oldest first (the last 100).

    @treturn { { n = number, from? = string, to? = string, text = string, time = number, read? = boolean,
    status? = string, error? = string }... } The messages. Each has `n`, a number which stays the same as other messages
    come and go; `text`; and `time` (as `os.epoch("utc")` gives it). Received messages have `from`, the sender's number,
    and `read`. Sent messages have `to`, and `status`: `"sending"`, `"sent"` (the network has it) or `"failed"`, with
    `error` saying why.
    ]]
    messages = function()
        local waiting = {}
        for _, message in ipairs(phone_instance and phone_instance.outbox or {}) do waiting[message.id] = true end
        local list = read_messages()
        for _, message in ipairs(list) do
            if message.from then
                message.read = message.read ~= false
            elseif message.status == "sending" and not waiting[message.id] then
                -- The computer restarted (or cell service was turned off) before the network took it.
                message.status, message.error = "failed", "Not sent"
            end
            message.id = nil
        end
        return list
    end,

    --[[- Mark messages as read.

    @tparam[opt] number n The message's number, as `net.cell.messages` gives it. Without one, every message is marked.
    @treturn number How many messages were marked.
    ]]
    markRead = function(n)
        expect(1, n, "number", "nil")
        local count = change_messages(function(message) return message.from and message.read == false and (n == nil or message.n == n) end,
            function(message) message.read = true end)
        if count > 0 then os.queueEvent("cell_messages") end
        return count
    end,

    --[[- Delete a message.

    @tparam number n The message's number, as `net.cell.messages` gives it.
    @treturn boolean Whether there was such a message.
    ]]
    deleteMessage = function(n)
        expect(1, n, "number")
        local found = change_messages(function(message) return message.n == n end, function() return false end) > 0
        if found then os.queueEvent("cell_messages") end
        return found
    end,

    --[[- Turn cell service off or on. While it's off, the phone doesn't listen or send, has no address, and isn't
    started with the computer. The SIM and messages are kept.

    @tparam boolean enabled Whether cell service should be on.
    @treturn[1] true If it's now as asked.
    @treturn[2] nil If it couldn't be turned on.
    @treturn[2] string Why not.
    ]]
    setEnabled = function(enabled)
        expect(1, enabled, "boolean")
        load()
        local chosen = read_table(PHONE_FILE)
        if not enabled then
            chosen.off = true
            write_table(PHONE_FILE, chosen)
            if phone_instance then
                phone_instance:stop()
                phone_instance = nil
            end
            os.queueEvent("cell_state", "off")
            return true
        end

        require_crypto()
        chosen.off = nil
        write_table(PHONE_FILE, chosen)
        -- A phone which was only listening (for the monitor) has no SIM to attach with.
        if phone_instance and not phone_instance.operator then
            phone_instance:stop()
            phone_instance = nil
        end
        if not phone_instance then
            local ok, err = pcall(start_phone)
            if not ok then return nil, tostring(err) end
        end
        if not phone_instance then
            local sim = read_table(SIM_FILE)
            if type(sim.network) ~= "string" then return nil, "No SIM: activate one with 'cell activate'" end
            return nil, "This needs a wireless modem"
        end
        os.queueEvent("cell_state", phone_instance.state)
        return true
    end,

    --[[- List the networks around, and the SIM's own.

    @treturn { { name = string, kind = string, allowed = boolean, signal? = number, serving = boolean,
    selected = boolean, equivalent? = boolean }... } Each network's `name`; its `kind`: `"home"` (the SIM's own, or one
    the phone treats as its own, which is `equivalent`), `"partner"` (one the SIM's network has a roaming agreement
    with) or `"other"`; whether the phone knows it's `allowed` to use it (its own
    network or a partner: it can still be told to use another, which it tries); the `signal` of its
    strongest cell in range (dBm), or `nil` if none is; whether the phone is using it now (`serving`); and whether it's
    the network the phone has been told to use (`selected`). The SIM's own network comes first, then those it treats as
    its own, then partners, then the rest, strongest first.
    ]]
    networks = function()
        local info = cell.info()
        local found, list = {}, {}
        local function entry(name)
            if not found[name] then
                found[name] = { name = name, kind = "other", allowed = false, serving = false, selected = info.selection == name }
                list[#list + 1] = found[name]
            end
            return found[name]
        end
        if info.network then
            local home = entry(info.network)
            home.kind, home.allowed = "home", true
        end
        for name in pairs(info.partners or {}) do
            local partner = entry(name)
            partner.kind, partner.allowed = "partner", true
            if (info.equivalent or {})[name] then partner.kind, partner.equivalent = "home", true end
        end
        if info.selection ~= "auto" then entry(info.selection) end
        for _, heard in ipairs(info.heard or {}) do
            -- Cells which have gone quiet don't count, nor do ones which only claim to be a network's.
            if heard.fresh and heard.verified ~= false then
                local network = entry(heard.network)
                if not network.signal or heard.signal > network.signal then network.signal = heard.signal end
                if heard.serving then network.serving = true end
            end
        end
        local order = { home = 1, partner = 3, other = 4 }
        local function rank(network) return network.equivalent and 2 or order[network.kind] end
        table.sort(list, function(a, b)
            if rank(a) ~= rank(b) then return rank(a) < rank(b) end
            if (a.signal or -math.huge) ~= (b.signal or -math.huge) then return (a.signal or -math.huge) > (b.signal or -math.huge) end
            return a.name < b.name
        end)
        return list
    end,

    --[[- Choose the network to use, or let the phone choose.

    Left to itself, the phone uses its SIM's own network when it can hear it (or one it treats as its own), and
    otherwise a partner's: it stays on its own network until it loses it, and goes back once its own network is stronger
    than the one it roams on. Where
    it hears neither, it tries other networks too, which may have an agreement with its own it hasn't heard of yet.
    Told to use one network, it uses no other, and has no service where that network has no cells. That may be any
    network: one the phone doesn't know has an agreement with its own, it tries anyway (and keeps trying, if turned
    away), and learns that it's a partner if it is.

    @tparam[opt] string name The network's name, or `nil` (or `"auto"`) to let the phone choose.
    @treturn[1] true If the choice was made.
    @treturn[2] nil If it couldn't be.
    @treturn[2] string Why not.
    ]]
    setNetwork = function(name)
        expect(1, name, "string", "nil")
        load()
        if name == "auto" then name = nil end
        if name and (#name > 32 or not name:find("^[%w%-]+$")) then
            return nil, "Network names are letters, digits and dashes, up to 32 of them"
        end
        local chosen = read_table(PHONE_FILE)
        chosen.network = name
        write_table(PHONE_FILE, chosen)
        if phone_instance and phone_instance.select then phone_instance:select(name) end
        os.queueEvent("cell_state", cell.info().state)
        return true
    end,

    --[[- Run a cell of a cellular network on this computer, in the background, from now on (also when the computer
    starts). It connects to the network's core, and if the core hasn't allowed this computer yet, waits until it does.
    This is for the `celld` program.

    A cell may serve several networks, which share it: give it each network's core. It connects to each, and serves
    each network while its core is there, naming each in its system information. Phones of each choose it as a cell of
    their network (or of one they roam on), and it takes them to that network's core.

    @tparam string|{ string... } core The core's name or address, or those of several networks' cores.
    @tparam[opt] number area The cell's tracking area.
    @treturn[1] true If it started.
    @treturn[2] nil If it couldn't.
    @treturn[2] string Why not.
    ]]
    startCell = function(core, area)
        expect(1, core, "string", "table")
        expect(2, area, "number", "nil")
        local cores = {}
        if type(core) == "string" then
            cores[1] = core
        else
            for i, name in ipairs(core) do
                if type(name) ~= "string" then error(("bad argument #1 (core %d is a %s, not a string)"):format(i, type(name)), 2) end
                cores[i] = name
            end
            if not cores[1] then error("bad argument #1 (expected at least one core)", 2) end
        end
        require_crypto()
        local config = { cores = cores, area = area or 0 }
        local old = read_table(CELL_CONFIG)
        -- Start again with new settings, or to try again at once after losing a core.
        if background.cell then
            local again = table.concat(cell_cores(old) or {}, " ") ~= table.concat(cores, " ") or (old.area or 0) ~= config.area
            for _, link in ipairs(background.cell:info().links) do
                if link.state ~= "serving" then again = true end
            end
            if again then
                background.cell:stop()
                background.cell = nil
            end
        end
        write_table(CELL_CONFIG, config)
        return start_cell_service(config)
    end,

    --- Stop this computer's cell, and don't start it when the computer starts.
    stopCell = function()
        local config = read_table(CELL_CONFIG)
        if cell_cores(config) then
            config.enabled = false
            write_table(CELL_CONFIG, config)
        end
        if background.cell then
            background.cell:stop()
            background.cell = nil
        end
    end,

    --[[- Get the state of this computer's cell.

    @treturn table Its `state`: `"stopped"`, `"connecting"`, `"waiting"` (for the core to allow it), `"serving"`,
    `"lost"` (it couldn't reach the core, or lost it, and tries again in `retry` seconds) or `"refused"`; `error`, saying
    why; the `core`; the `network` it serves; its `area`; its `id` and `fingerprint`, which the core's administrator
    checks before allowing it; and, while it runs, `links`: the same (`core`, `state`, `error`, `retry` and `network`)
    for each core, for a cell which serves several networks. Then the cell's own state is the best of its cores'.
    ]]
    cellInfo = function()
        if background.cell then return background.cell:info() end
        local config = read_table(CELL_CONFIG)
        local cores = cell_cores(config)
        return {
            state = "stopped", core = cores and cores[1], cores = cores, area = config.area, id = os.getComputerID(),
            fingerprint = crypto and enclave and fingerprint(getIdentity()) or nil,
        }
    end,

    --[[- Run this computer's cellular core, in the background, from now on (also when the computer starts). Set it up
    first, with `cellcore setup`. The `cellcore` program manages it while it runs, over the control port. This is for
    the `cellcore` program.

    The operator's keys live in the enclave: `cell.operator` (X25519), `cell.signing` (Ed25519) and `cell.secret`. This
    computer forwards packets, as phones' packets go through it.

    @treturn[1] true If it started, or was running already.
    @treturn[2] nil If it couldn't start.
    @treturn[2] string Why not.
    ]]
    startCore = function()
        require_crypto()
        local config = read_table(CORE_CONFIG)
        if config.enabled == false then
            config.enabled = nil
            write_table(CORE_CONFIG, config)
        end
        return start_core_service()
    end,

    --[[- Manage a cellular network's core: this computer's, or (over the network) another's.

    The core must know the computer managing it. Its own computer always may. Any other waits the first time, until
    someone allows its key on the core (`cellcore allow <ID>`, after checking the fingerprint is this computer's), and
    is let straight in from then on. The connection is a secure one (see [`net.secure`]), to port 2123.

    @tparam[opt] string core The core's name or address. Without one, this computer's own core.
    @tparam[opt] function(fingerprint:string):boolean|nil waiting Called if the core hasn't allowed this computer yet,
    with this computer's fingerprint, to show whoever can allow it. Unless it returns `false`, this function then waits
    until the core allows this computer, refuses it, or gives up (after ten minutes). Without it, there's no waiting.
    @treturn[1] table The manager, with a method for each thing a core can be asked (`status`, `log`, `add`, `remove`,
    `set`, `allow`, `deny`, `carry`, `uncarry`, `stop`, `restart`), `request` for anything else, and `close`. Its
    `network` field is the network's name.
    @treturn[2] nil If the core can't be managed from here.
    @treturn[2] string Why not.
    @treturn[2] string|nil This computer's fingerprint, if it's because the core hasn't allowed it.
    @usage List a network's subscribers from another computer.

    ```lua
    local core = assert(net.cell.manage("10.64.0.1"))
    for _, subscriber in ipairs(assert(core:status()).subscribers) do print(subscriber.id, subscriber.number) end
    core:close()
    ```
    ]]
    manage = function(core, waiting)
        expect(1, core, "string", "nil")
        expect(2, waiting, "function", "nil")
        require_crypto()
        local connection, err = secure.connect(core or "127.0.0.1", CONTROL_PORT)
        if not connection then return nil, err end
        connection:send({ role = "admin", id = os.getComputerID() })
        local reply, receive_err = connection:receive(15)
        if type(reply) == "table" and reply.waiting then
            local shown = tostring(reply.fingerprint)
            if not waiting or waiting(shown) == false then
                connection:close()
                return nil, "The core hasn't allowed this computer to manage it", shown
            end
            reply, receive_err = connection:receive()
        end
        if type(reply) ~= "table" then
            connection:close()
            return nil, "The core didn't answer: " .. tostring(receive_err or "it hung up")
        end
        if reply.error ~= nil then
            connection:close()
            return nil, tostring(reply.error)
        end
        return setmetatable({ connection = connection, network = reply.network }, Manager)
    end,

    --- Stop this computer's cellular core, and don't start it when the computer starts.
    stopCore = function()
        local config = read_table(CORE_CONFIG)
        if type(config.network) == "string" then
            config.enabled = false
            write_table(CORE_CONFIG, config)
        end
        if background.core then
            background.core:stop()
            background.core = nil
        end
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
    local kind = getmetatable(connection)
    if kind ~= Connection and kind ~= SecureConnection then error("bad argument #1 (expected a connection)", 2) end
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
