-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ cc.internal.locate at random: what it says must hold wherever the places are and however the computer moves, and
nothing it's given, however odd, may break it. ]]

describe("cc.internal.locate, at random,", function()
    local locate = require "cc.internal.locate".locate
    local yield = require "support.yield"

    local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
    local function distance(a, b)
        return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    end

    -- Run `case` with seeds from `first`, saying which failed.
    local function cases(first, n, case)
        for seed = first, first + n - 1 do
            math.randomseed(seed)
            local ok, err = pcall(case, seed)
            if not ok then error(("Seed %d: %s"):format(seed, type(err) == "table" and err.message or tostring(err)), 0) end
            if seed % 10 == 0 then yield() end
        end
    end

    -- Places around the origin: some spread out, some bunched, at heights which may all be much the same.
    local function places(n)
        local spread = ({ 20, 100, 400 })[math.random(1, 3)]
        local flat = math.random(1, 3) == 1
        local list = {}
        for i = 1, n do
            list[i] = {
                math.random(-spread, spread), flat and 64 + math.random(0, 2) or math.random(0, 255),
                math.random(-spread, spread),
            }
        end
        return list
    end

    -- What the solver says is either where we are, within the error it gives, or why it can't tell.
    local function sound(truth, x, y, z, off)
        if not x then
            assert(type(y) == "string", "No reason for not knowing")
            return false
        end
        assert(finite(x) and finite(y) and finite(z), ("A position which isn't one: %s %s %s"):format(x, y, z))
        assert(off == math.huge or (finite(off) and off >= 0), "An error which isn't one: " .. tostring(off))
        if truth then
            local miss = distance({ x, y, z }, truth)
            -- Positions and errors are rounded to hundredths.
            assert(miss <= off + 0.02, ("Off by %.3f, said %.3f, at %s"):format(miss, off, textutils.serialise(truth, { compact = true })))
        end
        return true
    end

    it("finds a computer which stays put, wherever the places are", function()
        local found = 0
        cases(1, 300, function()
            local list = places(math.random(3, 8))
            local truth = { math.random(-300, 300) + math.random(), math.random(0, 255), math.random(-300, 300) }
            local fixes = {}
            for i, place in ipairs(list) do
                -- Each heard once or a few times, a while ago.
                for _ = 1, math.random(1, 3) do
                    fixes[#fixes + 1] = {
                        x = place[1], y = place[2], z = place[3], distance = distance(place, truth), age = math.random() * 5,
                    }
                end
                if i == 1 then fixes[#fixes].age = 0 end
            end
            if sound(truth, locate(fixes)) then found = found + 1 end
        end)
        -- Most constellations will do.
        expect(found > 150):describe("Found " .. found):eq(true)
    end)

    -- A computer going along at a steady speed, turning at most once, hearing each place every second or so at its own
    -- moment: the fixes of the last few seconds, as a phone or GPS keeps them.
    local function walk(list, speed, turn)
        local heading = { math.random() - 0.5, (math.random() - 0.5) * 0.3, math.random() - 0.5 }
        local norm = math.sqrt(heading[1] ^ 2 + heading[2] ^ 2 + heading[3] ^ 2)
        local velocity = { heading[1] / norm * speed, heading[2] / norm * speed, heading[3] / norm * speed }
        local after = { -velocity[3], velocity[2], velocity[1] }
        local now = { math.random(-100, 100), math.random(30, 200), math.random(-100, 100) }
        -- Where it was `ago` seconds before now: turned `turn` seconds ago, if it turned.
        local function at(ago)
            if not turn or ago <= turn then
                local v = turn and after or velocity
                return { now[1] - v[1] * ago, now[2] - v[2] * ago, now[3] - v[3] * ago }
            end
            local corner = { now[1] - after[1] * turn, now[2] - after[2] * turn, now[3] - after[3] * turn }
            local back = ago - turn
            return { corner[1] - velocity[1] * back, corner[2] - velocity[2] * back, corner[3] - velocity[3] * back }
        end
        local fixes = {}
        local interval = 0.5 + math.random() * 1.5
        for _, place in ipairs(list) do
            local ago = math.random() * interval
            while ago <= 10 do
                fixes[#fixes + 1] = { x = place[1], y = place[2], z = place[3], distance = distance(place, at(ago)), age = ago }
                ago = ago + interval
            end
        end
        return fixes, now
    end

    it("never says it's closer than it is, however the computer moves", function()
        local found = 0
        cases(1001, 40, function()
            local list = places(math.random(4, 6))
            local speed = ({ 1, 4, 8, 20 })[math.random(1, 4)]
            local turn = math.random(1, 2) == 1 and math.random() * 6 or nil
            local fixes, truth = walk(list, speed, turn)
            if sound(truth, locate(fixes)) then found = found + 1 end
        end)
        expect(found > 20):describe("Found " .. found):eq(true)
    end)

    -- Odd values for each part of a fix.
    local ODD = { 0 / 0, math.huge, -math.huge, 1e308, -1e308, -1, 0, 1e-300, "1", true, {} }

    it("isn't broken by odd fixes", function()
        cases(2001, 200, function()
            local list = places(math.random(1, 6))
            local truth = { 10, 70, -20 }
            local fixes = {}
            for _, place in ipairs(list) do
                fixes[#fixes + 1] = { x = place[1], y = place[2], z = place[3], distance = distance(place, truth), age = math.random() }
            end
            -- Spoil a few: a part of a fix, or a fix twice, or one on top of another place.
            for _ = 1, math.random(1, 3) do
                local fix = fixes[math.random(1, #fixes)]
                local what = math.random(1, 3)
                if what == 1 then
                    fix[({ "x", "y", "z", "distance", "age" })[math.random(1, 5)]] = ODD[math.random(1, #ODD)]
                elseif what == 2 then
                    fixes[#fixes + 1] = { x = fix.x, y = fix.y, z = fix.z, distance = fix.distance, age = fix.age }
                else
                    fixes[#fixes + 1] = { x = fix.x, y = fix.y, z = fix.z, distance = math.random() * 50, age = 0 }
                end
            end
            -- Odd fixes may say anything about where we are, but nothing which isn't a position.
            sound(nil, locate(fixes))
        end)

        -- Nothing at all, places all in one spot or along one line, and everything at once.
        expect(select(1, locate {})):eq(nil)
        local same, line = {}, {}
        for i = 1, 10 do
            same[i] = { x = 5, y = 5, z = 5, distance = 3, age = i / 10 }
            line[i] = { x = i * 10, y = 64, z = 0, distance = 20, age = 0 }
        end
        expect(select(1, locate(same))):eq(nil)
        expect(select(1, locate(line))):eq(nil)
        local huge = {}
        for i = 1, 4 do huge[i] = { x = 3e7 * (i % 2), y = 64 + i, z = -3e7 * (i % 3), distance = 4e7, age = 0 } end
        sound(nil, locate(huge))
    end)

    it("works out where it is from many fixes in reasonable time", function()
        local list = places(30)
        local fixes = walk(list, 4, nil)
        local start = os.epoch("utc")
        sound(nil, locate(fixes))
        local took = os.epoch("utc") - start
        expect(took < 3000):describe(("Took %d ms for %d fixes"):format(took, #fixes)):eq(true)
    end)
end)
