-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"
local bands = require "cc.internal.net.bands"

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " <interface> <address>/<prefix>")
    print(name .. " <interface> dhcp")
    print(name .. " <interface> none")
    print(name .. " <interface> band <low|high>")
    print(name .. " <interface> channel <channel|none>")
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
        if interface.channel then
            kind = ("%s, channel %d"):format(kind, interface.channel)
        elseif kind == "wireless" or kind == "ender" then
            kind = ("%s, %s band"):format(kind, interface.band)
        end
        heading(("%s (%s)"):format(interface.name, kind))
        print("  " .. describe(interface))
        if interface.channel then
            local channel = interface.channel
            print(("  ID %d, sharing channel %d (%gMHz)"):format(interface.id, channel, bands.frequency(channel)))
        elseif interface.unicast then
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
    if settings.get("net." .. name .. ".channel") ~= nil then
        local program = arg[0] or fs.getName(shell.getRunningProgram())
        print(("It's set to a channel of its own, though, which it uses instead: \"%s %s channel none\" to stop.")
            :format(program, name))
    end
    return
end

if value == "channel" then
    local text = args[3]
    if not text or args[4] then
        usage()
        return
    end

    local interface = find(name)
    if not interface or (interface.kind ~= "wireless" and interface.kind ~= "ender") then
        printError("Only wireless and ender modems can have a channel of their own.")
        return
    end
    if interface.modem ~= name then
        printError(("Only a modem's own interface can: %s here."):format(interface.modem))
        return
    end

    if text == "none" then
        save("net." .. name .. ".channel", nil)
        print(("%s will use its band when the computer restarts."):format(name))
        return
    end

    local channel = tonumber(text)
    local usable, why = bands.check_link_channel(channel)
    if not usable then
        printError(why)
        return
    end
    save("net." .. name .. ".channel", channel)
    print(("%s will share channel %d (%gMHz) when the computer restarts. Every computer on the link needs the same one.")
        :format(name, channel, bands.frequency(channel)))
    local band, part = bands.of(channel)
    if part == "uplink" or part == "downlink" then
        print(("It's in cellular band %s: a phone or cell on this modem can't use it."):format(band))
    end
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
