-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A network stack: network addresses, neighbour discovery and ping, over any modem.

Every modem becomes a network *interface*. Each interface can have an address, such as `10.0.0.1/24`, and computers on
the same network can then reach each other by address. The stack runs in the background on every computer, much like
[`rednet`].

Wired and ender modems are one interface each. A wireless modem is one interface on the short-range high band by default
(channels 1024 and up). Set `net.<name>.band` to `"low"` to use the long-range low band instead (channels below 1024).
An interface on the other band of the same modem can be added by giving `<name>:low` (or `<name>:high`) an address.

Addresses are set with the `ifconfig` program, or with [`net.setAddress`]. `ifconfig` saves them in the settings
`net.<interface>.address`, so they are restored when the computer starts.

> [!WARNING]
> The network stack doesn't encrypt or authenticate anything yet. Anyone can listen to, or pretend to be, any computer.

@module net
@usage Give this computer an address on the network its top modem is on, then ping another computer.

```lua
net.setAddress("top", "10.0.0.1/24")
print(net.ping("10.0.0.2"))
```
]]

local expect = dofile("rom/modules/main/cc/expect.lua").expect

local DEFAULT_PREFIX = 24
local CHANNEL_CHECK_INTERVAL = 5
local MAX_ERRORS = 16

local stack, address, running
local add_modem
local errors = {}

-- Remember an error, rather than printing it over whatever the user is doing.
local function log_error(err)
    if #errors >= MAX_ERRORS then table.remove(errors, 1) end
    errors[#errors + 1] = tostring(err)
end

local function load()
    if stack then return stack end

    -- APIs can't use require, so make our own, much as the shell does for programs.
    local env = setmetatable({}, { __index = _ENV })
    env.require, env.package = dofile("rom/modules/main/cc/require.lua").make(env, "/")
    address = env.require("cc.net.address")

    settings.define("net.enabled", {
        description = "Run the network stack.",
        default = true,
        type = "boolean",
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
    }

    for _, name in ipairs(peripheral.getNames()) do add_modem(name) end
    return stack
end

local function open_channels(interface)
    peripheral.call(interface.modem, "open", interface.unicast)
    peripheral.call(interface.modem, "open", interface.broadcast)
end

local function configure(interface)
    local configured = settings.get("net." .. interface.name .. ".address")
    if type(configured) ~= "string" then return end

    local addr, prefix = address.parse(configured)
    if addr then stack:set_address(interface.name, addr, prefix or DEFAULT_PREFIX) end
end

local function add_interface(name, modem, kind, band)
    local interface = stack:add_interface(name, modem, kind, band)
    open_channels(interface)
    configure(interface)
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
    for _, interface in ipairs(stack:remove_modem(name)) do os.queueEvent("net_interface", interface, "down") end
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
    local channel_check = os.startTimer(CHANNEL_CHECK_INTERVAL)

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
                channel_check = os.startTimer(CHANNEL_CHECK_INTERVAL)
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
    name = string, kind = string, band = string, address? = string, prefix? = number,
    duplicate = boolean, id = number, unicast = number, broadcast = number, neighbours = number,
    frames_in = number, frames_out = number, dropped = number
}... } Each interface:

 - `name`: The interface's name, which is usually the modem's peripheral name.
 - `kind`: `"wired"`, `"wireless"` or `"ender"`.
 - `band`: `"high"` or `"low"`. Only meaningful for wireless modems.
 - `address`, `prefix`: The interface's address and prefix length, if it has one.
 - `duplicate`: Whether another computer is using the same address. The interface isn't used if so.
 - `id`: This computer's ID, which is its address on the link.
 - `unicast`, `broadcast`: The channels the interface listens on.
 - `neighbours`: How many computers it has talked to directly.
 - `frames_in`, `frames_out`, `dropped`: Statistics.
]]
function interfaces()
    return load():interface_info()
end

--[[- Set or remove an interface's address. This lasts until the computer restarts: use `ifconfig` to keep it.

@tparam string interface The interface's name.
@tparam string|nil addr The address and prefix length, such as `"10.0.0.1/24"`, or `nil` to remove it. Without a prefix
length, `/24` is assumed.
@throws If there is no such interface, or the address is invalid.
]]
function setAddress(interface, addr)
    expect(1, interface, "string")
    expect(2, addr, "string", "nil")
    local s = load()
    if not s.interfaces[interface] then error("No interface named '" .. interface .. "'", 2) end

    if addr == nil then
        s:set_address(interface, nil)
        return
    end

    local parsed, prefix = address.parse(addr)
    if not parsed then error(prefix, 2) end
    s:set_address(interface, parsed, prefix or DEFAULT_PREFIX)
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

--[[- Get the computers this one has talked to directly.

@treturn { { interface = string, address = string, id = number, expires = number, signal? = number }... } Each
neighbour's interface, address, computer ID, how many seconds until it's forgotten, and the signal strength of the last
radio message from it.
]]
function neighbours()
    return load():neighbour_info()
end

--[[- Send an echo request to another computer and wait for its reply.

@tparam string addr The computer's address. A broadcast address gets the first reply from anyone.
@tparam[opt=2] number timeout How long to wait, in seconds.
@treturn[1] number The round trip time, in seconds.
@treturn[1] number The reply's remaining time to live.
@treturn[1] string The address the reply came from.
@treturn[2] nil If there was no reply.
@treturn[2] string Why not, such as `"Timed out"` or `"Host unreachable"`.
@usage Check another computer can be reached.

```lua
local time, err = net.ping("10.0.0.2")
if time then print(("Reply in %d ms"):format(time * 1000)) else print(err) end
```
]]
function ping(addr, timeout)
    expect(1, addr, "string")
    expect(2, timeout, "number", "nil")
    local s = load()

    local dst, err = address.parse(addr)
    if not dst then return nil, err end

    local id
    id, err = s:echo(dst)
    if not id then return nil, err end

    local timer = os.startTimer(timeout or 2)
    while true do
        local event, arg = os.pullEvent()
        if event == "net_echo" and arg == id then
            os.cancelTimer(timer)
            local result = s:echo_result(id)
            s:forget_echo(id)
            if result.error then return nil, result.error end
            return result.rtt, result.ttl, address.format(result.from)
        elseif event == "timer" and arg == timer then
            s:forget_echo(id)
            return nil, "Timed out"
        end
    end
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
