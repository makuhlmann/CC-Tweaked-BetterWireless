-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.stack", function()
    local Stack = require "cc.internal.net.stack"
    local address = require "cc.net.address"

    local function ip(text) return (address.parse(text)) end

    -- Modems hand each receiver its own copy of a message.
    local function copy(value) return textutils.unserialise(textutils.serialise(value)) end

    --- A virtual network: one link, which every stack's interface "top" is on.
    local function network()
        local self = { time = 0, queue = {}, stacks = {} }

        function self.add(id, addr)
            local stack
            stack = Stack.new {
                id = id,
                clock = function() return self.time end,
                transmit = function(_, channel, _, frame)
                    table.insert(self.queue, { sender = stack, channel = channel, frame = copy(frame) })
                end,
                wake = function() end,
            }
            stack:add_interface("top", "top", "wired", "high")
            if addr then
                local parsed, prefix = address.parse(addr)
                stack:set_address("top", parsed, prefix)
            end
            table.insert(self.stacks, stack)
            return stack
        end

        --- Deliver frames until nobody sends anything more.
        function self.run()
            local count = 0
            while #self.queue > 0 do
                local item = table.remove(self.queue, 1)
                for _, stack in ipairs(self.stacks) do
                    if stack ~= item.sender then stack:receive("top", item.channel, copy(item.frame)) end
                end

                count = count + 1
                if count > 1000 then error("Network never went quiet", 2) end
            end
        end

        --- Let time pass, running any timers which are due.
        function self.advance(seconds)
            local target = self.time + seconds
            while true do
                local next
                for _, stack in ipairs(self.stacks) do
                    local deadline = stack:next_deadline()
                    if deadline and (not next or deadline < next) then next = deadline end
                end
                if not next or next > target then break end

                self.time = next
                for _, stack in ipairs(self.stacks) do stack:tick() end
                self.run()
            end
            self.time = target
        end

        return self
    end

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
end)
