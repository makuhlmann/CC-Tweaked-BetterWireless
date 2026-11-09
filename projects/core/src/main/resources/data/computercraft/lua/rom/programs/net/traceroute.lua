-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local args = { ... }
if #args < 1 or #args > 2 then
    print("Usage: " .. (arg[0] or fs.getName(shell.getRunningProgram())) .. " <target> [max hops]")
    return
end

local target, max_hops = args[1], tonumber(args[2] or 16)
local addr, err = net.resolve(target)
if not addr then
    printError(target .. ": " .. err)
    return
end
print(("Route to %s (%s)"):format(target, addr))

-- Send echo requests which may pass one router, then two, and so on. Each router where the request runs out reports
-- back, which shows the route.
for hop = 1, max_hops do
    local time, result, from = net.ping(addr, 2, hop)
    if time then
        print(("%2d  %s  %d ms"):format(hop, from, math.floor(time * 1000 + 0.5)))
        return
    elseif result == "TTL expired" then
        print(("%2d  %s"):format(hop, from))
    elseif result == "Timed out" then
        print(("%2d  *"):format(hop))
    else
        print(("%2d  %s%s"):format(hop, result, from and (" (from " .. from .. ")") or ""))
        return
    end
end
print("Gave up after " .. max_hops .. " hops.")
