-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Routing", function()
    local helpers = require "support.net_helpers"
    local Stack = require "cc.internal.net.stack"
    local rip = require "cc.internal.net.rip"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local ip = helpers.ip

    local default_route = helpers.default_route

    local router = helpers.router

    --[[ Two hosts with a router between them:

        host 1 (10.1.0.2) -- a -- (10.1.0.1) router 2 (10.2.0.1) -- b -- (10.2.0.2) host 3
    ]]
    local function one_router()
        local net = network()
        local h1 = net.stack(1)
        net.connect(h1, "a", "10.1.0.2/24")
        default_route(h1, "10.1.0.1")
        local r = router(net, 2, { { "a", "10.1.0.1/24" }, { "b", "10.2.0.1/24" } })
        local h3 = net.stack(3)
        net.connect(h3, "b", "10.2.0.2/24")
        default_route(h3, "10.2.0.1")
        net.run()
        return net, h1, r, h3
    end

    it("takes the longest prefix which matches, whatever order routes were added in", function()
        local net = network()
        local s = net.stack(1)
        net.connect(s, "a", "10.1.0.2/24")
        net.connect(s, "b", "10.2.0.2/24")
        net.run()
        s:add_route { network = 0, prefix = 0, gateway = ip("10.1.0.1"), source = "static" }
        s:add_route { network = ip("10.9.0.0"), prefix = 16, gateway = ip("10.1.0.1"), source = "static" }
        s:add_route { network = ip("10.9.9.0"), prefix = 24, gateway = ip("10.2.0.1"), source = "static", metric = 5 }
        s:add_route { network = ip("10.9.9.0"), prefix = 24, gateway = ip("10.1.0.1"), source = "static", metric = 2 }

        local function via(addr)
            local interface, hop = s:route(ip(addr))
            return interface and interface.name, hop and address.format(hop)
        end
        -- The cheaper of the two /24s, then the /16, then the default, then our own network.
        expect({ via("10.9.9.7") }):same { "a", "10.1.0.1" }
        expect({ via("10.9.1.7") }):same { "a", "10.1.0.1" }
        expect({ via("8.8.8.8") }):same { "a", "10.1.0.1" }
        expect({ via("10.2.0.9") }):same { "b", "10.2.0.9" }
        local prefixes = {}
        for i, route in ipairs(s.routes) do prefixes[i] = route.prefix end
        expect(prefixes):same { 24, 24, 16, 0 }
    end)

    describe("forwarding", function()
        it("passes packets between networks", function()
            local net, h1, r = one_router()

            local result = net.ping(h1, ip("10.2.0.2"))
            expect(result.error):eq(nil)
            expect(result.from):eq(ip("10.2.0.2"))
            expect(result.ttl):eq(31) -- One router on the way back.
            expect(r.forwarded):eq(2)
        end)

        it("only happens on routers", function()
            local net, h1, r = one_router()
            r.forwarding = false

            expect(net.ping(h1, ip("10.2.0.2"))):eq(nil)
            expect(r.interfaces.a.stats.dropped):eq(1)
        end)

        it("reports packets which run out of time from the router", function()
            local net, h1 = one_router()

            local result = net.ping(h1, ip("10.2.0.2"), 1)
            expect(result.error):eq("TTL expired")
            expect(result.from):eq(ip("10.1.0.1"))
        end)

        it("reports networks the router can't reach", function()
            local net, h1 = one_router()

            local result = net.ping(h1, ip("10.9.0.1"))
            expect(result.error):eq("Network unreachable")
            expect(result.from):eq(ip("10.1.0.1"))
        end)

        it("reports computers the router can't find", function()
            local net, h1 = one_router()

            local result = net.ping(h1, ip("10.2.0.9"))
            expect(result.error):eq("Host unreachable")
            -- The router doesn't know which interface the packet came in on any more, so uses the one facing us.
            expect(result.from):eq(ip("10.1.0.1"))
        end)

        it("doesn't forward broadcasts", function()
            local net, h1, r = one_router()

            expect(net.ping(h1, ip("10.1.0.255"), nil, 1).from):eq(ip("10.1.0.1"))
            expect(r.forwarded):eq(0)

            -- Nor broadcasts to a whole network on the other side.
            expect(net.ping(h1, ip("10.2.0.255"), nil, 1)):eq(nil)
            expect(r.forwarded):eq(0)
            expect(r.interfaces.a.stats.dropped):eq(1)
        end)
    end)

    describe("routes", function()
        local function stack_on(addr)
            return network().add(1, addr)
        end

        it("prefer the most specific", function()
            local s = stack_on("10.0.0.1/24")
            s:add_route { network = ip("10.0.0.0"), prefix = 8, gateway = ip("10.0.0.2"), source = "static" }
            s:add_route { network = ip("10.5.0.0"), prefix = 16, gateway = ip("10.0.0.3"), metric = 5, source = "static" }
            default_route(s, "10.0.0.4")

            expect(select(2, s:route(ip("10.5.1.1")))):eq(ip("10.0.0.3"))
            expect(select(2, s:route(ip("10.6.0.1")))):eq(ip("10.0.0.2"))
            expect(select(2, s:route(ip("192.168.0.1")))):eq(ip("10.0.0.4"))
            -- Our own network is more specific than any of them.
            expect(select(2, s:route(ip("10.0.0.9")))):eq(ip("10.0.0.9"))
        end)

        it("prefer the cheapest, and ignore unreachable ones", function()
            local s = stack_on("10.0.0.1/24")
            s:add_route { network = ip("10.5.0.0"), prefix = 16, gateway = ip("10.0.0.2"), metric = 3, source = "static" }
            s:add_route { network = ip("10.5.0.0"), prefix = 16, gateway = ip("10.0.0.3"), metric = 2, source = "static" }
            s:add_route { network = ip("10.5.0.0"), prefix = 16, gateway = ip("10.0.0.4"), metric = Stack.INFINITY, source = "rip" }

            expect(select(2, s:route(ip("10.5.0.1")))):eq(ip("10.0.0.3"))
        end)

        it("need a router on our own network", function()
            local s = stack_on("10.0.0.1/24")
            s:add_route { network = ip("10.5.0.0"), prefix = 16, gateway = ip("10.7.0.1"), source = "static" }

            expect(s:route(ip("10.5.0.1"))):eq(nil)
            expect({ s:echo(ip("10.5.0.1")) }):same { nil, "Network unreachable" }
        end)

        it("are listed with our own networks", function()
            local s = stack_on("10.0.0.1/24")
            default_route(s, "10.0.0.4")

            expect(s:route_info()):same {
                { network = ip("10.0.0.0"), prefix = 24, interface = "top", metric = 0, source = "connected" },
                { network = 0, prefix = 0, gateway = ip("10.0.0.4"), interface = "top", metric = 1, source = "static" },
            }
        end)
    end)

    describe("the firewall", function()
        it("stops denied packets", function()
            local net, h1, r = one_router()
            r:set_firewall { { action = "deny", src = ip("10.1.0.0"), src_prefix = 24, dst = ip("10.2.0.0"), dst_prefix = 24 } }

            local result = net.ping(h1, ip("10.2.0.2"))
            expect(result.error):eq("Prohibited")
            expect(result.from):eq(ip("10.1.0.1"))
            expect(r.forwarded):eq(0)
        end)

        it("lets the first matching rule decide", function()
            local net, h1, r = one_router()
            r:set_firewall {
                { action = "allow", src = ip("10.1.0.2"), src_prefix = 32 },
                { action = "deny", src = ip("10.1.0.0"), src_prefix = 24 },
            }

            expect(net.ping(h1, ip("10.2.0.2")).error):eq(nil)
        end)

        it("matches protocols, ports and interfaces", function()
            local _, _, r = one_router()
            r:set_firewall {
                { action = "deny", proto = "udp", port = 7 },
                { action = "deny", interface = "b" },
            }

            local a, b = r.interfaces.a, r.interfaces.b
            local function packet(proto, port) return { src = ip("10.1.0.2"), dst = ip("10.2.0.2"), proto = proto, body = { dp = port } } end
            expect(r:firewall_allows(packet("udp", 7), a)):eq(false)
            expect(r:firewall_allows(packet("udp", 8), a)):eq(true)
            expect(r:firewall_allows(packet("icmp", 7), a)):eq(true)
            expect(r:firewall_allows(packet("icmp"), b)):eq(false)
        end)
    end)

    describe("RIP", function()
        --[[ Three routers in a line, with a host at each end:

            host 1 -- a -- router 11 -- ab -- router 12 -- bc -- router 13 -- c -- host 3
        ]]
        local function line(options)
            local net = network()
            local h1 = net.stack(1)
            net.connect(h1, "a", "10.1.0.2/24")
            default_route(h1, "10.1.0.1")
            local r1 = router(net, 11, { { "a", "10.1.0.1/24" }, { "ab", "10.12.0.1/24" } })
            local r2 = router(net, 12, { { "ab", "10.12.0.2/24" }, { "bc", "10.23.0.2/24" } })
            local r3 = router(net, 13, { { "bc", "10.23.0.3/24" }, { "c", "10.3.0.1/24" } })
            local h3 = net.stack(3)
            net.connect(h3, "c", "10.3.0.2/24")
            default_route(h3, "10.3.0.1")

            local rips = {}
            for i, r in ipairs { r1, r2, r3 } do rips[i] = rip.start(r, options and options[i]) end
            return net, h1, h3, { r1, r2, r3 }, rips
        end

        local function find_route(stack, network)
            local addr, prefix = address.parse(network)
            for _, route in ipairs(stack.routes) do
                if route.network == addr and route.prefix == prefix then return route end
            end
        end

        it("finds routes across several routers", function()
            local net, h1 = line()
            net.advance(60)

            local result = net.ping(h1, ip("10.3.0.2"))
            expect(result.error):eq(nil)
            expect(result.ttl):eq(29)

            -- What traceroute does.
            local hops = {}
            for ttl = 1, 4 do
                net.advance(1)
                local hop = net.ping(h1, ip("10.3.0.2"), ttl)
                hops[ttl] = { hop.error or "reply", address.format(hop.from) }
            end
            expect(hops):same {
                { "TTL expired", "10.1.0.1" },
                { "TTL expired", "10.12.0.2" },
                { "TTL expired", "10.23.0.3" },
                { "reply", "10.3.0.2" },
            }
        end)

        it("adds up the cost of each link", function()
            local net, _, _, routers = line()
            net.advance(60)

            expect(find_route(routers[1], "10.3.0.0/24")):matches { gateway = ip("10.12.0.2"), interface = "ab", metric = 2 }
            expect(find_route(routers[3], "10.1.0.0/24")):matches { gateway = ip("10.23.0.2"), interface = "bc", metric = 2 }
            expect(find_route(routers[2], "10.12.0.0/24")):eq(nil) -- Its own network.
        end)

        it("doesn't advertise routes back where they came from", function()
            local net, _, _, routers, rips = line()
            net.advance(60)

            local back, onward = {}, {}
            for _, route in ipairs(rips[2]:routes_for(routers[2].interfaces.ab)) do back[address.format(route.network, route.prefix)] = route.metric end
            for _, route in ipairs(rips[2]:routes_for(routers[2].interfaces.bc)) do onward[address.format(route.network, route.prefix)] = route.metric end
            expect(back["10.1.0.0/24"]):eq(Stack.INFINITY)
            expect(onward["10.1.0.0/24"]):eq(1)
        end)

        it("finds another way when a router breaks", function()
            --[[ A square of routers, so there are two ways between the hosts:

                host 1 -- a -- router 11 -- ab -- router 12 -- bd -- router 14 -- d -- host 4
                                   |                                    |
                                   ac -------- router 13 -------- cd ---
            ]]
            local net = network()
            local h1 = net.stack(1)
            net.connect(h1, "a", "10.1.0.2/24")
            default_route(h1, "10.1.0.1")
            local r1 = router(net, 11, { { "a", "10.1.0.1/24" }, { "ab", "10.12.0.1/24" }, { "ac", "10.13.0.1/24" } })
            local r2 = router(net, 12, { { "ab", "10.12.0.2/24" }, { "bd", "10.24.0.2/24" } })
            local r3 = router(net, 13, { { "ac", "10.13.0.3/24" }, { "cd", "10.34.0.3/24" } })
            local r4 = router(net, 14, { { "bd", "10.24.0.4/24" }, { "cd", "10.34.0.4/24" }, { "d", "10.4.0.1/24" } })
            local h4 = net.stack(4)
            net.connect(h4, "d", "10.4.0.2/24")
            default_route(h4, "10.4.0.1")
            for _, r in ipairs { r1, r2, r3, r4 } do rip.start(r) end

            net.advance(60)
            expect(net.ping(h1, ip("10.4.0.2")).ttl):eq(29)

            -- Break whichever router the traffic goes through.
            local via = find_route(r1, "10.4.0.0/24").interface
            local broken, other = r2, "ac"
            if via == "ac" then broken, other = r3, "ab" end
            net.remove(broken)

            net.advance(200)
            expect(find_route(r1, "10.4.0.0/24").interface):eq(other)
            local result = net.ping(h1, ip("10.4.0.2"))
            expect(result.error):eq(nil)
            expect(result.ttl):eq(29)
        end)

        it("forgets routes which aren't refreshed", function()
            local net, _, _, routers = line()
            net.advance(60)
            net.remove(routers[3])

            net.advance(110)
            expect(find_route(routers[1], "10.3.0.0/24").metric):eq(Stack.INFINITY)
            net.advance(70)
            expect(find_route(routers[1], "10.3.0.0/24")):eq(nil)
        end)

        it("offers a default route", function()
            local net, h1, _, routers = line { nil, nil, { default = true } }
            net.advance(60)

            expect(find_route(routers[1], "0.0.0.0/0")):matches { gateway = ip("10.12.0.2"), metric = 2 }
            -- The router offering it doesn't learn one back.
            expect(find_route(routers[3], "0.0.0.0/0")):eq(nil)
            -- Packets for nowhere get as far as the last router.
            local result = net.ping(h1, ip("192.168.0.1"))
            expect(result.error):eq("Network unreachable")
            expect(result.from):eq(ip("10.23.0.3"))
        end)

        it("advertises each network once, at its lowest cost", function()
            local _, _, _, routers, rips = line { nil, nil, { default = true } }
            routers[3]:add_route { network = ip("10.3.0.0"), prefix = 24, gateway = ip("10.23.0.2"), metric = 5, source = "static" }
            routers[3]:add_route { network = 0, prefix = 0, gateway = ip("10.3.0.9"), metric = 3, source = "static" }

            local seen = {}
            for _, route in ipairs(rips[3]:routes_for(routers[3].interfaces.bc)) do
                local key = address.format(route.network, route.prefix)
                expect(seen[key]):describe("Duplicate " .. key):eq(nil)
                seen[key] = route.metric
            end
            expect(seen["10.3.0.0/24"]):eq(0)
            expect(seen["0.0.0.0/0"]):eq(0)
        end)

        it("advertises fixed routes", function()
            local net, _, _, routers = line()
            routers[3]:add_route { network = ip("10.50.0.0"), prefix = 16, gateway = ip("10.3.0.9"), metric = 2, source = "static" }
            net.advance(60)

            expect(find_route(routers[1], "10.50.0.0/16")):matches { gateway = ip("10.12.0.2"), metric = 4, source = "rip" }
        end)

        it("makes weak radio links cost more", function()
            local net = network()
            net.signals.w = -85
            local r1 = router(net, 11, { { "a", "10.1.0.1/24" }, { "w", "10.12.0.1/24", "wireless" } })
            local r2 = router(net, 12, { { "w", "10.12.0.2/24", "wireless" }, { "b", "10.2.0.1/24" } })
            rip.start(r1)
            rip.start(r2)
            net.advance(60)

            expect(find_route(r1, "10.2.0.0/24").metric):eq(3)
            expect(find_route(r2, "10.1.0.0/24").metric):eq(3)
        end)

        it("makes weak links between ender modems cost more too, as they're radios", function()
            local net = network()
            net.signals.w = -85
            local r1 = router(net, 11, { { "a", "10.1.0.1/24" }, { "w", "10.12.0.1/24", "ender" } })
            local r2 = router(net, 12, { { "w", "10.12.0.2/24", "ender" }, { "b", "10.2.0.1/24" } })
            rip.start(r1)
            rip.start(r2)
            net.advance(60)

            expect(find_route(r1, "10.2.0.0/24").metric):eq(3)
            expect(find_route(r2, "10.1.0.0/24").metric):eq(3)
        end)

        it("ignores updates without the right key", function()
            local function hmac(key, data) return key .. ":" .. data end
            local net, _, _, routers = line {
                { key = "secret", hmac = hmac }, { key = "secret", hmac = hmac }, { key = "other", hmac = hmac },
            }
            net.advance(60)

            expect(find_route(routers[1], "10.23.0.0/24")):ne(nil)
            expect(find_route(routers[1], "10.3.0.0/24")):eq(nil)
            expect(find_route(routers[3], "10.12.0.0/24")):eq(nil)
        end)

        it("ignores signed updates which are sent again later, or are too old", function()
            local function hmac(key, data) return key .. ":" .. data end
            local time = 1e12
            local function epoch() return time end
            local net = network()
            local r1 = router(net, 1, { { "a", "10.1.0.1/24" } })
            local r2 = router(net, 2, { { "a", "10.1.0.2/24" } })
            net.run()
            rip.start(r1, { key = "secret", hmac = hmac, epoch = epoch })

            -- An update from r2, as a router which knows the key would send it.
            local function update(metric, at)
                local routes = { { network = ip("10.9.0.0"), prefix = 24, metric = metric } }
                local text = ("%d/%d/%d|%d|%d"):format(ip("10.9.0.0"), 24, metric, at, ip("10.1.0.2"))
                local message = { version = 2, routes = routes, time = at, mac = hmac("secret", text) }
                r2:send_broadcast("a", "udp", { sp = rip.PORT, dp = rip.PORT, data = message })
                net.run()
            end
            local function metric()
                local route = find_route(r1, "10.9.0.0/24")
                return route and route.metric
            end

            update(1, time)
            expect(metric()):eq(2)
            -- r2 withdraws the route.
            time = time + 1000
            update(16, time)
            expect(metric()):eq(16)
            -- Its first update, sent again, doesn't bring it back: nor does one from long ago, or far in the future.
            update(1, time - 1000)
            expect(metric()):eq(16)
            time = time + 1000
            update(1, time - 120 * 1000)
            update(1, time + 120 * 1000)
            expect(metric()):eq(16)
            -- A new one does, and a signature over another time or sender doesn't count.
            update(1, time)
            expect(metric()):eq(2)
        end)

        it("forgets what it learned when stopped", function()
            local net, _, _, routers, rips = line()
            net.advance(60)
            expect(find_route(routers[1], "10.3.0.0/24")):ne(nil)

            rips[1]:stop()
            expect(find_route(routers[1], "10.3.0.0/24")):eq(nil)
            expect(routers[1].udp[rip.PORT]):eq(nil)
        end)
    end)
end)
