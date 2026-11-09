-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local args = { ... }
if #args < 1 or #args > 2 then
    print("Usage: " .. (arg[0] or fs.getName(shell.getRunningProgram())) .. " <address> [count]")
    return
end

local target = args[1]
local count = tonumber(args[2] or 4)
if not count or count < 1 then
    printError("Count must be a positive number.")
    return
end

print("Pinging " .. target)

local sent, received, total = 0, 0, 0
for i = 1, count do
    sent = sent + 1
    local time, ttl, from = net.ping(target, 2)
    if time then
        received, total = received + 1, total + time
        print(("Reply from %s: time %d ms, ttl %d"):format(from, math.floor(time * 1000 + 0.5), ttl))
    else
        -- On failure, the second result is the reason.
        print(ttl)
        if ttl:find("^Invalid") or ttl == "Network unreachable" then return end
    end

    if i < count then sleep(1) end
end

local summary = ("%d sent, %d received"):format(sent, received)
if received > 0 then summary = summary .. (", average %d ms"):format(math.floor(total / received * 1000 + 0.5)) end
print(summary)
