-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.recent", function()
    local recent = require "cc.internal.net.recent"

    local function keys(store)
        local result = {}
        for key, value in store:each() do result[key] = value end
        return result
    end

    it("forgets the oldest when there are too many", function()
        local store = recent.new(3)
        for i = 1, 5 do store:add(i, "v" .. i) end
        expect(keys(store)):same { [3] = "v3", [4] = "v4", [5] = "v5" }
        expect(store:count()):eq(3)

        -- Adding one again makes it the newest.
        store:add(3)
        store:add(6)
        expect(keys(store)):same { [3] = true, [5] = "v5", [6] = true }
        expect(store:get(4)):eq(nil)
    end)

    it("forgets what's too old", function()
        local now = 0
        local store = recent.new(10, 5, function() return now end)
        store:add("a")
        now = 3
        store:add("b")
        expect({ store:get("a"), store:get("b") }):same { true, true }
        now = 5
        expect({ store:get("a"), store:get("b"), store:count() }):same { nil, true, 1 }
        -- Adding it again starts it afresh.
        store:add("b")
        now = 9
        expect(store:get("b")):eq(true)
        now = 10
        expect(store:get("b")):eq(nil)
        expect(store:count()):eq(0)
    end)

    it("forgets what's removed, and passes its old place by", function()
        local now = 0
        local store = recent.new(2, 5, function() return now end)
        store:add("a")
        now = 1
        store:add("b")
        expect(store:remove("a")):eq(true)
        expect(store:remove("a")):eq(false)
        now = 2
        store:add("c")
        -- "b" isn't forgotten for "a"'s place, which is gone.
        expect(keys(store)):same { b = true, c = true }
        now = 5.5
        expect(keys(store)):same { b = true, c = true }
        now = 6
        expect(keys(store)):same { c = true }

        -- Removing during a walk through it is fine.
        store:add("d")
        for key in store:each() do store:remove(key) end
        expect(store:count()):eq(0)
    end)

    it("stays small when the same things are added again and again", function()
        local store = recent.new(4)
        for i = 1, 10000 do store:add(i % 3) end
        expect(store:count()):eq(3)
        local slots = 0
        for _ in pairs(store.order) do slots = slots + 1 end
        expect(slots <= 2 * 4 + 16):eq(true)
        expect(keys(store)):same { [0] = true, [1] = true, [2] = true }
    end)
end)
