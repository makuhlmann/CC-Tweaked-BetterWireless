-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Services: programs which run in the background, and start with the computer, so the shell stays free.

A service is a program and its arguments, run from the root directory as the shell would run it. It runs alongside
whatever the user is doing, and keeps running until it's stopped. It has no screen: what it prints goes to its log,
which keeps the last 100 lines. Nor does it get the computer's own keyboard and mouse, or Ctrl+T. Starting a service
has it start with the computer from now on; stopping it, not.

To stop a service, it gets a `terminate` event, as Ctrl+T would send, so a program which closes what it has open on
Ctrl+T (as most do, by catching the `"Terminated"` error) finishes properly. One which hasn't finished three seconds
later is stopped anyway.

The network's servers (`dnsd`, `dhcpd` and `rshd`) run as services: `dnsd start home`, say, adds and starts one. A
cellular network's cell (`celld`), core (`cellcore`) and phone (`phone`) run in the network stack's background process,
but are listed, started and stopped here too, once they're set up on this computer.

The `service` program lists the services, starts and stops them, shows their logs, and adds programs of your own.

Each change to a service queues a `service` event, with the service's name and its new state (`"running"`,
`"stopping"`, `"stopped"`, `"exited"` or `"removed"`).

@module service
@usage Run a program of your own in the background, from now on.

```lua
assert(service.add("beacon", "/beacon.lua", "--loud"))
```
]]

local expect = dofile("rom/modules/main/cc/expect.lua").expect

--- The file services are kept in.
local FILE = "/.services"

--- How long to wait for the background process to start or stop a service, in seconds.
local WAIT_TIMEOUT = 10

--- How many of the service manager's own errors to keep.
local MAX_ERRORS = 16

local manager, running
local errors = {}

-- Remember an error, rather than printing it over whatever the user is doing.
local function log_error(err)
    if #errors >= MAX_ERRORS then table.remove(errors, 1) end
    errors[#errors + 1] = tostring(err)
end

-- Services which run elsewhere: a cellular network's cell, core and phone, in the network stack's background process.
local function cellular_services()
    local function cell() return assert(net and net.cell, "There's no network stack") end
    return {
        {
            name = "celld", description = "This computer's cell", hint = "celld status",
            info = function()
                local info = cell().cellInfo()
                if not info.cores then return nil end
                return { running = info.state ~= "stopped", enabled = info.enabled, detail = info.state }
            end,
            start = function() return cell().startCell() end,
            stop = function()
                cell().stopCell()
                return true
            end,
        },
        {
            name = "cellcore", description = "This computer's cellular core", hint = "cellcore log",
            info = function()
                local info = cell().coreInfo()
                if not info then return nil end
                return { running = info.running, enabled = info.enabled, detail = info.network }
            end,
            start = function() return cell().startCore() end,
            stop = function()
                cell().stopCore()
                return true
            end,
        },
        {
            name = "phone", description = "Cell service, as a phone", hint = "cell",
            info = function()
                local info = cell().info()
                if not info.enabled and info.state ~= "off" then return nil end
                return {
                    running = info.state ~= "none" and info.state ~= "off", enabled = info.enabled, detail = info.state,
                }
            end,
            start = function() return cell().setEnabled(true) end,
            stop = function() return cell().setEnabled(false) end,
        },
    }
end

local function load()
    if manager then return manager end
    -- APIs can't use require, so make our own, much as the shell does for programs.
    local env = setmetatable({}, { __index = _ENV })
    env.require = dofile("rom/modules/main/cc/require.lua").make(env, "/")
    manager = env.require("cc.internal.services").new { file = FILE, builtins = cellular_services() }
    return manager
end

-- Wait until the background process has done what was asked of a service, or given up waiting.
local function await(name)
    local m = load()
    if m:settled(name) then return true end
    local timer = os.startTimer(WAIT_TIMEOUT)
    while not m:settled(name) do
        local event, id = os.pullEvent()
        if event == "timer" and id == timer then return false end
    end
    os.cancelTimer(timer)
    return true
end

-- Ask for something, and wait for it: true if it's done, or nil and why not.
local function ask(name, ok, err)
    if not ok then return nil, err end
    if not await(name) then return nil, "The service manager isn't running" end
    return true
end

--- Run the services. This is started when the computer starts, and never returns, so there's no need to call it
-- yourself.
function run()
    if running then error("service is already running", 2) end
    running = true

    -- If this function ever returned or errored, the shell would stop and the computer shut down.
    local ok, m = pcall(load)
    if not ok then
        log_error(m)
        while true do os.pullEventRaw() end
    end
    while true do
        local event = table.pack(os.pullEventRaw())
        local resumed, err = pcall(m.resume, m, table.unpack(event, 1, event.n))
        if not resumed then log_error(err) end
    end
end

--[[- Get the errors the service manager itself has had (not those of the services, which are in their logs), oldest
first. The `service` program shows them, if there are any.

@treturn { string... } The last 16 errors.
]]
function getErrors()
    local result = {}
    for i, err in ipairs(errors) do result[i] = err end
    return result
end

--[[- Start the services which start with the computer. The shell does this as the computer starts, so there's no need
to call it yourself: only the first call counts.

@tparam table shell The shell, which each service's own shell takes its path, aliases and completion from.
]]
function boot(shell)
    expect(1, shell, "table")
    load():boot(shell)
end

--[[- List the services.

@treturn { {
    name = string, state = string, enabled = boolean, command? = string, description? = string, detail? = string,
    started? = number, ended? = number
}... } Each service, by name:

 - `name`: The service's name.
 - `state`: `"running"`, `"stopping"`, `"stopped"` (by being told to), or `"exited"` (by itself).
 - `enabled`: Whether it starts with the computer.
 - `command`: The program it runs, and its arguments, as one line.
 - `description`, `detail`: For services which run elsewhere (`celld`, `cellcore` and `phone`), what it is, and what
   it's doing.
 - `started`, `ended`: When it last started and ended, in milliseconds (as `os.epoch("utc")`).
]]
function list()
    return load():list()
end

--[[- Say what a service is doing.

@tparam string name The service.
@treturn table|nil What [`service.list`] says of it, with `log`: the lines it's printed since it last started (not for
services which run elsewhere). Nil if there's no such service.
]]
function status(name)
    expect(1, name, "string")
    return load():status(name)
end

--[[- Add a service, which runs a program, and start it. It starts with the computer from now on. If there's already a
service of that name, it runs the new command instead, and starts again if the command changed.

@tparam string name The service's name: up to 32 letters, digits, `_`, `-` and `.`.
@tparam string program The program's path (from the root directory, not the current one).
@tparam string ... Its arguments.
@treturn[1] true If it was added, and has started.
@treturn[2] nil If not.
@treturn[2] string Why not.
@see service.status To see whether it's still running, or what it printed if not.
]]
function add(name, program, ...)
    expect(1, name, "string")
    expect(2, program, "string")
    local command = { program, ... }
    for i = 3, select("#", ...) + 2 do expect(i, command[i - 1], "string") end
    return ask(name, load():add(name, command))
end

--[[- Stop a service, and forget it.

@tparam string name The service.
@treturn[1] true Once it's stopped and forgotten.
@treturn[2] nil If not.
@treturn[2] string Why not.
]]
function remove(name)
    expect(1, name, "string")
    return ask(name, load():remove(name))
end

--[[- Start a service, if it isn't running, and have it start with the computer.

@tparam string name The service.
@treturn[1] true Once it's started. It may have exited again since: see [`service.status`].
@treturn[2] nil If it couldn't start.
@treturn[2] string Why not.
]]
function start(name)
    expect(1, name, "string")
    return ask(name, load():start(name))
end

--[[- Stop a service, and have it not start with the computer.

@tparam string name The service.
@treturn[1] true Once it's stopped.
@treturn[2] nil If it couldn't be stopped.
@treturn[2] string Why not.
]]
function stop(name)
    expect(1, name, "string")
    return ask(name, load():stop(name))
end

--[[- Stop a service if it's running, and start it again. It starts with the computer from now on.

@tparam string name The service.
@treturn[1] true Once it's started again.
@treturn[2] nil If it couldn't be.
@treturn[2] string Why not.
]]
function restart(name)
    expect(1, name, "string")
    return ask(name, load():restart(name))
end

--[[- Get the name of the service the code calling this runs in, if it's one.

@treturn string|nil The service's name, or nil if this isn't running as a service.
@usage Only tell the user how to stop a program when they ran it themselves.

```lua
if not service.current() then print("Press Ctrl+T to stop.") end
```
]]
function current()
    return manager and manager.current
end
