-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Let the computer get on with other things for a moment, as a test which takes a while must, or it's stopped for
running too long without yielding.

It queues an event and waits for it. A computer's queue holds 256 events, and an event queued while it's full is lost,
so waiting for that event alone could wait for good. Once more than that have come first, it's queued again. Which
events they were is printed, the first time, to show what filled the queue.
]]

local told = false

return function()
    while true do
        os.queueEvent("spec_yield")
        local seen, timers = {}, {}
        for _ = 1, 256 do
            local event, id = os.pullEvent()
            if event == "spec_yield" then return end
            seen[event] = (seen[event] or 0) + 1
            -- Where the timers came from, when the test runner says.
            local creator = _G.cct_test_timer_creator
            if event == "timer" and creator then
                local where = creator(id) or "?"
                timers[where] = (timers[where] or 0) + 1
            end
        end
        if not told then
            told = true
            local names = {}
            for name, count in pairs(seen) do names[#names + 1] = ("%s x%d"):format(tostring(name), count) end
            table.sort(names)
            print("The event queue was full, of " .. table.concat(names, ", "))
            for where, count in pairs(timers) do print(("  timers from %s x%d"):format(where, count)) end
        end
    end
end
