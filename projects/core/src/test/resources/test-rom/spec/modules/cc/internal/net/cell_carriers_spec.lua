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

        -- Someone sends an attach in phone one's name: the cell sends its frames on the beacon channel again, which
        -- every phone hears, but only until the phone's next packet, which says where it listens.
        expect(cell.phones[1].dl_heard):eq(true)
        cell.phones[1].dl_heard = false
        net.not_for = {}
        expect(net.ping(one_stack, ip("10.0.0.60"))):matches { done = true }
        expect(cell.phones[1].dl_heard):eq(true)
        expect(net.not_for[two_stack] or 0):eq(0)
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

    it("puts cells in the band they ask for, and has one the network has no carrier for wait", function()
        math.randomseed(5)
        local acme = operator({ 0, 50 }, { carriers = { "b20/1", "b3/1" }, bands = { "b3", "b7" } })
        local net = acme.net
        local waiting = acme.towers[2]
        wait_until(net, function() return waiting.service:info().state == "unplaced" end, 10, "Waiting for a carrier")
        expect(waiting.service:info().links[1].unplaced):same { "b7" }
        expect(acme.service:no_carrier(acme.service.standby[12].unplaced)):eq("ACME has no carrier in band b7")
        expect(bands.carrier_name(acme.towers[1].tower.carrier)):eq("b3/1")
        expect(waiting.tower):eq(nil)
        -- It takes one as soon as there is one.
        acme.set_carriers({ "b20/1", "b3/1", "b7/2" })
        wait_until(net, function() return waiting.tower ~= nil end, 10, "Taking the carrier")
        expect(bands.carrier_name(waiting.tower.carrier)):eq("b7/2")
        expect(acme.towers[1].tower.stopped):eq(nil)
    end)

    it("may have more carriers than any site serves, and puts each site on those it asks for", function()
        math.randomseed(7)
        -- Every carrier of bands 20 and 3: more than a site may run cells on.
        local names = {}
        for _, band in ipairs { "b20", "b3" } do
            for i in ipairs(bands.raster(band)) do names[#names + 1] = ("%s/%d"):format(band, i) end
        end
        expect(#names > common.MAX_CARRIERS):eq(true)
        -- A site with a cell in each band, one on a carrier of band 3 it names, and one which doesn't say.
        local acme = operator({ 0, 20, 40 }, { carriers = names, bands = { { "b20", "b3" }, { "b3/12" } } })
        local net = acme.net
        local cells = acme.service.cells
        wait_until(net, function() return cells[11] and cells[12] and cells[13] end, 10, "Putting the cells on carriers")
        expect(#acme.service:spectrum()):eq(#names)

        local function carriers_of(id)
            local result = {}
            for i, cell in ipairs(cells[id].cells) do result[i] = bands.carrier_name(cell.carrier) end
            return result
        end
        local first, second, third = carriers_of(11), carriers_of(12), carriers_of(13)
        expect({ #first, first[1]:match("^b%d+"), first[2]:match("^b%d+") }):same { 2, "b20", "b3" }
        expect(second):same { "b3/12" }
        expect(#third):eq(1)
        -- No two of them share a carrier: there are plenty.
        local seen = {}
        for _, name in ipairs { first[1], first[2], second[1], third[1] } do
            expect(seen[name]):describe(name .. " is used twice"):eq(nil)
            seen[name] = true
        end

        -- Cells name every one of the network's carriers, and a phone listens for the network on them all.
        expect(#acme.towers[1].tower.links.ACME.carriers):eq(#names)
        local phone = acme.add_phone(1, 10)
        wait_until(net, function() return phone.state == "attached" end, 15, "Attaching")
        for _, name in ipairs(names) do
            expect(phone.listening[bands.parse_carrier(name)]):describe("Listening on " .. name):eq(true)
        end

        -- A network may have every carrier there is, but no more.
        local all = {}
        for _, carrier in ipairs(bands.beacon_channels()) do all[#all + 1] = bands.carrier_name(carrier) end
        expect(acme.service:set_spectrum(all)):eq(true)
        expect(#acme.service:spectrum()):eq(common.MAX_SPECTRUM)
        all[#all + 1] = "b20/1"
        expect({ acme.service:set_spectrum(all) })
            :same { nil, ("A network has up to %d carriers"):format(common.MAX_SPECTRUM) }
        expect(net.errors):same {}
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
        acme.positions[1] = -20
        net.advance(10)
        expect(phone.cell):eq(12)

        -- Further, band 3's is no longer strong: it moves down, handed over while band 3's cell is still well within
        -- reach, rather than losing it.
        acme.positions[1] = -44
        wait_until(net, function() return phone.cell == 11 end, 20, "Moving down a band")
        expect(#phone.events):eq(events + 1)
        expect(phone.events[#phone.events].kind):eq("handover")
        expect(phone.cells[12].signal >= -85):eq(true)

        -- Back again, band 3's is strong enough once more: it moves up.
        acme.positions[1] = 5
        wait_until(net, function() return phone.cell == 12 end, 20, "Moving up a band")
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)

    it("uses a nearby cell on a low band rather than a far one on a high band", function()
        math.randomseed(8)
        -- Cell 11 on band 8 (900MHz) at 0, cell 12 on band 1 (2100MHz) at 70.
        local acme = operator({ 0, 70 }, { carriers = { "b8/1", "b1/1" }, bands = { "b8", "b1" } })
        local net = acme.net
        -- Beside band 8's cell, band 1's can be heard, with bars to spare: but it isn't strong, and behind the next
        -- wall it would be gone. The phone uses the cell beside it, whichever it heard first.
        local phone, stack = acme.add_phone(1, 6)
        wait_until(net, function() return phone.state == "attached" and phone.cells[11] and phone.cells[12] end, 15, "Hearing both")
        net.advance(10)
        expect(phone.cell):eq(11)
        expect({ phone.cells[12].signal > -90, phone.cells[12].signal < -70 }):same { true, true }

        -- Nearer the other, it stays until band 1's is strong, and is then handed up.
        acme.positions[1] = 28
        net.advance(10)
        expect(phone.cell):eq(11)
        acme.positions[1] = 44
        wait_until(net, function() return phone.cell == 12 end, 20, "Moving up a band")
        -- And handed down again in good time, on the way back.
        acme.positions[1] = 20
        wait_until(net, function() return phone.cell == 11 end, 20, "Moving down a band")
        expect(phone.events[#phone.events]):matches { kind = "handover", from = 12, to = 11 }
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
        -- A cell site's name: 1 to 8 printable characters, not starting or ending with a space.
        expect(with("name", "Old Mill")):same { good.networks[1] }
        for _, name in ipairs { "", "NINE-CHAR", " HILL", "HILL ", "HILL\n", "H\195\164GE", 5 } do
            expect(with("name", name)):describe(tostring(name)):eq(nil)
        end

        -- A network's name: up to 32 printable characters but ", read without the spaces at its ends.
        expect(with("networks", { { network = "Old Mill Co., Ltd." } })):same { { network = "Old Mill Co., Ltd." } }
        expect(with("networks", { { network = "  ACME \t", carriers = { 7935 }, cert = "c", sig = "s" } }))
            :same { { network = "ACME", carriers = { 7935 }, cert = "c", sig = "s" } }
        expect(with("networks", { { network = " " .. ("A"):rep(32) .. " " } })):same { { network = ("A"):rep(32) } }
        for _, network in ipairs { "", "   ", 'A "B"', "A\0B", "A\tB", ("A"):rep(33), "H\195\164GE", 5 } do
            expect(with("networks", { { network = network } })):describe(tostring(network)):same {}
        end
        -- Names which are the same without their spaces are one network: the first.
        expect(with("networks", { { network = "ACME ", sig = "a" }, { network = "ACME", sig = "b" } }))
            :same { { network = "ACME", sig = "a" } }

        -- A network naming carriers which aren't is left out, the others kept.
        local mixed = with("networks", {
            { network = "ACME", carriers = { 7936 } }, { network = "BETA", carriers = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } },
            { network = "GAMMA", carriers = { 7985 } },
        })
        expect(mixed):same { { network = "GAMMA", carriers = { 7985 } } }
    end)

    it("says its site's name, signed with the rest, which phones hear at once", function()
        math.randomseed(3)
        -- Cell 11's site has a name, and cell 12's none.
        local acme = operator({ 0, 20 }, { names = { "Old Mill" } })
        local net = acme.net
        local phone = acme.add_phone(1, 5)
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        local function names()
            local result = {}
            for _, cell in ipairs(phone:info().heard) do result[cell.id] = cell.name or false end
            return result
        end
        expect(names()):same { [11] = "Old Mill", [12] = false }

        -- The name is signed: one changed on the way doesn't check out.
        local carrier, sibs = acme.towers[1].tower.carrier, {}
        local listener = net.stack(99)
        acme.positions[99] = 0
        listener:add_interface("ears", "air", "wireless", {
            band = "test", listen = { carrier }, reply = carrier, to = function() return nil end,
        })
        listener:on_frame(common.FRAME, function(_, src, body)
            if type(body) == "table" and body.op == "sib" then sibs[src] = body end
        end, true)
        net.advance(2)
        local sib = sibs[11]
        expect(sib.name):eq("Old Mill")
        local options = { network = "ACME", signing = acme.signing_public, now = acme.now(), sender = 11 }
        expect(common.check_sib(crypto, sib, common.sib_networks(sib, 11)[1], options)):eq(true)
        sib.name = "Old Mil1"
        expect({ common.check_sib(crypto, sib, common.sib_networks(sib, 11)[1], options) }):same { nil, "bad signature" }
        sib.name = "Old Mill"
        -- Spaces put at the ends of the network's name on the way are taken off again: it's the name its core signed.
        sib.networks[1].network = " ACME "
        local entry = common.sib_networks(sib, 11)[1]
        expect(entry.network):eq("ACME")
        expect(common.check_sib(crypto, sib, entry, options)):eq(true)
        expect(sib.networks[1].network):eq(" ACME ")

        -- Renamed (or no longer named) while it runs, it says so at once, and its phones keep their service.
        acme.towers[1].service:configure { area = 1, name = "HILL-1" }
        net.advance(2)
        expect(names()):same { [11] = "HILL-1", [12] = false }
        acme.towers[1].service:configure { area = 1 }
        net.advance(2)
        expect(names()):same { [11] = false, [12] = false }
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        expect(net.errors):same {}
    end)
end)
