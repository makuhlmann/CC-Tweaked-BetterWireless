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
