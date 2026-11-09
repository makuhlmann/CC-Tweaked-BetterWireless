-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.dhcp", function()
    local dhcp = require "cc.internal.net.dhcp"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    local function server_options(net, extra)
        local options = {
            address = ip("10.0.0.1"), prefix = 24, first = ip("10.0.0.100"), last = ip("10.0.0.102"), lease = 100,
            dns = { ip("10.0.0.1") }, domain = "home",
            clock = function() return net.time end,
        }
        for k, v in pairs(extra or {}) do options[k] = v end
        return options
    end

    -- Run a DHCP server on a stack, as dhcpd does.
    local function serve(stack, options)
        local server = dhcp.server(options)
        local socket
        socket = stack:udp_open(dhcp.SERVER_PORT, function(message, _, _, name)
            local reply = server:handle(message)
            if reply then stack:udp_send(socket, address.BROADCAST, dhcp.CLIENT_PORT, reply, name) end
        end)
        return server
    end

    local function client(stack, name)
        return dhcp.start(stack, "top", { hostname = function() return name or "client" end })
    end

    it("cleans hostnames", function()
        expect(dhcp.clean_hostname("My Turtle #7")):eq("my-turtle-7")
        expect(dhcp.clean_hostname("craftos_test.peer")):eq("craftos-test-peer")
        expect(dhcp.clean_hostname("---")):eq(nil)
        expect(dhcp.clean_hostname(nil)):eq(nil)
    end)

    it("gets an address from a server", function()
        local net = network()
        serve(net.add(1, "10.0.0.1/24"), server_options(net))
        local stack = net.add(2)
        local c = client(stack)
        net.run()

        expect(stack.interfaces.top.address):eq(ip("10.0.0.100"))
        expect(stack.interfaces.top.prefix):eq(24)
        local info = c:info()
        expect(info.state):eq("bound")
        expect(info.dns):same { ip("10.0.0.1") }
        expect(info.domain):eq("home")
    end)

    it("gives computers different addresses", function()
        local net = network()
        serve(net.add(1, "10.0.0.1/24"), server_options(net))
        local a, b = net.add(2), net.add(3)
        client(a)
        client(b)
        net.run()

        expect(a.interfaces.top.address):eq(ip("10.0.0.100"))
        expect(b.interfaces.top.address):eq(ip("10.0.0.101"))
    end)

    it("keeps its address when renewing", function()
        local net = network()
        local server = serve(net.add(1, "10.0.0.1/24"), server_options(net))
        local stack = net.add(2)
        local c = client(stack, "laptop")
        net.run()

        net.advance(250)
        expect(c:info().state):eq("bound")
        expect(stack.interfaces.top.address):eq(ip("10.0.0.100"))
        expect(server.leases[2].expires > 250):eq(true)
        expect(server.leases[2].hostname):eq("laptop")
    end)

    it("falls back to a link-local address", function()
        local net = network()
        local stack = net.add(2)
        local c = client(stack)
        net.advance(7)

        expect(c:info().state):eq("link-local")
        expect(stack.interfaces.top.address):eq(dhcp.link_local(2, 1))
        expect(stack.interfaces.top.prefix):eq(16)
        expect(address.format(dhcp.link_local(2, 1))):eq("169.254.1.2")
    end)

    it("picks another link-local address if its first is taken", function()
        local net = network()
        local other = net.add(3)
        other:set_address("top", dhcp.link_local(2, 1), 16)
        local stack = net.add(2)
        client(stack)
        net.advance(10)

        expect(stack.interfaces.top.address):eq(dhcp.link_local(2, 2))
        expect(stack.interfaces.top.duplicate):eq(false)
    end)

    it("switches to a server's address once one appears", function()
        local net = network()
        local stack = net.add(2)
        local c = client(stack)
        net.advance(7)
        expect(c:info().state):eq("link-local")

        serve(net.add(1, "10.0.0.1/24"), server_options(net))
        net.advance(20)
        expect(c:info().state):eq("bound")
        expect(stack.interfaces.top.address):eq(ip("10.0.0.100"))
    end)

    describe("server", function()
        local function server(options)
            local now = 0
            local s = dhcp.server(server_options({ time = 0 }, options))
            s.clock = function() return now end
            return s, function(time) now = time end
        end

        local function discover(s, client, requested)
            return s:handle({ op = "discover", xid = 1, client = client, requested = requested })
        end

        it("gives clients back their old address", function()
            local s = server()
            local offer = discover(s, 5)
            s:handle({ op = "request", xid = 1, client = 5, server = ip("10.0.0.1"), address = offer.address })
            discover(s, 6)

            expect(discover(s, 5).address):eq(ip("10.0.0.100"))
        end)

        it("skips addresses which are in use", function()
            local s = server { in_use = function(addr) return addr == ip("10.0.0.100") end }
            expect(discover(s, 5).address):eq(ip("10.0.0.101"))
        end)

        it("refuses addresses leased to someone else", function()
            local s = server()
            local offer = discover(s, 5)
            s:handle({ op = "request", xid = 1, client = 5, server = ip("10.0.0.1"), address = offer.address })

            local reply = s:handle({ op = "request", xid = 2, client = 6, server = ip("10.0.0.1"), address = offer.address })
            expect(reply.op):eq("nak")
        end)

        it("runs out of addresses", function()
            local s = server()
            for client = 1, 3 do
                local offer = discover(s, client)
                s:handle({ op = "request", xid = 1, client = client, server = ip("10.0.0.1"), address = offer.address })
            end
            expect(discover(s, 4)):eq(nil)
        end)

        it("hands out expired leases again", function()
            local s, set_time = server()
            for client = 1, 3 do
                local offer = discover(s, client)
                s:handle({ op = "request", xid = 1, client = client, server = ip("10.0.0.1"), address = offer.address })
            end
            set_time(1000)
            expect(discover(s, 4).address):eq(ip("10.0.0.100"))
        end)

        it("ignores requests for other servers", function()
            local s = server()
            discover(s, 5)
            expect(s:handle({ op = "request", xid = 1, client = 5, server = ip("10.0.0.9"), address = ip("10.0.0.100") })):eq(nil)
            -- The offer was withdrawn, so someone else can have that address.
            expect(discover(s, 6).address):eq(ip("10.0.0.100"))
        end)
    end)
end)
