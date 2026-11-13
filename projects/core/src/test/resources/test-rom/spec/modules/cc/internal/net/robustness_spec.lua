-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Big networks, slow and lossy links, floods, loops and address conflicts. ]]

describe("The network stack, under stress,", function()
    local helpers = require "support.net_helpers"
    local Stack = require "cc.internal.net.stack"
    local rip = require "cc.internal.net.rip"
    local dhcp = require "cc.internal.net.dhcp"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local ip = helpers.ip

    local default_route = helpers.default_route

    local router = helpers.router

    local count = helpers.count

    -- Run a DHCP server on a stack's interface, as the dhcpd program does.
    local function dhcp_server(stack, name, options)
        local interface = stack.interfaces[name]
        options.address, options.prefix = interface.address, interface.prefix
        options.lease = options.lease or 600
        options.clock = options.clock or stack.clock
        local server = dhcp.server(options)
        local socket
        socket = stack:udp_open(dhcp.SERVER_PORT, function(message, _, _, received_on)
            if received_on ~= name then return end
            local reply = server:handle(message)
            if reply then stack:udp_send(socket, address.BROADCAST, dhcp.CLIENT_PORT, reply, name) end
        end)
        return server
    end

    describe("big networks", function()
        --[[ A grid of routers, each with a network of its own, and hosts on the networks in two corners. ]]
        local function grid(size)
            local net = network()
            net.frame_limit = 5000
            local routers, link = {}, 0
            local function id(row, col) return 100 + row * size + col end
            for row = 1, size do
                routers[row] = {}
                for col = 1, size do
                    local r = net.stack(id(row, col))
                    r.forwarding = true
                    net.connect(r, "lan" .. id(row, col), ("10.%d.%d.1/24"):format(100 + row, col))
                    routers[row][col] = r
                end
            end
            -- Links to the right and below.
            for row = 1, size do
                for col = 1, size do
                    for _, other in ipairs { { row, col + 1 }, { row + 1, col } } do
                        local neighbour = routers[other[1]] and routers[other[1]][other[2]]
                        if neighbour then
                            link = link + 1
                            local name = "link" .. link
                            net.connect(routers[row][col], name, ("10.1.%d.1/24"):format(link))
                            net.connect(neighbour, name, ("10.1.%d.2/24"):format(link))
                        end
                    end
                end
            end
            for row = 1, size do
                for col = 1, size do rip.start(routers[row][col]) end
            end

            local first, last = net.stack(1), net.stack(2)
            net.connect(first, "lan" .. id(1, 1), "10.101.1.2/24")
            default_route(first, "10.101.1.1")
            net.connect(last, "lan" .. id(size, size), ("10.%d.%d.2/24"):format(100 + size, size))
            default_route(last, ("10.%d.%d.1"):format(100 + size, size))
            return net, routers, first, last
        end

        it("route across a grid of 16 routers, and around broken ones", function()
            math.randomseed(1)
            local net, routers, first = grid(4)
            net.advance(60)

            -- The shortest way goes through 7 routers.
            local result = net.ping(first, ip("10.104.4.2"))
            expect(result and result.error):eq(nil)
            expect(result.ttl):eq(32 - 7)

            -- Every router knows every network: 16 of their own and 24 links between them.
            for _, row in ipairs(routers) do
                for _, r in ipairs(row) do expect(#r:route_info()):eq(40) end
            end

            -- Each of the 64 interfaces sends an update every 15 to 18 seconds, and nothing else is sent.
            local before = net.total_frames()
            net.advance(60)
            expect(net.total_frames() - before <= 64 * 4):eq(true)

            -- Break the middle of the grid, and a router next to the start.
            net.remove(routers[3][3])
            net.remove(routers[2][2])
            net.remove(routers[1][2])
            net.advance(200)
            result = net.ping(first, ip("10.104.4.2"))
            expect(result and result.error):eq(nil)
            expect(result.ttl):eq(32 - 7)
        end)

        --[[ A long line of routers, with a network at each. RIP counts 16 as unreachable, so a network 16 routers away
        can't be reached. ]]
        it("reach at most 15 routers away", function()
            math.randomseed(2)
            local net = network()
            local routers = {}
            for i = 1, 17 do
                local links = { { "lan" .. i, ("10.2.%d.1/24"):format(i) } }
                if i > 1 then links[#links + 1] = { "link" .. (i - 1), ("10.1.%d.2/24"):format(i - 1) } end
                if i < 17 then links[#links + 1] = { "link" .. i, ("10.1.%d.1/24"):format(i) } end
                routers[i] = router(net, 100 + i, links)
                rip.start(routers[i])
            end
            net.advance(120)

            local function metric(stack, network)
                for _, route in ipairs(stack:route_info()) do
                    if address.format(route.network, route.prefix) == network then return route.metric end
                end
            end
            expect(metric(routers[2], "10.2.17.0/24")):eq(15)
            expect(metric(routers[1], "10.2.17.0/24")):eq(nil)

            -- A host 15 routers from the far network reaches it.
            local host = net.stack(1)
            net.connect(host, "lan2", "10.2.2.2/24")
            default_route(host, "10.2.2.1")
            local far = net.stack(2)
            net.connect(far, "lan17", "10.2.17.2/24")
            default_route(far, "10.2.17.1")
            net.run()
            local result = net.ping(host, ip("10.2.17.2"))
            expect(result and result.error):eq(nil)
            expect(result.ttl):eq(32 - 16)
        end)

        it("hand out addresses to 80 computers from 60", function()
            math.randomseed(3)
            local net = network()
            net.frame_limit = 5000
            local server = net.add(1, "10.0.0.1/24")
            dhcp_server(server, "top", { first = ip("10.0.0.100"), last = ip("10.0.0.159") })
            local clients = {}
            for i = 1, 80 do
                clients[i] = net.add(100 + i)
                dhcp.start(clients[i], "top", {})
            end
            net.advance(60)

            local seen, leased, link_local = {}, 0, 0
            for _, client in ipairs(clients) do
                local interface = client.interfaces.top
                expect(interface.address):ne(nil)
                expect(interface.duplicate):eq(false)
                expect(seen[interface.address]):eq(nil)
                seen[interface.address] = true
                if interface.prefix == 24 then leased = leased + 1 else link_local = link_local + 1 end
            end
            expect(leased):eq(60)
            expect(link_local):eq(20)
            -- Fewer than 20 frames for each computer.
            expect(net.frames.top < 80 * 20):eq(true)
        end)

        it("keep working over slow and lossy radio links", function()
            math.randomseed(4)
            --[[ host 1 -- a -- router 11 ~~ w1 ~~ router 12 ~~ w2 ~~ router 13 -- c -- host 3
            with the host on a getting its address by DHCP from router 11. ]]
            local net = network()
            local r1 = router(net, 11, { { "a", "10.1.0.1/24" }, { "w1", "10.12.0.1/24", "wireless" } })
            local r2 = router(net, 12, { { "w1", "10.12.0.2/24", "wireless" }, { "w2", "10.23.0.2/24", "wireless" } })
            local r3 = router(net, 13, { { "w2", "10.23.0.3/24", "wireless" }, { "c", "10.3.0.1/24" } })
            for _, r in ipairs { r1, r2, r3 } do rip.start(r) end
            dhcp_server(r1, "a", { first = ip("10.1.0.100"), last = ip("10.1.0.199"), gateway = ip("10.1.0.1") })
            local h1 = net.stack(1)
            net.connect(h1, "a")
            dhcp.start(h1, "a", {
                on_change = function(client)
                    h1:remove_routes(function(route) return route.source == "dhcp" end)
                    if client.lease and client.lease.gateway then
                        h1:add_route { network = 0, prefix = 0, gateway = client.lease.gateway, metric = 10, source = "dhcp" }
                    end
                end,
            })
            local h3 = net.stack(3)
            net.connect(h3, "c", "10.3.0.2/24")
            default_route(h3, "10.3.0.1")

            for _, link in ipairs { "w1", "w2" } do
                net.latency[link], net.loss[link], net.signals[link] = 0.3, 0.1, -70
            end
            net.advance(120)
            expect(h1.interfaces.a.prefix):eq(24)

            local replies = 0
            for _ = 1, 30 do
                local result = net.ping(h1, ip("10.3.0.2"), nil, 3)
                if result and not result.error then
                    replies = replies + 1
                    expect(result.rtt > 4 * 0.3 - 0.01):eq(true)
                end
            end
            -- Each ping crosses a lossy link four times, so about two thirds get through.
            expect(replies >= 10):eq(true)
        end)
    end)

    describe("floods", function()
        local function packet(src, dst, body, proto, ttl)
            local inner = { v = 1, src = src, dst = dst, ttl = ttl or 32, proto = proto or "icmp", id = 1, body = body }
            return { net = 1, src = 9, dst = 1, type = "ip", body = inner }
        end

        it("from many addresses don't fill memory", function()
            local net = network()
            net.frame_limit = 10000
            local target = net.add(1, "10.0.0.1/16")
            net.run()
            for i = 1, 2000 do
                local src = ip("10.0.0.0") + 256 + i
                -- An echo request, and a datagram to a closed port.
                net.inject("top", target.interfaces.top.unicast, packet(src, ip("10.0.0.1"), { type = "echo", id = i, seq = 1 }))
                net.inject("top", target.interfaces.top.unicast, packet(src, ip("10.0.0.1"), { sp = 1, dp = 9999 }, "udp"))
                if i % 100 == 0 then net.advance(0.1) end
            end
            net.advance(1)

            expect(count(target.interfaces.top.neighbours) <= 512):eq(true)
            expect(count(target.last_error) <= 512):eq(true)
        end)

        it("of packets to computers which don't exist are limited", function()
            local net = network()
            net.frame_limit = 10000
            local host = net.add(1, "10.0.0.1/16")
            net.run()
            local wakes = net.wakes[host]
            wakes.net_wakeup = 0

            local before = net.total_frames()
            for i = 1, 500 do host:echo(ip("10.0.0.0") + 256 + i) end
            expect(count(host.interfaces.top.waiting) <= 64):eq(true)
            -- Each scheduled timer doesn't need its own event.
            expect(wakes.net_wakeup <= 1):eq(true)

            net.advance(10)
            expect(net.total_frames() - before <= 64 * 3):eq(true)
            expect(count(host.interfaces.top.waiting)):eq(0)
        end)

        it("of routes are limited", function()
            local net = network()
            local target = net.add(1, "10.0.0.1/24")
            target.forwarding = true
            rip.start(target)
            net.run()

            local routes = {}
            for i = 1, 3000 do routes[i] = { network = ip("172.16.0.0") + i * 256, prefix = 24, metric = 1 } end
            net.inject("top", target.interfaces.top.unicast, packet(ip("10.0.0.9"), ip("10.0.0.1"),
                { sp = rip.PORT, dp = rip.PORT, data = { version = 1, routes = routes } }, "udp"))
            net.advance(1)
            expect(#target.routes <= 1024):eq(true)
        end)

        it("can't loop forever", function()
            -- Two routers which each think the other is the way to 10.9.0.0/16.
            local net = network()
            local r1 = router(net, 11, { { "top", "10.0.0.1/24" } })
            local r2 = router(net, 12, { { "top", "10.0.0.2/24" } })
            r1:add_route { network = ip("10.9.0.0"), prefix = 16, gateway = ip("10.0.0.2"), source = "static" }
            r2:add_route { network = ip("10.9.0.0"), prefix = 16, gateway = ip("10.0.0.1"), source = "static" }
            local host = net.add(1, "10.0.0.5/24")
            default_route(host, "10.0.0.1")
            net.run()

            local before = net.total_frames()
            local result = net.ping(host, ip("10.9.0.1"))
            expect(result.error):eq("TTL expired")
            expect(net.total_frames() - before <= 40):eq(true)

            -- Packets which claim to have a lot of time left (or a time which isn't a number) are dropped.
            for _, ttl in ipairs { 0 / 0, math.huge, 1e9, 256 } do
                before = net.total_frames()
                net.inject("top", r1.interfaces.top.unicast, packet(ip("10.0.0.9"), ip("10.9.0.1"), { type = "echo", id = 1, seq = 1 }, "icmp", ttl))
                net.advance(1)
                expect(net.total_frames() - before <= 300):eq(true)
            end
        end)
    end)

    describe("routers", function()
        it("don't forward link-local addresses", function()
            local net = network()
            local r = router(net, 11, { { "a", "10.1.0.1/24" }, { "b", "10.2.0.1/24" } })
            local far = net.stack(2)
            net.connect(far, "b", "10.2.0.2/24")
            net.run()

            local function inject(src, dst)
                local packet = { v = 1, src = ip(src), dst = ip(dst), ttl = 32, proto = "icmp", id = 1, body = { type = "echo", id = 1, seq = 1 } }
                net.inject("a", r.interfaces.a.unicast, { net = 1, src = 9, dst = 11, type = "ip", body = packet })
                net.advance(1)
            end
            inject("169.254.1.1", "10.2.0.2")
            inject("10.1.0.5", "169.254.3.3")
            expect(r.forwarded):eq(0)
            expect(r.interfaces.a.stats.dropped):eq(2)
        end)
    end)

    describe("address conflicts", function()
        it("leave the computer which had the address first alone", function()
            local net = network()
            local r = net.add(1, "10.0.0.1/24")
            local host = net.add(2, "10.0.0.2/24")
            net.advance(10)

            -- Someone else takes the router's address.
            local intruder = net.add(3, "10.0.0.1/24")
            net.advance(5)
            expect(r.interfaces.top.duplicate):eq(false)
            expect(intruder.interfaces.top.duplicate):eq(true)
            local result = net.ping(host, ip("10.0.0.1"))
            expect(result and result.error):eq(nil)
        end)

        it("move link-local addresses which clash", function()
            -- These two computers' IDs give the same link-local addresses.
            local net = network()
            local a, b = net.add(5), net.add(5 + 254 * 256)
            dhcp.start(a, "top", {})
            dhcp.start(b, "top", {})
            net.advance(30)

            expect(a.interfaces.top.address):ne(nil)
            expect(b.interfaces.top.address):ne(nil)
            expect(a.interfaces.top.address):ne(b.interfaces.top.address)
            expect(a.interfaces.top.duplicate):eq(false)
            expect(b.interfaces.top.duplicate):eq(false)
        end)

        it("make DHCP clients ask for another address", function()
            -- The server doesn't know that a computer with a fixed address has 10.0.0.100.
            local net = network()
            local server = net.add(1, "10.0.0.1/24")
            dhcp_server(server, "top", { first = ip("10.0.0.100"), last = ip("10.0.0.110") })
            local fixed = net.add(2, "10.0.0.100/24")
            net.advance(5)

            local client = net.add(3)
            dhcp.start(client, "top", {})
            net.advance(30)

            expect(fixed.interfaces.top.duplicate):eq(false)
            expect(client.interfaces.top.duplicate):eq(false)
            expect(client.interfaces.top.prefix):eq(24)
            expect(client.interfaces.top.address):ne(ip("10.0.0.100"))
        end)

        it("between two DHCP servers are sorted out", function()
            math.randomseed(5)
            local net = network()
            net.frame_limit = 5000
            local s1, s2 = net.add(1, "10.0.0.1/24"), net.add(2, "10.0.0.2/24")
            dhcp_server(s1, "top", { first = ip("10.0.0.100"), last = ip("10.0.0.149") })
            dhcp_server(s2, "top", { first = ip("10.0.0.100"), last = ip("10.0.0.149") })
            local clients = {}
            for i = 1, 20 do
                clients[i] = net.add(100 + i)
                dhcp.start(clients[i], "top", {})
            end
            net.advance(120)

            local seen = {}
            for _, client in ipairs(clients) do
                local interface = client.interfaces.top
                expect(interface.prefix):eq(24)
                expect(interface.duplicate):eq(false)
                expect(seen[interface.address]):eq(nil)
                seen[interface.address] = true
            end
        end)
    end)

    describe("DHCP servers", function()
        it("don't let leases pile up", function()
            -- A new client every 10 seconds, for a long time, each wanting a 60 second lease.
            local now = 0
            local server = dhcp.server {
                address = ip("10.0.0.1"), prefix = 24, first = ip("10.0.0.100"), last = ip("10.0.0.109"), lease = 60,
                clock = function() return now end,
            }
            for client = 1, 500 do
                now = now + 10
                local offer = server:handle { op = "discover", xid = client, client = client }
                expect(offer):ne(nil)
                server:handle { op = "request", xid = client, client = client, server = ip("10.0.0.1"), address = offer.address }
            end
            expect(count(server.leases) <= 10):eq(true)
            expect(count(server.offers) <= 10):eq(true)
        end)

        it("avoid addresses which clients decline", function()
            local server = dhcp.server {
                address = ip("10.0.0.1"), prefix = 24, first = ip("10.0.0.100"), last = ip("10.0.0.109"), lease = 60,
                clock = function() return 0 end,
            }
            local offer = server:handle { op = "discover", xid = 1, client = 5 }
            server:handle { op = "request", xid = 1, client = 5, server = ip("10.0.0.1"), address = offer.address }
            server:handle { op = "decline", xid = 1, client = 5, server = ip("10.0.0.1"), address = offer.address }
            expect(server:handle { op = "discover", xid = 2, client = 5 }.address):ne(offer.address)
            expect(server:handle { op = "discover", xid = 3, client = 6 }.address):ne(offer.address)
        end)
    end)

    describe("misbehaving servers", function()
        it("don't make DHCP clients flood the network", function()
            -- A server which offers addresses, then refuses every request.
            local net = network()
            local server = net.add(1, "10.0.0.1/24")
            local socket
            socket = server:udp_open(dhcp.SERVER_PORT, function(message)
                local op = message.op == "discover" and "offer" or "nak"
                server:udp_send(socket, address.BROADCAST, dhcp.CLIENT_PORT, {
                    op = op, xid = message.xid, client = message.client, server = ip("10.0.0.1"), address = ip("10.0.0.50"),
                    prefix = 24, lease = 600,
                }, "top")
            end)
            local client = net.add(2)
            dhcp.start(client, "top", {})
            net.advance(300)

            -- A few attempts, then less and less often.
            expect(net.frames.top < 100):eq(true)
            expect(client.interfaces.top.address):ne(nil)
        end)
    end)

    it("keep their timers working", function()
        local net = network()
        local stack = net.add(1, "10.0.0.1/24")
        expect(pcall(stack.schedule, stack, 0 / 0, function() end)):eq(false)
        expect(pcall(stack.schedule, stack, math.huge, function() end)):eq(false)
        local deadline = stack:next_deadline()
        expect(deadline == nil or deadline == deadline):eq(true)
        expect(Stack.INFINITY):eq(16)
    end)
end)
