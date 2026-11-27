-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.cell.common sealers", function()
    local common = require "cc.internal.net.cell.common"

    local KEY = ("k"):rep(32)
    local now = 1.7e12
    local function epoch() return now end

    before_each(function() now = 1.7e12 end)

    -- A pair of sealers sharing a key, as a phone and its cell have.
    local function pair()
        return common.new_sealer(crypto, KEY, common.UPLINK, common.DOWNLINK, epoch),
            common.new_sealer(crypto, KEY, common.DOWNLINK, common.UPLINK, epoch)
    end

    it("opens what the other end sealed, once", function()
        local phone, cell = pair()
        local sealed = phone:seal({ hello = true })
        local value, counter = cell:open(sealed)
        expect(value):same { hello = true }
        expect(counter):eq(sealed.ctr)
        expect(cell:open(sealed)):eq(nil)
    end)

    it("never seals with a counter it has used before, when the same key is used again", function()
        -- A phone at a cell, then elsewhere, then back at the same cell: it shares the same key with the cell both
        -- times, and makes a new sealer each time.
        local first = pair()
        local used = {}
        for _ = 1, 5 do used[first:seal("first stay").ctr] = true end
        now = now + 2000
        local second = pair()
        for _ = 1, 5 do
            local counter = second:seal("second stay").ctr
            expect(used[counter]):eq(nil)
        end
    end)

    it("refuses what was sealed for an earlier stay with the same key", function()
        local old_phone = pair()
        local recorded = old_phone:seal({ target = 12 })
        -- Back at the same cell a while later: a recording from the first stay is a replay.
        now = now + 20000
        local _, cell = pair()
        expect(cell:open(recorded)):eq(nil)
        -- What the phone seals now is fine.
        local phone = pair()
        expect(cell:open(phone:seal({ ok = true }))):same { ok = true }
    end)

    it("takes what was sealed a moment before it was made", function()
        -- The cell seals the phone's address as soon as it knows the phone, and the phone only makes its sealer once
        -- that arrives, held back on the way.
        local _, cell = pair()
        local sealed = cell:seal({ address = 5 })
        now = now + 2500
        local phone = pair()
        expect(phone:open(sealed)):same { address = 5 }
    end)

    it("takes messages out of order, as far as a radio holds one back", function()
        local phone, cell = pair()
        local held = phone:seal("held")
        now = now + 3000
        local later = phone:seal("later")
        expect(cell:open(later)):eq("later")
        expect(cell:open(held)):eq("held")

        -- Much older than the newest: a replay, as a radio doesn't hold messages that long.
        local ancient = phone:seal("ancient")
        now = now + 10000
        expect(cell:open(phone:seal("newest"))):eq("newest")
        expect(cell:open(ancient)):eq(nil)
    end)

    it("refuses messages from far in the future", function()
        local phone, cell = pair()
        now = now + 120000
        local future = phone:seal("future")
        now = now - 120000
        expect(cell:open(future)):eq(nil)
    end)
end)
