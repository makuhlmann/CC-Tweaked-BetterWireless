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
    print(name .. " <interface> dhcp")
    print(name .. " <interface> none")
    print(name .. " <interface> band <low|high>")
    print(name .. " <interface> psk <passphrase|none>")
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

local function describe(interface)
    if not interface.address then
        if interface.config == "dhcp" then return "No address yet (DHCP: " .. tostring(interface.dhcp) .. ")" end
        return "No address"
    end

    local text = interface.address .. "/" .. interface.prefix
    if interface.duplicate then
        text = text .. " (in use by another computer!)"
    elseif interface.link_local then
        text = text .. " (link-local: no DHCP server)"
    elseif interface.config == "dhcp" and interface.lease then
        text = text .. (" (DHCP, %d s left)"):format(math.floor(interface.lease))
    elseif interface.config == "static" then
        text = text .. " (fixed)"
    end
    return text
end

if #args == 0 then
    local interfaces = net.interfaces()
    if #interfaces == 0 then
        print("No modems attached.")
        return
    end

    print("Hostname: " .. net.getHostname())
    for _, interface in ipairs(interfaces) do
        local kind = interface.kind
        if kind == "wireless" or kind == "ender" then kind = ("%s, %s band"):format(kind, interface.band) end
        heading(("%s (%s)"):format(interface.name, kind))
        print("  " .. describe(interface))
        if interface.unicast then
            print(("  ID %d, channels %d and %d"):format(interface.id, interface.unicast, interface.broadcast))
        else
            print("  A virtual link, with no modem of its own")
        end
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
    if not interface or (interface.kind ~= "wireless" and interface.kind ~= "ender") then
        printError("Only wireless and ender modems have bands.")
        return
    end

    save("net." .. name .. ".band", band ~= "high" and band or nil)
    print(("%s will use the %s band when the computer restarts."):format(name, band))
    return
end

if value == "psk" then
    local passphrase = table.concat(args, " ", 3)
    if passphrase == "" then
        usage()
        return
    end
    if passphrase == "none" then passphrase = nil end
    save("net." .. name .. ".psk", passphrase)
    if find(name) then net.setPassphrase(name, passphrase) end
    print(passphrase and (name .. " is encrypted. Every computer on it needs the same passphrase.") or (name .. " is no longer encrypted."))
    return
end

local setting, text
if value == "dhcp" then
    setting, text = "dhcp", "dhcp"
elseif value == "none" then
    setting, text = "none", nil
else
    local addr, prefix = address.parse(value)
    if not addr then
        printError(prefix)
        return
    end
    prefix = prefix or 24
    local usable, why = false, "The prefix length must be from 1 to 32"
    if prefix >= 1 then usable, why = address.check_host(addr, prefix) end
    if not usable then
        printError(why)
        return
    end
    text = address.format(addr, prefix)
    setting = text
end

-- Use it first, and keep it only if that worked: a setting which can't be used would be refused at every start.
local interface = find(name)
if interface then
    local ok, err = pcall(net.setAddress, name, text)
    if not ok then
        printError(err)
        return
    end
end
save("net." .. name .. ".address", setting)

if interface then
    if value == "dhcp" then
        print(name .. ": asking for an address")
    else
        print(name .. ": " .. (text or "no address"))
    end
else
    print(("No interface named %s yet. The setting will be used once it's added."):format(name))
end
