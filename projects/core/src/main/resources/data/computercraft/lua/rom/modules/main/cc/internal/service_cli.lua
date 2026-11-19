-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What the programs which start and stop services share: the `service` program, and the servers which run as
services (`dnsd`, `dhcpd` and `rshd`). Each says what it did, and fails (with an error, as programs do) if it couldn't.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local command_line = require "cc.internal.services".command_line

local STATE_COLOURS = {
    running = colours.green, stopping = colours.yellow, stopped = colours.lightGrey, exited = colours.red,
}

--[[- Write text in a colour, on a screen which has colours.

@tparam string text The text.
@tparam number colour The colour.
]]
local function coloured(text, colour)
    local old = term.getTextColour()
    if term.isColour() then term.setTextColour(colour) end
    write(text)
    term.setTextColour(old)
end

-- How long ago a time was, roughly: "5s", "3m", "2h", "4d".
local function ago(epoch)
    local seconds = math.max(0, math.floor((os.epoch("utc") - epoch) / 1000))
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 86400) .. "d"
end

--[[- Say what a service is doing, in a line: "running for 5m, and starts with the computer".

@tparam table info What [`service.status`] says of it.
@treturn string What it's doing.
]]
local function describe(info)
    local text = info.state
    if info.detail then text = ("%s (%s)"):format(text, info.detail) end
    if info.state == "running" and info.started then
        text = text .. " for " .. ago(info.started)
    elseif (info.state == "exited" or info.state == "stopped") and info.ended then
        text = text .. " " .. ago(info.ended) .. " ago"
    end
    return text .. (info.enabled and ", and starts with the computer" or ", and doesn't start with the computer")
end

--[[- Print what a service is doing, and its log.

@tparam table info What [`service.status`] says of it.
]]
local function show(info)
    coloured(info.name .. ": ", colours.white)
    coloured(describe(info), STATE_COLOURS[info.state] or colours.white)
    print()
    if info.command then print("Runs " .. info.command) end
    if info.description then print(info.description) end
    if info.log and info.log[1] then
        coloured("Log:\n", colours.lightGrey)
        for _, line in ipairs(info.log) do print(line) end
    end
end

-- What a service printed as it started (to say why, if it stopped at once), and then what's become of it.
local function started(name, how_to_stop)
    local info = service.status(name)
    if info and info.log then
        for _, line in ipairs(info.log) do print(line) end
    end
    if info and info.state ~= "running" then
        error(("%s stopped as soon as it started."):format(name), 0)
    end
    print(("%s runs in the background, and starts with the computer. %s stops it."):format(name, how_to_stop))
end

--[[- Add a service (or change its command), start it, and say what it printed as it started.

@tparam string name The service.
@tparam { string... } command The program's path, from the root, and its arguments.
@tparam string how_to_stop The command which stops it, to say so.
]]
local function add(name, command, how_to_stop)
    local before = service.status(name)
    if before and before.state == "running" and before.command == command_line(command) then
        print(("%s is running already."):format(name))
        return
    end
    local ok, err = service.add(name, table.unpack(command))
    if not ok then error(err, 0) end
    started(name, how_to_stop)
end

--[[- Start a service afresh, running a command (which it's changed to, if it ran another), and say what it printed as
it started.

@tparam string name The service.
@tparam { string... } command The program's path, from the root, and its arguments.
@tparam string how_to_stop The command which stops it, to say so.
]]
local function restart(name, command, how_to_stop)
    local before = service.status(name)
    if not before or before.command ~= command_line(command) then
        local ok, err = service.add(name, table.unpack(command))
        if not ok then error(err, 0) end
    else
        local ok, err = service.restart(name)
        if not ok then error(err, 0) end
    end
    started(name, how_to_stop)
end

--[[- Start a service, and say what it printed as it started.

@tparam string name The service.
@tparam string how_to_stop The command which stops it, to say so.
@tparam[opt] string missing What to say if there's no such service.
]]
local function start(name, how_to_stop, missing)
    local before = service.status(name)
    if not before then error(missing or ("There's no service called %s."):format(name), 0) end
    if before.state == "running" then
        print(("%s is running already."):format(name))
        return
    end
    local ok, err = service.start(name)
    if not ok then error(err, 0) end
    if before.builtin then
        print(("Started %s."):format(name))
    else
        started(name, how_to_stop)
    end
end

--[[- Stop a service.

@tparam string name The service.
@tparam[opt] string missing What to say if there's no such service.
]]
local function stop(name, missing)
    local before = service.status(name)
    if not before then error(missing or ("There's no service called %s."):format(name), 0) end
    local ok, err = service.stop(name)
    if not ok then error(err, 0) end
    if before.state == "running" or before.state == "stopping" then
        print(("Stopped %s. It doesn't start with the computer now."):format(name))
    else
        print(("%s wasn't running. It doesn't start with the computer now."):format(name))
    end
end

--[[- Say what a service is doing, and show its log.

@tparam string name The service.
@tparam[opt] string missing What to say if there's no such service.
]]
local function status(name, missing)
    local info = service.status(name)
    if not info then error(missing or ("There's no service called %s."):format(name), 0) end
    show(info)
end

--[[- The colour a service's state is shown in.

@tparam string state The state.
@treturn number Its colour.
]]
local function state_colour(state)
    return STATE_COLOURS[state] or colours.white
end

return {
    describe = describe, show = show, add = add, restart = restart, start = start, stop = stop, status = status,
    coloured = coloured, state_colour = state_colour,
}
