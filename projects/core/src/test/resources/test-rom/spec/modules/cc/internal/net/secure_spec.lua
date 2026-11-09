-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.secure", function()
    local secure = require "cc.internal.net.secure"
    local noise = require "cc.internal.net.noise"
    local tcp = require "cc.internal.net.tcp"
    local stream = require "cc.internal.net.stream"
    local codec = require "cc.net.codec"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    local function new_key()
        local private = crypto.generateKeyPair("x25519")
        return { public = noise.public_key(crypto, private), exchange = function(public) return crypto.exchange(private, public) end }
    end

    -- Run functions side by side, letting time pass on the network between turns. Functions wait by yielding.
    local function run(net, functions, limit)
        local threads, results = {}, {}
        for i, fn in ipairs(functions) do
            threads[i] = coroutine.create(function() results[i] = table.pack(fn()) end)
        end
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
            if not alive then return results end
            net.advance(0.05)
            elapsed = elapsed + 0.05
            if elapsed > (limit or 120) then error("Still running", 0) end
        end
    end

    -- A connection whose send and receive wait (by yielding), like the net API's.
    local function blocking(net, connection)
        return {
            connection = connection,
            send = function(_, value)
                while true do
                    local ok, err = connection:send(value)
                    if ok then return true end
                    if err ~= "Full" then return nil, err end
                    coroutine.yield()
                end
            end,
            receive = function(_, timeout)
                local started = net.time
                while true do
                    local ok, value = connection:take()
                    if ok then return value end
                    if value == "closed" then return nil end
                    if value then return nil, value end
                    if timeout and net.time - started >= timeout then return nil, "Timed out" end
                    coroutine.yield()
                end
            end,
            close = function() connection:close() end,
            abort = function() connection:abort() end,
        }
    end

    --[[ Two computers, a client and a server, with a secure connection between them. ]]
    local function connect(options)
        options = options or {}
        local net = network()
        local a, b = net.add(1, "10.0.0.1/24"), net.add(2, "10.0.0.2/24")
        net.run()
        local client_key, server_key = new_key(), new_key()
        local listener = assert(tcp.listen(b, 22))
        local client_tcp = assert(tcp.connect(a, ip("10.0.0.2"), 22))

        local client, server, client_err, server_err
        run(net, {
            function()
                while client_tcp.state == "syn_sent" do coroutine.yield() end
                client, client_err = secure.client(blocking(net, client_tcp), {
                    crypto = crypto, static = client_key, pattern = options.pattern, verify = options.verify,
                    remote_static = options.remote_static or (options.pattern == "NK" and server_key.public) or nil, timeout = 5,
                })
            end,
            function()
                local connection
                repeat
                    connection = listener:accept()
                    if not connection then coroutine.yield() end
                until connection
                server, server_err = secure.server(blocking(net, connection), {
                    crypto = crypto, static = server_key, certificate = options.certificate, timeout = 5,
                    anonymous = options.anonymous,
                })
            end,
        })
        return {
            net = net, a = a, b = b, client = client, server = server, client_err = client_err, server_err = server_err,
            client_key = client_key, server_key = server_key,
        }
    end

    -- Put a segment into the server's side of the connection, as if from the client, with the next sequence number.
    local function inject(setup, flags, data)
        local server_tcp = setup.server.transport.connection
        local segment = {
            sp = server_tcp.remote_port, dp = server_tcp.local_port, flags = flags, seq = server_tcp.rcv_nxt,
            ack = server_tcp.snd_nxt, win = 16, data = data,
        }
        local packet = { v = 1, src = ip("10.0.0.1"), dst = ip("10.0.0.2"), ttl = 32, proto = "tcp", id = 1, body = segment }
        setup.net.inject("top", setup.b.interfaces.top.unicast, { net = 1, src = 1, dst = 2, type = "ip", body = packet })
        setup.net.advance(0.5)
    end

    local function exchange(setup, functions) return run(setup.net, functions) end

    it("opens a connection on which both sides know who the other is", function()
        local setup = connect()
        expect(setup.client_err):eq(nil)
        expect(setup.server_err):eq(nil)
        expect(setup.client.peer_key):eq(setup.server_key.public)
        expect(setup.server.peer_key):eq(setup.client_key.public)
        expect(setup.client.handshake_hash):eq(setup.server.handshake_hash)

        local results = exchange(setup, {
            function()
                assert(setup.client:send({ op = "balance", account = 7 }))
                return setup.client:receive(5)
            end,
            function()
                local request = setup.server:receive(5)
                assert(setup.server:send({ balance = 100, for_account = request.account }))
                return request
            end,
        })
        expect(results[1][1]):same { balance = 100, for_account = 7 }
        expect(results[2][1]):same { op = "balance", account = 7 }

        -- Nothing on the wire is readable.
        expect(setup.net.frames.top > 0):eq(true)
    end)

    it("lets a client which knows the server's key stay anonymous, if the server allows it", function()
        local setup = connect { pattern = "NK", anonymous = true }
        expect(setup.client.peer_key):eq(setup.server_key.public)
        expect(setup.server.peer_key):eq(nil)

        setup = connect { pattern = "NK" }
        expect(setup.server_err):eq("The client didn't say who it is")
        expect(setup.client):eq(nil)
    end)

    it("checks the server before saying who the client is", function()
        local seen
        local function verify(key)
            seen = key
            return nil, "Not the server we wanted"
        end
        local setup = connect { verify = verify }
        expect(seen):eq(setup.server_key.public)
        expect(setup.client_err):eq("Not the server we wanted")
        -- The server never learnt the client's key.
        expect(setup.server):eq(nil)
        expect(setup.server_err:find("Connection", 1, true) ~= nil):eq(true)
    end)

    it("fails if the server isn't who the client expected", function()
        local setup = connect { pattern = "NK", remote_static = new_key().public, anonymous = true }
        expect(setup.client):eq(nil)
        expect(setup.client_err:sub(1, 21)):eq("The handshake failed:")
        expect(setup.server):eq(nil)
    end)

    it("passes the server's certificate", function()
        local setup = connect { certificate = "a certificate" }
        expect(setup.client.peer_info.certificate):eq("a certificate")
    end)

    it("rejects tampered messages, and ends the connection", function()
        local setup = connect()
        inject(setup, "A", ("x"):rep(40))
        local result = exchange(setup, { function() return setup.server:receive(5) end })[1]
        expect(result[1]):eq(nil)
        expect(result[2]):eq("Message was tampered with")
        expect(setup.server:send("anything")):eq(nil)

        -- The client's side is reset.
        setup.net.advance(1)
        expect(setup.client.transport.connection.error):eq("Connection reset")
    end)

    it("rejects replayed messages", function()
        local setup = connect()
        -- Watch the client's message go by, and send it again later.
        local captured
        local real_inject = setup.net.queue
        exchange(setup, {
            function()
                assert(setup.client:send("pay 10 to Bob"))
                for _, item in ipairs(real_inject) do
                    local segment = item.frame.body and item.frame.body.body
                    if type(segment) == "table" and type(segment.data) == "string" then captured = segment.data end
                end
            end,
        })
        expect(type(captured)):eq("string")
        local first = exchange(setup, { function() return setup.server:receive(5) end })[1]
        expect(first[1]):eq("pay 10 to Bob")

        inject(setup, "A", captured)
        local again = exchange(setup, { function() return setup.server:receive(5) end })[1]
        expect(again[1]):eq(nil)
        expect(again[2]):eq("Message was tampered with")
    end)

    it("notices a connection cut short", function()
        local setup = connect()
        inject(setup, "FA")
        local result = exchange(setup, { function() return setup.server:receive(5) end })[1]
        expect(result[1]):eq(nil)
        expect(result[2]):eq("Connection closed unexpectedly")
    end)

    it("closes cleanly", function()
        local setup = connect()
        local results = exchange(setup, {
            function()
                setup.client:send("last words")
                setup.client:close()
                return setup.client:receive(5)
            end,
            function()
                local first = setup.server:receive(5)
                local second = setup.server:receive(5)
                setup.server:close()
                return first, second
            end,
        })
        expect(results[1][1]):eq(nil)
        expect(results[1].n):eq(1)
        expect(results[2][1]):eq("last words")
        expect(results[2][2]):eq(nil)
        expect({ setup.client:send("more") }):same { nil, "Connection closed" }
    end)

    it("carries streams, even over a lossy link", function()
        local setup = connect()
        setup.net.loss.top, setup.net.jitter.top = 0.1, 0.1
        math.randomseed(3)
        local data = ("All work and no play. "):rep(12000)
        local results = exchange(setup, {
            function()
                local out = stream.wrap(setup.client)
                out.write(data)
                out.close()
            end,
            function() return stream.wrap(setup.server).readAll() end,
        })
        expect(results[2][1] == data):eq(true)

        -- A full stream chunk fits in one message.
        expect(#codec.encode({ d = ("x"):rep(stream.CHUNK) }) <= secure.MAX_ENCODED):eq(true)
    end)

    it("refuses messages it can't send, without breaking the connection", function()
        local setup = connect()
        expect({ setup.client:send(nil) }):same { nil, "Can't send nil" }
        expect({ setup.client:send(print) }):same { nil, "Can't encode a function" }
        expect({ setup.client:send(("x"):rep(secure.MAX_ENCODED)) }):same { nil, "Message too large" }
        local results = exchange(setup, {
            function() return setup.client:send("fine") end,
            function() return setup.server:receive(5) end,
        })
        expect(results[2][1]):eq("fine")
    end)

    it("refuses connections which don't start with a handshake", function()
        local net = network()
        local a, b = net.add(1, "10.0.0.1/24"), net.add(2, "10.0.0.2/24")
        net.run()
        local listener = assert(tcp.listen(b, 22))
        local client_tcp = assert(tcp.connect(a, ip("10.0.0.2"), 22))
        local results = run(net, {
            function()
                while client_tcp.state == "syn_sent" do coroutine.yield() end
                client_tcp:send({ hello = "plain" })
            end,
            function()
                local connection
                repeat
                    connection = listener:accept()
                    if not connection then coroutine.yield() end
                until connection
                return secure.server(blocking(net, connection), { crypto = crypto, static = new_key(), timeout = 5 })
            end,
        })
        expect(results[2][1]):eq(nil)
        expect(results[2][2]):eq("Not a secure connection")
    end)
end)
