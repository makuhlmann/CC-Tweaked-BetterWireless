-- SPDX-FileCopyrightText: 2017 Daniel Ratcliffe
--
-- SPDX-License-Identifier: LicenseRef-CCPL

local completion = require "cc.shell.completion"

-- Setup paths
local sPath = ".:/rom/programs:/rom/programs/http:/rom/programs/net"
if term.isColor() then
    sPath = sPath .. ":/rom/programs/advanced"
end
if turtle then
    sPath = sPath .. ":/rom/programs/turtle"
else
    sPath = sPath .. ":/rom/programs/rednet:/rom/programs/fun"
    if term.isColor() then
        sPath = sPath .. ":/rom/programs/fun/advanced"
    end
end
if pocket then
    sPath = sPath .. ":/rom/programs/pocket"
end
if commands then
    sPath = sPath .. ":/rom/programs/command"
end
shell.setPath(sPath)
help.setPath("/rom/help")

-- Setup aliases
shell.setAlias("ls", "list")
shell.setAlias("dir", "list")
shell.setAlias("cp", "copy")
shell.setAlias("mv", "move")
shell.setAlias("rm", "delete")
shell.setAlias("clr", "clear")
shell.setAlias("rs", "redstone")
shell.setAlias("sh", "shell")
if term.isColor() then
    shell.setAlias("background", "bg")
    shell.setAlias("foreground", "fg")
end

-- Setup completion functions

local function completePastebinPut(shell, text, previous)
    if previous[2] == "put" then
        return fs.complete(text, shell.dir(), true, false)
    end
end

shell.setCompletionFunction("rom/programs/alias.lua", completion.build(nil, completion.program))
shell.setCompletionFunction("rom/programs/cd.lua", completion.build(completion.dir))
shell.setCompletionFunction("rom/programs/clear.lua", completion.build({ completion.choice, { "screen", "palette", "all" } }))
shell.setCompletionFunction("rom/programs/copy.lua", completion.build(
    { completion.dirOrFile, true },
    completion.dirOrFile
))
shell.setCompletionFunction("rom/programs/delete.lua", completion.build({ completion.dirOrFile, many = true }))
shell.setCompletionFunction("rom/programs/drive.lua", completion.build(completion.dir))
shell.setCompletionFunction("rom/programs/edit.lua", completion.build(completion.file))
shell.setCompletionFunction("rom/programs/eject.lua", completion.build(completion.peripheral))
shell.setCompletionFunction("rom/programs/gps.lua", completion.build({ completion.choice, { "host", "host ", "locate" } }))
shell.setCompletionFunction("rom/programs/help.lua", completion.build(completion.help))
shell.setCompletionFunction("rom/programs/id.lua", completion.build(completion.peripheral))
shell.setCompletionFunction("rom/programs/label.lua", completion.build(
    { completion.choice, { "get", "get ", "set ", "clear", "clear " } },
    completion.peripheral
))
shell.setCompletionFunction("rom/programs/list.lua", completion.build(completion.dir))
shell.setCompletionFunction("rom/programs/mkdir.lua", completion.build({ completion.dir, many = true }))

local complete_monitor_extra = { "scale" }
shell.setCompletionFunction("rom/programs/monitor.lua", completion.build(
    function(shell, text, previous)
        local choices = completion.peripheral(shell, text, previous, true)
        for _, option in pairs(completion.choice(shell, text, previous, complete_monitor_extra, true)) do
            choices[#choices + 1] = option
        end
        return choices
    end,
    function(shell, text, previous)
        if previous[2] == "scale" then
            return completion.peripheral(shell, text, previous, true)
        else
            return completion.programWithArgs(shell, text, previous, 3)
        end
    end,
    {
        function(shell, text, previous)
            if previous[2] ~= "scale" then
                return completion.programWithArgs(shell, text, previous, 3)
            end
        end,
        many = true,
    }
))

shell.setCompletionFunction("rom/programs/move.lua", completion.build(
    { completion.dirOrFile, true },
    completion.dirOrFile
))
shell.setCompletionFunction("rom/programs/redstone.lua", completion.build(
    { completion.choice, { "probe", "set ", "pulse " } },
    completion.side
))
shell.setCompletionFunction("rom/programs/rename.lua", completion.build(
    { completion.dirOrFile, true },
    completion.dirOrFile
))
shell.setCompletionFunction("rom/programs/shell.lua", completion.build({ completion.programWithArgs, 2, many = true }))
shell.setCompletionFunction("rom/programs/type.lua", completion.build(completion.dirOrFile))
shell.setCompletionFunction("rom/programs/set.lua", completion.build({ completion.setting, true }))
shell.setCompletionFunction("rom/programs/advanced/bg.lua", completion.build({ completion.programWithArgs, 2, many = true }))
shell.setCompletionFunction("rom/programs/advanced/fg.lua", completion.build({ completion.programWithArgs, 2, many = true }))
shell.setCompletionFunction("rom/programs/fun/dj.lua", completion.build(
    { completion.choice, { "play", "play ", "stop " } },
    completion.peripheral
))
shell.setCompletionFunction("rom/programs/fun/speaker.lua", completion.build(
    { completion.choice, { "play ", "sound ", "stop " } },
    function(shell, text, previous)
        if previous[2] == "play" then return completion.file(shell, text, previous, true)
        elseif previous[2] == "stop" then return completion.peripheral(shell, text, previous, false)
        end
    end,
    function(shell, text, previous)
        if previous[2] == "play" then return completion.peripheral(shell, text, previous, false)
        end
    end
))
shell.setCompletionFunction("rom/programs/fun/advanced/paint.lua", completion.build(completion.file))
shell.setCompletionFunction("rom/programs/http/pastebin.lua", completion.build(
    { completion.choice, { "put ", "get ", "run " } },
    completePastebinPut
))
shell.setCompletionFunction("rom/programs/rednet/chat.lua", completion.build({ completion.choice, { "host ", "join " } }))
local cellcore_commands = {
    "status", "log", "add ", "subscribers", "remove ", "set ", "cells", "allow ", "deny ", "networks", "network ",
    "numbers ", "restart", "roaming", "carry ", "uncarry ", "partner ", "peers", "peer ", "unpeer ",
}
shell.setCompletionFunction("rom/programs/net/cellcore.lua", function(shell, index, text, previous)
    if index == 1 then
        local choices = { "setup ", "start", "stop", "remote " }
        for _, choice in ipairs(cellcore_commands) do choices[#choices + 1] = choice end
        return completion.choice(shell, text, previous, choices)
    elseif index == 3 and previous[2] == "remote" then
        return completion.choice(shell, text, previous, cellcore_commands)
    end
end)
shell.setCompletionFunction("rom/programs/net/celld.lua", completion.build({ completion.choice, { "stop" } }))
shell.setCompletionFunction("rom/programs/net/cell.lua", function(shell, index, text, previous)
    if index == 1 then
        return completion.choice(shell, text, previous, {
            "activate ", "send ", "messages", "networks", "network ", "on", "off", "monitor", "gui", "bar ",
        })
    elseif index == 2 and previous[2] == "network" then
        local choices = { "auto" }
        for _, network in ipairs(net.cell.networks()) do
            if network.allowed then choices[#choices + 1] = network.name end
        end
        return completion.choice(shell, text, previous, choices)
    elseif index == 2 and previous[2] == "bar" then
        local choices = completion.choice(shell, text, previous, { "on", "off" }) or {}
        for _, choice in ipairs(completion.programWithArgs(shell, text, previous, 3) or {}) do
            choices[#choices + 1] = choice
        end
        return choices
    elseif previous[2] == "bar" then
        return completion.programWithArgs(shell, text, previous, 3)
    end
end)
shell.setCompletionFunction("rom/programs/command/exec.lua", completion.build(completion.command))
shell.setCompletionFunction("rom/programs/http/wget.lua", completion.build({ completion.choice, { "run " } }))

if turtle then
    shell.setCompletionFunction("rom/programs/turtle/go.lua", completion.build(
        { completion.choice, { "left", "right", "forward", "back", "down", "up" }, true, many = true }
    ))
    shell.setCompletionFunction("rom/programs/turtle/turn.lua", completion.build(
        { completion.choice, { "left", "right" }, true, many = true }
    ))
    shell.setCompletionFunction("rom/programs/turtle/equip.lua", completion.build(
        nil,
        { completion.choice, { "left", "right" } }
    ))
    shell.setCompletionFunction("rom/programs/turtle/unequip.lua", completion.build(
        { completion.choice, { "left", "right" } }
    ))
end

if pocket then
    shell.setCompletionFunction("rom/programs/pocket/equip.lua", completion.build(
        nil,
        { completion.choice, { "top", "back" } }
    ))
    shell.setCompletionFunction("rom/programs/pocket/unequip.lua", completion.build(
        { completion.choice, { "top", "back" } }
    ))
end

-- Run autorun files
if fs.exists("/rom/autorun") and fs.isDir("/rom/autorun") then
    local tFiles = fs.list("/rom/autorun")
    for _, sFile in ipairs(tFiles) do
        if string.sub(sFile, 1, 1) ~= "." then
            local sPath = "/rom/autorun/" .. sFile
            if not fs.isDir(sPath) then
                shell.run(sPath)
            end
        end
    end
end

local function findStartups(sBaseDir)
    local tStartups = nil
    local sBasePath = "/" .. fs.combine(sBaseDir, "startup")
    local sStartupNode = shell.resolveProgram(sBasePath)
    if sStartupNode then
        tStartups = { sStartupNode }
    end
    -- It's possible that there is a startup directory and a startup.lua file, so this has to be
    -- executed even if a file has already been found.
    if fs.isDir(sBasePath) then
        if tStartups == nil then
            tStartups = {}
        end
        for _, v in pairs(fs.list(sBasePath)) do
            local sPath = "/" .. fs.combine(sBasePath, v)
            if not fs.isDir(sPath) then
                tStartups[#tStartups + 1] = sPath
            end
        end
    end
    return tStartups
end

-- The rest of starting up: the message of the day, and the user's startup programs.
local function finishStartup()
    -- Show MOTD
    if settings.get("motd.enable") then
        shell.run("/rom/programs/motd")
    end

    -- Run the user created startup, either from disk drives or the root
    local tUserStartups = nil
    if settings.get("shell.allow_startup") then
        tUserStartups = findStartups("/")
    end
    if settings.get("shell.allow_disk_startup") then
        for _, sName in pairs(peripheral.getNames()) do
            if disk.isPresent(sName) and disk.hasData(sName) then
                local startups = findStartups(disk.getMountPath(sName))
                if startups then
                    tUserStartups = startups
                    break
                end
            end
        end
    end
    if tUserStartups then
        for _, v in pairs(tUserStartups) do
            shell.run(v)
        end
    end
end

-- A computer activated on a cellular network (a phone, say) has the cell status bar at the top of the screen, unless
-- "cell bar off" turned it off. The rest of starting up, and the shell, run beneath it; leaving that shell leaves this
-- one too, as it would have without the bar.
local hasCellBar, cellBar = pcall(require, "cc.internal.net.cell.bar")
if hasCellBar and cellBar.at_startup() then
    cellBar.run(function()
        finishStartup()
        shell.run("/rom/programs/shell.lua")
    end)
    shell.exit()
else
    finishStartup()
end
