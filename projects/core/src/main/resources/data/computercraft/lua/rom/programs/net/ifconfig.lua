-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " <interface> <address>/<prefix>")
    print(name .. " <interface> none")
    print(name .. " <interface> band <low|high>")
end

local function heading(text)
    if term.isColour() then term.setTextColour(colours.yellow) end
    print(text)
    term.setTextColour(colours.white)
end

local function find(name)
    for _, interface in ipairs(net.interfaces()) do
        if interface.name == name then return interface end
    end
end

local function save(key, value)
    if value == nil then settings.unset(key) else settings.set(key, value) end
    settings.save()
end

if #args == 0 then
    local interfaces = net.interfaces()
    if #interfaces == 0 then
        print("No modems attached.")
        return
    end

    for _, interface in ipairs(interfaces) do
        local kind = interface.kind == "wireless" and ("wireless, " .. interface.band .. " band") or interface.kind
        heading(("%s (%s)"):format(interface.name, kind))
        if interface.address then
            local addr = interface.address .. "/" .. interface.prefix
            if interface.duplicate then addr = addr .. " (in use by another computer!)" end
            print("  " .. addr)
        else
            print("  No address")
        end
        print(("  ID %d, channels %d and %d"):format(interface.id, interface.unicast, interface.broadcast))
        print(("  %d neighbours, %d frames in, %d out"):format(interface.neighbours, interface.frames_in, interface.frames_out))
    end

    local errors = net.getErrors()
    if #errors > 0 then
        printError(("%d recent errors. The last was:"):format(#errors))
        printError(errors[#errors])
    end
    return
end

local name, value = args[1], args[2]
if not value then
    usage()
    return
end

if value == "band" then
    local band = args[3]
    if band ~= "low" and band ~= "high" then
        usage()
        return
    end

    local interface = find(name)
    if not interface or interface.kind ~= "wireless" then
        printError("Only wireless modems have bands.")
        return
    end

    save("net." .. name .. ".band", band ~= "high" and band or nil)
    print(("%s will use the %s band when the computer restarts."):format(name, band))
    return
end

if value == "none" then
    save("net." .. name .. ".address", nil)
    if find(name) then net.setAddress(name, nil) end
    print(name .. ": no address")
    return
end

local addr, prefix = address.parse(value)
if not addr then
    printError(prefix)
    return
end

local text = address.format(addr, prefix or 24)
save("net." .. name .. ".address", text)

if find(name) then
    net.setAddress(name, text)
    print(name .. ": " .. text)
else
    print(("No interface named %s yet. It will have address %s once it's added."):format(name, text))
end
