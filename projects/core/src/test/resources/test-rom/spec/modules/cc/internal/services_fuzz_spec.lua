-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Random sequences of what can be asked of services, with services which behave in different ways (exit at once,
stop when told, ignore being told, change another service, or ask for something about themselves as they stop), events
and time passing, and the computer restarting. After each step, what the services say must hang together, and agree
with the file; at the end, everything asked for must be done within a few seconds. ]]

describe("cc.internal.services, at random", function()
    local services = require "cc.internal.services"
    local files = require "cc.internal.net.files"
    local yield = require "support.yield"

    local FILE = "/.services_fuzz"
    local DIR = "/services_fuzz"
    local NAMES = { "a", "b", "c", "d", "e" }
    local ACTIONS = { "start", "stop", "restart", "remove" }

    local PROGRAMS = {
        exits = [[print("Bye")]],
        polite = [[pcall(function() while true do os.pullEvent() end end)]],
        stubborn = [[while true do os.pullEventRaw() end]],
        -- On its first event, asks for something of another service (once per name, so it all settles).
        meddler = [[
            local name, other, action = ...
            local fuzz = _G.services_fuzz
            pcall(function()
                os.pullEvent("spec")
                if not fuzz.acted[name] then
                    fuzz.acted[name] = true
                    fuzz.manager[action](fuzz.manager, other)
                end
                while true do os.pullEvent() end
            end)
        ]],
        -- As it's told to stop, asks to start again, or be removed (once per name).
        flipper = [[
            local name, action = ...
            local fuzz = _G.services_fuzz
            pcall(function() while true do os.pullEvent() end end)
            if not fuzz.flipped[name] then
                fuzz.flipped[name] = true
                fuzz.manager[action](fuzz.manager, name)
            end
        ]],
    }
    local KINDS = { "exits", "polite", "stubborn", "meddler", "flipper" }

    -- A small random number generator of our own, so a seed means the same everywhere.
    local function random(seed)
        local state = seed
        return function(n)
            state = (state * 1103515245 + 12345) % 2147483648
            return math.floor(state / 65536) % n + 1
        end
    end

    local function run(seed, steps)
        fs.delete(FILE)
        fs.delete(DIR)
        for kind, text in pairs(PROGRAMS) do
            local file = fs.open(fs.combine(DIR, kind .. ".lua"), "w")
            file.write(text)
            file.close()
        end

        local pick = random(seed)
        local now, timers = 0, {}
        local function new_manager()
            return services.new {
                file = FILE, width = 51,
                queue_event = function() end,
                clock = function() return now end,
                start_timer = function(delay)
                    timers[#timers + 1] = now + delay
                    return #timers
                end,
                cancel_timer = function(id) timers[id] = nil end,
            }
        end

        local m = new_manager()
        _G.services_fuzz = { manager = m, acted = {}, flipped = {} }
        local screen, history = term.current(), {}

        local function fail(message)
            error(("Seed %d, after %s: %s"):format(seed, table.concat(history, ", ", math.max(1, #history - 12)), message), 0)
        end

        -- What the services say must hang together, and agree with the file.
        local function check()
            if term.current() ~= screen then fail("the terminal was left redirected") end
            if m.current ~= nil then fail("a service is still said to be running") end
            local saved = files.read_table(FILE)
            for name, record in pairs(m.services) do
                local alive = record.co ~= nil
                local live_state = record.state == "running" or record.state == "stopping"
                if alive ~= live_state then fail(("%s is %s, with%s a coroutine"):format(name, record.state, alive and "" or "out")) end
                if record.state == "stopping" and not (record.terminated and record.deadline and m.timer) then
                    fail(name .. " is stopping, with nothing to stop it if it doesn't")
                end
                if record.state == "removed" then fail(name .. " is removed, but still there") end
                if record.want == "remove" then
                    if saved[name] then fail(name .. " is being removed, but still in the file") end
                else
                    local entry = saved[name]
                    if not entry then fail(name .. " isn't in the file") end
                    if entry.enabled ~= record.enabled then fail(name .. "'s file says otherwise whether it starts") end
                    if table.concat(entry.command, " ") ~= table.concat(record.command, " ") then
                        fail(name .. "'s file has another command")
                    end
                end
            end
            for name in pairs(saved) do
                if not m.services[name] then fail(name .. " is in the file, but not known") end
            end
        end

        -- Fire the timers which are due, in order (not while going through them: firing one may set another).
        local function fire_timers()
            local due = {}
            for id, at in pairs(timers) do
                if at <= now then due[#due + 1] = id end
            end
            table.sort(due)
            for _, id in ipairs(due) do
                if timers[id] then
                    timers[id] = nil
                    m:resume("timer", id)
                end
            end
        end

        for step = 1, steps do
            local roll, name = pick(100), NAMES[pick(#NAMES)]
            if roll <= 22 then
                local kind = KINDS[pick(#KINDS)]
                local command = { fs.combine(DIR, kind .. ".lua") }
                if kind == "meddler" then
                    command[2], command[3], command[4] = name, NAMES[pick(#NAMES)], ACTIONS[pick(#ACTIONS)]
                elseif kind == "flipper" then
                    command[2], command[3] = name, pick(2) == 1 and "start" or "remove"
                end
                history[#history + 1] = ("add %s %s"):format(name, table.concat(command, " ", 2))
                command[1] = "/" .. command[1]
                m:add(name, command)
            elseif roll <= 32 then
                history[#history + 1] = "start " .. name
                m:start(name)
            elseif roll <= 46 then
                history[#history + 1] = "stop " .. name
                m:stop(name)
            elseif roll <= 54 then
                history[#history + 1] = "restart " .. name
                m:restart(name)
            elseif roll <= 62 then
                history[#history + 1] = "remove " .. name
                m:remove(name)
            elseif roll <= 82 then
                history[#history + 1] = "event"
                m:resume("spec")
            elseif roll <= 95 then
                local seconds = pick(4) - 1
                history[#history + 1] = ("wait %ds"):format(seconds)
                now = now + seconds
                fire_timers()
            else
                -- The computer restarts: what was running is gone, and the file says what starts again.
                history[#history + 1] = "reboot"
                m = new_manager()
                _G.services_fuzz.manager = m
                timers = {}
                m:boot(shell)
                m:resume("service_wake")
            end
            check()
            if step % 25 == 0 then yield() end
        end

        -- Everything asked for is done within a few seconds, and what starts with the computer is running (or has
        -- exited by itself), and what doesn't, isn't.
        for _ = 1, 6 do
            now = now + 4
            fire_timers()
            m:resume("spec")
            check()
        end
        for name, record in pairs(m.services) do
            if not m:settled(name) then fail(("%s hasn't done what was asked (%s, %s)"):format(name, record.state, tostring(record.want))) end
            if record.enabled and record.state ~= "running" and record.state ~= "exited" then
                fail(("%s starts with the computer, but is %s"):format(name, record.state))
            end
            if not record.enabled and record.state == "running" then fail(name .. " doesn't start with the computer, but is running") end
        end
    end

    local function cleanup()
        fs.delete(FILE)
        fs.delete(DIR)
        _G.services_fuzz = nil
    end

    for _, seed in ipairs { 1, 2, 3, 4, 5, 6 } do
        it(("keeps its services in order (seed %d)"):format(seed), function()
            local ok, err = pcall(run, seed, 150)
            cleanup()
            if not ok then error(err, 0) end
        end)
    end
end)
