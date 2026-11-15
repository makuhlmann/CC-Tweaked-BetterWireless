-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Subscribers which are routers, with a network of their own behind their phone: a range of the network's own
addresses, for a small site, or a subnet which isn't the network's own, for a site with addresses of its own. ]]

describe("Subscribers with a network of their own", function()
    local helpers = require "support.net_helpers"
    local address = require "cc.net.address"
    local rip = require "cc.internal.net.rip"
    local operator = require "support.cell_network".operator

    local ip, hex = helpers.ip, helpers.hex
    local wait_until = helpers.wait_until

    -- The routes a core has for its subscribers' networks.
    local function subscriber_routes(setup)
        local routes = {}
        for _, route in ipairs(setup.core_stack.routes) do
            if route.source == "subscriber" then
                routes[#routes + 1] = ("%s via %s"):format(address.format(route.network, route.prefix), address.format(route.gateway))
            end
        end
        table.sort(routes)
        return routes
    end

    -- Put a computer behind a phone's computer, which is its router: on a cable between the two.
    local function site(setup, stack, id, router_address, host_address)
        local net = setup.net
        local link = "lan" .. id
        stack.forwarding = true
        net.connect(stack, link, router_address)
        local host = net.stack(id)
        net.connect(host, link, host_address)
        helpers.default_route(host, router_address:match("^[^/]+"))
        return host
    end

    it("have a range of the network's addresses sent to their phone", function()
        math.randomseed(1)
        local acme = operator { 0 }
        local net = acme.net
        local phone, stack = acme.add_phone(1, 10)
        local sim = hex(phone.sim.public)
        wait_until(net, function() return phone.state == "attached" end, 15, "Attaching")
        expect(phone.subscriber.routed):eq(nil)
        expect(subscriber_routes(acme)):same {}

        -- The subscriber becomes a router: its phone is cut off, and hears of its range as it attaches again.
        expect(acme.core:set_network(sim, "range", "10.64.5.7/28")):eq("10.64.5.0/28")
        wait_until(net, function() return phone.state == "attached" and phone.subscriber.routed ~= nil end, 60, "Attaching again")
        expect(phone.subscriber.routed):same { kind = "range", network = "10.64.5.0/28" }
        expect(phone:info().subscriber.routed):same { kind = "range", network = "10.64.5.0/28" }
        -- The phone has an address like any other, which the core sends the range to.
        local own = address.format(phone.address)
        expect(address.contains(ip("10.64.5.0"), 28, phone.address)):eq(false)
        expect(subscriber_routes(acme)):same { "10.64.5.0/28 via " .. own }

        -- A computer behind the router, with one of the range's addresses, reaches the network, and is reached.
        local host = site(acme, stack, 2, "10.64.5.1/28", "10.64.5.2/28")
        expect(net.ping(host, ip("10.0.0.60"))):matches { done = true }
        expect(net.ping(acme.server, ip("10.64.5.2"))):matches { done = true }
        expect(net.ping(acme.server, ip("10.64.5.1"))):matches { done = true }
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }

        -- No phone is given an address in the range, even when it's the next one along.
        acme.core.next_host = ip("10.64.5.3") - ip("10.64.0.0")
        local other, other_stack = acme.add_phone(3, 12)
        wait_until(net, function() return other.state == "attached" end, 15, "The other phone attaching")
        expect(address.format(other.address)):eq("10.64.5.16")
        expect(net.ping(other_stack, ip("10.64.5.2"))):matches { done = true }

        -- Only what's in its range may be sent from behind the router: not addresses which are anyone's.
        local stranger = site(acme, stack, 4, "10.64.9.1/28", "10.64.9.2/28")
        acme.server:add_route { network = ip("10.64.9.0"), prefix = 28, gateway = ip("10.0.0.1"), source = "static" }
        local before = acme.core_stack.forwarded
        expect(net.ping(stranger, ip("10.0.0.60"), nil, 2)):eq(nil)
        expect(acme.core_stack.forwarded):eq(before)

        -- Taken away, the range is nobody's again: the core routes nothing there, and tells the phone so.
        expect(acme.core:set_network(sim, nil)):eq(true)
        expect(subscriber_routes(acme)):same {}
        wait_until(net, function() return phone.state == "attached" and phone.subscriber.routed == nil end, 60, "Attaching once more")
        expect(net.ping(host, ip("10.0.0.60"), nil, 2)):eq(nil)
        expect(net.errors):same {}
    end)

    it("have a subnet of their own sent to their phone, and told to other routers", function()
        math.randomseed(2)
        local acme = operator { 0 }
        local net = acme.net
        local phone, stack = acme.add_phone(1, 10)
        local sim = hex(phone.sim.public)
        -- A subscriber may be one from the start.
        acme.subscribers[sim].subnet = "192.168.5.0/24"
        wait_until(net, function() return phone.state == "attached" end, 15, "Attaching")
        expect(phone.subscriber.routed):same { kind = "subnet", network = "192.168.5.0/24" }
        expect(subscriber_routes(acme)):same { "192.168.5.0/24 via " .. address.format(phone.address) }

        -- The rest of the network needs a route to it through the core, which the core tells whoever listens.
        local advertised = {}
        for _, route in ipairs(rip.start(acme.core_stack):routes_for(acme.core_stack.interfaces.backhaul)) do
            advertised[address.format(route.network, route.prefix)] = route.metric
        end
        expect(advertised["192.168.5.0/24"]):eq(1)
        expect(advertised["10.64.0.0/16"]):eq(0)
        acme.server:add_route { network = ip("192.168.5.0"), prefix = 24, gateway = ip("10.0.0.1"), source = "static" }

        local host = site(acme, stack, 2, "192.168.5.1/24", "192.168.5.20/24")
        expect(net.ping(host, ip("10.0.0.60"))):matches { done = true }
        expect(net.ping(acme.server, ip("192.168.5.20"))):matches { done = true }

        -- Barred, the subscriber's site is cut off with their phone; and it's back when they are.
        acme.subscribers[sim].barred = true
        acme.core:detach(sim)
        expect(subscriber_routes(acme)):same {}
        acme.subscribers[sim].barred = nil
        wait_until(net, function() return phone.state == "attached" and #subscriber_routes(acme) == 1 end, 60, "Attaching again")
        expect(net.ping(acme.server, ip("192.168.5.20"))):matches { done = true }

        -- Removed, there's nothing left of it.
        acme.core:remove_subscriber(sim)
        expect(subscriber_routes(acme)):same {}
        expect(net.errors):same {}
    end)

    it("only have networks they can have", function()
        local acme = operator { 0 }
        local one, two = acme.add_phone(1, 10), acme.add_phone(2, 10)
        local first, second = hex(one.sim.public), hex(two.sim.public)
        local core = acme.core
        local function refused(sim, kind, text) return select(2, core:set_network(sim, kind, text)) end

        expect(refused("nobody", "range", "10.64.5.0/28")):eq("There's no such subscriber")
        expect(refused(first, "block", "10.64.5.0/28")):eq("Expected a range or a subnet")
        expect(refused(first, "range", "somewhere")):eq("Expected a network, such as 10.64.5.0/28")
        expect(refused(first, "range", "10.64.5.0")):eq("Expected a network, such as 10.64.5.0/28")
        expect(refused(first, "range", "10.64.5.0/31")):eq("A network needs room for two computers at least: /30 or bigger")
        -- A range is part of the network's addresses: not all of them, not others, and not the gateway's.
        local own = "A range is part of this network's own addresses, 10.64.0.0/16"
        expect(refused(first, "range", "10.64.0.0/16")):eq(own)
        expect(refused(first, "range", "10.0.0.0/8")):eq(own)
        expect(refused(first, "range", "10.65.0.0/24")):eq(own)
        expect(refused(first, "range", "10.64.0.0/24")):eq("That range has the gateway's own address in it")
        -- A subnet isn't, and is one computers can be in.
        expect(refused(first, "subnet", "10.64.5.0/24"))
            :eq("That's part of this network's own addresses: give the subscriber a range of them instead")
        expect(refused(first, "subnet", "10.0.0.0/8"))
            :eq("That's part of this network's own addresses: give the subscriber a range of them instead")
        for _, network in ipairs { "127.0.0.0/8", "224.0.0.0/8", "0.0.0.0/8", "169.254.0.0/16", "192.0.0.0/4" } do
            expect(refused(first, "subnet", network)):describe(network):eq("That isn't a network computers can have addresses in")
        end

        -- Nobody has part of another's.
        expect(core:set_network(first, "range", "10.64.5.0/24")):eq("10.64.5.0/24")
        expect(refused(second, "range", "10.64.5.64/28")):eq("ACME-1 has 10.64.5.0/24 already")
        expect(refused(second, "range", "10.64.4.0/23")):eq("ACME-1 has 10.64.5.0/24 already")
        expect(core:set_network(second, "subnet", "192.168.0.0/16")):eq("192.168.0.0/16")
        expect(refused(first, "subnet", "192.168.7.0/24")):eq("ACME-2 has 192.168.0.0/16 already")
        -- One kind replaces the other, and their own may change.
        expect(core:set_network(first, "range", "10.64.5.0/25")):eq("10.64.5.0/25")
        expect(core:set_network(first, "subnet", "172.16.0.0/12")):eq("172.16.0.0/12")
        expect({ acme.subscribers[first].range, acme.subscribers[first].subnet }):same { nil, "172.16.0.0/12" }
        expect(core:set_network(second, "range", "10.64.5.64/28")):eq("10.64.5.64/28")
        expect({ acme.subscribers[second].range, acme.subscribers[second].subnet }):same { "10.64.5.64/28" }
    end)

    it("take the addresses of phones which are in their range", function()
        math.randomseed(4)
        local acme = operator { 0 }
        local net = acme.net
        -- (Away from the gateway's own address, which no range may have in it.)
        acme.core.next_host = 100
        local router = acme.add_phone(1, 10)
        local phone, stack = acme.add_phone(2, 12)
        wait_until(net, function() return router.state == "attached" and phone.state == "attached" end, 15, "Attaching")
        local old = phone.address
        -- The range the phone's address is in becomes the router's: the phone gets another.
        local range = address.format(address.network(old, 28), 28)
        expect(acme.core:set_network(hex(router.sim.public), "range", range)):eq(range)
        wait_until(net, function()
            return phone.state == "attached" and phone.address ~= old and router.state == "attached" and router.subscriber.routed
        end, 60, "Attaching again")
        expect(address.contains(old, 28, phone.address)):eq(false)
        expect(address.contains(old, 28, router.address)):eq(false)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)
end)
