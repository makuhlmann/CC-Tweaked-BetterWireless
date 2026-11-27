-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cells' signed system information, and what phones check of it. Checking each cell's signature every time a phone
heard it was most of what a busy server's computers spent on cryptography: a cell now sends what it signed again, as
it was, until something in it changes, and a phone checks only what it hasn't checked before. Nothing a cell didn't
sign may get through. ]]

describe("Cells' signed system information", function()
    local common = require "cc.internal.net.cell.common"
    local bands = require "cc.internal.net.bands"
    local operator = require "support.cell_network".operator
    local yield = require "support.yield"

    local function count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end

    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}
        for k, v in pairs(value) do result[k] = copy(v) end
        return result
    end

    -- Count the signatures a phone checks, and how many of them didn't check out.
    local function counting(phone)
        local counts = { checked = 0, failed = 0 }
        local real = phone.crypto
        phone.crypto = setmetatable({
            verify = function(...)
                local ok = real.verify(...)
                counts.checked = counts.checked + 1
                if not ok then counts.failed = counts.failed + 1 end
                return ok
            end,
        }, { __index = real })
        return counts
    end

    -- A computer which hears the system information a network's cells send: the last from each cell, how many, and
    -- which signatures.
    local function ears(setup, id, position)
        local stack = setup.net.stack(id)
        setup.positions[id] = position
        stack:add_interface("ears", "air", "wireless", {
            band = "test", listen = { setup.carrier }, reply = setup.carrier, to = function() return nil end,
        })
        local heard = { last = {}, count = {}, sigs = {} }
        stack:on_frame(common.FRAME, function(_, src, body)
            if type(body) ~= "table" or body.op ~= "sib" then return end
            heard.last[src] = body
            heard.count[src] = (heard.count[src] or 0) + 1
            local sigs = heard.sigs[src] or {}
            heard.sigs[src] = sigs
            sigs[body.networks[1].sig] = true
        end, true)
        return heard
    end

    it("is checked by a phone only when the cell signs it again", function()
        math.randomseed(1)
        -- Six of ACME's cells, each sending system information every second, all heard by a phone near the third.
        local acme = operator { 0, 20, 40, 60, 80, 100 }
        local net = acme.net
        local phone = acme.add_phone(1, 45)
        local heard = ears(acme, 99, 45)
        net.advance(8)
        expect(phone.state):eq("attached")

        local counts = counting(phone)
        heard.count, heard.sigs = {}, {}
        for _ = 1, 30 do
            net.advance(1)
            yield()
        end

        -- Each cell sent it every second, but signed it only every ten seconds.
        local sent, signings = 0, 0
        for _, tower in ipairs(acme.towers) do
            local id = tower.id
            expect((heard.count[id] or 0) >= 29):describe(("Heard cell %d %d times"):format(id, heard.count[id] or 0))
                :eq(true)
            local signed = count(heard.sigs[id])
            expect(signed >= 3 and signed <= 4):describe(("Cell %d signed %d times"):format(id, signed)):eq(true)
            sent, signings = sent + heard.count[id], signings + signed
        end

        -- The phone heard all of it, and every cell is still one it may use, yet it checked each signature at most once:
        -- a few dozen checks, where it used to make one each time it heard a cell.
        expect(counts.checked <= signings and counts.checked >= #acme.towers * 2)
            :describe(("Checked %d of %d signatures, %d sent"):format(counts.checked, signings, sent)):eq(true)
        expect(counts.checked * 6 <= sent):eq(true)
        expect(counts.failed):eq(0)
        expect(phone.state):eq("attached")
        local now = net.time
        for _, tower in ipairs(acme.towers) do
            expect(phone:usable(tower.id, phone.cells[tower.id], "ACME", now)):describe("Cell " .. tower.id):eq(true)
        end
    end)

    it("is still refused when anything a cell signed was changed", function()
        math.randomseed(2)
        local acme = operator { 0 }
        local net = acme.net
        local phone = acme.add_phone(1, 10)
        local heard = ears(acme, 99, 10)
        net.advance(5)
        expect(phone.state):eq("attached")
        local events = #phone.events
        local counts = counting(phone)

        -- Sent at once, before the cell sends anything more.
        local function send(body)
            acme.inject(phone.stack, { net = 1, src = 11, dst = -1, type = common.FRAME, body = body })
            net.run()
        end

        -- What the cell sent last, which the phone checked: sent again, exactly, it needn't be checked again.
        local real = heard.last[11]
        expect(real.cell):eq(11)
        send(real)
        expect(counts.checked):eq(0)

        -- But with anything else changed, keeping the signature, it's checked, and refused.
        local carrier = bands.carrier(acme.carrier)
        local other_carrier
        for _, channel in ipairs(bands.beacon_channels()) do
            if channel ~= acme.carrier then
                other_carrier = channel
                break
            end
        end
        -- And with the signature of something else the cell signed.
        local older = common.make_sib {
            network = "ACME", certificate = real.networks[1].cert, cell = 11, area = real.area, load = real.load,
            time = real.time - 5000, ul = real.ul, interval = real.interval, sign = acme.towers[1].sign,
        }
        local cases = {
            { time = real.time + 1000 }, { time = real.time - 1000 }, { load = 0.5 }, { area = real.area + 1 },
            { ul = real.ul < carrier.uplink[2] and real.ul + 1 or real.ul - 1 }, { interval = 2 },
            { pos = { 1, 2, 3 } }, { service = "sms" }, { name = "FAKE" },
            { part = { path = { phone.stack.id } } }, { part = { carriers = { other_carrier } } },
            { part = { sig = older.networks[1].sig } },
        }
        for _, case in ipairs(cases) do
            local body = copy(real)
            for key, value in pairs(case) do
                if key == "part" then
                    for k, v in pairs(value) do body.networks[1][k] = v end
                else
                    body[key] = value
                end
            end
            local before = counts.failed
            send(body)
            expect(counts.failed):describe(textutils.serialise(case, { compact = true })):eq(before + 1)
            yield()
        end
        expect(counts.checked):eq(#cases)

        -- None of it changed what the phone knows of the cell, or did anything.
        local cell = phone.cells[11]
        expect({ cell.area, cell.interval, cell.ul, cell.service, cell.networks.ACME.path }):same {
            real.area, real.interval, real.ul, nil, nil,
        }
        expect(phone.carriers[other_carrier] == nil or phone.carriers[other_carrier].ACME == nil):eq(true)
        expect(phone.state):eq("attached")
        expect(#phone.events):eq(events)

        -- What the cell really sent is still known to be good.
        send(real)
        expect(counts.checked):eq(#cases)
        net.advance(5)
        expect(phone.state):eq("attached")
        expect(phone:usable(11, phone.cells[11], "ACME", net.time)):eq(true)
    end)
end)
