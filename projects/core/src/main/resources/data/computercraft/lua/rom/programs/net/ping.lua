-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Ping as Unix systems do: a request every second, each numbered, until stopped (or until a count has been sent), with
-- every reply shown as it comes, however late, out of order or doubled. Then a summary, also when it's terminated.

local args = { ... }
if #args < 1 or #args > 2 then
    print("Usage: " .. (arg[0] or fs.getName(shell.getRunningProgram())) .. " <address> [count]")
    return
end

local target, count = args[1], nil
if args[2] then
    count = tonumber(args[2])
    if not count or count < 1 or count % 1 ~= 0 then
        printError("Count must be a whole number, from 1.")
        return
    end
end

local pinger, err = net.pinger(target)
if not pinger then
    printError(target .. ": " .. err)
    return
end
local addr = pinger:getAddress()
print(addr == target and "PING " .. addr or ("PING %s (%s)"):format(target, addr))

-- How long to wait for late replies once the last request is sent, if none came at all.
local LINGER = 10
-- os.clock counts in ticks of a twentieth of a second, which don't add up exactly: a time this close counts as come.
local SLACK = 0.01

local function ms(time) return math.floor(time * 1000 + 0.5) end

local sent, received, duplicates, errors = 0, 0, 0, 0
local min, max, total
local answered = {}

local function run()
    local next_send, last_sent = os.clock(), nil
    while true do
        local now = os.clock()
        if not count or sent < count then
            if now >= next_send - SLACK then
                local seq, why = pinger:send()
                if not seq then error(why, 0) end
                sent, last_sent = seq, now
                if why then
                    -- It won't be answered, so it counts as an error.
                    errors = errors + 1
                    printError(("seq=%d: %s"):format(seq, why))
                end
                -- Requests go out a second apart, however long the replies take.
                next_send = next_send + 1
                if next_send < now then next_send = now + 1 end
            end
        elseif received + errors >= sent then
            return
        else
            -- All sent: wait a little for the replies still to come, longer if none came at all.
            local wait = max and math.max(1, 2 * max) or LINGER
            if now >= last_sent + wait - SLACK then return end
            next_send = last_sent + wait
        end

        local reply = pinger:receive(math.max(0, next_send - os.clock()))
        if reply and reply.error then
            errors = errors + 1
            print(("From %s: seq=%d %s"):format(reply.from, reply.seq, reply.error))
        elseif reply then
            local time = reply.time
            if reply.duplicate then
                duplicates = duplicates + 1
            elseif not answered[reply.seq] then
                answered[reply.seq] = true
                received = received + 1
                min, max, total = math.min(min or time, time), math.max(max or time, time), (total or 0) + time
            end
            print(("Reply from %s: seq=%d ttl=%d time=%d ms%s"):format(
                reply.from, reply.seq, reply.ttl, ms(time), reply.duplicate and " (DUP!)" or ""
            ))
        end
    end
end

local ok, failure = pcall(run)
pinger:close()
if not ok and failure ~= "Terminated" then error(failure, 0) end

print(("--- %s ping statistics ---"):format(target))
local summary = ("%d sent, %d received"):format(sent, received)
if duplicates > 0 then summary = summary .. (", +%d duplicate%s"):format(duplicates, duplicates == 1 and "" or "s") end
if errors > 0 then summary = summary .. (", +%d error%s"):format(errors, errors == 1 and "" or "s") end
if sent > 0 then summary = summary .. (", %d%% loss"):format(math.floor((sent - received) * 100 / sent)) end
print(summary)
if received > 0 then print(("time min/avg/max = %d/%d/%d ms"):format(ms(min), ms(total / received), ms(max))) end
