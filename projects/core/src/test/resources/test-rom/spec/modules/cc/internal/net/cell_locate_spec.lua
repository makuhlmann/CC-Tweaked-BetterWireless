-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Phones working out where they are from cells which say where they are, as GPS does from its hosts. ]]

describe("Cellular positions", function()
    local operator = require "support.cell_network".operator
    local wait_until = require "support.net_helpers".wait_until

    -- Four of ACME's cells, at different heights, around a phone at 20, 64, 30.
    local cells = { { 0, 80, 0 }, { 60, 100, 0 }, { 0, 60, 60 }, { 60, 90, 60 } }
    local here = { 20, 64, 30 }

    local function distance(a, b)
        return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    end

    it("works out where a phone is from cells which say where they are", function()
        math.randomseed(1)
        local acme = operator(cells)
        local phone = acme.add_phone(1, here)
        acme.net.advance(5)
        expect(phone.state):eq("attached")
        expect(acme.towers[2].tower.pos):same { 60, 100, 0 }
        expect({ phone:locate() }):same { 20, 64, 30, 0 }

        -- The phone says where each cell says it is, and how far away it was.
        local heard
        for _, cell in ipairs(phone:info().heard) do
            if cell.id == acme.towers[2].id then heard = cell end
        end
        expect(heard.pos):same { 60, 100, 0 }
        expect(math.abs(heard.distance - distance({ 60, 100, 0 }, here)) < 1e-9):eq(true)
        expect(acme.net.errors):same {}
    end)

    it("works out how a phone is moving, and is exact again once it stops", function()
        math.randomseed(2)
        local acme = operator(cells)
        local phone = acme.add_phone(1, here)
        acme.net.advance(5)

        -- Walking along at 2 blocks a second, hearing each cell every second.
        local x = here[1]
        for _ = 1, 60 do
            x = x + 0.2
            acme.positions[1] = { x, 64, 30 }
            acme.net.advance(0.1)
        end
        local lx, ly, lz, off = phone:locate()
        local miss = distance({ lx, ly, lz }, { x, 64, 30 })
        expect(off > 0):describe("The error, " .. tostring(off)):eq(true)
        expect(miss <= off):describe(("Off by %.2f, said %.2f"):format(miss, off)):eq(true)
        -- No more than it could have gone another way since it last heard three cells, and then some.
        expect(off < 5):describe("The error, " .. tostring(off)):eq(true)

        -- Standing still, it's exact once each cell has been heard twice from where it stands.
        acme.net.advance(3)
        expect({ phone:locate() }):same { math.floor(x * 100 + 0.5) / 100, 64, 30, 0 }
    end)

    it("only takes other networks' cells' word for it when its own aren't enough", function()
        -- BETA shares ACME's carrier, so ACME's phones hear its cells while attached.
        local function beta_options(join)
            return {
                join = join, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
                carriers = { "b20/1" },
            }
        end

        math.randomseed(3)
        local acme = operator(cells)
        local beta = operator({ { 30, 70, 30 } }, beta_options(acme))
        -- BETA's cell says it's somewhere it isn't. Anyone's could: only our own network's system information is checked.
        wait_until(acme.net, function() return beta.towers[1].tower end, 10, "BETA's cell starting")
        beta.towers[1].tower.pos = { 500, 64, 500 }
        local phone = acme.add_phone(1, here)
        acme.net.advance(5)
        expect(phone.state):eq("attached")
        expect(phone.heard[beta.towers[1].id].pos):same { 500, 64, 500 }
        expect({ phone:locate() }):same { 20, 64, 30, 0 }

        -- With only two of its own, it takes the others' word too.
        math.randomseed(4)
        local few = operator({ cells[1], cells[2] })
        operator({ cells[3], cells[4] }, beta_options(few))
        local other = few.add_phone(1, here)
        few.net.advance(5)
        expect(other.state):eq("attached")
        expect({ other:locate() }):same { 20, 64, 30, 0 }
    end)

    it("works out where a computer without a SIM is, from any cells", function()
        math.randomseed(6)
        local acme = operator(cells)
        local phone = acme.add_phone(1, here, false, { activated = false })
        acme.net.advance(5)
        expect(phone.state):eq("inactive")
        expect({ phone:locate() }):same { 20, 64, 30, 0 }
    end)

    it("can't tell where it is without cells which say where they are", function()
        math.randomseed(5)
        local acme = operator { 0, 60 }
        local phone = acme.add_phone(1, 30)
        acme.net.advance(5)
        expect({ phone:locate() }):same { nil, "Too few cells around say where they are" }
    end)
end)
