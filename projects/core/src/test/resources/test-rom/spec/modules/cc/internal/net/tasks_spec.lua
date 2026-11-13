-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.tasks", function()
    local tasks = require "cc.internal.net.tasks"

    it("runs tasks side by side, each waiting for its own events", function()
        local seen = {}
        local set = tasks.new()
        set:spawn(function(name)
            while true do
                local _, value = coroutine.yield("a")
                seen[#seen + 1] = name .. value
            end
        end, "first ")
        set:spawn(function()
            local event, value = coroutine.yield()
            seen[#seen + 1] = event .. " " .. value
        end)
        set:resume("b", "one")
        set:resume("a", "two")
        set:resume("terminate")
        set:resume("a", "three")
        expect(seen):same { "b one", "first two", "first three" }
        expect(set:count()):eq(1)

        set:stop()
        set:resume("a", "four")
        expect(#seen):eq(3)
    end)

    it("reports tasks which fail, and carries on", function()
        local errors = {}
        local set = tasks.new(function(err) errors[#errors + 1] = err end)
        local ran = 0
        set:spawn(function() coroutine.yield() error("Broken", 0) end)
        set:spawn(function() while true do coroutine.yield() ran = ran + 1 end end)
        set:resume()
        set:resume()
        expect(errors):same { "Broken" }
        expect(ran):eq(2)
        expect(set:count()):eq(1)
    end)

    -- A connection which takes messages once there's room, waiting (by yielding) until then.
    local function connection(sent)
        local self = { room = true, fails = false }
        function self.send(_, message)
            while not self.room do coroutine.yield() end
            if self.fails then return nil, "Connection closed" end
            sent[#sent + 1] = message
            return true
        end
        return self
    end

    it("sends from a task of its own, so what sends needn't wait", function()
        local set, sent, woken = tasks.new(), {}, 0
        local target = connection(sent)
        target.room = false
        local send = set:sender(target, function() woken = woken + 1 end)

        -- Messages are queued at once, and the tasks woken to send them.
        send("one")
        send("two")
        expect(woken):eq(2)
        expect(sent):same {}
        set:resume()
        expect(sent):same {}

        -- In order, once there's room.
        target.room = true
        set:resume()
        expect(sent):same { "one", "two" }
        send("three")
        set:resume()
        expect(sent):same { "one", "two", "three" }
    end)

    it("stops sending once a send fails, or it's told to", function()
        local set, sent = tasks.new(), {}
        local target = connection(sent)
        local send = set:sender(target, function() end)
        target.fails = true
        send("lost")
        set:resume()
        expect(set:count()):eq(0)
        target.fails = false
        send("never")
        set:resume()
        expect(sent):same {}

        local woken = 0
        local again, stop = set:sender(target, function() woken = woken + 1 end)
        stop()
        again("never either")
        set:resume()
        expect({ sent, woken, set:count() }):same { {}, 0, 0 }
    end)
end)
