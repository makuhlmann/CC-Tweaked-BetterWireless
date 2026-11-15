-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Run a cell of a cellular network (or of several networks, which share it) in the background, change it one thing at
-- a time, or show how it's doing. Its cores and settings are kept: each command changes one thing, and checks it
-- first, so a mistake changes nothing.

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local cell_menu = require "cc.internal.net.cell.cell_menu"

local function usage()
    print("Usages:")
    print(name)
    print(name .. " status")
    print(name .. " add <core>")
    print(name .. " remove <core>")
    print(name .. " set area <number>")
    print(name .. " set band <band>...")
    print(name .. " set interval <seconds>")
    print(name .. " set pos <x> <y> <z>")
    print(name .. " set power <dBm>")
    print(name .. " set service sms|full")
    print(name .. " unset <setting>")
    print(name .. " confirm")
    print(name .. " start|stop|restart")
end

if not crypto or not enclave then
    printError("Cells need the crypto and enclave APIs, which are turned off on this server")
    return
end

-- Each setting, with what it takes after its name (for "set"), in the order they're shown.
local SETTINGS = cell_menu.SETTINGS
local SETTING = {}
for _, setting in ipairs(SETTINGS) do SETTING[setting.name] = setting end

local function setting_names()
    local names = {}
    for i, setting in ipairs(SETTINGS) do names[i] = setting.name end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- Say what the cell is doing with one of its cores. `added` is the core just added, which may have been mistyped.
local function show_link(info, link, added)
    for _, line in ipairs(cell_menu.link_lines(info, link, name, added)) do
        if line.bad then printError(line.text) else print(line.text) end
    end
end

-- Show the cell's settings, set or not.
local function show_settings(info)
    local shown = cell_menu.setting_values(info)
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
        for _, line in ipairs(cell_menu.carrier_lines(info)) do print(line) end
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
            local settled, serving, any, standing_by = true, true, false, false
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
                    if link.state == "standby" then standing_by = true end
                end
            end
            if not any then return end
            if settled then
                if standing_by then
                    print("It waits in the background, and starts with this computer.")
                elseif serving then
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

local read_value = cell_menu.read_value

local function check(ok, err)
    if not ok then error(err, 0) end
    return ok, err
end

-- Say what changing a setting did, for a cell which runs. `restarted` if it started again for it.
local function say_changed(info, key, value, restarted)
    for _, line in ipairs(cell_menu.changed_lines(info, key, value, restarted, name)) do print(line) end
    -- It started again, or went on the air for the first time.
    if restarted or (key == "band" and info.state == "standby") then watch() end
end

-- With nothing asked of it, it shows the cell's menu: everything below, to look through and change.
if #args == 0 then return cell_menu.run(name) end

local command = args[1]

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
        local given = #args - 2
        if given < (setting.count or 1) or given > (setting.most or setting.count or 1) then
            error(("Usage: %s set %s %s"):format(name, key, setting.takes), 0)
        end
        value = read_value(key, { table.unpack(args, 3) })
    end
    local info = net.cell.cellInfo()
    local _, restarted = check(net.cell.configureCell({ [key] = value }))
    say_changed(info, key, value or nil, restarted)

elseif command == "confirm" then
    -- A new cell stands by, off the air, until its bands are confirmed: as they're set, or any.
    if #args > 1 then return usage() end
    local info = net.cell.cellInfo()
    if not info.cores then error(("The cell has no cores to connect to. Add one with '%s add <core>'."):format(name), 0) end
    if info.confirmed ~= false then
        print("The cell's bands are confirmed already.")
        return
    end
    check(net.cell.configureCell({ confirmed = true }))
    print(("The cell goes on the air, on %s."):format(
        info.band and cell_menu.band_label(info.band) or "any band, as its core picks"
    ))
    if info.state ~= "stopped" then watch() end

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
