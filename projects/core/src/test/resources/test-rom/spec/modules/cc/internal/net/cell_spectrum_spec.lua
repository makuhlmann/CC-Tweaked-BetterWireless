-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ A network's carriers, which its administrator chooses: none to begin with. Its cells are on the air only where it
has a carrier for them, and follow as its carriers change. ]]

describe("A network's carriers", function()
    local helpers = require "support.net_helpers"
    local bands = require "cc.internal.net.bands"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local ip = helpers.ip
    local wait_until = helpers.wait_until

    local B3_1, B7_3 = bands.parse_carrier("b3/1"), bands.parse_carrier("b7/3")

    -- Each of a computer's towers, by its carrier's name.
    local function on(entry)
        local result = {}
        for id, tower in pairs(entry.towers or {}) do
            if not tower.stopped then result[bands.carrier_name(tower.carrier)] = id end
        end
        return result
    end

    local function state(entry) return entry.service:info().state end

    -- Whether a line of the core's log says something.
    local function logged(setup, text)
        for _, line in ipairs(setup.service.lines) do
            if line.text:find(text, 1, true) then return true end
        end
        return false
    end

    -- Whether a phone gets through to the server, once it has noticed that its cell moved: within a minute.
    local function gets_through(net, stack)
        for _ = 1, 60 do
            local reply = net.ping(stack, ip("10.0.0.60"))
            if reply and reply.done then return true end
            net.advance(1)
        end
        return false
    end

    it("are none to begin with: its cells wait, off the air, and take them as they're chosen", function()
        math.randomseed(21)
        local acme = operator({ 0, 60 }, { carriers = {}, bands = { nil, { "b3" } } })
        local net = acme.net
        local any, high = acme.towers[1], acme.towers[2]
        wait_until(net, function() return state(any) == "unplaced" and state(high) == "unplaced" end, 10, "Waiting for carriers")
        -- They were let in, and told there's nothing for them: neither refused, nor on the air.
        expect(any.service:info().links):same { { core = "10.0.0.1", state = "unplaced", network = "ACME", carriers = {} } }
        expect(high.service:info().links):same {
            { core = "10.0.0.1", state = "unplaced", network = "ACME", carriers = {}, unplaced = { "b3" } },
        }
        expect({ acme.service.standby[11].unplaced, acme.service.standby[12].unplaced }):same { {}, { "b3" } }
        expect(acme.service:no_carrier(acme.service.standby[12].unplaced)):eq("ACME has no carriers yet")
        expect({ next(acme.service.cells), next(acme.core.towers) }):same {}
        expect(logged(acme, "Cell #12 is off the air, from 10.0.0.12: ACME has no carriers yet")):eq(true)
        local phone, stack = acme.add_phone(1, 5)
        net.frames.air = 0
        net.advance(15)
        expect({ net.frames.air, phone.state, next(phone.heard) }):same { 0, "searching" }

        -- A carrier in band 20: the cell which takes any goes on it at once, without being asked twice. The other
        -- wants band 3, and waits on.
        acme.set_carriers({ "b20/1" })
        wait_until(net, function() return state(any) == "serving" end, 10, "Taking the carrier")
        expect(on(any)):same { ["b20/1"] = 11 }
        net.advance(5)
        expect(high.service:info().links):same {
            { core = "10.0.0.1", state = "unplaced", network = "ACME", carriers = { "b20/1" }, unplaced = { "b3" } },
        }
        expect(acme.service:no_carrier({ "b3" })):eq("ACME has no carrier in band b3")
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 20, "Attaching")
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }

        -- One in band 3 too: the other takes it, and the first stays as it is.
        local first = any.tower
        acme.set_carriers({ "b20/1", "b3/2" })
        wait_until(net, function() return state(high) == "serving" end, 10, "Taking band 3")
        expect(on(high)):same { ["b3/2"] = 12 }
        expect({ any.tower == first, first.stopped }):same { true }
        expect(acme.service.standby[12]):eq(nil)

        -- A carrier which is no longer the network's is left: its cell goes to one which is, and the phone with it.
        local second = high.tower
        acme.set_carriers({ "b20/2", "b3/2" })
        wait_until(net, function() return on(any)["b20/2"] == 11 end, 10, "Moving to the other carrier")
        expect({ on(any)["b20/1"], first.stopped }):same { nil, true }
        expect({ high.tower == second, second.stopped }):same { true }
        -- (The phone misses its cell where it was, and finds it on the other carrier, or the other cell.)
        expect(gets_through(net, stack)):eq(true)

        -- None again: everything goes quiet, and waits.
        acme.set_carriers({})
        wait_until(net, function() return state(any) == "unplaced" and state(high) == "unplaced" end, 10, "Going off the air")
        expect({ next(on(any)), next(on(high)) }):same {}
        expect(logged(acme, "This network has no carriers now")):eq(true)
        net.advance(3)
        net.frames.air = 0
        net.advance(10)
        expect(net.frames.air):eq(0)
        expect(net.errors):same {}
    end)

    it("needn't be where a cell is, once whoever set it up overrode them", function()
        math.randomseed(22)
        local acme = operator({ 0 }, { carriers = { "b20/1" }, bands = { { "b20", "b7/3" } }, override = { true } })
        local net = acme.net
        local site = acme.towers[1]
        local outside = common.carrier_cell(11, B7_3)
        wait_until(net, function() return on(site)["b7/3"] ~= nil end, 10, "Going on both")
        expect(on(site)):same { ["b20/1"] = 11, ["b7/3"] = outside }
        expect(site.service:info().links[1].unplaced):eq(nil)
        expect(logged(acme, "Cell #11 connected, from 10.0.0.11, on b20/1 and b7/3 (not this network's: b7/3)")):eq(true)
        -- A phone uses it like any other.
        local phone, stack = acme.add_phone(1, 5, nil, { bands = { "b7" } })
        wait_until(net, function() return phone.state == "attached" and phone.cell == outside end, 20, "Attaching on band 7")
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        -- The network's carriers changing doesn't move it.
        acme.set_carriers({ "b20/1", "b3/1" })
        net.advance(5)
        expect(on(site)):same { ["b20/1"] = 11, ["b7/3"] = outside }

        -- No longer overridden, the cell leaves what isn't the network's, and says what it has no carrier for.
        site.service:set_override(false)
        wait_until(net, function() return on(site)["b7/3"] == nil and state(site) == "serving" end, 10, "Leaving band 7")
        expect(on(site)):same { ["b20/1"] = 11 }
        expect(site.service:info().links[1].unplaced):same { "b7/3" }
        -- And overridden again, it's back.
        site.service:set_override(true)
        wait_until(net, function() return on(site)["b7/3"] ~= nil end, 10, "Going back on band 7")
        expect(on(site)):same { ["b20/1"] = 11, ["b7/3"] = outside }
        wait_until(net, function() return phone.state == "attached" and phone.cell == outside end, 30, "Attaching again")
        expect(net.errors):same {}
    end)

    it("are each network's own at a cell which serves several, whichever answers first", function()
        math.randomseed(23)
        -- BETA has no carriers yet. Its cell wants a carrier ACME has, and one nobody has.
        local acme = operator({ 300 }, { carriers = { "b20/1" } })
        local beta = operator({ 0 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            carriers = {}, bands = { { "b20/1", "b3/1" } },
        })
        local net = acme.net
        local site = beta.towers[1]
        wait_until(net, function() return state(site) == "unplaced" end, 10, "Waiting for a carrier")

        -- Serving ACME too, it goes on ACME's carrier: and BETA, which had nothing for it, is served there as well.
        beta.add_core(1, acme)
        wait_until(net, function() return site.tower and site.tower.links.ACME and site.tower.links.BETA end, 20, "Both networks on band 20")
        expect(on(site)):same { ["b20/1"] = 21 }
        local links = site.service:info().links
        expect({ links[1].state, links[1].unplaced, links[2].state, links[2].unplaced }):same { "serving", { "b3/1" }, "serving", { "b3/1" } }
        local ours, ours_stack = beta.add_phone(1, 5)
        local theirs, theirs_stack = acme.add_phone(1, 8)
        wait_until(net, function() return ours.state == "attached" and theirs.state == "attached" end, 20, "Attaching")
        expect({ ours.cell, theirs.cell }):same { 21, 21 }

        -- BETA gets the other carrier: the site grows a cell there, and ACME is served on it too.
        local high = common.carrier_cell(21, B3_1)
        beta.set_carriers({ "b3/1" })
        wait_until(net, function()
            local upper = site.towers[high]
            return upper and upper.links.ACME and upper.links.BETA and site.tower.links.ACME and site.tower.links.BETA
        end, 20, "Both networks on both bands")
        expect(on(site)):same { ["b20/1"] = 21, ["b3/1"] = high }
        expect(site.service:info().links[1].unplaced):eq(nil)

        -- ACME gives its carrier up: the site leaves it, and both networks carry on where BETA has one.
        acme.set_carriers({})
        wait_until(net, function()
            local now = on(site)
            local tower = now["b3/1"] and site.towers[now["b3/1"]]
            return not now["b20/1"] and tower and tower.links.ACME and tower.links.BETA
        end, 20, "Leaving band 20")
        expect(on(site)):same { ["b3/1"] = 21 }
        expect(gets_through(net, ours_stack)):eq(true)
        expect(gets_through(net, theirs_stack)):eq(true)
        expect({ ours.cell, theirs.cell }):same { 21, 21 }
        expect(net.errors):same {}
    end)
end)
