-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Run a cell of a cellular network (or of several networks, which share it), in the background, or show how it's
-- doing.

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " <core> [core...] [area]")
    print(name)
    print(name .. " stop")
end

if not crypto or not enclave then
    printError("Cells need the crypto and enclave APIs, which are turned off on this server")
    return
end

-- Say what the cell is doing with one of several cores.
local function show_link(info, link)
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
    end
    if link.newer then
        print(("%s speaks a newer version of the network (%d). If they don't work together, update this cell's ROM."):format(
            link.core, link.newer
        ))
    end
end

-- Say what the cell is doing.
local function show(info)
    if info.links and #info.links > 1 then
        print(("Cell #%d, area %d, for %d networks:"):format(info.id, info.area, #info.links))
        for _, link in ipairs(info.links) do show_link(info, link) end
        return
    end
    if info.state == "stopped" then
        print("This computer isn't running a cell. Start one with 'celld <core>'.")
    elseif info.state == "connecting" then
        print(("Connecting to the core %s..."):format(info.core))
    elseif info.state == "waiting" then
        print("The core hasn't allowed this cell yet. On the core, run:")
        print(("  cellcore allow %d"):format(info.id))
        print("and check it shows this fingerprint:")
        print("  " .. tostring(info.fingerprint))
    elseif info.state == "serving" then
        print(("Cell #%d of %s, area %d, through the core %s."):format(info.id, info.network, info.area, info.core))
    elseif info.state == "refused" then
        printError(("The core %s refused this cell: %s"):format(info.core, tostring(info.error)))
    elseif info.state == "lost" then
        printError(("Cannot reach the core %s: %s"):format(info.core, tostring(info.error)))
        if info.retry then print(("Trying again in %d seconds."):format(info.retry)) end
    end
end

if #args == 0 then
    show(net.cell.cellInfo())
    return
elseif args[1] == "stop" then
    if #args > 1 then return usage() end
    net.cell.stopCell()
    print("Stopped the cell. It starts again with 'celld <core>'.")
    return
end

-- Cores, and the area last if it's given.
local cores, area = {}, nil
for i, arg in ipairs(args) do
    if i == #args and i > 1 and arg:match("^%d+$") then area = tonumber(arg) else cores[#cores + 1] = arg end
end

local ok, err = net.cell.startCell(#cores == 1 and cores[1] or cores, area)
if not ok then
    printError(err)
    return
end

-- Follow the cell until it serves each network, or something goes wrong. It runs in the background either way.
local watched, watch_err = pcall(function()
    local shown = {}
    while true do
        local info = net.cell.cellInfo()
        local links = info.links or { info }
        local settled, serving = true, true
        for i, link in ipairs(links) do
            if link.state ~= shown[i] then
                shown[i] = link.state
                if #links > 1 then show_link(info, link) else show(info) end
                if link.state == "waiting" then print("Waiting... Press Ctrl+T to stop watching. The cell carries on waiting.") end
            end
            if link.state == "connecting" or link.state == "waiting" then settled = false end
            if link.state ~= "serving" then serving = false end
        end
        if settled then
            if serving then
                print("It runs in the background, and starts with this computer. 'celld' shows how it's doing.")
            else
                print("It keeps trying in the background. 'celld' shows how it's doing.")
            end
            return
        end
        sleep(0.2)
    end
end)
if not watched then
    if watch_err ~= "Terminated" then error(watch_err, 0) end
    print("Stopped watching. The cell carries on in the background.")
end
