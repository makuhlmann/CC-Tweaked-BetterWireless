-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Run a cell of a cellular network, in the background, or show how it's doing.

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " <core> [area]")
    print(name)
    print(name .. " stop")
end

if not crypto or not enclave then
    printError("Cells need the crypto and enclave APIs, which are turned off on this server")
    return
end

-- Say what the cell is doing.
local function show(info)
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
elseif args[1] == "stop" and #args == 1 then
    net.cell.stopCell()
    print("Stopped the cell. It starts again with 'celld <core>'.")
    return
elseif #args > 2 or (args[2] and not tonumber(args[2])) then
    return usage()
end

local ok, err = net.cell.startCell(args[1], tonumber(args[2]))
if not ok then
    printError(err)
    return
end

-- Follow the cell until it's serving, or something goes wrong. It runs in the background either way.
local watched, watch_err = pcall(function()
    local shown
    while true do
        local info = net.cell.cellInfo()
        if info.state ~= shown then
            shown = info.state
            show(info)
            if info.state == "waiting" then print("Waiting... Press Ctrl+T to stop watching. The cell carries on waiting.") end
            if info.state == "serving" then
                print("It runs in the background, and starts with this computer. 'celld' shows how it's doing.")
                return
            elseif info.state == "lost" or info.state == "refused" then
                print("It keeps trying in the background. 'celld' shows how it's doing.")
                return
            end
        end
        sleep(0.2)
    end
end)
if not watched then
    if watch_err ~= "Terminated" then error(watch_err, 0) end
    print("Stopped watching. The cell carries on in the background.")
end
