-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Virtual interfaces and frame handlers", function()
    local tcp = require "cc.internal.net.tcp"
    local rip = require "cc.internal.net.rip"
    local link = require "cc.internal.net.link"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    it("carry pings and connections", function()
        local net = network()
        local a, b = net.stack(1), net.stack(2)
        net.virtual_link(a, b, "v", "10.9.0.1/24", "10.9.0.2/24")
        net.run()

        local result = net.ping(a, ip("10.9.0.2"))
        expect(result and result.error):eq(nil)
        expect(result.ttl):eq(32)
        -- No neighbour discovery happens on them.
        expect(net.frames.v):eq(2)

        local listener = assert(tcp.listen(b, 80))
        local client = assert(tcp.connect(a, ip("10.9.0.2"), 80))
        net.advance(0.5)
        local server = listener:accept()
        expect(server ~= nil):eq(true)
        for i = 1, 30 do assert(client:send(i)) end
        -- The receiver takes 16 at a time, and more come as it reads.
        local got = {}
        for _ = 1, 20 do
            net.advance(0.5)
            while true do
                local ok, value = server:take()
                if not ok then break end
                got[#got + 1] = value
            end
        end
        expect(#got):eq(30)
        for i = 1, 30 do expect(got[i]):eq(i) end
    end)

    it("can be routed through", function()
        -- host 1 ~~ v ~~ router 2 -- top -- host 3
        local net = network()
        local h1, r, h3 = net.stack(1), net.stack(2), net.stack(3)
        net.virtual_link(h1, r, "v", "10.9.0.5/32", "10.9.0.1/24")
        h1:add_route { network = 0, prefix = 0, interface = "v", source = "static" }
        r.forwarding = true
        net.connect(r, "top", "10.0.0.1/24")
        net.connect(h3, "top", "10.0.0.2/24")
        h3:add_route { network = ip("10.9.0.0"), prefix = 24, gateway = ip("10.0.0.1"), source = "static" }
        net.run()

        local result = net.ping(h1, ip("10.0.0.2"))
        expect(result and result.error):eq(nil)
        expect(result.ttl):eq(31)
        expect(r.forwarded):eq(2)
    end)

    it("don't carry routes, though the networks on them are advertised", function()
        local net = network()
        local phone, gateway = net.stack(1), net.stack(2)
        net.virtual_link(phone, gateway, "v", "10.64.0.5/32", "10.64.0.1/16")
        net.connect(gateway, "top", "10.0.0.1/24")
        gateway.forwarding = true
        local routing = rip.start(gateway)
        net.advance(20)

        -- Nothing was sent to the phone.
        expect(net.frames.v):eq(nil)

        -- What a phone says about routes is ignored.
        local before = #gateway.routes
        gateway:inject("v", {
            v = 1, src = ip("10.64.0.5"), dst = address.BROADCAST, ttl = 32, proto = "udp", id = 1,
            body = { sp = rip.PORT, dp = rip.PORT, data = { version = 1, routes = { { network = 0, prefix = 0, metric = 1 } } } },
        })
        net.run()
        expect(#gateway.routes):eq(before)

        -- But the phones' network is advertised to other routers.
        local advertised = {}
        for _, route in ipairs(routing:routes_for(gateway.interfaces.top)) do
            advertised[address.format(route.network, route.prefix)] = route.metric
        end
        expect(advertised["10.64.0.0/16"]):eq(0)
    end)

    it("lose their address when removed", function()
        local net = network()
        local a, b = net.stack(1), net.stack(2)
        net.virtual_link(a, b, "v", "10.9.0.1/24", "10.9.0.2/24")
        tcp.listen(b, 80)
        local client = assert(tcp.connect(a, ip("10.9.0.2"), 80))
        net.advance(0.5)
        expect(client.state):eq("established")

        a:remove_interface("v")
        expect(client.error):eq("Address lost")
        expect(a.interfaces.v):eq(nil)
    end)

    it("pass new frame types to their handlers, unsealed when they protect themselves", function()
        local net = network()
        local key = link.derive(crypto, "passphrase")
        local a, b = net.stack(1), net.stack(2)
        for i, stack in ipairs { a, b } do
            net.connect(stack, "top")
            stack:set_link_key("top", key)
            stack:set_address("top", ip("10.0.0." .. i), 24)
        end
        net.run()

        local got = {}
        b:on_frame("cell", function(interface, src, body, _, dst) got[#got + 1] = { interface.name, src, body, dst } end, true)
        a:on_frame("cell", function() end, true)
        a:send_frame("top", 2, "cell", { op = "hello" })
        a:send_frame("top", -1, "cell", { op = "everyone" })
        net.run()
        expect(got):same { { "top", 1, { op = "hello" }, 2 }, { "top", 1, { op = "everyone" }, -1 } }

        -- They go unsealed, while everything else on the link is still sealed.
        a:send_frame("top", 2, "cell", "visible")
        a:echo(ip("10.0.0.2"))
        local kinds = {}
        for _, item in ipairs(net.queue) do kinds[#kinds + 1] = item.frame.type end
        expect(kinds):same { "cell", "sealed" }
        net.run()

        -- An unsealed frame of another type is still refused on an encrypted link, and unknown types are ignored.
        local before = b.interfaces.top.stats.frames_in
        net.inject("top", b.interfaces.top.unicast, { net = 1, src = 9, dst = 2, type = "ip", body = {} })
        net.inject("top", b.interfaces.top.unicast, { net = 1, src = 9, dst = 2, type = "mystery", body = {} })
        net.run()
        expect(b.interfaces.top.stats.frames_in):eq(before)

        -- A handler which fails doesn't break the stack.
        b:on_frame("cell", function() error("broken handler") end, true)
        a:send_frame("top", 2, "cell", {})
        net.run()
        expect(net.errors[#net.errors]:find("broken handler", 1, true) ~= nil):eq(true)
    end)

    it("let tests choose who hears whom", function()
        local net = network()
        local stacks = {}
        for i = 1, 3 do stacks[i] = net.add(i, "10.0.0." .. i .. "/24") end
        -- 1 and 3 are too far apart to hear each other; 2 hears both, one weakly.
        net.reach = function(_, sender, receiver)
            if not sender then return -50 end
            local a, b = sender.id, receiver.id
            if a + b == 4 then return false end
            return (a == 3 or b == 3) and -95 or -50
        end
        net.run()

        expect(net.ping(stacks[1], ip("10.0.0.2")) ~= nil):eq(true)
        expect(stacks[2].interfaces.top.neighbours[ip("10.0.0.3")].signal):eq(-95)
        local result = net.ping(stacks[1], ip("10.0.0.3"), nil, 4)
        expect(result and result.error):eq("Host unreachable")
    end)
end)
