-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Run a cell of a cellular network (or of several networks, which share it) in the background, change it one thing at
-- a time, or show how it's doing. Its cores and settings are kept: each command changes one thing, and checks it
-- first, so a mistake changes nothing.

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local bands = require "cc.internal.net.bands"

local function usage()
    print("Usages:")
    print(name .. " [status]")
    print(name .. " add <core>")
    print(name .. " remove <core>")
    print(name .. " set area <number>")
    print(name .. " set band <band>")
    print(name .. " set interval <seconds>")
    print(name .. " set pos <x> <y> <z>")
    print(name .. " set power <dBm>")
    print(name .. " set service sms|full")
    print(name .. " unset <setting>")
    print(name .. " start|stop|restart")
end

if not crypto or not enclave then
    printError("Cells need the crypto and enclave APIs, which are turned off on this server")
    return
end

-- Each setting, with what it takes after its name (for "set"), in the order they're shown.
local SETTINGS = {
    { name = "area", takes = "<number>" },
    { name = "band", takes = "<band>" },
    { name = "interval", takes = "<seconds>" },
    { name = "pos", takes = "<x> <y> <z>", count = 3 },
    { name = "power", takes = "<dBm>" },
    { name = "service", takes = "sms|full" },
}
local SETTING = {}
for _, setting in ipairs(SETTINGS) do SETTING[setting.name] = setting end

local function setting_names()
    local names = {}
    for i, setting in ipairs(SETTINGS) do names[i] = setting.name end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- A band, as a person might write it: "b3", "B3", "3", or its frequency, "1800" or "1800MHz".
local function parse_band(text)
    local wanted = text:lower():gsub("mhz$", "")
    for _, band in ipairs(bands.cellular()) do
        if wanted == band.name or "b" .. wanted == band.name or wanted == band.label then return band.name end
    end
end

local function band_label(band_name)
    local band = bands.get(band_name)
    return band and band.label and ("%s (%sMHz)"):format(band_name, band.label) or band_name
end

-- Say what the cell is doing with one of its cores. `added` is the core just added, which may have been mistyped.
local function show_link(info, link, added)
    if link.state == "connecting" then
        print(("%s: connecting..."):format(link.core))
    elseif link.state == "waiting" then
        print(("%s: waiting to be allowed. On that core, run 'cellcore allow %d', and check it shows this fingerprint:"):format(link.core, info.id))
        print("  " .. tostring(info.fingerprint))
    elseif link.state == "serving" then
        print(("%s: serving %s."):format(link.core, link.network))
    elseif link.state == "refused" then
        printError(("%s refused this cell: %s"):format(link.core, tostring(link.error)))
    elseif link.state == "lost" then
        printError(("%s can't be reached: %s"):format(link.core, tostring(link.error)))
        if link.retry then print(("Trying again in %d seconds."):format(link.retry)) end
        if link.core == added then print(("If that's not the right core, '%s remove %s' stops trying."):format(name, link.core)) end
    end
    if link.newer then
        print(("%s speaks a newer version of the network (%d). If they don't work together, update this cell's ROM."):format(
            link.core, link.newer
        ))
    end
end

-- Show the cell's settings, set or not.
local function show_settings(info)
    local shown = {
        area = tostring(info.area or 0),
        band = info.band and band_label(info.band) or "any (its core picks)",
        interval = info.interval and ("%g seconds"):format(info.interval)
            or info.current_interval and ("as its core says (%g seconds)"):format(info.current_interval)
            or "as its core says",
        pos = info.pos and ("%d %d %d"):format(info.pos[1], info.pos[2], info.pos[3]) or "not said",
        power = info.power and ("%g dBm"):format(info.power) or "the modem's own",
        service = info.service == "sms" and "messages only" or "full",
    }
    print(("Settings ('%s set <setting> <value>'):"):format(name))
    for _, setting in ipairs(SETTINGS) do print(("  %-9s %s"):format(setting.name, shown[setting.name])) end
end

-- Say what the cell is doing, and how it's set up.
local function show(info)
    if not info.cores then
        print(("This computer isn't running a cell. Start one with '%s add <core>'."):format(name))
    elseif info.state == "stopped" then
        if info.enabled == false then
            print(("The cell is stopped. It starts again with '%s start'."):format(name))
        else
            print(("The cell isn't running. '%s start' starts it, or says why it can't."):format(name))
        end
        print("Cores: " .. table.concat(info.cores, ", "))
    else
        print(("Cell #%d, area %d."):format(info.id, info.area or 0))
        if info.carrier then print(("On %s, reached on channel %d."):format(info.carrier, info.ul)) end
        for _, link in ipairs(info.links or {}) do show_link(info, link) end
    end
    show_settings(info)
end

-- Follow the cell's cores (or one core) until each serves, or something goes wrong. The cell runs in the background
-- either way.
local function watch(only)
    local watched, err = pcall(function()
        local shown = {}
        while true do
            local info = net.cell.cellInfo()
            if info.state == "stopped" then return end
            local settled, serving, any = true, true, false
            for _, link in ipairs(info.links or {}) do
                if not only or link.core == only then
                    any = true
                    if link.state ~= shown[link.core] then
                        shown[link.core] = link.state
                        show_link(info, link, only)
                        if link.state == "waiting" then print("Waiting... Press Ctrl+T to stop watching. The cell carries on waiting.") end
                    end
                    if link.state == "connecting" or link.state == "waiting" then settled = false end
                    if link.state ~= "serving" then serving = false end
                end
            end
            if not any then return end
            if settled then
                if serving then
                    print(("It runs in the background, and starts with this computer. '%s' shows how it's doing."):format(name))
                else
                    print(("It keeps trying in the background. '%s' shows how it's doing."):format(name))
                end
                return
            end
            sleep(0.2)
        end
    end)
    if not watched then
        if err ~= "Terminated" then error(err, 0) end
        print("Stopped watching. The cell carries on in the background.")
    end
end

-- A setting's value, from what was typed after its name. `false` means "full" for the service: not only messages.
local function read_value(key, words)
    local text = words[1]
    if key == "band" then
        local band = parse_band(text)
        if not band then
            local names = {}
            for _, each in ipairs(bands.cellular()) do names[#names + 1] = band_label(each.name) end
            error(("There's no cellular band called %s. They're %s."):format(text, table.concat(names, ", ")), 0)
        end
        return band
    elseif key == "service" then
        if text == "sms" then return "sms" end
        if text == "full" then return false end
        error("A cell's service is sms (it only carries messages) or full.", 0)
    elseif key == "pos" then
        local x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3])
        if not x or not y or not z then error("A cell's position is three whole numbers: its computer's x, y and z.", 0) end
        return { x, y, z }
    end
    local number = tonumber(text)
    if not number then error(("Expected a number, not %s."):format(text), 0) end
    return number
end

local function check(ok, err)
    if not ok then error(err, 0) end
    return ok, err
end

-- What changing each setting did, for a cell which runs. `restarted` if it started again for it.
local function say_changed(info, key, value, restarted)
    if key == "area" then
        print(("The cell is in area %d now."):format(value or 0))
    elseif key == "band" then
        if value and info.state ~= "stopped" and not restarted then
            print(("The cell is on band %s already, and stays there."):format(band_label(value)))
        elseif value then
            print(("The cell goes on a carrier of its core's in band %s."):format(band_label(value)))
        else
            print("The cell may go on any of its core's carriers, when it next connects. It stays where it is until then.")
        end
    elseif key == "interval" then
        if value then
            print(("The cell sends its system information every %g seconds, whatever its core says."):format(value))
        else
            print("The cell sends its system information as often as its core says.")
        end
    elseif key == "pos" then
        if value then
            print(("The cell says it's at %d, %d, %d."):format(value[1], value[2], value[3]))
        else
            print("The cell no longer says where it is.")
        end
    elseif key == "power" then
        if value then print(("The cell sends with %g dBm."):format(value)) else print("The cell sends with its modem's own power.") end
    elseif key == "service" then
        if value then
            print("The cell only carries messages now. Its phones move to a cell which carries everything, if there's one.")
        else
            print("The cell carries everything.")
        end
    end
    if restarted then
        print("It started again for that: its phones lose service for a moment, and attach again.")
        watch()
    elseif info.state == "stopped" then
        if not info.cores then
            print(("It's kept for when the cell starts. Add a core with '%s add <core>'."):format(name))
        else
            print(("It's kept for when the cell starts again ('%s start')."):format(name))
        end
    end
end

local command = args[1] or "status"

if command == "status" then
    if #args > 1 then return usage() end
    show(net.cell.cellInfo())

elseif command == "add" then
    if #args ~= 2 then return usage() end
    local core = args[2]
    local info = net.cell.cellInfo()
    local cores = {}
    for i, other in ipairs(info.cores or {}) do
        if other:lower() == core:lower() then error(("This cell connects to %s already."):format(other), 0) end
        cores[i] = other
    end
    cores[#cores + 1] = core
    check(net.cell.configureCell({ cores = cores }))
    if info.state == "stopped" then
        if info.enabled == false and info.cores then
            print(("Added %s. The cell is stopped: '%s start' starts it."):format(core, name))
            return
        end
        check(net.cell.startCell())
    end
    watch(core)

elseif command == "remove" then
    if #args ~= 2 then return usage() end
    local info = net.cell.cellInfo()
    if not info.cores then error("This cell has no cores.", 0) end
    -- By the name or address it was added as, or the network it serves.
    local wanted, found = args[2]:lower(), nil
    for _, core in ipairs(info.cores) do
        if core:lower() == wanted then found = core end
    end
    for _, link in ipairs(info.links or {}) do
        if not found and link.network and link.network:lower() == wanted then found = link.core end
    end
    if not found then
        error(("This cell doesn't connect to %s. Its cores are %s."):format(args[2], table.concat(info.cores, ", ")), 0)
    end
    local cores = {}
    for _, core in ipairs(info.cores) do
        if core ~= found then cores[#cores + 1] = core end
    end
    check(net.cell.configureCell({ cores = cores }))
    if not cores[1] then
        print(("Removed %s. The cell has no cores left, so it stopped. '%s add <core>' starts it again."):format(found, name))
    else
        print(("Removed %s: the cell no longer serves its network, and carries on serving the others."):format(found))
    end

elseif command == "set" or command == "unset" then
    local setting = SETTING[args[2] or ""]
    if not args[2] then return usage() end
    if not setting then error(("There's no setting called %s. They're %s."):format(args[2], setting_names()), 0) end
    local key, value = setting.name, false
    if command == "unset" then
        if #args ~= 2 then return usage() end
    else
        if #args ~= 2 + (setting.count or 1) then
            error(("Usage: %s set %s %s"):format(name, key, setting.takes), 0)
        end
        value = read_value(key, { table.unpack(args, 3) })
    end
    local info = net.cell.cellInfo()
    local _, restarted = check(net.cell.configureCell({ [key] = value }))
    say_changed(info, key, value or nil, restarted)

elseif command == "start" then
    if #args > 1 then return usage() end
    local info = net.cell.cellInfo()
    if not info.cores then error(("The cell has no cores to connect to. Add one with '%s add <core>'."):format(name), 0) end
    if info.state ~= "stopped" then
        print(("The cell is running. '%s restart' connects to its cores again."):format(name))
        return
    end
    check(net.cell.startCell())
    watch()

elseif command == "stop" then
    if #args > 1 then return usage() end
    net.cell.stopCell()
    print(("Stopped the cell. It starts again with '%s start'."):format(name))

elseif command == "restart" then
    if #args > 1 then return usage() end
    local info = net.cell.cellInfo()
    if not info.cores then error(("The cell has no cores to connect to. Add one with '%s add <core>'."):format(name), 0) end
    net.cell.stopCell()
    check(net.cell.startCell())
    print("Started the cell again: its phones lose service for a moment, and attach again.")
    watch()

else
    usage()
    error(("There's no command called %s. To serve a core's network, use '%s add <core>'."):format(command, name), 0)
end
