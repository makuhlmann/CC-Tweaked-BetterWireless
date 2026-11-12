-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.stack", function()
    local Stack = require "cc.internal.net.stack"
    local address = require "cc.net.address"

    local function ip(text) return (address.parse(text)) end

    local network = require "support.virtual_network"

    it("uses separate channels for each band", function()
        expect({ Stack.channels(1500, "low") }):same { 500, 1000 }
        expect({ Stack.channels(5, "high") }):same { 1029, 61024 }
    end)

    it("gives radios either band, and wired modems the high band's channels", function()
        local stack = network().stack(5)
        -- Ender modems are radios too.
        expect(stack:add_interface("a", "a", "wireless", "low")):matches { band = "low", unicast = 5, broadcast = 1000 }
        expect(stack:add_interface("b", "b", "ender", "low")):matches { band = "low", unicast = 5, broadcast = 1000 }
        expect(stack:add_interface("c", "c", "ender", "high")):matches { band = "high", unicast = 1029, broadcast = 61024 }
        expect(stack:add_interface("d", "d", "wired", "low")):matches { band = "high", unicast = 1029, broadcast = 61024 }
    end)

    it("answers pings", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        net.add(2, "10.0.0.2/24")
        net.run()

        local id = a:echo(ip("10.0.0.2"))
        net.run()

        local result = a:echo_result(id)
        expect(result.done):eq(true)
        expect(result.error):eq(nil)
        expect(result.from):eq(ip("10.0.0.2"))
        expect(result.ttl):eq(32)
    end)

    it("finds computers it hasn't heard from", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        local b = net.add(2, "10.0.0.2/24")
        net.run()
        a.interfaces.top.neighbours = {}
        b.interfaces.top.neighbours = {}

        local id = a:echo(ip("10.0.0.2"))
        net.run()

        expect(a:echo_result(id).error):eq(nil)
        expect(a.interfaces.top.neighbours[ip("10.0.0.2")].id):eq(2)
        -- The other side learns about us from our question, without asking itself.
        expect(b.interfaces.top.neighbours[ip("10.0.0.1")].id):eq(1)
    end)

    it("gives up on computers which don't answer", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        net.run()

        local id = a:echo(ip("10.0.0.9"))
        net.run()
        expect(a:echo_result(id).done):eq(false)

        net.advance(5)
        expect(a:echo_result(id).error):eq("Host unreachable")
    end)

    it("reports networks it isn't on", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        expect({ a:echo(ip("10.1.0.1")) }):same { nil, "Network unreachable" }
    end)

    it("pings itself", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")

        local own = a:echo(ip("10.0.0.1"))
        expect(a:echo_result(own).done):eq(true)
        local loopback = a:echo(ip("127.0.0.1"))
        expect(a:echo_result(loopback).done):eq(true)
        expect(#net.queue):eq(1) -- Just the announcement of our address.
    end)

    it("answers broadcast pings", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        net.add(2, "10.0.0.2/24")
        net.run()

        local id = a:echo(ip("10.0.0.255"))
        net.run()
        expect(a:echo_result(id).from):eq(ip("10.0.0.2"))
    end)

    describe("a series of pings", function()
        local function take_all(stack, id)
            local replies = {}
            while true do
                local reply = stack:echo_take(id)
                if not reply then return replies end
                replies[#replies + 1] = reply
            end
        end

        it("numbers each request, and keeps every reply, saying which request it answers", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            net.add(2, "10.0.0.2/24")
            net.add(3, "10.0.0.3/24")
            net.run()

            local id = a:echo_series()
            expect({ a:echo_next(id, ip("10.0.0.2")) }):same { 1 }
            -- Everyone answers a broadcast: each answer after the first is a duplicate.
            expect({ a:echo_next(id, ip("10.0.0.255")) }):same { 2 }
            net.run()

            local replies = take_all(a, id)
            expect(replies[1]):matches { seq = 1, from = ip("10.0.0.2"), ttl = 32, duplicate = false }
            expect(type(replies[1].rtt)):eq("number")
            local from = {}
            for i = 2, #replies do
                expect(replies[i]):matches { seq = 2, duplicate = i > 2 }
                from[replies[i].from] = true
            end
            expect({ from[ip("10.0.0.2")], from[ip("10.0.0.3")] }):same { true, true }
        end)

        it("keeps errors about requests, and says which couldn't be sent", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            net.run()

            local id = a:echo_series()
            expect({ a:echo_next(id, ip("10.0.0.9")) }):same { 1 }
            -- One which can't be sent still uses up a number.
            expect({ a:echo_next(id, ip("10.1.0.1")) }):same { 2, "Network unreachable" }
            net.run()
            expect(a:echo_take(id)):eq(nil)

            net.advance(5)
            expect(take_all(a, id)):same { { seq = 1, error = "Host unreachable", from = ip("10.0.0.1") } }
            expect({ a:echo_next(id, ip("10.0.0.1")) }):same { 3 }
            expect(take_all(a, id)):matches { { seq = 3, from = ip("10.0.0.1"), duplicate = false } }
        end)

        it("ignores replies once it's ended, and to requests it didn't send", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            local b = net.add(2, "10.0.0.2/24")
            net.run()

            local id = a:echo_series()
            a:echo_next(id, ip("10.0.0.2"))
            a:forget_echo(id)
            net.run()
            expect(a:echo_take(id)):eq(nil)
            expect(a:echo_next(id, ip("10.0.0.2"))):eq(nil)

            -- Replies to a series' requests which weren't sent, or with no number, aren't kept.
            local other = a:echo_series()
            for _, seq in ipairs { 5, "x", 1.5 } do
                b:send(ip("10.0.0.1"), "icmp", { type = "echo_reply", id = other, seq = seq })
            end
            net.run()
            expect(a:echo_take(other)):eq(nil)
        end)
    end)

    it("reports unknown protocols", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        net.add(2, "10.0.0.2/24")
        net.run()

        local reported
        a.error_handlers.mystery = function(_, message) reported = message.code end
        a:send(ip("10.0.0.2"), "mystery", {})
        net.run()
        expect(reported):eq("proto")
    end)

    it("ignores frames for other computers", function()
        local net = network()
        local c = net.add(3, "10.0.0.3/24")
        local interface = c.interfaces.top
        local before = interface.stats.frames_in

        local packet = { v = 1, src = ip("10.0.0.1"), dst = ip("10.0.0.3"), ttl = 32, proto = "icmp", body = { type = "echo", id = 1, seq = 1 } }
        c:receive("top", interface.unicast, { net = 1, src = 1, dst = 2, type = "ip", body = packet })
        c:receive("top", interface.unicast, { net = 1, src = 3, dst = 3, type = "ip", body = packet })
        c:receive("top", interface.unicast, { src = 1, dst = 3, type = "ip", body = packet })
        expect(interface.stats.frames_in):eq(before)
        expect(#net.queue):eq(1) -- Just the announcement of our address.
    end)

    it("notices duplicate addresses", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        local b = net.add(2, "10.0.0.1/24")
        net.run()

        expect(a.interfaces.top.duplicate):eq(true)
        expect(b.interfaces.top.duplicate):eq(true)
        expect({ a:echo(ip("10.0.0.5")) }):same { nil, "Network unreachable" }
    end)

    describe("datagrams", function()
        it("are delivered to sockets", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            local b = net.add(2, "10.0.0.2/24")
            net.run()

            local server = b:udp_open(7000)
            local client = a:udp_open()
            expect(client.port >= 49152):eq(true)
            expect(a:udp_send(client, ip("10.0.0.2"), 7000, { hello = "world" })):eq(true)
            net.run()

            expect(#server.queue):eq(1)
            expect(server.queue[1]):same { data = { hello = "world" }, from = ip("10.0.0.1"), port = client.port, interface = "top" }
        end)

        it("refuse data which some links couldn't carry, and say why", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            local b = net.add(2, "10.0.0.2/24")
            net.run()
            local server = b:udp_open(7000)
            local client = a:udp_open()
            local frames = net.total_frames()

            local recursive = {}
            recursive.self = recursive
            local deep = {}
            for _ = 1, 60 do deep = { deep } end
            local dst = ip("10.0.0.2")
            expect({ a:udp_send(client, dst, 7000, print) }):same { nil, "Can't send a function" }
            expect({ a:udp_send(client, dst, 7000, { ok = true, callback = print }) }):same { nil, "Can't send a function" }
            expect({ a:udp_send(client, dst, 7000, recursive) }):same { nil, "Can't send a table which contains itself" }
            expect({ a:udp_send(client, dst, 7000, { [{}] = 1 }) }):same { nil, "Can't send a table with a table as a key" }
            expect({ a:udp_send(client, dst, 7000, deep) }):same { nil, "Can't send tables nested more than 60 deep" }
            expect({ a:udp_send(client, dst, 7000, ("x"):rep(64 * 1024)) }):same { nil, "Message too large" }
            expect({ a:udp_send(client, 0xFFFFFFFF, 7000, recursive, "top") }):same { nil, "Can't send a table which contains itself" }
            net.run()
            expect(net.total_frames()):eq(frames)
            expect(#server.queue):eq(0)

            -- The socket still works, and a datagram may hold nothing at all.
            expect(a:udp_send(client, dst, 7000, nil)):eq(true)
            expect(a:udp_send(client, dst, 7000, false)):eq(true)
            expect(a:udp_send(client, dst, 7000, { 1, { two = 2 } })):eq(true)
            net.run()
            expect(#server.queue):eq(3)
            expect(server.queue[1].data):eq(nil)
            expect(server.queue[2].data):eq(false)
            expect(server.queue[3].data):same { 1, { two = 2 } }
        end)

        it("call handlers instead of queueing", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            local b = net.add(2, "10.0.0.2/24")
            net.run()

            local received
            b:udp_open(7000, function(data, from, port) received = { data, from, port } end)
            local client = a:udp_open()
            a:udp_send(client, ip("10.0.0.2"), 7000, "hi")
            net.run()
            expect(received):same { "hi", ip("10.0.0.1"), client.port }
        end)

        it("report closed ports", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            net.add(2, "10.0.0.2/24")
            net.run()

            local client = a:udp_open()
            local reported
            client.on_error = function(err) reported = err end
            a:udp_send(client, ip("10.0.0.2"), 7000, "hi")
            net.run()
            expect(reported):eq("Port unreachable")
        end)

        it("can be broadcast without an address", function()
            local net = network()
            local a = net.add(1)
            local b = net.add(2, "10.0.0.2/24")
            net.run()

            local server = b:udp_open(67)
            local client = a:udp_open(68)
            a:udp_send(client, 0xFFFFFFFF, 67, "anyone?", "top")
            net.run()
            expect(server.queue[1].from):eq(0)
        end)

        it("refuse ports which are in use", function()
            local net = network()
            local a = net.add(1, "10.0.0.1/24")
            expect(a:udp_open(7000) ~= nil):eq(true)
            expect({ a:udp_open(7000) }):same { nil, "Port 7000 is in use" }
        end)
    end)

    it("runs timers in order, unless cancelled", function()
        local net = network()
        local a = net.add(1, "10.0.0.1/24")
        local ran = {}
        a:schedule(2, function() ran[#ran + 1] = "second" end)
        a:schedule(1, function() ran[#ran + 1] = "first" end)
        local cancelled = a:schedule(1.5, function() ran[#ran + 1] = "cancelled" end)
        a:cancel(cancelled)

        net.advance(3)
        expect(ran):same { "first", "second" }
    end)
end)
