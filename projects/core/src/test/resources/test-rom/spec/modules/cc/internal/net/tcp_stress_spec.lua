-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Connections on bad links, between computers which restart, and with computers which misbehave. Whatever happens,
a connection delivers what was sent in order and exactly once or fails saying why, and nothing is left behind. ]]

describe("Connections, under stress,", function()
    local tcp = require "cc.internal.net.tcp"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    -- Two computers on one link.
    local function pair()
        local net = network()
        local a, b = net.add(1, "10.0.0.1/24"), net.add(2, "10.0.0.2/24")
        net.run()
        return net, a, b
    end

    local function count(list)
        local total = 0
        for _ in pairs(list) do total = total + 1 end
        return total
    end

    -- Check a computer's tables of connections agree with each other.
    local function check_registry(stack)
        local registry, ports = stack.tcp, {}
        for key, connection in pairs(registry.connections) do
            if connection.key ~= key then error("Connection listed under the wrong key", 0) end
            if connection.state == "closed" then error("A closed connection is still listed", 0) end
            if registry.by_id[connection.id] ~= connection then error("Connection isn't listed by ID", 0) end
            ports[connection.local_port] = (ports[connection.local_port] or 0) + 1
        end
        expect(registry.count):describe("Connections counted"):eq(count(registry.connections))
        expect(count(registry.by_id)):describe("Connections by ID"):eq(registry.count)
        expect(registry.ports):describe("Ports in use"):same(ports)

        for _, listener in pairs(registry.listeners) do
            local pending = 0
            for _, connection in pairs(registry.connections) do
                if connection.listener == listener and connection.state == "syn_received" then pending = pending + 1 end
            end
            expect(listener.pending):describe("Connections still opening on port " .. listener.port):eq(pending)
            for _, connection in ipairs(listener.queue) do
                if registry.connections[connection.key] ~= connection then error("An unlisted connection is waiting to be accepted", 0) end
            end
        end
    end

    -- Check a computer has forgotten every connection, and has nothing left to do for them.
    local function check_idle(stack)
        check_registry(stack)
        expect(stack.tcp.count):describe("Connections left"):eq(0)
        expect(stack:timer_count()):describe("Timers left"):eq(0)
    end

    -- A segment from `src` (which computer `id` sends), put on the link for `target`.
    local function forge(net, target, id, src, segment)
        net.inject("top", target.interfaces.top.unicast, {
            net = 1, src = id, dst = target.id, type = "ip",
            body = { v = 1, src = src, dst = target.interfaces.top.address, ttl = 32, proto = "tcp", id = 1, body = segment },
        })
    end

    -- Open a connection from `client` to port 80 on `server`, which has `listener`.
    local function open(net, client, server, listener)
        local connection = assert(tcp.connect(client, server.interfaces.top.address, 80))
        net.advance(1)
        expect(connection.state):eq("established")
        return connection, assert(listener:accept())
    end

    -- Lose the segments on their way which match a test, returning how many there were.
    local function lose(net, test)
        local lost = 0
        for i = #net.queue, 1, -1 do
            local packet = net.queue[i].frame.body
            local segment = type(packet) == "table" and packet.body
            if type(segment) == "table" and test(segment, net.queue[i].sender) then
                table.remove(net.queue, i)
                lost = lost + 1
            end
        end
        return lost
    end

    -- Take everything waiting on a connection, adding it to a list.
    local function drain(connection, into)
        while true do
            local ok, value = connection:take()
            if not ok then return value end
            into[#into + 1] = value
        end
    end

    describe("on bad links,", function()
        it("deliver everything once and in order when frames are lost, late, and sent twice", function()
            math.randomseed(11)
            local net, a, b = pair()
            net.latency.top, net.jitter.top, net.loss.top, net.duplicate.top = 0.05, 0.4, 0.2, 0.5
            local listener = assert(tcp.listen(b, 80))
            local client = assert(tcp.connect(a, ip("10.0.0.2"), 80))

            local server
            local sent = { [a] = 0, [b] = 0 }
            local got = { [a] = {}, [b] = {} }
            local slowest = 0
            for _ = 1, 1200 do
                server = server or listener:accept()
                slowest = math.max(slowest, client.srtt or 0, server and server.srtt or 0)
                for _, side in ipairs { { a, client }, { b, server } } do
                    local stack, connection = side[1], side[2]
                    if connection then
                        drain(connection, got[stack])
                        while sent[stack] < 150 and connection:send(sent[stack] + 1) do sent[stack] = sent[stack] + 1 end
                        if sent[stack] == 150 then connection:close() end
                    end
                end
                net.advance(0.1)
                if server and client.state ~= "established" and server.state ~= "established" then break end
            end

            expect(client.error):eq(nil)
            expect(server.error):eq(nil)
            -- A round trip takes from 0.1 to 0.9 seconds here. Measuring it as much longer (by timing a message which
            -- was sent twice, or one which waited for the message before it) makes every later loss slow to notice.
            expect(slowest > 0.1 and slowest < 1):describe("The longest round trip measured, " .. slowest):eq(true)
            for _, stack in ipairs { a, b } do
                expect(#got[stack]):eq(150)
                for i = 1, 150 do expect(got[stack][i]):eq(i) end
            end
            net.advance(10)
            check_idle(a)
            check_idle(b)
        end)

        it("deliver a prefix of what was sent, or everything, whatever each side does", function()
            -- Random programs on both sides of random links. Whatever happens, each side has received the first so
            -- many messages the other sent, and all of them if both closed and nothing failed.
            math.randomseed(23)
            for round = 1, 40 do
                local net, a, b = pair()
                net.jitter.top, net.loss.top = math.random() * 0.3, math.random() * 0.4
                net.duplicate.top = math.random() * 0.3
                local listener = assert(tcp.listen(b, 80))
                local ends = { { stack = a, connection = assert(tcp.connect(a, ip("10.0.0.2"), 80)), sent = 0, got = {} } }
                ends[2] = { stack = b, sent = 0, got = {} }
                local aborted = false

                local function step(side, action)
                    local connection = side.connection
                    if not connection then return end
                    if action <= 5 then
                        if connection:send({ n = side.sent + 1 }) then side.sent = side.sent + 1 end
                    elseif action <= 8 then
                        drain(connection, side.got)
                    elseif action == 9 and math.random() < 0.2 then
                        connection:close()
                        side.closed = true
                    elseif action == 10 and math.random() < 0.03 then
                        connection:abort()
                        aborted = true
                    end
                end

                for _ = 1, 150 do
                    ends[2].connection = ends[2].connection or listener:accept()
                    step(ends[math.random(1, 2)], math.random(1, 10))
                    if math.random() < 0.5 then net.advance(math.random() * 0.5) end
                end
                -- Both sides finish: close, and read whatever comes, until it's over.
                for _ = 1, 600 do
                    ends[2].connection = ends[2].connection or listener:accept()
                    for _, side in ipairs(ends) do
                        if side.connection then
                            side.connection:close()
                            side.closed = true
                            drain(side.connection, side.got)
                        end
                    end
                    net.advance(1)
                    if ends[1].connection.state == "closed" and (not ends[2].connection or ends[2].connection.state == "closed") then break end
                end

                local name = "Round " .. round
                local failed = aborted
                for i, side in ipairs(ends) do
                    local connection = side.connection
                    if connection and connection.state ~= "closed" then
                        error(("%s: side %d is still %s (%d queued, %d in flight, %d retries, resending in %s seconds, %d waiting to be read)"):format(
                            name, i, connection.state, #connection.queue, connection.snd_nxt - connection.snd_una, connection.retries,
                            tostring(connection.rto), #connection.inbox), 0)
                    end
                end
                for i, side in ipairs(ends) do
                    local other = ends[3 - i]
                    if side.connection and side.connection.error then failed = true end
                    if #side.got > other.sent then error(("%s: received %d of %d messages"):format(name, #side.got, other.sent), 0) end
                    for n, message in ipairs(side.got) do
                        if type(message) ~= "table" or message.n ~= n then error(("%s: message %d is wrong"):format(name, n), 0) end
                    end
                end
                if not failed then
                    expect(ends[2].connection):describe(name):ne(nil)
                    expect(#ends[1].got):describe(name):eq(ends[2].sent)
                    expect(#ends[2].got):describe(name):eq(ends[1].sent)
                end

                listener:close()
                net.loss.top = 0
                net.advance(200)
                check_idle(a)
                check_idle(b)
            end
        end)

        it("measure the round trip rightly when a message waits for the one before it", function()
            -- Two messages are sent. The first is lost, and so is the acknowledgement of the second. Once the first has
            -- been sent again, both are acknowledged at once: long after the second was sent, though the round trip
            -- is as short as ever. Mistaking that wait for the round trip makes the sender wait longer before sending
            -- anything again, which makes the next such wait longer still.
            local net, a, b = pair()
            net.latency.top = 0.1
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)
            local got = {}
            for round = 1, 10 do
                assert(client:send("first"))
                assert(client:send("second"))
                expect(client.snd_nxt - client.snd_una):describe("Messages in flight"):eq(2)
                expect(lose(net, function(segment) return segment.data == "first" end)):eq(1)
                net.advance(0.1)
                expect(lose(net, function(_, sender) return sender == b end)):eq(1)
                net.advance(5)
                drain(server, got)
                expect(#got):eq(round * 5 - 3)
                expect(client.srtt < 0.25):describe(("Round trip measured as %.2f seconds in round %d"):format(client.srtt, round)):eq(true)
                expect(client.rto <= 0.7):describe(("Waiting %.2f seconds to resend in round %d"):format(client.rto, round)):eq(true)

                -- A few messages which get through, so two can be in flight again.
                for _ = 1, 3 do
                    assert(client:send("more"))
                    net.advance(0.5)
                end
                drain(server, got)
            end
        end)

        it("notice losses quickly again after a link has been down", function()
            local net, a, b = pair()
            net.latency.top = 0.1
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)

            -- Nothing gets through for a while, so the sender waits longer and longer between tries.
            net.loss.top = 1
            assert(client:send(1))
            net.advance(20)
            expect(client.rto >= 8):eq(true)

            -- Once the link is back, so is the short wait.
            net.loss.top = 0
            net.advance(30)
            expect({ server:take() }):same { true, 1 }
            expect(client.rto <= 1):eq(true)

            -- So the next message to be lost is sent again within a second or two, not half a minute later.
            net.loss.top = 1
            assert(client:send(2))
            net.advance(0.15)
            net.loss.top = 0
            net.advance(2)
            expect({ server:take() }):same { true, 2 }
        end)

        it("stay quiet when there's nothing to say", function()
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)
            assert(client:send("hello"))
            net.advance(1)
            expect({ server:take() }):same { true, "hello" }

            -- Nothing for a minute, then a few frames a minute to check the other side is still there.
            local before = net.total_frames()
            net.advance(50)
            expect(net.total_frames() - before):eq(0)
            net.advance(600)
            expect(net.total_frames() - before <= 2 * 2 * 60):eq(true)
            expect(client.state):eq("established")
            expect(server.state):eq("established")
        end)
    end)

    describe("between computers which restart,", function()
        it("let a client which restarted connect again from the same port", function()
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            local old, old_server = open(net, a, b, listener)

            -- The client restarts: it forgets the connection, but the server doesn't know. Its first connection
            -- afterwards uses the same port as before.
            net.remove(a)
            a = net.add(1, "10.0.0.1/24")
            net.run()
            a.tcp.next_port = old.local_port
            local new = assert(tcp.connect(a, ip("10.0.0.2"), 80))
            expect(new.local_port):eq(old.local_port)

            -- Programs wait 5 seconds for a connection to open.
            net.advance(4)
            expect(new.state):eq("established")
            expect(old_server.state):eq("closed")
            expect(old_server.error):eq("Connection reset")

            local new_server = assert(listener:accept())
            assert(new:send("back again"))
            net.advance(1)
            expect({ new_server:take() }):same { true, "back again" }
            check_registry(a)
            check_registry(b)
        end)

        it("tell a client its server restarted as soon as it sends something", function()
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            local client = open(net, a, b, listener)

            net.remove(b)
            b = net.add(2, "10.0.0.2/24")
            net.run()
            assert(tcp.listen(b, 80))
            assert(client:send("still there?"))
            net.advance(1)
            expect(client.state):eq("closed")
            expect(client.error):eq("Connection reset")
            check_idle(a)
            check_idle(b)
        end)

        it("don't start at the same port every time", function()
            -- A computer which always starts from the same port reuses the ports of the connections it had before it
            -- restarted, which the other sides may still think are open.
            local ports = {}
            for _ = 1, 8 do
                local net, a = pair()
                ports[assert(tcp.connect(a, ip("10.0.0.2"), 80)).local_port] = true
                net.advance(1)
            end
            expect(count(ports) > 1):eq(true)
        end)
    end)

    describe("with many connections,", function()
        it("open as many as a computer may have, and forget them all afterwards", function()
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            local clients, servers = {}, {}
            for _ = 1, 128 / 8 do
                for _ = 1, 8 do clients[#clients + 1] = assert(tcp.connect(a, ip("10.0.0.2"), 80)) end
                net.advance(0.5)
                for _ = 1, 8 do servers[#servers + 1] = assert(listener:accept()) end
            end
            expect({ tcp.connect(a, ip("10.0.0.2"), 80) }):same { nil, "Too many connections" }
            check_registry(a)
            check_registry(b)
            expect(a.tcp.count):eq(128)
            expect(b.tcp.count):eq(128)
            -- Each connection needs at most a timer for resending and one for checking the other side is there.
            expect(b:timer_count() <= 2 * 128):eq(true)

            -- A third computer can't get in while the server is full, but can as soon as there's room.
            local c = net.add(3, "10.0.0.3/24")
            net.run()
            local late = assert(tcp.connect(c, ip("10.0.0.2"), 80))
            net.advance(2)
            expect(late.state):eq("syn_sent")
            servers[1]:abort()
            net.advance(4)
            expect(late.state):eq("established")
            late:abort()

            -- Every connection carries a message each way.
            for i, client in ipairs(clients) do
                if i > 1 then
                    assert(client:send(i))
                    assert(servers[i]:send(-i))
                end
            end
            net.advance(2)
            for i, client in ipairs(clients) do
                if i > 1 then
                    expect({ servers[i]:take() }):same { true, i }
                    expect({ client:take() }):same { true, -i }
                end
            end

            for i, client in ipairs(clients) do
                client:close()
                servers[i]:close()
            end
            listener:close()
            net.advance(10)
            check_idle(a)
            check_idle(b)
            check_idle(c)
        end)

        it("open and close a thousand, one after another, leaving nothing behind", function()
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            for i = 1, 1000 do
                local client = assert(tcp.connect(a, ip("10.0.0.2"), 80))
                net.advance(0.1)
                local server = assert(listener:accept())
                assert(client:send(i))
                client:close()
                net.advance(0.1)
                expect({ server:take() }):same { true, i }
                server:close()
                net.advance(0.1)
                expect(client.state):ne("established")
                -- Connections linger for 5 seconds once closed, so at most a few dozen exist at once.
                if a.tcp.count > 40 or a:timer_count() > 80 or b:timer_count() > 80 then
                    error(("%d connections and %d timers after %d connections"):format(a.tcp.count, a:timer_count(), i), 0)
                end
            end
            net.advance(10)
            check_idle(a)
            check_idle(b)
        end)
    end)

    describe("on encrypted links,", function()
        local link = require "cc.internal.net.link"
        local KEY = link.derive(crypto, "correct horse battery staple")

        -- Two computers on one link, which seals every frame.
        local function sealed_pair()
            local net = network()
            local stacks = {}
            for i = 1, 2 do
                local stack = net.stack(i)
                net.connect(stack, "top")
                stack:set_link_key("top", KEY)
                stack:set_address("top", ip("10.0.0." .. i), 24)
                stacks[i] = stack
            end
            net.run()
            return net, stacks[1], stacks[2]
        end

        local function nested(depth)
            local value = {}
            for _ = 2, depth do value = { value } end
            return value
        end

        it("refuse messages the link couldn't carry, and carry on", function()
            -- A modem can send these, but they can't be sealed. A connection which took one would send it again and
            -- again, and then fail, along with everything waiting behind it.
            local net, a, b = sealed_pair()
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)
            local dropped = a.interfaces.top.stats.dropped

            local loop = {}
            loop.self = loop
            expect({ client:send(loop) }):same { nil, "Can't send a table which contains itself" }
            expect({ client:send({ [{}] = "a key" }) }):same { nil, "Can't send a table with a table as a key" }
            expect({ client:send(nested(61)) }):same { nil, "Can't send tables nested more than 60 deep" }

            assert(client:send("fine"))
            net.advance(120)
            expect({ server:take() }):same { true, "fine" }
            expect(client.state):eq("established")
            expect(a.interfaces.top.stats.dropped):eq(dropped)
        end)

        it("deliver everything a connection accepts, in frames a radio can send", function()
            local net, a, b = sealed_pair()
            net.latency.top = 0.05
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)

            -- Messages as deep and as big as a connection takes: big as modems reckon it, and big once encoded.
            local numbers, strings, mixed = {}, {}, {}
            for i = 1, 3413 do numbers[i] = i / 3 end
            for i = 1, 4400 do strings[i] = "" end
            for i = 1, 1400 do mixed["key " .. i] = { i % 2 == 0, "" } end
            local messages = { nested(60), ("x"):rep(60 * 1024 - 2), numbers, strings, mixed, { nested(59), nested(59) } }

            local largest = 0
            for i, message in ipairs(messages) do
                expect({ client:send(message) }):describe("Message " .. i):same { true }
                for _, item in ipairs(net.queue) do
                    expect(item.frame.type):eq("sealed")
                    largest = math.max(largest, #item.frame.body.data)
                end
                net.advance(1)
                local ok, value = server:take()
                expect(ok):describe("Message " .. i):eq(true)
                if type(message) == "string" then
                    expect(value == message):describe("Message " .. i):eq(true)
                else
                    expect(value):describe("Message " .. i):same(message)
                end
            end
            expect(a.interfaces.top.stats.dropped):eq(0)
            -- Radio messages may be 64 KiB, as modems reckon it: the sealed bytes, and a little for the rest of the frame.
            expect(largest > 60 * 1024 and largest + 256 <= 64 * 1024):describe("The largest frame, " .. largest .. " bytes"):eq(true)
        end)
    end)

    describe("with computers which misbehave,", function()
        -- Opens from computer 9, pretending to be many computers which don't exist.
        local function flood(net, b, first, last)
            for i = first, last do
                forge(net, b, 9, ip("10.0.0.0") + 10 + i % 200, { sp = 1024 + i, dp = 80, flags = "S", seq = i })
            end
        end

        it("aren't shut out by a few connections which never finish opening", function()
            -- Eight opens fill a listening port's queue, and each waits a minute for an answer which never comes. That
            -- mustn't close the port for that minute, or eight frames a minute would close it for good.
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            flood(net, b, 1, 8)
            net.advance(1)
            check_registry(b)

            local client = assert(tcp.connect(a, ip("10.0.0.2"), 80))
            net.advance(4)
            expect(client.state):eq("established")
            local server = assert(listener:accept())
            assert(client:send("hello"))
            net.advance(1)
            expect({ server:take() }):same { true, "hello" }
            check_registry(b)
        end)

        it("survive a flood of connections which never finish opening", function()
            math.randomseed(13)
            local net, a, b = pair()
            net.jitter.top = 0.05
            local listener = assert(tcp.listen(b, 80))
            local frames = net.total_frames()

            -- 20 a second for over a minute. Meanwhile a real client tries to connect every six seconds, waiting five
            -- (as programs do), and leaving a second afterwards for the flood to take the room it leaves.
            local worst, connected, client = 0, 0, nil
            local injected = 12 * 120
            for i = 1, injected do
                flood(net, b, i, i)
                if i % 120 == 20 then client = assert(tcp.connect(a, ip("10.0.0.2"), 80)) end
                net.advance(0.05)
                worst = math.max(worst, b.tcp.count)
                if i % 120 == 0 then
                    if client.state == "established" then connected = connected + 1 end
                    client:abort()
                    check_registry(b)
                end
            end
            expect(worst <= 16):describe("Connections at once"):eq(true)
            -- Not every try gets in (about half do), but the port isn't closed to everyone.
            if connected < 4 then error(("Only %d of 12 real connections opened"):format(connected), 0) end
            -- The server answers each open, and tries a few again, but never sends more than a few frames for each.
            expect(net.total_frames() - frames - injected <= 4 * injected):describe("Frames sent in answer"):eq(true)

            -- And it's all forgotten soon after the flood stops.
            net.advance(70)
            listener:close()
            net.advance(10)
            check_idle(b)
            check_idle(a)
        end)

        it("let a crowd connect at once, a few at a time", function()
            -- More computers than a listening port queues, all connecting in the same moment. The ones there's no room
            -- for are kept waiting, not turned away, and none which got in is thrown out to make room.
            local net = network()
            local server = net.add(100, "10.0.0.100/24")
            local listener = assert(tcp.listen(server, 80))
            local stacks = {}
            for i = 1, 30 do stacks[i] = net.add(i, "10.0.0." .. i .. "/24") end
            net.run()

            local clients, accepted = {}, 0
            for i, stack in ipairs(stacks) do clients[i] = assert(tcp.connect(stack, ip("10.0.0.100"), 80)) end
            for _ = 1, 40 do
                net.advance(0.5)
                while true do
                    local connection = listener:accept()
                    if not connection then break end
                    accepted = accepted + 1
                    assert(connection:send("welcome"))
                end
                check_registry(server)
            end
            expect(accepted):eq(30)
            for i, client in ipairs(clients) do
                expect(client.error):describe("Client " .. i):eq(nil)
                expect({ client:take() }):describe("Client " .. i):same { true, "welcome" }
            end
        end)

        it("don't answer made-up segments with a storm of their own", function()
            math.randomseed(5)
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)

            -- Segments which look like they're from the client, with every kind of sequence number: far away, nearly
            -- right, and exactly right.
            local frames, injected = net.total_frames(), 0
            local all_flags = { "A", "KA", "FA", "S", "SA", "R", "RA", "", "K", "F" }
            for _ = 1, 400 do
                local near = math.random() < 0.5
                forge(net, b, 1, ip("10.0.0.1"), {
                    sp = client.local_port, dp = 80, flags = all_flags[math.random(#all_flags)],
                    seq = near and server.rcv_nxt + math.random(17, 40) or math.random(0, 2 ^ 31),
                    ack = near and server.snd_nxt + math.random(-3, 3) or math.random(0, 2 ^ 31),
                    win = math.random(0, 64), sack = math.random() < 0.3 and { math.random(0, 2 ^ 31) } or nil,
                    data = math.random() < 0.5 and "made up" or nil,
                })
                injected = injected + 1
                if injected % 20 == 0 then net.advance(0.2) end
            end
            net.advance(5)
            -- Each gets at most an acknowledgement, which the real client may answer once.
            expect(net.total_frames() - frames - injected <= 2 * injected):describe("Frames sent in answer"):eq(true)
            local quiet = net.total_frames()
            net.advance(30)
            expect(net.total_frames() - quiet):describe("Frames sent afterwards"):eq(0)

            -- None of it was delivered, and the connection still works.
            expect({ server:take() }):same { false, nil }
            assert(client:send("real"))
            net.advance(2)
            expect({ server:take() }):same { true, "real" }
            assert(server:send("answer"))
            net.advance(2)
            expect({ client:take() }):same { true, "answer" }
            check_registry(a)
            check_registry(b)
        end)

        it("only wake programs when there's something new", function()
            -- A computer's event queue holds 256 events. Sending a megabyte queues a few events per message at most.
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            local client, server = open(net, a, b, listener)
            local chunk, sent, received = ("x"):rep(16 * 1024), 0, {}
            while #received < 64 do
                while sent < 64 and client:send(chunk) do sent = sent + 1 end
                net.advance(0.05)
                drain(server, received)
            end
            for _, stack in ipairs { a, b } do
                local total = 0
                for _, wakes in pairs(net.wakes[stack]) do total = total + wakes end
                expect(total <= 4 * 64):describe("Events queued"):eq(true)
            end
        end)

        it("leave nothing behind when a listener closes with connections still opening", function()
            local net, a, b = pair()
            local listener = assert(tcp.listen(b, 80))
            flood(net, b, 1, 4)
            local client = assert(tcp.connect(a, ip("10.0.0.2"), 80))
            net.advance(0.5)
            listener:close()

            -- The same port can be listened on again at once, and connections to the old listener don't turn up there.
            local again = assert(tcp.listen(b, 80))
            net.advance(1)
            expect(again:accept()):eq(nil)
            expect(client.state):eq("closed")
            net.advance(70)
            again:close()
            check_idle(b)
            check_idle(a)
        end)
    end)
end)
