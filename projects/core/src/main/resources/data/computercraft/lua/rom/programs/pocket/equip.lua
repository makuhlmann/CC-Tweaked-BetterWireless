-- SPDX-FileCopyrightText: 2017 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

if not pocket then
    printError("Requires a Pocket Computer")
    return
end

if select('#', ...) > 1 then
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usage: " .. programName .. " <side>")
    return
end

local function equip(fn)
    local ok, err = fn()
    if not ok then
        printError(err)
    else
        print("Item equipped")
    end
end

local functions = { top = "equipTop", back = "equipBack", left = "equipLeft", right = "equipRight" }

local side = ... or "back"
local fn = functions[side]
if not fn then
    printError("Unknown side. Expected 'top', 'back', 'left' or 'right'.")
    return
end

equip(pocket[fn])
