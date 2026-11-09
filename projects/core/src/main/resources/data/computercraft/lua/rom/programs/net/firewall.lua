-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " <allow|deny> [proto <udp|tcp|icmp>] [from <network>] [to <network>] [port <port>] [on <interface>]")
    print(name .. " delete <number>")
    print(name .. " clear")
end

local function save(rules)
    if #rules == 0 then settings.unset("net.firewall") else settings.set("net.firewall", rules) end
    settings.save()
    net.reload()
end

local function describe(rule)
    local parts = { rule.action }
    if rule.proto then parts[#parts + 1] = rule.proto end
    if rule.from then parts[#parts + 1] = "from " .. rule.from end
    if rule.to then parts[#parts + 1] = "to " .. rule.to end
    if rule.port then parts[#parts + 1] = "port " .. rule.port end
    if rule.on then parts[#parts + 1] = "on " .. rule.on end
    return table.concat(parts, " ")
end

local rules = settings.get("net.firewall") or {}
local command = args[1]

if command == nil then
    if #rules == 0 then
        print("No rules: everything is forwarded.")
    else
        for i, rule in ipairs(rules) do print(("%d. %s"):format(i, describe(rule))) end
        print("Anything else is forwarded.")
    end
elseif command == "allow" or command == "deny" then
    local rule = { action = command }
    local fields = { proto = "proto", from = "from", to = "to", port = "port", on = "on" }
    local i = 2
    while i <= #args do
        local field, value = fields[args[i]], args[i + 1]
        if not field or not value then
            usage()
            return
        end
        if field == "port" then
            value = tonumber(value)
            if not value then
                printError("Expected a port number")
                return
            end
        elseif field == "proto" and value ~= "udp" and value ~= "tcp" and value ~= "icmp" then
            printError("Expected a protocol of udp, tcp or icmp")
            return
        elseif (field == "from" or field == "to") and not address.parse(value) then
            printError("Expected an address or network, such as 10.2.0.0/16")
            return
        end
        rule[field] = value
        i = i + 2
    end

    rules[#rules + 1] = rule
    save(rules)
    print(("Added rule %d: %s"):format(#rules, describe(rule)))
elseif command == "delete" and tonumber(args[2]) and rules[tonumber(args[2])] then
    local removed = table.remove(rules, tonumber(args[2]))
    save(rules)
    print("Deleted: " .. describe(removed))
elseif command == "clear" then
    save({})
    print("Deleted every rule.")
else
    usage()
end
