-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Phones told which bands they may use, or pinned to one cell: for where a phone's own choice of cell isn't the one
its user wants, as for a relay, whose phone is its cell's way to the core. ]]

describe("Phones told which cells they may use", function()
    local helpers = require "support.net_helpers"
    local bands = require "cc.internal.net.bands"
    local operator = require "support.cell_network".operator

    local ip, hex = helpers.ip, helpers.hex
    local wait_until = helpers.wait_until
    local B20_1, B3_1 = bands.parse_carrier("b20/1"), bands.parse_carrier("b3/1")

    local function kinds(phone, from)
        local list = {}
        for i = from, #phone.events do list[#list + 1] = phone.events[i].kind end
        return list
    end

    it("use only the bands they may, and listen on no others", function()
        math.randomseed(1)
        -- Cell 11 on band 20, and cell 12 on band 3, both near the phone.
        local acme = operator({ 0, 20 }, { carriers = { "b20/1", "b3/1" }, bands = { "b20", "b3" } })
        local net = acme.net
        local phone, stack = acme.add_phone(1, 5)
        -- Left to itself, it uses band 3, which is strong enough.
        wait_until(net, function() return phone.state == "attached" and phone.cell == 12 end, 15, "Using band 3")
        expect(phone:info().bands):eq(nil)
        local events = #phone.events

        phone:restrict({ "b20" })
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 15, "Using band 20")
        expect(kinds(phone, events + 1)):same { "lost", "attached" }
        expect(phone:info().bands):same { "b20" }
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        -- It doesn't listen on band 3 any more, so it's never asked to move up to it.
        net.advance(15)
        expect(phone.cell):eq(11)
        expect(phone.listening[B3_1]):eq(nil)
        expect(phone.listening[B20_1]):eq(true)
        for channel in pairs(phone.listening) do expect((bands.of(channel))):eq("b20") end

        -- A band with no cells is no service: it listens there, and nowhere else.
        phone:restrict({ "b7", "b1", "b33", 5 })
        expect(phone.state):eq("searching")
        expect(phone:info().bands):same { "b1", "b7" }
        net.advance(10)
        expect(phone.state):eq("searching")
        local listened = {}
        for channel in pairs(phone.listening) do
            local band = bands.of(channel)
            listened[band] = true
        end
        expect(listened):same { b1 = true, b7 = true }

        -- Any band again: back to band 3. (Names which are no bands are as good as none.)
        phone:restrict({ "b33" })
        expect(phone:info().bands):eq(nil)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 12 end, 20, "Using band 3 again")
        expect(net.errors):same {}
    end)

    it("use only the cell they're pinned to, and have no service without it", function()
        math.randomseed(2)
        local acme = operator { 0, 100 }
        local net = acme.net
        local phone, stack = acme.add_phone(1, 10)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 20, "Attaching")
        local events = #phone.events

        -- Pinned to the cell further away, it uses that one, however much stronger the other is.
        phone:restrict(nil, 12)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 12 end, 15, "Using the pinned cell")
        expect(kinds(phone, events + 1)):same { "lost", "attached" }
        expect(phone.cells[11].signal > phone.cells[12].signal + 30):eq(true)
        expect(phone:info().pinned):eq(12)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        net.advance(15)
        expect(phone.cell):eq(12)
        expect(#phone.events):eq(events + 2)
        wait_until(net, function() return acme.core.sessions[hex(phone.sim.public)].cell == 12 end, 10, "The core hearing of it")

        -- Out of its reach, there's no service, though the other cell is right there.
        acme.positions[1] = -15
        wait_until(net, function() return phone.state == "searching" end, 30, "Losing the pinned cell")
        net.advance(15)
        expect(phone.state):eq("searching")
        expect(phone.heard[11] ~= nil and phone.heard[11].signal > -70):eq(true)

        -- Let go, it uses what's there; and pinned to the cell it's on, it just stays.
        phone:restrict(nil, nil)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 15, "Using the other cell")
        events = #phone.events
        phone:restrict(nil, 11)
        net.advance(5)
        expect({ phone.state, phone.cell, #phone.events }):same { "attached", 11, events }
        -- Pinned, it isn't handed over either, as it's carried towards the other cell.
        acme.positions[1] = 95
        net.advance(20)
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        expect(net.errors):same {}
    end)

    it("start as they were told, and may be pinned to a cell on a band they may not use", function()
        math.randomseed(3)
        local acme = operator({ 0, 20 }, { carriers = { "b20/1", "b3/1" }, bands = { "b20", "b3" } })
        local net = acme.net
        local pinned = acme.add_phone(1, 5, true, { pinned = 11 })
        local low = acme.add_phone(2, 5, true, { bands = { "b20" } })
        -- Pinned to band 3's cell, but only allowed band 20: nothing will do.
        local neither = acme.add_phone(3, 5, true, { bands = { "b20" }, pinned = 12 })
        wait_until(net, function() return pinned.state == "attached" and low.state == "attached" end, 15, "Attaching")
        net.advance(10)
        expect({ pinned.cell, low.cell, neither.state }):same { 11, 11, "searching" }
        expect({ pinned:info().pinned, low:info().bands }):same { 11, { "b20" } }
        expect(low.listening[B3_1]):eq(nil)
        expect(net.errors):same {}
    end)

    it("are a relay's way to the core through the cell its user chose", function()
        math.randomseed(4)
        -- The relay is nearer cell 11, but is to reach the core through cell 12.
        local acme = operator { 0, 60 }
        local net = acme.net
        local relay = acme.add_relay(30, 20, nil, { pinned = 12 })
        wait_until(net, function() return relay.tower ~= nil and #relay.tower.links.ACME.path == 1 end, 60, "The relay's cell")
        expect(relay.phone.cell):eq(12)
        expect(relay.cells):same { 12 }
        expect(acme.core:path_of(30)):same { 12 }
        expect(relay.tower.links.ACME.path):same { 12 }

        -- A phone behind it reaches the network through both.
        local phone, stack = acme.add_phone(1, -60)
        wait_until(net, function()
            local session = acme.core.sessions[hex(phone.sim.public)]
            return phone.state == "attached" and phone.cell == 30 and session and session.cell == 30
        end, 30, "Using the relay")
        expect(net.ping(stack, ip("10.0.0.60")).error):eq(nil)
        net.advance(10)
        expect(relay.phone.cell):eq(12)
        expect(net.errors):same {}
    end)
end)
