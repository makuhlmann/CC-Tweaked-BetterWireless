-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Renaming a network: its core starts afresh under the new name, and everything which knew it by the old one
follows. Phones know their operator by its keys, and other networks' cores know its core by its key. ]]

describe("A renamed network", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator

    local wait_until = helpers.wait_until

    -- Whether a phone gets through to the server, once it has found its network again: within a minute.
    local function gets_through(net, stack)
        for _ = 1, 60 do
            if helpers.reaches_server(net, stack) then return true end
            net.advance(1)
        end
        return false
    end

    local function event_kinds(phone)
        local kinds = {}
        for i, event in ipairs(phone.events) do kinds[i] = event.kind end
        return table.concat(kinds, " ")
    end

    it("is found by its phones under its new name, which they keep", function()
        math.randomseed(31)
        local acme = operator({ 0 }, { carriers = { "b20/1" } })
        local net = acme.net
        local kept = {}
        local phone, stack = acme.add_phone(1, 5, nil, {
            on_renamed = function(network, since, was) kept[#kept + 1] = { network, was, type(since) } end,
        })
        wait_until(net, function() return phone.state == "attached" end, 15, "Attaching")
        expect(gets_through(net, stack)):eq(true)
        local before = phone.newest[acme.signing_public]

        acme.rename("ZETA")
        -- The cell joins again by itself, and names the network as it's called now.
        local site = acme.towers[1]
        wait_until(net, function() return site.tower and site.tower.links.ZETA end, 20, "The cell serving ZETA")
        expect(site.tower.links.ACME):eq(nil)
        -- The phone knows its operator's key on the cell's certificate, which is newer than any it saw: so that's what
        -- its network is called now. It attaches again, and whoever keeps its SIM is told.
        expect(gets_through(net, stack)):eq(true)
        expect({ phone.operator.network, phone:info().network, phone.here.via }):same { "ZETA", "ZETA", "ZETA" }
        expect(kept):same { { "ZETA", "ACME", "number" } }
        expect(phone.newest[acme.signing_public] > before):eq(true)
        expect(event_kinds(phone)):str_match("renamed")
        expect(phone:roaming()):eq(false)

        -- A phone which was away while it was renamed finds it just so, when it's back.
        local away, away_stack = acme.add_phone(2, 8, nil, { network = "ACME" })
        expect(gets_through(net, away_stack)):eq(true)
        expect(away.operator.network):eq("ZETA")
        -- One which has seen a newer certificate than the cell's under the name it knows doesn't take another name from
        -- it: that cell is from before, and not one to use.
        local wary = acme.add_phone(3, 8, nil, { network = "OMEGA" })
        wary.newest[acme.signing_public] = math.huge
        net.advance(20)
        expect({ wary.operator.network, wary.state, next(wary.cells) }):same { "OMEGA", "searching" }

        -- And back to the name it had: that's newer again.
        acme.rename("ACME")
        expect(gets_through(net, stack)):eq(true)
        expect(gets_through(net, away_stack)):eq(true)
        expect({ phone.operator.network, away.operator.network }):same { "ACME", "ACME" }
        expect(acme.service.config.former):same { "ZETA" }
        expect(net.errors):same {}
    end)

    it("is still the network other networks' phones roam on", function()
        math.randomseed(32)
        -- ACME's phone is where only BETA's cells are.
        local acme = operator({ 0 }, { carriers = { "b20/1" } })
        local beta = operator({ 300 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            carriers = { "b20/2" },
        })
        local net = acme.net
        acme.roam_on(beta)
        local partners
        local phone, stack = acme.add_phone(1, 305, true, {
            partners = { BETA = beta.signing_public }, on_partners = function(list) partners = list end,
        })
        wait_until(net, function() return phone.state == "attached" and phone:roaming() end, 20, "Roaming")
        expect(gets_through(net, stack)):eq(true)

        -- BETA is renamed. ACME's core knows BETA's by its key, and keeps the agreement; the phone knows BETA's
        -- operator by its key, and roams on.
        beta.rename("GAMMA")
        expect(gets_through(net, stack)):eq(true)
        expect({ phone.partners.BETA, phone.partners.GAMMA }):same { nil, beta.signing_public }
        expect({ phone.here.via, phone:roaming(), phone.operator.network }):same { "GAMMA", true, "ACME" }
        expect(partners.GAMMA):eq(beta.signing_public)
        expect({ acme.service.networks.BETA, acme.service.networks.GAMMA ~= nil }):same { nil, true }
        expect(acme.service.networks.GAMMA.former):same { "BETA" }
        expect(acme.core:info()[1].roaming):eq("GAMMA")
        expect(net.errors):same {}
    end)

    it("is still its phones' own while they roam, and never hear its cells", function()
        math.randomseed(33)
        local acme = operator({ 0 }, { carriers = { "b20/1" } })
        local beta = operator({ 300 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            carriers = { "b20/2" },
        })
        local net = acme.net
        acme.roam_on(beta)
        local kept
        local phone, stack = acme.add_phone(1, 305, true, {
            partners = { BETA = beta.signing_public }, on_renamed = function(network, _, was) kept = { network, was } end,
        })
        wait_until(net, function() return phone.state == "attached" and phone:roaming() end, 20, "Roaming")

        -- ACME is renamed while its phone is away. BETA's core follows ACME's to its new name, and is told what it was
        -- called: the phone attaches as ACME's, which ZETA's core still answers to, and hears the name from it.
        acme.rename("ZETA")
        expect(gets_through(net, stack)):eq(true)
        expect({ phone.operator.network, phone:roaming(), phone.here.via }):same { "ZETA", true, "BETA" }
        expect(kept):same { "ZETA", "ACME" }
        expect({ beta.service.networks.ACME, beta.service.networks.ZETA ~= nil }):same { nil, true }
        expect(beta.core:partner_called("ACME")):eq("ZETA")
        expect(beta.core:visitor_info()[1].network):eq("ZETA")

        -- Back home, it's one of ZETA's own.
        acme.positions[1] = 5
        wait_until(net, function() return phone.state == "attached" and not phone:roaming() end, 60, "Going home")
        expect(phone.here.via):eq("ZETA")
        expect(gets_through(net, stack)):eq(true)
        expect(net.errors):same {}
    end)
end)
