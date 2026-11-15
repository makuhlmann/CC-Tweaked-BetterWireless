-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cell sites with several bands: one computer running a cell on each of several carriers, each a cell of its own to
phones, with an ID of its own. ]]

describe("Cell sites with several bands", function()
    local helpers = require "support.net_helpers"
    local network = require "support.virtual_network"
    local bands = require "cc.internal.net.bands"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local ip, hex = helpers.ip, helpers.hex
    local wait_until = helpers.wait_until

    local B20_1, B20_2 = bands.parse_carrier("b20/1"), bands.parse_carrier("b20/2")
    local B3_1, B3_2 = bands.parse_carrier("b3/1"), bands.parse_carrier("b3/2")

    -- Each of a computer's towers, by its carrier's name.
    local function on(entry)
        local result = {}
        for id, tower in pairs(entry.towers or {}) do
            if not tower.stopped then result[bands.carrier_name(tower.carrier)] = id end
        end
        return result
    end

    -- Have higher bands fade sooner, as they do in the game: band 3 is 12dB weaker than band 20 everywhere.
    local function fade_band_3(net)
        local reach = net.reach
        net.reach = function(link, sender, receiver, channel)
            local signal = reach(link, sender, receiver)
            if signal and link == "air" and bands.of(channel) == "b3" then
                signal = signal - 12
                if signal < -110 then return false end
            end
            return signal
        end
    end

    -- The phone's session, as its core has it.
    local function session(setup, phone)
        return setup.core.sessions[hex(phone.sim.public)]
    end

    describe("give each of a computer's cells an ID", function()
        it("made from the computer's ID and the cell's carrier", function()
            -- A computer's first cell has the computer's ID, as every cell did.
            expect({ common.site_of(11) }):same { 11 }
            expect(common.cell_label(11)):eq("11")

            local id = common.carrier_cell(11, B3_2)
            expect(id > 2 ^ 31 and id < 2 ^ 53 and id % 1 == 0):eq(true)
            expect(common.is_id(id)):eq(true)
            expect({ common.site_of(id) }):same { 11, B3_2 }
            expect(common.cell_label(id)):eq("11 b3/2")
            -- What isn't an ID (another computer may say anything) is shown as it is.
            expect({ common.cell_label("x"), common.cell_label(nil), common.cell_label(1.5), common.cell_label(-1) })
                :same { "x", "nil", "1.5", "-1" }
            expect(common.cell_label({})):str_match("^table")
            -- However big the computer's ID, and whichever the carrier, no two cells share one.
            local seen = {}
            for _, site in ipairs { 0, 1, 11, 2 ^ 31 - 1 } do
                for _, carrier in ipairs(bands.beacon_channels()) do
                    local cell = common.carrier_cell(site, carrier)
                    expect(seen[cell]):eq(nil)
                    seen[cell] = true
                    expect({ common.site_of(cell) }):same { site, carrier }
                    -- It's written out in full, as certificates and keys have it.
                    expect(tonumber(("%d"):format(cell))):eq(cell)
                    expect(common.cell_name("ACME", cell)):eq("ACME/cell/" .. ("%d"):format(cell))
                end
            end
        end)

        it("which its frames are from and to", function()
            local net = network()
            local a, b = net.stack(1), net.stack(2)
            local own = common.carrier_cell(1, B3_1)
            a:add_interface("first", "air", "wireless", {
                band = "test", listen = { 100 }, broadcast = 200, reply = 100, to = function() return 200 end,
            })
            a:add_interface("second", "air", "wireless", {
                band = "test", listen = { 101 }, broadcast = 201, reply = 101, to = function() return 201 end, id = own,
            })
            b:add_interface("radio", "air", "wireless", {
                band = "test", listen = { 200, 201 }, reply = 200, to = function(id) return id == own and 101 or 100 end,
            })
            local got = {}
            for _, stack in ipairs { a, b } do
                stack:on_frame("test", function(interface, src, body, _, dst)
                    got[#got + 1] = { stack.id, interface.name, src, dst, body }
                end, true)
            end

            a:send_frame("first", -1, "test", "one")
            net.run()
            a:send_frame("second", -1, "test", "two")
            net.run()
            expect(got):same { { 2, "radio", 1, -1, "one" }, { 2, "radio", own, -1, "two" } }

            got = {}
            b:send_frame("radio", own, "test", "three")
            net.run()
            b:send_frame("radio", 1, "test", "four")
            net.run()
            expect(got):same { { 1, "second", 2, own, "three" }, { 1, "first", 2, 1, "four" } }

            -- Each interface only takes what's for its own ID; and nothing is from ourselves, under either.
            got = {}
            net.inject("air", 101, { net = 1, src = 2, dst = 1, type = "test", body = "for the computer" })
            net.inject("air", 100, { net = 1, src = 2, dst = own, type = "test", body = "for its other cell" })
            net.inject("air", 100, { net = 1, src = own, dst = 1, type = "test", body = "from itself" })
            net.inject("air", 101, { net = 1, src = 1, dst = own, type = "test", body = "from itself" })
            net.inject("air", 101, { net = 1, src = 2, dst = -1, type = "test", body = "for everyone" })
            net.run()
            expect(got):same { { 1, "second", 2, -1, "for everyone" } }

            local shown = {}
            for _, interface in ipairs(a:interface_info()) do shown[interface.name] = interface.id end
            expect(shown):same { first = 1, second = own }

            -- Once the interface has gone, so has its ID.
            a:remove_interface("second")
            expect(next(a.own_ids)):eq(nil)
        end)
    end)

    it("match what a site wants with the carriers there are", function()
        local function match(wants, carriers)
            local by_want = common.match_wants(wants, carriers)
            local names = {}
            for i = 1, #wants do names[i] = by_want[i] and bands.carrier_name(by_want[i]) or false end
            return names
        end
        local all = { B20_1, B20_2, B3_1, B3_2 }
        expect(match({ "b20", "b3" }, all)):same { "b20/1", "b3/1" }
        -- A band twice is two of its carriers; a third has none left.
        expect(match({ "b3", "b3", "b3" }, all)):same { "b3/1", "b3/2", false }
        -- A carrier named goes to whoever named it, whatever comes first.
        expect(match({ "b3", "b3/1", "b20/2" }, all)):same { "b3/2", "b3/1", "b20/2" }
        expect(match({ "b7", "b20/3" }, all)):same { false, false }

        expect(common.is_wants({ "b20", "b3/2", "b20" })):eq(true)
        for _, bad in ipairs { {}, { "low" }, { "b33" }, { "b3/99" }, { "b3", 5 }, { n = 1, "b3" }, "b3", { "b3", [3] = "b20" } } do
            expect(common.is_wants(bad)):eq(false)
        end
        expect(common.is_wants({ "b3", "b3", "b3", "b3", "b3", "b3", "b3", "b3", "b3" })):eq(false)
    end)

    it("run a cell on each band, each a cell of its own to phones", function()
        math.randomseed(1)
        -- Computer 11 has a cell on band 20 and one on band 3. Computer 12, further away, only on band 20.
        local acme = operator({ 0, 60 }, { carriers = { "b20/1", "b3/1", "b3/2" }, bands = { { "b20", "b3" }, "b20" } })
        local net = acme.net
        local site = acme.towers[1]
        local high = common.carrier_cell(11, B3_1)
        wait_until(net, function() return site.towers and site.towers[high] and acme.towers[2].tower end, 10, "Starting the cells")

        -- The first has the computer's ID, as ever; the other one made from the computer's and its carrier.
        expect(on(site)):same { ["b20/1"] = 11, ["b3/1"] = high }
        expect(on(acme.towers[2])):same { ["b20/1"] = 12 }
        local low, upper = site.tower, site.towers[high]
        expect({ low.id, low.interface, upper.id, upper.interface }):same { 11, "cell.tower", high, "cell.tower.b3/1" }
        expect(site.stack.interfaces["cell.tower.b3/1"].id):eq(high)
        expect(bands.carrier_of(upper.ul)):eq(B3_1)
        -- Their core knows both, at the one computer, each with its own tunnel.
        expect({ acme.core.towers[11].address, acme.core.towers[high].address }):same { site.address, site.address }
        local info = site.service:info()
        expect(info.cells):same {
            { id = 11, carrier = "b20/1", ul = low.ul }, { id = high, carrier = "b3/1", ul = upper.ul },
        }
        expect({ info.carrier, info.ul, info.state }):same { "b20/1", low.ul, "serving" }

        -- Each sends system information of its own, on its own carrier: a listener which knows nothing of sites takes
        -- each as a cell's, and checks it as any cell's.
        local listener, sibs = net.stack(99), {}
        acme.positions[99] = 0
        listener:add_interface("ears", "air", "wireless", {
            band = "test", listen = { B20_1, B3_1 }, reply = B20_1, to = function() return nil end,
        })
        listener:on_frame(common.FRAME, function(_, src, body)
            if type(body) == "table" and body.op == "sib" then sibs[src] = body end
        end, true)
        net.advance(3)
        local function fields(sib)
            local keys = {}
            for key in pairs(sib) do keys[#keys + 1] = key end
            table.sort(keys)
            return keys
        end
        for _, id in ipairs { 11, high } do
            local sib = sibs[id]
            expect(sib ~= nil):describe("System information from " .. common.cell_label(id)):eq(true)
            expect(sib.cell):eq(id)
            local networks = common.sib_networks(sib, id)
            expect(#networks):eq(1)
            expect(common.check_sib(crypto, sib, networks[1], {
                network = "ACME", signing = acme.signing_public, now = acme.now(), sender = id,
            })):eq(true)
            -- A cell's certificate is for that cell, not its neighbour on the same computer.
            expect((common.check_sib(crypto, sib, networks[1], {
                network = "ACME", signing = acme.signing_public, now = acme.now(), sender = id == 11 and high or 11,
            }))):eq(nil)
        end
        expect(fields(sibs[high])):same(fields(sibs[11]))
        expect({ sibs[11].ul, sibs[high].ul }):same { low.ul, upper.ul }

        -- A phone next to the computer hears both, and uses band 3's, which has more room and is strong enough.
        local phone, stack = acme.add_phone(1, 5)
        wait_until(net, function() return phone.state == "attached" and phone.cell == high end, 15, "Using band 3")
        wait_until(net, function() return phone.cells[11] ~= nil end, 10, "Hearing band 20's cell too")
        expect(phone.cells[11].signal):eq(phone.cells[high].signal)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        wait_until(net, function() return session(acme, phone).cell == high end, 10, "The core hearing of it")
        expect(upper.phones[1] ~= nil and low.phones[1] == nil):eq(true)
        local block = bands.carrier(B3_1).downlink
        expect(phone.here.dl >= block[1] and phone.here.dl <= block[2]):eq(true)

        -- Both are in what it has heard, each on its band.
        local heard = {}
        for _, cell in ipairs(phone:info().heard) do heard[cell.id] = { cell.band, cell.verified, cell.serving } end
        expect(heard[11]):same { "b20", true, false }
        expect(heard[high]):same { "b3", true, true }

        -- The core has one computer, with two cells; and the other, with one.
        local cells = {}
        for id, entry in pairs(acme.service.cells) do
            cells[id] = {}
            for i, cell in ipairs(entry.cells) do cells[id][i] = { cell.id, bands.carrier_name(cell.carrier), cell.ul } end
        end
        expect(cells):same {
            [11] = { { 11, "b20/1", low.ul }, { high, "b3/1", upper.ul } },
            [12] = { { 12, "b20/1", acme.towers[2].tower.ul } },
        }
        expect(net.errors):same {}
    end)

    it("hand a phone over between a site's bands, as between any two cells", function()
        math.randomseed(2)
        local acme = operator({ 0 }, { carriers = { "b20/1", "b3/1" }, bands = { { "b20", "b3" } } })
        local net = acme.net
        fade_band_3(net)
        local site = acme.towers[1]
        local high = common.carrier_cell(11, B3_1)

        local phone, stack = acme.add_phone(1, 10)
        wait_until(net, function() return phone.state == "attached" and phone.cell == high end, 15, "Using band 3")
        wait_until(net, function() return session(acme, phone).cell == high end, 10, "The core hearing of it")
        local address, events = phone.address, #phone.events

        -- Far from the site, band 3 is too weak to stay on, and band 20 still good: down it goes, without attaching again.
        acme.positions[1] = 74
        wait_until(net, function() return phone.cell == 11 end, 20, "Moving down a band")
        expect(phone.events[#phone.events]):matches { kind = "handover", from = high, to = 11 }
        expect(#phone.events):eq(events + 1)
        wait_until(net, function() return session(acme, phone).cell == 11 end, 10, "The core moving its tunnel")
        wait_until(net, function() return site.towers[high].phones[1] == nil end, 10, "Band 3's cell forgetting it")
        expect(site.tower.phones[1] ~= nil):eq(true)
        expect(phone.address):eq(address)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        local block = bands.carrier(B20_1).downlink
        wait_until(net, function() return phone.here.dl ~= nil end, 10, "A channel of its own")
        expect(phone.here.dl >= block[1] and phone.here.dl <= block[2]):eq(true)

        -- Back near it, band 3 is strong enough again: up it goes.
        acme.positions[1] = 10
        wait_until(net, function() return phone.cell == high end, 20, "Moving up a band")
        wait_until(net, function() return session(acme, phone).cell == high end, 10, "The core moving its tunnel back")
        expect(phone.address):eq(address)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }

        -- The core logged both, between the computer's two cells.
        local moves = {}
        for _, event in ipairs(acme.events) do
            if event[1] == "handover" then moves[#moves + 1] = { event[3], event[4] } end
        end
        -- (And perhaps one before them, if the phone heard band 20's cell first.)
        expect({ moves[#moves - 1], moves[#moves] }):same { { high, 11 }, { 11, high } }
        expect(net.errors):same {}
    end)

    it("go on a band's carriers as often as it's named, and on the carriers named", function()
        math.randomseed(3)
        local acme = operator({ 0, 40, 80 }, {
            carriers = { "b20/1", "b20/2", "b3/1", "b3/2" },
            bands = { { "b3", "b3", "b20/2" }, { "b3" }, { "b20", "b7", "b3", "b3", "b3" } },
        })
        local net = acme.net
        net.advance(3)
        -- Band 3 twice is both its carriers, and one of them is the computer's first cell: what it named first.
        local first = on(acme.towers[1])
        expect(acme.towers[1].tower.band):eq("b3")
        expect(first["b20/2"]):eq(common.carrier_cell(11, B20_2))
        expect({ common.site_of(first["b3/1"]), (common.site_of(first["b3/2"])) }):same { 11, 11 }
        expect(first["b3/1"] == 11 or first["b3/2"] == 11):eq(true)
        expect(first["b20/1"]):eq(nil)
        expect(acme.towers[2].tower.band):eq("b3")
        -- Each cell's uplink channel is its own, on its carrier.
        local seen = {}
        for _, entry in ipairs(acme.towers) do
            for _, tower in pairs(entry.towers) do
                expect(bands.carrier_of(tower.ul)):eq(tower.carrier)
                expect(seen[tower.ul]):eq(nil)
                seen[tower.ul] = true
            end
        end
        -- What there's no carrier for is left out, and the cell says so; the rest is served.
        expect(on(acme.towers[3])):same {
            ["b20/1"] = 13, ["b3/1"] = common.carrier_cell(13, B3_1), ["b3/2"] = common.carrier_cell(13, B3_2),
        }
        local link = acme.towers[3].service:info().links[1]
        expect({ link.state, link.unplaced }):same { "serving", { "b7", "b3" } }
        expect(acme.towers[1].service:info().links[1].unplaced):eq(nil)
        expect(acme.towers[3].service:unplaceable({ "b20", "b7", "b3" })):eq("b7")
        expect(acme.towers[3].service:unplaceable({ "b3", "b3", "b3" })):eq("b3")
        expect(acme.towers[3].service:unplaceable({ "b3", "b3/2", "b20/3" })):eq("b20/3")
        expect(acme.towers[3].service:unplaceable({ "b3", "b3", "b20", "b20/1" })):eq(nil)

        -- A computer with nothing the network has a carrier for waits, off the air, until there's one for it.
        local nothing = operator({ 0 }, {
            name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16", join = acme,
            carriers = { "b20/3" }, bands = { { "b7", "b3/1" } },
        })
        local waiting = nothing.towers[1]
        wait_until(net, function() return waiting.service:info().state == "unplaced" end, 10, "Waiting for a carrier")
        expect(waiting.service:info().links):same {
            { core = "10.0.0.2", state = "unplaced", network = "BETA", carriers = { "b20/3" }, unplaced = { "b7", "b3/1" } },
        }
        expect(nothing.service.standby[21].unplaced):same { "b7", "b3/1" }
        expect(next(waiting.towers or {})):eq(nil)
        expect(net.errors):same {}
    end)

    it("put a cell on the carrier of its band with fewest cells", function()
        math.randomseed(4)
        local acme = operator({ 0, 40, 80 }, {
            carriers = { "b3/1", "b3/2", "b20/1" }, bands = { { "b20", "b3" }, { "b3", "b20" }, { "b3", "b3" } },
        })
        acme.net.advance(3)
        -- Whichever joined first got band 3's first carrier, and the next its second: the last has one on each.
        local first, second = on(acme.towers[1]), on(acme.towers[2])
        expect(first["b20/1"] and second["b20/1"] and true):eq(true)
        expect((first["b3/1"] and second["b3/2"] or first["b3/2"] and second["b3/1"]) ~= nil):eq(true)
        local third = on(acme.towers[3])
        expect({ common.site_of(third["b3/1"]), common.site_of(third["b3/2"]), third["b20/1"] }):same { 13, 13 }
        -- Each computer's first cell is the one it asked for first.
        expect({ acme.towers[1].tower.band, acme.towers[2].tower.band }):same { "b20", "b3" }
        expect(acme.net.errors):same {}
    end)

    it("serve every network which shares them on every band", function()
        math.randomseed(5)
        -- ACME has band 20 and band 3. BETA, which only has band 20, shares ACME's computer.
        local acme = operator({ 0 }, { carriers = { "b20/1", "b3/1" }, bands = { { "b20", "b3" } } })
        local beta = operator({ 300 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            carriers = { "b20/2" },
        })
        local net = acme.net
        fade_band_3(net)
        local site = acme.towers[1]
        local high = common.carrier_cell(11, B3_1)
        wait_until(net, function() return site.towers and site.towers[high] end, 10, "Starting the cells")
        acme.add_core(1, beta)
        wait_until(net, function() return site.tower.links.BETA and site.towers[high].links.BETA end, 15, "Serving BETA")
        -- BETA's core was told where the cells are, and took them as they are: on ACME's carriers.
        expect(on(site)):same { ["b20/1"] = 11, ["b3/1"] = high }
        local served = {}
        for i, cell in ipairs(beta.service.cells[11].cells) do served[i] = { cell.id, cell.carrier, cell.ul } end
        expect(served):same { { 11, B20_1, site.tower.ul }, { high, B3_1, site.towers[high].ul } }
        local info = site.service:info()
        expect({ info.links[1].state, info.links[1].network, info.links[2].state, info.links[2].network })
            :same { "serving", "ACME", "serving", "BETA" }

        -- A phone of each network, on band 3 near the computer, and handed down to band 20 further away.
        local ours, ours_stack = acme.add_phone(1, 10)
        local theirs, theirs_stack = beta.add_phone(2, 12)
        wait_until(net, function()
            return ours.state == "attached" and ours.cell == high and theirs.state == "attached" and theirs.cell == high
        end, 20, "Using band 3")
        expect({ ours.via, theirs.via }):same { "ACME", "BETA" }
        expect(net.ping(ours_stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.ping(theirs_stack, ip("10.0.0.60"))):matches { done = true }

        acme.positions[2] = 74
        wait_until(net, function() return theirs.cell == 11 end, 20, "BETA's phone moving down a band")
        expect(theirs.events[#theirs.events]):matches { kind = "handover", from = high, to = 11 }
        wait_until(net, function() return session(beta, theirs).cell == 11 end, 10, "BETA's core moving its tunnel")
        expect(net.ping(theirs_stack, ip("10.0.0.60"))):matches { done = true }
        expect(ours.cell):eq(high)

        -- ACME's core goes: BETA's phones carry on, on both bands, and ACME's come back when its core does.
        acme.service:stop()
        wait_until(net, function() return site.tower.links.ACME == nil and site.towers[high].links.ACME == nil end, 10, "Losing ACME")
        expect(site.tower.links.BETA ~= nil and site.towers[high].links.BETA ~= nil):eq(true)
        expect(net.ping(theirs_stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)

    it("grow a cell for what only another of their networks has a carrier for", function()
        math.randomseed(6)
        -- BETA's computer wants band 20 and band 3, but BETA only has band 20: the computer says so, and serves on it.
        local acme = operator({ 300 }, { carriers = { "b20/1", "b3/1" } })
        local beta = operator({ 0 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            carriers = { "b20/2" }, bands = { { "b20", "b3" } },
        })
        local net = acme.net
        local site = beta.towers[1]
        wait_until(net, function() return site.tower ~= nil end, 10, "Starting the cell")
        expect(on(site)):same { ["b20/2"] = 21 }
        expect(site.service:info().links[1].unplaced):same { "b3" }

        -- It serves ACME too, which has a carrier in band 3: ACME's core puts a cell there. BETA's core hears of it at
        -- once, and BETA is served there too.
        local high = common.carrier_cell(21, B3_1)
        beta.add_core(1, acme)
        wait_until(net, function()
            local upper = site.towers[high]
            return upper and upper.links.ACME and upper.links.BETA and site.tower.links.ACME and site.tower.links.BETA
        end, 20, "Both networks on both bands")
        expect(on(site)):same { ["b20/2"] = 21, ["b3/1"] = high }
        local info = site.service:info()
        expect({ info.links[1].state, info.links[2].state }):same { "serving", "serving" }
        expect(#beta.service.cells[21].cells):eq(2)
        -- Each cell names the carriers of the computer's other cell, for the network which doesn't have it as its own:
        -- its phones listen for it at once.
        local low, upper = site.tower, site.towers[high]
        expect(low:carriers_of(low.links.BETA)):same { B20_2, B3_1 }
        expect(low:carriers_of(low.links.ACME)):same { B20_1, B3_1 }
        expect(upper:carriers_of(upper.links.ACME)):same { B20_1, B3_1, B20_2 }
        expect(upper.links.BETA.carriers):same { B20_2 }

        local phone, stack = beta.add_phone(1, 5)
        wait_until(net, function() return phone.state == "attached" and phone.cell == high end, 20, "Using band 3")
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)

    it("relay on several bands, and count as one computer on the way to the core", function()
        math.randomseed(7)
        local acme = operator({ 0 }, { carriers = { "b20/1", "b3/1" }, bands = { "b20" } })
        local net = acme.net
        local relay = acme.add_relay(30, 30, { "b20", "b3" })
        local high = common.carrier_cell(30, B3_1)
        wait_until(net, function() return relay.towers and relay.towers[30] and relay.towers[high] end, 60, "The relay's cells")
        expect(relay.phone.cell):eq(11)
        expect(on(relay)):same { ["b20/1"] = 30, ["b3/1"] = high }

        -- Both of the relay's cells reach the core through the cell its phone uses, and say so.
        expect(acme.core:path_of(30)):same { 11 }
        expect(acme.core:path_of(high)):same { 11 }
        wait_until(net, function() return #relay.towers[high].links.ACME.path == 1 end, 10, "The path")
        expect(relay.towers[high].links.ACME.path):same { 11 }
        -- The relay's own phone may use neither: they're both behind it.
        expect(acme.core:would_loop(30, high)):eq(true)
        expect(acme.core:would_loop(30, 30)):eq(true)
        expect(acme.core:would_loop(1, high)):eq(false)

        -- A phone nearer the relay than the first cell uses the relay's band 3 cell, and reaches the network through it.
        local phone, stack = acme.add_phone(1, 60)
        wait_until(net, function()
            local known = session(acme, phone)
            return phone.state == "attached" and phone.cell == high and known and known.cell == high
        end, 30, "Using the relay's band 3")
        expect(net.ping(stack, ip("10.0.0.60")).error):eq(nil)

        -- A relay behind that one names the computer in its path, not which of its cells it came through.
        local second = acme.add_relay(31, 110)
        wait_until(net, function() return second.phone.cell == high end, 60, "The second relay's phone on band 3")
        wait_until(net, function() return second.tower ~= nil and #second.tower.links.ACME.path == 2 end, 60, "The second relay")
        expect(acme.core:path_of(31)):same { 30, 11 }
        expect(second.tower.links.ACME.path):same { 30, 11 }
        -- So the first relay's phone keeps off it, as the core would have it.
        expect(relay.phone:behind_us(second.tower.links.ACME.path)):eq(true)
        expect(acme.core:would_loop(30, 31)):eq(true)
        expect(net.errors):same {}
    end)

    it("stand by, off the air, until their bands are confirmed", function()
        math.randomseed(10)
        local acme = operator({ 0 }, { carriers = { "b20/1", "b3/1" }, standby = { true } })
        local net = acme.net
        local site = acme.towers[1]
        wait_until(net, function() return site.service:info().state == "standby" end, 10, "Standing by")
        -- The core let it in, and told it what the network has: but it has no cell, and neither has the core.
        local info = site.service:info()
        expect(info.links):same { { core = "10.0.0.1", state = "standby", network = "ACME", carriers = { "b20/1", "b3/1" } } }
        expect({ info.cells, info.carrier, site.tower }):same {}
        expect(site.service:bands()):same { b20 = true, b3 = true }
        expect(site.service:unplaceable({ "b3", "b7" })):eq("b7")
        expect(acme.service.cells[11]):eq(nil)
        expect(acme.service.standby[11].address):eq("10.0.0.11")
        expect(acme.core.towers[11]):eq(nil)
        expect(site.stack.interfaces["cell.tower"]):eq(nil)

        -- Nothing is on the air: a phone beside it hears nothing, however long it listens.
        local phone, stack = acme.add_phone(1, 5)
        net.frames.air = 0
        net.advance(15)
        expect(phone.state):eq("searching")
        expect(next(phone.heard)):eq(nil)
        expect(net.frames.air):eq(0)

        -- Its bands confirmed, it's placed on them, and the phone finds it.
        acme.confirm_cell(1, { "b20", "b3" })
        local high = common.carrier_cell(11, B3_1)
        wait_until(net, function() return phone.state == "attached" and phone.cell == high end, 20, "Using the cell")
        expect(on(site)):same { ["b20/1"] = 11, ["b3/1"] = high }
        expect(site.service:info().state):eq("serving")
        expect(acme.service.standby[11]):eq(nil)
        expect(#acme.service.cells[11].cells):eq(2)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        -- The core's log says both.
        local standing, connected = false, false
        for _, line in ipairs(acme.service.lines) do
            standing = standing or line.text:find("Cell #11 is standing by", 1, true) ~= nil
            connected = connected or line.text:find("Cell #11 connected", 1, true) ~= nil
        end
        expect({ standing, connected }):same { true, true }
        expect(net.errors):same {}
    end)

    it("stand by as a relay too, whatever bands its own phone may use", function()
        math.randomseed(11)
        local acme = operator({ 0 }, { carriers = { "b20/1", "b3/1" }, bands = { "b20" } })
        local net = acme.net
        -- The relay's phone may only use band 20, and is pinned to the cell it should reach the core through.
        local relay = acme.add_relay(30, 30, nil, { bands = { "b20" }, pinned = 11 })
        relay.standby = true
        wait_until(net, function() return relay.service and relay.service:info().state == "standby" end, 60, "Standing by")
        expect(relay.phone.cell):eq(11)
        expect(relay.service:info().links[1].carriers):same { "b20/1", "b3/1" }
        expect(relay.tower):eq(nil)

        -- Its cells go on both bands: what its phone may use says nothing about them.
        acme.confirm_cell(relay, { "b20", "b3" })
        local high = common.carrier_cell(30, B3_1)
        wait_until(net, function() return relay.towers and relay.towers[30] and relay.towers[high] end, 60, "The relay's cells")
        expect(on(relay)):same { ["b20/1"] = 30, ["b3/1"] = high }
        wait_until(net, function() return #relay.towers[high].links.ACME.path == 1 end, 10, "The path")
        expect({ relay.towers[30].links.ACME.path, relay.towers[high].links.ACME.path }):same { { 11 }, { 11 } }
        -- Its phone stays where it was told, on band 20, and listens on nothing else: not on its own cell's band 3.
        net.advance(10)
        expect({ relay.phone.state, relay.phone.cell }):same { "attached", 11 }
        expect(relay.phone.listening[B3_1]):eq(nil)
        expect(next(relay.phone.heard, 11) == nil and relay.phone.heard[11] ~= nil):eq(true)

        -- A phone near it uses its band 3 cell, through the relay's band 20 backhaul.
        local phone, stack = acme.add_phone(1, 60)
        wait_until(net, function()
            local known = session(acme, phone)
            return phone.state == "attached" and phone.cell == high and known and known.cell == high
        end, 30, "Using the relay's band 3")
        expect(net.ping(stack, ip("10.0.0.60")).error):eq(nil)
        expect(net.errors):same {}
    end)

    it("are one place to work out where a phone is from", function()
        math.randomseed(8)
        local here = { 20, 64, 30 }
        local places = { { 0, 80, 0 }, { 60, 100, 0 }, { 0, 60, 60 }, { 60, 90, 60 } }
        -- Four computers, the first with a cell on each of two bands: five cells, four places.
        local acme = operator(places, { carriers = { "b20/1", "b3/1" }, bands = { { "b20", "b3" } } })
        local phone = acme.add_phone(1, here)
        local high = common.carrier_cell(11, B3_1)
        acme.net.advance(6)
        expect(phone.state):eq("attached")
        -- Both of the first computer's cells say where it is, and were as far away.
        expect(phone.heard[11].pos):same(places[1])
        expect(phone.heard[high].pos):same(places[1])
        expect(phone.heard[high].distance):eq(phone.heard[11].distance)
        expect({ phone:locate() }):same { 20, 64, 30, 0 }

        -- Three computers aren't enough to tell, however many cells one of them has: its cells are one place.
        math.randomseed(9)
        local few = operator({ places[1], places[2], places[3] }, {
            carriers = { "b20/1", "b3/1", "b3/2" }, bands = { { "b20", "b3", "b3" } },
        })
        local lost = few.add_phone(1, here)
        few.net.advance(6)
        expect(lost.state):eq("attached")
        local count = 0
        for _, cell in pairs(lost.heard) do
            if cell.pos then count = count + 1 end
        end
        expect(count):eq(5)
        local alone = operator({ places[1], places[2], places[3] })
        local other = alone.add_phone(1, here)
        alone.net.advance(6)
        expect({ lost:locate() }):same { other:locate() }
        expect(acme.net.errors):same {}
        expect(few.net.errors):same {}
    end)
end)
