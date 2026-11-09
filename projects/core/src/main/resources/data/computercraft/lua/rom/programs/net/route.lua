-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " add <network>/<prefix> <gateway> [metric]")
    print(name .. " delete <network>/<prefix>")
    print(name .. " default <gateway|none>")
    print(name .. " forwarding <on|off>")
    print(name .. " rip <on|off|default>")
end

-- Change a setting, save it, and apply it straight away.
local function save(key, value)
    if value == nil then settings.unset(key) else settings.set(key, value) end
    settings.save()
    net.reload()
end

local function parse_network(text)
    local addr, prefix = address.parse(text or "")
    if not addr or not prefix then
        printError("Expected a network such as 10.5.0.0/16")
        return nil
    end
    return address.format(address.network(addr, prefix), prefix)
end

local command = args[1]
if command == nil then
    local width = term.getSize()
    for _, route in ipairs(net.routes()) do
        local via = route.gateway and ("via " .. route.gateway) or "direct"
        local line = ("%-18s %s"):format(route.network, via)
        if route.interface then line = line .. " on " .. route.interface end
        local detail = ("%s, cost %d"):format(route.source, route.metric)
        if route.metric >= 16 then detail = route.source .. ", unreachable" end
        if #line + #detail + 3 > width then
            print(line)
            print("  " .. detail)
        else
            print(line .. " (" .. detail .. ")")
        end
    end
    if settings.get("net.forwarding") then print("Forwarding packets for other computers.") end
    return
end

if command == "add" and (#args == 3 or #args == 4) then
    local network = parse_network(args[2])
    local gateway = address.parse(args[3])
    local metric = tonumber(args[4] or 1)
    if not network then return end
    if not gateway or not metric then
        usage()
        return
    end

    local routes = settings.get("net.routes") or {}
    local text = network .. " via " .. address.format(gateway)
    if metric ~= 1 then text = text .. " metric " .. metric end
    routes[#routes + 1] = text
    save("net.routes", routes)
    print("Added " .. text)
elseif command == "delete" and #args == 2 then
    local network = parse_network(args[2])
    if not network then return end

    local kept, removed = {}, 0
    for _, text in ipairs(settings.get("net.routes") or {}) do
        if text:match("^%s*(%S+)") == network then removed = removed + 1 else kept[#kept + 1] = text end
    end
    if network == "0.0.0.0/0" and settings.get("net.gateway") then
        settings.unset("net.gateway")
        removed = removed + 1
    end
    save("net.routes", #kept > 0 and kept or nil)
    print(removed > 0 and ("Deleted the route to " .. network) or ("No fixed route to " .. network))
elseif command == "default" and #args == 2 then
    if args[2] == "none" then
        save("net.gateway", nil)
        print("No default gateway")
    elseif address.parse(args[2]) then
        save("net.gateway", args[2])
        print("Default gateway: " .. args[2])
    else
        usage()
    end
elseif command == "forwarding" and (args[2] == "on" or args[2] == "off") then
    save("net.forwarding", args[2] == "on")
    print(args[2] == "on" and "This computer now forwards packets: it is a router." or "This computer no longer forwards packets.")
elseif command == "rip" and (args[2] == "on" or args[2] == "off" or args[2] == "default") then
    settings.set("net.rip.default", args[2] == "default")
    save("net.rip", args[2] ~= "off")
    if args[2] == "off" then
        print("No longer learning routes from other routers.")
    else
        print("Learning routes from other routers" .. (args[2] == "default" and ", and offering a default route." or "."))
    end
else
    usage()
end
