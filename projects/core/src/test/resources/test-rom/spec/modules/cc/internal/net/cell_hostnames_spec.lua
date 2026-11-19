-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ A cellular network's core registering its phones' names at a DNS server (dnsd), as they attach: each phone as its
subscriber's ID, in the domain phones are given, or a zone of its own. ]]

describe("Phones' names", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator
    local dns = require "cc.internal.net.dns"
    local address = require "cc.net.address"

    -- Whether the core logged something.
    local function logged(acme, text)
        for _, line in ipairs(acme.service.lines) do
            if line.text == text then return true end
        end
        return false
    end

    --[[ A DNS server, as dnsd runs one, on the backhaul's server (10.0.0.60), for these zones, which takes updates from
    anyone (signed with the key, if there is one). Gives its names, and what it logged. Its clock is the core's. ]]
    local function name_server(acme, zone_names, key)
        local stack, net = acme.server, acme.net
        local names = dns.names({}, function() return net.time end)
        local zones = {}
        for i, zone in ipairs(zone_names) do zones[i] = dns.server(zone, {}, function() return names:lookup(zone) end) end
        local log, seen, socket = {}, {}, nil
        socket = stack:udp_open(dns.DNS_PORT, function(message, from, port)
            local answer, _, text = dns.handle_update(message, {
                zones = zones, names = names, allowed = true, key = key, epoch = 1.7e12 + net.time * 1000, seen = seen,
                from = address.format(from),
            })
            if text then log[#log + 1] = text end
            if answer then stack:udp_send(socket, from, port, answer) end
        end)
        return names, log
    end

    local function sim_of(acme, id)
        for sim, subscriber in pairs(acme.subscribers) do
            if subscriber.id == id then return sim end
        end
    end

    it("are registered as phones attach, and deleted when their subscribers go", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { domain = "acme", hostnames = { server = "10.0.0.60" } })
        local net = acme.net
        local names, log = name_server(acme, { "acme" })
        local one, one_stack = acme.add_phone(1, 10, true)
        local two, two_stack = acme.add_phone(2, 20, true)
        net.advance(8)
        expect({ one.state, two.state }):same { "attached", "attached" }
        expect(names:lookup("acme")):same {
            ["acme-1"] = one_stack.interfaces.cell.address, ["acme-2"] = two_stack.interfaces.cell.address,
        }
        expect(log[1]):str_match("^Set acme%-%d%.acme to 10%.64%.0%.%d+ %(subscriber ACME%-%d, from 10%.0%.0%.1%)$")
        expect(acme.service:request({ op = "status" }).hostnames)
            :same { server = "10.0.0.60", key = false, registering = "acme" }

        -- A subscriber who's removed loses their name; the other keeps theirs.
        acme.core:remove_subscriber(sim_of(acme, "ACME-1"))
        net.advance(2)
        expect(names:lookup("acme")):same { ["acme-2"] = two_stack.interfaces.cell.address }

        -- They last an hour, and are registered again before then while the core runs.
        expect(names.entries["acme-2.acme"].expires - net.time > 3000):eq(true)
        expect(net.errors):same {}
    end)

    it("move with the domain, or to a zone of their own, and stop", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { domain = "acme", hostnames = { server = "10.0.0.60" } })
        local net = acme.net
        local names = name_server(acme, { "acme", "acme.example", "phones.acme" })
        local _, stack = acme.add_phone(1, 10, true)
        net.advance(8)
        local addr = stack.interfaces.cell.address
        expect(names:lookup("acme")):same { ["acme-1"] = addr }

        expect(acme.service:request({ op = "dns", domain = "acme.example" }).domain):eq("acme.example")
        net.advance(2)
        expect({ names:lookup("acme"), names:lookup("acme.example") }):same { {}, { ["acme-1"] = addr } }

        expect(acme.service:request({ op = "hostnames", zone = "phones.acme" }))
            :same { server = "10.0.0.60", zone = "phones.acme", domain = "acme.example", key = false }
        net.advance(2)
        expect({ names:lookup("acme.example"), names:lookup("phones.acme") }):same { {}, { ["acme-1"] = addr } }
        -- The domain doesn't move them now.
        acme.service:request({ op = "dns", domain = "acme" })
        net.advance(2)
        expect(names:lookup("phones.acme")):same { ["acme-1"] = addr }

        expect(acme.service:request({ op = "hostnames", server = false }).server):eq(nil)
        net.advance(2)
        expect(names:lookup("phones.acme")):same {}
        expect(acme.service.hostnames):eq(nil)
        expect(net.errors):same {}
    end)

    it("are signed with the key the server asks for", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { domain = "acme", hostnames = { server = "10.0.0.60" } })
        local net = acme.net
        local names, log = name_server(acme, { "acme" }, "s3cret")
        local _, stack = acme.add_phone(1, 10, true)
        net.advance(8)
        expect(names:lookup("acme")):same {}
        expect(log[1]):eq("Refused an update from 10.0.0.1: it isn't signed")
        expect(logged(acme, "The DNS server wouldn't set acme-1.acme: it isn't signed")):eq(true)

        expect(acme.service:request({ op = "hostnames", key = "s3cret" }).key):eq(true)
        net.advance(2)
        expect(names:lookup("acme")):same { ["acme-1"] = stack.interfaces.cell.address }
        expect(net.errors):same {}
    end)

    it("aren't registered without a zone, or a server", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { hostnames = { server = "10.0.0.60" } })
        local net = acme.net
        local names = name_server(acme, { "acme" })
        acme.add_phone(1, 10, true)
        net.advance(8)
        expect(names:lookup("acme")):same {}
        expect(acme.service:request({ op = "status" }).hostnames):same { server = "10.0.0.60", key = false }

        -- Garbage in the settings file is passed by.
        local other = operator({ 0 }, { name = "BETA", hostnames = { server = "nowhere", zone = 5, key = { "x" } } })
        expect(other.service.config.hostnames):eq(nil)
    end)

    it("are checked by the core before it takes them", function()
        local acme = operator({ 0 }, { domain = "acme" })
        local function ask(request)
            request.op = "hostnames"
            return acme.service:request(request)
        end
        expect(ask({ server = "10.0.0.0/8" }).error):eq("The DNS server is an address, such as 10.0.0.53")
        expect(ask({ server = 5 }).error):eq("The DNS server is an address, such as 10.0.0.53")
        expect(ask({ zone = "a..b" }).error)
            :eq("A zone is names of letters, digits and dashes, separated by dots, such as acme")
        expect(ask({ key = "two words" }).error):eq("A key is up to 128 characters, without spaces or #")
        expect(ask({ key = "#" }).error):eq("A key is up to 128 characters, without spaces or #")
        expect(ask({})):same { domain = "acme", key = false }

        expect(ask({ server = "10.0.0.60", zone = "Phones.Acme.", key = "s3cret" }))
            :same { server = "10.0.0.60", zone = "phones.acme", domain = "acme", key = true }
        -- It's kept, and the key isn't said.
        local config = helpers.copy(acme.service.config.hostnames)
        expect(config):same { server = "10.0.0.60", zone = "phones.acme", key = "s3cret" }
        expect(acme.service:request({ op = "status" }).hostnames)
            :same { server = "10.0.0.60", zone = "phones.acme", key = true, registering = "phones.acme" }
        expect(ask({ zone = false, key = false })):same { server = "10.0.0.60", domain = "acme", key = false }
        expect(ask({ server = false })):same { domain = "acme", key = false }
        expect(acme.service.config.hostnames):eq(nil)
        expect(logged(acme, "Phones' names are registered nowhere")):eq(true)
    end)
end)
