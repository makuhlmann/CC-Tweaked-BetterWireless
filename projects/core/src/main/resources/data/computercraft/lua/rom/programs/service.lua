-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- List the services which run in the background, start and stop them, show their logs, and add programs of your own.

local cli = require "cc.internal.service_cli"

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name)
    print(name .. " status <service>")
    print(name .. " start <service>")
    print(name .. " stop <service>")
    print(name .. " restart <service>")
    print(name .. " log <service>")
    print(name .. " add <service> <program> [arguments]")
    print(name .. " remove <service>")
end

local function how_to_stop(service_name) return ('"%s stop %s"'):format(name, service_name) end

-- Each service in a line: its name, state, whether it starts with the computer, and what it runs.
local function list()
    local services = service.list()
    if not services[1] then
        print(("No services. Add a program with \"%s add <service> <program>\"."):format(name))
        return
    end

    local width = term.getSize()
    local name_width = 4
    for _, info in ipairs(services) do name_width = math.max(name_width, #info.name) end
    local state_width, boot_width = 8, 4
    local rest = math.max(4, width - name_width - state_width - boot_width - 3)

    local function line(service_name, state, boot, runs, colour)
        cli.coloured(service_name .. (" "):rep(name_width - #service_name + 1), colours.white)
        cli.coloured(state .. (" "):rep(state_width - #state + 1), colour)
        cli.coloured(boot .. (" "):rep(boot_width - #boot + 1), colours.white)
        if #runs > rest then runs = runs:sub(1, rest - 3) .. "..." end
        print(runs)
    end

    local header = colours.orange
    cli.coloured(("Name"):sub(1, name_width) .. (" "):rep(name_width - 3), header)
    cli.coloured("State" .. (" "):rep(state_width - 4), header)
    cli.coloured("Boot ", header)
    cli.coloured("Runs\n", header)
    for _, info in ipairs(services) do
        line(info.name, info.state, info.enabled and "yes" or "no", info.command or info.description or "",
            cli.state_colour(info.state))
    end
end

local command, service_name = args[1], args[2]
if command == nil or (command == "list" and #args == 1) then
    list()
elseif command == "status" and #args == 2 then
    cli.status(service_name)
elseif command == "start" and #args == 2 then
    cli.start(service_name, how_to_stop(service_name))
elseif command == "stop" and #args == 2 then
    cli.stop(service_name)
elseif command == "restart" and #args == 2 then
    if not service.status(service_name) then error(("There's no service called %s."):format(service_name), 0) end
    local ok, err = service.restart(service_name)
    if not ok then error(err, 0) end
    local info = service.status(service_name)
    if info and info.builtin then
        print(("Restarted %s."):format(service_name))
    else
        for _, text in ipairs(info and info.log or {}) do print(text) end
        if not info or info.state ~= "running" then error(("%s stopped as soon as it started."):format(service_name), 0) end
        print(("Restarted %s."):format(service_name))
    end
elseif command == "log" and #args == 2 then
    local info = service.status(service_name)
    if not info then error(("There's no service called %s."):format(service_name), 0) end
    if not info.log then
        print(("%s keeps no log here: \"%s\" says how it's doing."):format(service_name, info.hint or service_name))
    elseif not info.log[1] then
        print(("%s hasn't printed anything since it started."):format(service_name))
    else
        for _, text in ipairs(info.log) do print(text) end
    end
elseif command == "add" and #args >= 3 then
    local program = shell.resolveProgram(args[3])
    if not program then error(("There's no program called %s."):format(args[3]), 0) end
    local command_words = { "/" .. program }
    for i = 4, #args do command_words[#command_words + 1] = args[i] end
    cli.add(service_name, command_words, how_to_stop(service_name))
elseif command == "remove" and #args == 2 then
    if not service.status(service_name) then error(("There's no service called %s."):format(service_name), 0) end
    local ok, err = service.remove(service_name)
    if not ok then error(err, 0) end
    print(("Stopped and removed %s."):format(service_name))
else
    usage()
end
