-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name .. " <name>")
    print(name .. " service <service>")
end

if #args == 1 then
    local addr, err = net.resolve(args[1])
    if addr then
        print(args[1] .. ": " .. addr)
    else
        printError(args[1] .. ": " .. err)
    end
elseif #args == 2 and args[1] == "service" then
    local found = net.lookup(args[2])
    if #found == 0 then
        printError("Nobody on the local network offers " .. args[2])
    else
        for _, server in ipairs(found) do
            print(("%s (%s) port %d"):format(server.host, server.address, server.port))
        end
    end
else
    usage()
end
