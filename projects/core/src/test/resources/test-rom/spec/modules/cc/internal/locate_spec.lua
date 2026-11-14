-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.locate", function()
    local locate = require "cc.internal.locate".locate

    local function distance(a, b)
        return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    end

    -- Fixes from places, heard from `at` (or from where `at(age)` says we were that long ago).
    local function fixes(places, at, ages)
        local result = {}
        for i, place in ipairs(places) do
            local age = ages and ages[i] or 0
            local from = type(at) == "function" and at(age) or at
            result[i] = { x = place[1], y = place[2], z = place[3], distance = distance(place, from), age = age }
        end
        return result
    end

    local hosts = { { 5, 5, 5 }, { 10, 5, 5 }, { 5, 10, 5 }, { 5, 5, 10 } }

    it("finds a computer which stays put exactly", function()
        expect({ locate(fixes(hosts, { 12, 23, 52 })) }):same { 12, 23, 52, 0 }
        expect({ locate(fixes(hosts, { -3000, 64, 1200 }), 5) }):same { -3000, 64, 1200, 0 }
    end)

    it("finds computers anywhere", function()
        math.randomseed(1)
        local spread = { { 0, 0, 0 }, { 0, 16, 16 }, { 16, 16, 0 }, { 16, 0, 16 } }
        for _ = 1, 200 do
            local at = { (math.random() - 0.5) * 20000, (math.random() - 0.5) * 1024, (math.random() - 0.5) * 20000 }
            local x, y, z, off = locate(fixes(spread, at))
            expect(math.abs(x - at[1]) <= 0.01 and math.abs(y - at[2]) <= 0.01 and math.abs(z - at[3]) <= 0.01)
                :describe(("At %.2f, %.2f, %.2f, found %s, %s, %s"):format(at[1], at[2], at[3], x, y, z)):eq(true)
            expect(off):eq(0)
        end
    end)

    it("takes the newest fix from each place", function()
        local list = fixes({ { 5, 5, 5 }, table.unpack(hosts) }, { 12, 23, 52 })
        list[1].distance, list[1].age = 1000, 5
        expect({ locate(list) }):same { 12, 23, 52, 0 }
    end)

    it("needs three places, not on a line", function()
        expect({ locate({}) }):same { nil, "too few" }
        expect({ locate(fixes({ { 0, 0, 0 }, { 10, 0, 0 } }, { 3, 4, 5 })) }):same { nil, "too few" }
        expect({ locate(fixes({ { 0, 0, 0 }, { 10, 0, 0 }, { 20, 0, 0 }, { 30, 0, 0 } }, { 3, 4, 5 })) })
            :same { nil, "too few" }
    end)

    it("can't tell which side of the places' plane we're on", function()
        -- Three places, or any number at one height.
        expect({ locate(fixes({ { 5, 5, 5 }, { 10, 5, 5 }, { 5, 10, 5 } }, { 12, 23, 52 })) })
            :same { nil, "ambiguous", { 12, 23, 52 }, { 12, 23, -42 } }
        local level = { { 0, 100, 0 }, { 500, 100, 0 }, { 0, 100, 500 }, { 500, 100, 500 } }
        local x, why, one, other = locate(fixes(level, { 200, 64, 300 }))
        expect({ x, why }):same { nil, "ambiguous" }
        expect({ one[2], other[2] }):same { 136, 64 }

        -- Unless we're in it.
        expect({ locate(fixes(level, { 200, 100, 300 })) }):same { 200, 100, 300, 0 }
    end)

    it("is right at a place", function()
        expect({ locate(fixes(hosts, { 5, 10, 5 })) }):same { 5, 10, 5, 0 }
    end)

    describe("on the move", function()
        -- Going along at 5 blocks a second, hearing each place half a second after the last.
        local function moving(age) return { 1000 - 5 * age, 70, 400 } end
        local ages = { 0, 0.5, 1, 1.5, 2, 2.5 }

        local function check(places)
            local x, y, z, off = locate(fixes(places, moving, ages), 5)
            local miss = distance({ x, y, z }, moving(0))
            expect(off > 0):describe("The error, " .. tostring(off)):eq(true)
            expect(miss <= off):describe(("Off by %.2f, said %.2f"):format(miss, off)):eq(true)
            return off, miss
        end

        it("says how far off it may be", function()
            local off = check { { 0, 300, 0 }, { 2000, 0, 0 }, { 0, 0, 1000 }, { 2000, 300, 1000 }, { 1000, 250, -500 }, { 1000, 10, 1500 } }
            expect(off < 40):describe("The error, " .. off):eq(true)
        end)

        it("may be either side of places at much the same height, seen from far away", function()
            check { { 0, 120, 0 }, { 2000, 90, 0 }, { 0, 150, 1000 }, { 2000, 60, 1000 }, { 1000, 200, -500 }, { 1000, 20, 1500 } }
        end)

        it("is exact again for fixes heard at once", function()
            local list = fixes(hosts, { 300, 80, 20 })
            expect({ locate(list, 5) }):same { 300, 80, 20, 0 }
        end)
    end)

    it("says it's further off where the places are at much the same height", function()
        -- Distances a little off, from places at different heights, and at much the same height.
        local function off(places)
            local list = fixes(places, { 1000, 70, 400 })
            for i, fix in ipairs(list) do fix.distance = fix.distance + (i % 2 == 0 and 2 or -2) end
            local _, _, _, result = locate(list)
            return result
        end
        local spread = off { { 0, 300, 0 }, { 2000, 0, 0 }, { 0, 0, 1000 }, { 2000, 300, 1000 }, { 1000, 250, -500 }, { 1000, 10, 1500 } }
        local level = off { { 0, 100, 0 }, { 2000, 101, 0 }, { 0, 100, 1000 }, { 2000, 102, 1000 }, { 1000, 101, -500 }, { 1000, 100, 1500 } }
        expect(spread > 0 and level > spread * 2):describe(("Level %.2f, spread %.2f"):format(level, spread)):eq(true)
    end)
end)
