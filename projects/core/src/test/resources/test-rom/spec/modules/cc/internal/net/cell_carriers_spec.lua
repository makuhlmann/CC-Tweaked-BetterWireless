-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cells on carriers: each network's cells on its own 5MHz of a band, each cell reached on an uplink channel of its
own, and each phone sent its frames on a downlink channel of its own, so nobody is handed what isn't for them. ]]

describe("Cellular carriers", function()
    local helpers = require "support.net_helpers"
    local bands = require "cc.internal.net.bands"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local ip = helpers.ip
    local wait_until = helpers.wait_until

    -- How many frames a computer was handed from another.
    local function heard(net, stack, from)
        return net.from[stack] and net.from[stack][from] or 0
    end


    it("keeps networks, cells and phones apart on their channels", function()
        math.randomseed(1)
        -- ACME's cells 11 and 12, and BETA's 21, all within range of each other and of ACME's two phones.
        local acme = operator { 0, 60 }
        local beta = operator({ 30 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
        })
        local net = acme.net
        local one, one_stack = acme.add_phone(1, 5)
        local two, two_stack = acme.add_phone(2, 6)
        net.advance(5)
        expect({ one.state, one.cell, two.state, two.cell }):same { "attached", 11, "attached", 11 }

        -- Each network's cells are on its carrier, each reached on a channel of its own.
        local cell, neighbour = acme.towers[1].tower, acme.towers[2].tower
        expect(bands.carrier_name(cell.carrier)):eq("b20/1")
        expect(bands.carrier_name(neighbour.carrier)):eq("b20/1")
        expect(bands.carrier_name(beta.towers[1].tower.carrier)):eq("b20/2")
        expect(cell.ul ~= neighbour.ul):eq(true)

        -- Each phone has a downlink channel of its own, which the other doesn't listen on.
        expect(one.here.dl ~= nil and two.here.dl ~= nil and one.here.dl ~= two.here.dl):eq(true)
        expect(two_stack:hears("air", one.here.dl)):eq(false)
        expect(cell.phones[1].dl_heard and cell.phones[2].dl_heard):eq(true)

        -- From now on, while phones talk to the network: phones are handed nothing of the other network's cell, nor
        -- each other's frames; cells nothing of each other's.
        net.from, net.not_for = {}, {}
        for _ = 1, 10 do
            expect(net.ping(one_stack, ip("10.0.0.60"))):matches { done = true }
            net.advance(1)
        end
        expect(heard(net, one_stack, 21)):eq(0)
        expect(heard(net, one_stack, 2)):eq(0)
        expect(heard(net, two_stack, 1)):eq(0)
        expect(heard(net, cell.stack, 12)):eq(0)
        expect(heard(net, neighbour.stack, 11)):eq(0)
        -- But their own cell, of course.
        expect(heard(net, one_stack, 11) > 0):eq(true)
        expect(heard(net, cell.stack, 1) > 0):eq(true)
        -- Nobody was handed a frame for someone else: phone two none of phone one's packets.
        for _, stack in ipairs { one_stack, two_stack, cell.stack, neighbour.stack } do
            expect(net.not_for[stack] or 0):describe("Frames for others handed to #" .. stack.id):eq(0)
        end
        expect(net.errors):same {}
    end)

    it("gives a phone a downlink channel at each cell it's handed over to", function()
        math.randomseed(2)
        local acme = operator { 0, 100 }
        local net = acme.net
        local phone, stack = acme.add_phone(1, 10)
        net.advance(5)
        expect(phone.cell):eq(11)
        local first = acme.towers[1].tower

        acme.positions[1] = 95
        wait_until(net, function() return phone.cell == 12 and phone.here.dl ~= nil end, 30, "Handover")
        local second = acme.towers[2].tower
        wait_until(net, function() return second.phones[1] and second.phones[1].dl_heard end, 10, "Saying it's listening")
        expect(phone.here.dl):eq(second.phones[1].dl)
        local block = bands.carrier(second.carrier).downlink
        expect(phone.here.dl >= block[1] and phone.here.dl <= block[2]):eq(true)
        -- The first cell has forgotten it, and its channel is free again.
        wait_until(net, function() return first.phones[1] == nil end, 10, "The first cell forgetting the phone")
        expect(next(first.downlinks)):eq(nil)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)

    it("waits longer for cells which send system information less often", function()
        math.randomseed(3)
        -- The default: every two seconds.
        local acme = operator({ 0, 300 }, { interval = common.DEFAULT_INTERVAL })
        local net = acme.net
        local phone = acme.add_phone(1, 10)
        wait_until(net, function() return phone.state == "attached" end, 10, "Attaching")
        expect(acme.towers[1].tower.interval):eq(2)
        expect(phone.cells[11].interval):eq(2)

        -- The cell goes quiet. Four seconds without it would be enough at one second, but not at two: three
        -- intervals.
        local last = phone.cells[11].networks.ACME.heard
        net.remove(acme.towers[1].stack)
        wait_until(net, function() return phone.state ~= "attached" end, 20, "Losing the cell")
        expect(net.time - last >= 6):describe("Gave up after " .. (net.time - last)):eq(true)
    end)

    it("sends system information on a network's carriers, as often as its core says", function()
        math.randomseed(4)
        local acme = operator({ 0 }, { carriers = { "b3/2", "b20/3" }, interval = 3 })
        local net = acme.net
        net.advance(1)
        local tower = acme.towers[1].tower
        -- The cell is on the network's first carrier (it asked for no band), and names both.
        expect(bands.carrier_name(tower.carrier)):eq("b3/2")
        expect(tower.interval):eq(3)
        expect(tower.links.ACME.carriers):same { bands.parse_carrier("b3/2"), bands.parse_carrier("b20/3") }

        -- A phone hears it there, and listens for the network on both carriers once attached.
        local phone = acme.add_phone(1, 10)
        wait_until(net, function() return phone.state == "attached" end, 15, "Attaching")
        expect(phone.listening[bands.parse_carrier("b3/2")]):eq(true)
        expect(phone.listening[bands.parse_carrier("b20/3")]):eq(true)
        expect(phone.listening[bands.parse_carrier("b20/1")]):eq(nil)
    end)

    it("puts cells in the band they ask for, and refuses one the network has no carrier in", function()
        math.randomseed(5)
        local acme = operator({ 0, 50 }, { carriers = { "b20/1", "b3/1" }, bands = { "b3", "b7" } })
        local net = acme.net
        wait_until(net, function() return acme.towers[2].service:info().state == "refused" end, 10, "Refusing the cell")
        expect(acme.towers[2].service:info().error):eq("ACME has no carrier in band b7")
        expect(bands.carrier_name(acme.towers[1].tower.carrier)):eq("b3/1")
        expect(acme.towers[2].tower):eq(nil)
    end)

    it("prefers a higher band where it's strong enough, and a lower one where it isn't", function()
        math.randomseed(6)
        -- Cell 11 on band 20 (800MHz) at 0, cell 12 on band 3 (1800MHz) at 20.
        local acme = operator({ 0, 20 }, { carriers = { "b20/1", "b3/1" }, bands = { "b20", "b3" } })
        local net = acme.net
        local phone, stack = acme.add_phone(1, 5)
        -- Band 3's cell is weaker here, but strong enough: it ends up there (moving up from band 20's, if it heard
        -- that first).
        wait_until(net, function() return phone.state == "attached" and phone.cell == 12 end, 15, "Using band 3")
        expect(phone.cells[11].signal > phone.cells[12].signal):eq(true)
        net.advance(5)
        expect(phone.cell):eq(12)
        local events = #phone.events

        -- Further away, band 20's is stronger still, but band 3's is good enough to stay on.
        acme.positions[1] = -60
        net.advance(10)
        expect(phone.cell):eq(12)

        -- Further, band 3's is too weak: it moves down.
        acme.positions[1] = -78
        wait_until(net, function() return phone.cell == 11 end, 20, "Moving down a band")
        expect(#phone.events):eq(events + 1)
        expect(phone.events[#phone.events].kind):eq("handover")

        -- Back again, band 3's is strong enough once more: it moves up.
        acme.positions[1] = 5
        wait_until(net, function() return phone.cell == 12 end, 20, "Moving up a band")
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)

    it("only takes system information which says how to reach the cell", function()
        local good = {
            op = "sib", cell = 5, area = 1, load = 0, time = 0, ul = 8320, interval = 2,
            networks = { { network = "ACME", carriers = { 7935, 18075 } } },
        }
        expect(common.sib_networks(good, 5)):same { good.networks[1] }

        local function with(field, value)
            local sib = {}
            for k, v in pairs(good) do sib[k] = v end
            sib[field] = value
            return common.sib_networks(sib, 5)
        end
        -- No uplink channel, a downlink one, one beyond any carrier, or something else.
        for _, ul in ipairs { false, 7920, 4580, 8320.5, "8320" } do expect(with("ul", ul or nil)):eq(nil) end
        -- Intervals phones would wait too long (or not long enough) for.
        for _, interval in ipairs { false, 0.1, 11, 300, "2" } do expect(with("interval", interval or nil)):eq(nil) end
        -- Only messages, or everything.
        expect(with("service", "sms")):same { good.networks[1] }
        expect(with("service", "voice")):eq(nil)
        expect(with("pos", { 1, 64, -20 })):same { good.networks[1] }
        expect(with("pos", { 1, 64 })):eq(nil)
        expect(with("pos", { 1, 64, 0.5 })):eq(nil)

        -- A network naming carriers which aren't is left out, the others kept.
        local mixed = with("networks", {
            { network = "ACME", carriers = { 7936 } }, { network = "BETA", carriers = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } },
            { network = "GAMMA", carriers = { 7985 } },
        })
        expect(mixed):same { { network = "GAMMA", carriers = { 7985 } } }
    end)
end)
