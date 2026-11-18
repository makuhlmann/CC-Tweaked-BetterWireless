-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ The DNS servers and domain a cellular network gives its phones: as they attach, and whenever they change. ]]

describe("A cellular network's DNS servers", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator

    local wait_until = helpers.wait_until

    -- The core's session for a phone, which is attached.
    local function session_of(core)
        for _, session in pairs(core.sessions) do
            if session.teid and session.cell then return session end
        end
        error("No phone is attached", 2)
    end

    it("are given to phones as they attach, and changed at once", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { dns = { "10.0.0.53" }, domain = "acme" })
        local net = acme.net
        local phone = acme.add_phone(1, 10, true)
        net.advance(8)
        expect(phone.state):eq("attached")
        expect(phone.subscriber.dns):same { servers = { "10.0.0.53" }, domain = "acme" }

        acme.core:set_dns({ "10.0.0.54", "10.0.0.55" }, "acme.example")
        net.advance(2)
        expect(phone.subscriber.dns):same { servers = { "10.0.0.54", "10.0.0.55" }, domain = "acme.example" }

        -- Either, or both, may be taken away.
        acme.core:set_dns(nil, "acme.example")
        net.advance(2)
        expect(phone.subscriber.dns):same { domain = "acme.example" }
        acme.core:set_dns(nil, nil)
        net.advance(2)
        expect(phone.subscriber.dns):eq(nil)

        -- A phone which attaches again is given what's set now.
        acme.core:set_dns({ "10.0.0.56" }, nil)
        local again = acme.add_phone(2, 20, true)
        net.advance(8)
        expect(again.state):eq("attached")
        expect(again.subscriber.dns):same { servers = { "10.0.0.56" } }
        expect(phone.subscriber.dns):same { servers = { "10.0.0.56" } }
        expect(net.errors):same {}
    end)

    it("aren't given when the network has none", function()
        math.randomseed(1)
        local acme = operator({ 0 })
        local phone = acme.add_phone(1, 10, true)
        acme.net.advance(8)
        expect(phone.state):eq("attached")
        expect(phone.subscriber):same { id = "ACME-1", number = "1" }
        expect(acme.net.errors):same {}
    end)

    it("are checked by the phone, which keeps nothing it can't use", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { dns = { "10.0.0.53" } })
        local net = acme.net
        local phone = acme.add_phone(1, 10, true)
        net.advance(8)
        expect(phone.subscriber.dns):same { servers = { "10.0.0.53" } }

        -- As a core which checked nothing (or another network carrying the phone) might send.
        local session = session_of(acme.core)
        local function send(servers, domain)
            acme.core:send(session.cell, { op = "dns", teid = session.teid, servers = servers, domain = domain })
            net.advance(2)
            return phone.subscriber.dns
        end
        expect(send({ "127.0.0.1" }, "Not a domain")):eq(nil)
        expect(send({ "10.0.0.53", "10.0.0.0/8" }, "a..b")):eq(nil)
        expect(send({ "1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4", "5.5.5.5" }, 5)):eq(nil)
        expect(send("10.0.0.53", { "acme" })):eq(nil)
        expect(send({ { "10.0.0.53" } }, ("x"):rep(65))):eq(nil)
        expect(send({ "10.0.0.53", "10.0.0.53" }, "acme")):same { servers = { "10.0.0.53" }, domain = "acme" }
        expect(send(true, "acme")):same { domain = "acme" }

        expect(phone.state):eq("attached")
        expect(net.errors):same {}
    end)

    it("are given at a cell which only carries messages too, for when the phone moves on", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { services = { "sms" }, dns = { "10.0.0.53" } })
        local phone = acme.add_phone(1, 10, true)
        acme.net.advance(8)
        expect(phone.state):eq("attached")
        expect(phone:messages_only()):eq(true)
        expect(phone.subscriber.dns):same { servers = { "10.0.0.53" } }
        expect(acme.net.errors):same {}
    end)

    it("reach phones roaming on another network", function()
        math.randomseed(1)
        local acme = operator({ 0, 100 }, { dns = { "10.0.0.53" }, domain = "acme" })
        local beta = operator({ 300, 400 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            dns = { "10.0.0.99" }, domain = "beta",
        })
        acme.roam_on(beta)
        local net = acme.net
        local phone = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        wait_until(net, function() return phone.state == "attached" end, 30, "Roaming")
        expect(phone:roaming()):eq(true)
        -- Its own network's, not the one which carries it.
        expect(phone.subscriber.dns):same { servers = { "10.0.0.53" }, domain = "acme" }

        acme.core:set_dns({ "10.0.0.54" }, nil)
        net.advance(2)
        expect(phone.subscriber.dns):same { servers = { "10.0.0.54" } }

        -- The carrying network passes on only what could be servers and a domain.
        local visitor
        for _, each in pairs(beta.core.visitors) do visitor = each end
        beta.core:partner_control("ACME", { op = "dns", teid = visitor.home_teid, servers = { "127.0.0.1" }, domain = "acme" })
        net.advance(2)
        expect(phone.subscriber.dns):same { domain = "acme" }
        expect(net.errors):same {}
    end)
end)
