-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.timers", function()
    local timers = require "cc.internal.net.timers"

    local function run_due(set, now, last)
        local ran = {}
        while true do
            local timer = set:pop_due(now, last)
            if not timer then return ran end
            ran[#ran + 1] = timer.fn()
        end
    end

    it("gives timers in the order they're due, and those due together in the order they were set", function()
        local set = timers.new()
        local times = { 5, 1, 3, 3, 9, 1, 7, 3 }
        for i, time in ipairs(times) do set:add(time, function() return i end) end
        expect(set:count()):eq(8)
        expect(set:peek().time):eq(1)
        expect(run_due(set, 4)):same { 2, 6, 3, 4, 8 }
        expect(run_due(set, 100)):same { 1, 7, 5 }
        expect(set:count()):eq(0)
        expect(set:peek()):eq(nil)
    end)

    it("passes by cancelled timers, and leaves those set later for later", function()
        local set = timers.new()
        local a = set:add(1, function() return "a" end)
        set:add(2, function() return "b" end)
        set:cancel(a)
        set:cancel(a)
        expect(set:count()):eq(1)
        -- One set while others run is due then at the earliest, as the stack sets them.
        local last = set:last_set()
        set:add(5, function() return "late" end)
        expect(run_due(set, 5, last)):same { "b" }
        expect(run_due(set, 5)):same { "late" }
    end)

    it("stays small when timers are set and cancelled again and again", function()
        local set = timers.new()
        local keep = set:add(1e9, function() end)
        for i = 1, 10000 do set:cancel(set:add(1e6 + i, function() end)) end
        expect(set:count()):eq(1)
        expect(#set.heap <= 2 + 64):eq(true)
        expect(set:peek()):eq(keep)
    end)
end)
