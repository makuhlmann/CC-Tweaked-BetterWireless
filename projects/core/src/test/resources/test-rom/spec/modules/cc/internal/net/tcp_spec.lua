-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.tcp", function()
    local tcp = require "cc.internal.net.tcp"
    local stream = require "cc.internal.net.stream"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    local function route(stack, network_text, gateway)
        local addr, prefix = address.parse(network_text)
        stack:add_route { network = addr, prefix = prefix, gateway = ip(gateway), source = "static" }
    end

    --[[ Run several functions side by side, like `parallel`, letting a little time pass on the network between turns.
    Functions wait by yielding. ]]
    local function run(net, functions, limit)
        local threads = {}
        for i, fn in ipairs(functions) do threads[i] = coroutine.create(fn) end
        local elapsed = 0
        while true do
            local alive = false
            for _, thread in ipairs(threads) do
                if coroutine.status(thread) ~= "dead" then
                    local ok, err = coroutine.resume(thread)
                    if not ok then error(err, 0) end
                    if coroutine.status(thread) ~= "dead" then alive = true end
                end
            end
            if not alive then return elapsed end
            net.advance(0.05)
            elapsed = elapsed + 0.05
            if elapsed > (limit or 300) then error(("Still running after %d seconds"):format(elapsed), 0) end
        end
    end

    -- Wrap a connection so `send` and `receive` wait (by yielding), as the net API's do.
    local function blocking(connection)
        return {
            send = function(_, value)
                while true do
                    local ok, err = connection:send(value)
                    if ok then return true end
                    if err ~= "Full" then return nil, err end
                    coroutine.yield()
                end
            end,
            receive = function()
                while true do
                    local ok, value = connection:take()
                    if ok then return value end
                    if value == "closed" then return nil end
                    if value then return nil, value end
                    coroutine.yield()
                end
            end,
            close = function() connection:close() end,
        }
    end

    local function accept(listener)
        while true do
            local connection = listener:accept()
            if connection then return connection end
            coroutine.yield()
        end
    end

    local function wait_open(connection)
        while connection.state == "syn_sent" do coroutine.yield() end
        return connection.state == "established", connection.error
    end

    -- Two computers on one link.
    local function pair()
        local net = network()
        local a, b = net.add(1, "10.0.0.1/24"), net.add(2, "10.0.0.2/24")
        net.run()
        return net, a, b
    end

    --[[ The phase 4 goal: a megabyte across three radio hops which lose and reorder frames.

        host 1 -- a -- router 11 ~~ w1 ~~ router 12 ~~ w2 ~~ router 13 -- c -- host 3
    ]]
    it("carries a megabyte across a lossy radio path intact", function()
        math.randomseed(42)
        local net = network()
        local h1 = net.stack(1)
        net.connect(h1, "a", "10.1.0.2/24")
        route(h1, "0.0.0.0/0", "10.1.0.1")
        local routers = {}
        for i, links in ipairs {
            { { "a", "10.1.0.1/24" }, { "w1", "10.12.0.1/24", "wireless" } },
            { { "w1", "10.12.0.2/24", "wireless" }, { "w2", "10.23.0.2/24", "wireless" } },
            { { "w2", "10.23.0.3/24", "wireless" }, { "c", "10.3.0.1/24" } },
        } do
            local r = net.stack(10 + i)
            for _, link in ipairs(links) do net.connect(r, link[1], link[2], link[3]) end
            r.forwarding = true
            routers[i] = r
        end
        route(routers[1], "10.3.0.0/24", "10.12.0.2")
        route(routers[2], "10.1.0.0/24", "10.12.0.1")
        route(routers[2], "10.3.0.0/24", "10.23.0.3")
        route(routers[3], "10.1.0.0/24", "10.23.0.2")
        local h3 = net.stack(3)
        net.connect(h3, "c", "10.3.0.2/24")
        route(h3, "0.0.0.0/0", "10.3.0.1")
        for _, link in ipairs { "w1", "w2" } do
            net.latency[link], net.jitter[link], net.loss[link] = 0.05, 0.1, 0.1
        end
        net.run()

        -- A megabyte with every byte value in it.
        local bytes = {}
        for i = 0, 255 do bytes[i + 1] = string.char(i) end
        local block, parts = table.concat(bytes), {}
        for i = 1, 4096 do parts[i] = block:sub(i % 256 + 1) .. block:sub(1, i % 256) end
        local data = table.concat(parts)
        expect(#data):eq(1024 * 1024)

        local listener = assert(tcp.listen(h3, 115))
        local received
        local elapsed = run(net, {
            function()
                local connection = assert(tcp.connect(h1, ip("10.3.0.2"), 115))
                expect(wait_open(connection)):eq(true)
                local out = stream.wrap(blocking(connection))
                out.write(data)
                out.close()
            end,
            function()
                local input = stream.wrap(blocking(accept(listener)))
                received = input.readAll()
            end,
        })

        expect(#received):eq(#data)
        expect(received == data):eq(true)
        -- 64 messages of 16 KiB, with a tenth lost on each radio hop, take about 15 seconds. Much longer means losses
        -- aren't being recovered from quickly.
        expect(elapsed < 30):eq(true)
    end)

    it("delivers messages in order, exactly once, both ways", function()
        local net, a, b = pair()
        net.jitter.top, net.loss.top = 0.2, 0.2
        math.randomseed(7)
        local listener = assert(tcp.listen(b, 80))
        local values = { "text", 42, false, { nested = { true } }, "" }

        local got_a, got_b = {}, {}
        local client = blocking(assert(tcp.connect(a, ip("10.0.0.2"), 80)))
        run(net, {
            function()
                for i = 1, 100 do assert(client:send(values[i % #values + 1])) end
                client:close()
            end,
            -- Read the replies at the same time, or both sides would fill up and wait for each other.
            function()
                while true do
                    local value = client:receive()
                    if value == nil then break end
                    got_a[#got_a + 1] = value
                end
            end,
            function()
                local connection = blocking(accept(listener))
                while true do
                    local value = connection:receive()
                    if value == nil then break end
                    got_b[#got_b + 1] = value
                    assert(connection:send(#got_b))
                end
                connection:close()
            end,
        })

        expect(#got_b):eq(100)
        for i = 1, 100 do expect(got_b[i]):same(values[i % #values + 1]) end
        expect(#got_a):eq(100)
        for i = 1, 100 do expect(got_a[i]):eq(i) end

        -- Both ends are forgotten once closed.
        net.advance(10)
        expect(next(a.tcp.connections)):eq(nil)
        expect(next(b.tcp.connections)):eq(nil)
    end)

    it("refuses connections to ports nobody listens on", function()
        local net, a = pair()
        local connection = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        expect(connection.state):eq("closed")
        expect(connection.error):eq("Connection refused")
    end)

    it("reports computers which can't be reached", function()
        local net, a = pair()
        expect({ tcp.connect(a, ip("10.9.0.1"), 80) }):same { nil, "Network unreachable" }
        expect({ tcp.connect(a, address.BROADCAST, 80) }):same { nil, "Can't connect to a broadcast address" }
        expect({ tcp.connect(a, ip("10.0.0.255"), 80) }):same { nil, "Can't connect to a broadcast address" }

        local connection = tcp.connect(a, ip("10.0.0.9"), 80)
        net.advance(5)
        expect(connection.error):eq("Host unreachable")
    end)

    it("connects to itself", function()
        local net, a = pair()
        local listener = assert(tcp.listen(a, 80))
        local connection = assert(tcp.connect(a, ip("127.0.0.1"), 80))
        net.advance(0.1)
        expect(connection.state):eq("established")
        local server = listener:accept()
        assert(connection:send("hello"))
        net.advance(0.1)
        expect({ server:take() }):same { true, "hello" }
    end)

    it("waits while the receiver is full, even if it says it has room again and that's lost", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        local server = listener:accept()

        -- The receiver doesn't read, so only its window's worth arrives, and the sender's buffer fills.
        local sent = 0
        for _ = 1, 2 do
            while client:send(sent + 1) do sent = sent + 1 end
            net.advance(5)
        end
        expect(#server.inbox):eq(tcp.WINDOW)
        expect({ client:send("more") }):same { nil, "Full" }

        -- Now it reads everything, but the message saying it has room is lost.
        net.loss.top = 1
        local got = {}
        while true do
            local ok, value = server:take()
            if not ok then break end
            got[#got + 1] = value
        end
        net.loss.top = nil

        -- The sender asks again in a while, and carries on.
        for _ = 1, 120 do
            net.advance(0.5)
            while true do
                local ok, value = server:take()
                if not ok then break end
                got[#got + 1] = value
            end
            if #got == sent then break end
        end
        expect(#got):eq(sent)
        for i = 1, sent do expect(got[i]):eq(i) end
        expect(client.state):eq("established")
    end)

    it("times out when the other side disappears", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        expect(listener:accept()):ne(nil)

        net.remove(b)
        client:send("anyone there?")
        net.advance(300)
        expect(client.state):eq("closed")
        expect(client.error):eq("Timed out")
        expect(net.wakes[a].net_closed):eq(1)
    end)

    it("notices an idle connection's other side has gone", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        local server = listener:accept()

        -- Idle, but both sides are there.
        net.advance(200)
        expect(client.state):eq("established")
        expect(server.state):eq("established")

        net.remove(b)
        net.advance(200)
        expect(client.error):eq("Timed out")
    end)

    it("resets connections nobody accepted when the listener closes", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        listener:close()
        net.advance(0.5)
        expect(client.error):eq("Connection reset")
        expect(next(b.tcp.connections)):eq(nil)
    end)

    it("queues a limited number of connections to accept", function()
        local net, a, b = pair()
        tcp.listen(b, 80)
        local clients = {}
        for i = 1, 12 do clients[i] = tcp.connect(a, ip("10.0.0.2"), 80) end
        net.advance(2)

        local open = 0
        for _, client in ipairs(clients) do
            if client.state == "established" then open = open + 1 end
        end
        expect(open):eq(8)
        expect(#b.tcp.listeners[80].queue):eq(8)
    end)

    it("lets one side close while the other keeps sending", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        local server = listener:accept()

        assert(client:send("request"))
        client:close()
        net.advance(0.5)
        expect({ server:take() }):same { true, "request" }
        expect({ server:take() }):same { false, "closed" }
        expect({ server:send("still here") }):same { true }
        net.advance(0.5)
        expect({ client:take() }):same { true, "still here" }
        expect({ client:send("no") }):same { nil, "Connection closed" }

        server:close()
        net.advance(10)
        expect({ client:take() }):same { false, "closed" }
        expect(next(a.tcp.connections)):eq(nil)
        expect(next(b.tcp.connections)):eq(nil)
    end)

    it("doesn't say it's closed until everything has been received", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        local server = listener:accept()

        for i = 1, 3 do client:send(i) end
        client:close()
        server:close()
        net.advance(1)
        expect(server.state):eq("time_wait")
        expect(net.wakes[b].net_closed):eq(nil)

        for i = 1, 3 do expect({ server:take() }):same { true, i } end
        expect(net.wakes[b].net_closed):eq(1)
        expect({ server:take() }):same { false, "closed" }
    end)

    it("ignores resets which don't know where the connection is up to", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        -- Half open: the server has answered, but the client has gone before its answer arrives.
        net.remove(a)
        net.run()
        local _, server = next(b.tcp.connections)
        expect(server.state):eq("syn_received")

        local function forge(flags, seq, ack)
            local segment = { sp = client.local_port, dp = 80, flags = flags, seq = seq, ack = ack, win = 0 }
            local packet = { v = 1, src = ip("10.0.0.1"), dst = ip("10.0.0.2"), ttl = 32, proto = "tcp", id = 1, body = segment }
            net.inject("top", b.interfaces.top.unicast, { net = 1, src = 1, dst = 2, type = "ip", body = packet })
            net.run()
        end
        forge("R", server.rcv_nxt)
        forge("RA", server.rcv_nxt, server.iss + 5)
        expect(server.state):eq("syn_received")

        -- The client comes back, and opens the connection properly.
        table.insert(net.stacks, a)
        net.advance(3)
        expect(client.state):eq("established")
        expect(listener:accept()):eq(server)
        forge("R", server.rcv_nxt + 100)
        expect(server.state):eq("established")
        forge("R", server.rcv_nxt)
        expect(server.error):eq("Connection reset")
    end)

    it("clears a half open connection whose other side gave up", function()
        local net, a, b = pair()
        local listener = assert(tcp.listen(b, 80))
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        -- The server's answer is lost, and the client gives up waiting.
        net.remove(a)
        net.run()
        client:abort()
        table.insert(net.stacks, a)
        expect(listener.pending):eq(1)

        -- The server answers again, and is told there's no such connection.
        net.advance(3)
        expect(next(b.tcp.connections)):eq(nil)
        expect(listener.pending):eq(0)
    end)

    it("fails connections when their address goes", function()
        local net, a, b = pair()
        tcp.listen(b, 80)
        local client = tcp.connect(a, ip("10.0.0.2"), 80)
        net.advance(0.5)
        a:set_address("top", ip("10.0.0.9"), 24)
        expect(client.error):eq("Address lost")
        expect(next(a.tcp.connections)):eq(nil)
    end)

    it("refuses messages it can't send", function()
        local recursive = {}
        recursive.self = recursive
        expect({ tcp.check_message(nil) }):same { nil, "Can't send nil" }
        expect({ tcp.check_message(print) }):same { nil, "Can't send a function" }
        expect({ tcp.check_message({ fn = print }) }):same { nil, "Can't send a function" }
        expect({ tcp.check_message(("x"):rep(tcp.MAX_MESSAGE)) }):same { nil, "Message too large" }
        expect(tcp.check_message(recursive)):eq(true)
        expect(tcp.check_message(("x"):rep(stream.CHUNK))):eq(true)

        local deep = {}
        for _ = 1, 100000 do deep = { deep } end
        local ok, err = tcp.check_message(deep)
        expect(ok):eq(nil)
        expect(err == "Message too complex to send" or err == "Message too large"):eq(true)
    end)

    describe("streams", function()
        -- A pretend connection, holding messages in a list.
        local function pipe()
            local messages, closed = {}, false
            local connection = {
                send = function(_, value)
                    messages[#messages + 1] = value
                    return true
                end,
                receive = function() return table.remove(messages, 1) end,
                close = function() closed = true end,
            }
            return connection, messages, function() return closed end
        end

        it("send in chunks, and read in any amounts", function()
            local connection, messages = pipe()
            local s = stream.wrap(connection)
            s.write(("a"):rep(stream.CHUNK + 10))
            expect(#messages):eq(1)
            s.writeLine("line one")
            s.write("line two\nend")
            s.flush()
            expect(#messages):eq(2)

            expect(s.read(stream.CHUNK)):eq(("a"):rep(stream.CHUNK))
            expect(s.read(5)):eq("aaaaa")
            expect(s.readLine()):eq("aaaaaline one")
            expect(s.readLine(true)):eq("line two\n")
            expect(s.readAll()):eq("end")
            expect(s.read()):eq(nil)
            expect(s.readLine()):eq(nil)
        end)

        it("flush when closed", function()
            local connection, messages, closed = pipe()
            local s = stream.wrap(connection)
            s.write("bye")
            s.close()
            expect(messages):same { "bye" }
            expect(closed()):eq(true)
        end)

        it("complain about messages which aren't text", function()
            local connection = pipe()
            connection:send({})
            local s = stream.wrap(connection)
            expect.error(s.read):eq("Expected text in the stream, got a table")
        end)
    end)
end)
