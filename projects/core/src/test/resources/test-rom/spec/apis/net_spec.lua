-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The net library", function()
    describe("net.tcp", function()
        it("validates its arguments", function()
            expect.error(net.tcp.connect, nil):eq("bad argument #1 (string expected, got nil)")
            expect.error(net.tcp.listen, "x"):eq("bad argument #1 (number expected, got string)")
            expect.error(net.stream, {}):eq("bad argument #1 (expected a connection)")
            expect({ net.tcp.listen(0) }):same { nil, "Ports must be whole numbers from 1 to 65535" }
            expect({ net.tcp.connect("127.0.0.1", 0) }):same { nil, "Ports must be whole numbers from 1 to 65535" }
            expect({ net.tcp.connect("127.0.0.1", 1.5) }):same { nil, "Ports must be whole numbers from 1 to 65535" }
            for _, timeout in ipairs { -1, math.huge, 0 / 0 } do
                expect.error(net.tcp.connect, "127.0.0.1", 80, timeout):eq("bad argument #3 (invalid timeout)")
                expect.error(net.lookup, "chat", timeout):eq("bad argument #2 (invalid timeout)")
            end
            expect.error(net.host, "chat", 70000):eq("bad argument #2 (Ports must be whole numbers from 1 to 65535)")

            local listener = assert(net.tcp.listen(4324))
            expect.error(listener.accept, listener, -1):eq("bad argument #1 (invalid timeout)")
            listener:close()
        end)

        it("connects to this computer, and carries messages and streams", function()
            local listener = assert(net.tcp.listen(4321))
            expect({ net.tcp.listen(4321) }):same { nil, "Port 4321 is in use" }
            local client = assert(net.tcp.connect("127.0.0.1", 4321, 1))
            local server = assert(listener:accept(1))
            listener:close()
            expect(client:isOpen()):eq(true)
            expect(select(2, server:getPeer())):eq(client:getPort())

            expect(client:send({ hello = true })):eq(true)
            expect(server:receive(1)):same { hello = true }
            expect({ client:send(print) }):same { nil, "Can't send a function" }

            local data = ("0123456789"):rep(5000)
            local out = net.stream(server)
            out.write(data)
            out.close()
            local input = net.stream(client)
            expect(input.read(10)):eq("0123456789")
            expect(input.readAll()):eq(data:sub(11))
            expect(input.read()):eq(nil)
            expect(client:receive(1)):eq(nil)

            client:close()
            expect(client:isOpen()):eq(false)
        end)

        it("refuses connections nobody is listening for", function()
            expect({ net.tcp.connect("127.0.0.1", 4322, 1) }):same { nil, "Connection refused" }
        end)
    end)

    describe("net.udp", function()
        it("sends datagrams to this computer, and refuses ones which couldn't cross every link", function()
            local server, client = assert(net.udp.open(4323)), assert(net.udp.open())
            local recursive = {}
            recursive.self = recursive
            expect({ client:send("127.0.0.1", 4323, { reply = print }) }):same { nil, "Can't send a function" }
            expect({ client:send("127.0.0.1", 4323, recursive) }):same { nil, "Can't send a table which contains itself" }

            expect({ client:send("127.0.0.1", 4323, { hello = "world" }) }):same { true }
            local data, from, port = server:receive(2)
            expect(data):same { hello = "world" }
            expect(from):eq("127.0.0.1")
            expect(port):eq(client:getPort())
            -- Nothing else was sent.
            expect(server:receive(0.1)):eq(nil)
            server:close()
            client:close()
        end)
    end)

    describe("net.udp's sockets", function()
        it("check ports and timeouts, and say why nothing was received", function()
            expect({ net.udp.open(0) }):same { nil, "Ports must be whole numbers from 1 to 65535" }
            expect({ net.udp.open(65536) }):same { nil, "Ports must be whole numbers from 1 to 65535" }
            local socket = assert(net.udp.open())
            expect({ socket:send("127.0.0.1", 0, "x") }):same { nil, "Ports must be whole numbers from 1 to 65535" }
            expect.error(socket.receive, socket, 0 / 0):eq("bad argument #1 (invalid timeout)")
            expect({ socket:receive(0.05) }):same { nil, "Timed out" }
            socket:close()
            expect({ socket:receive(1) }):same { nil, "Socket is closed" }
        end)

        it("leave no event behind for each datagram sent to an address", function()
            local server, client = assert(net.udp.open(4325)), assert(net.udp.open())
            for i = 1, 5 do assert(client:send("127.0.0.1", 4325, i)) end
            os.queueEvent("net_spec_marker")
            while true do
                local event = os.pullEvent()
                expect(event):ne("net_done")
                if event == "net_spec_marker" then break end
            end
            for i = 1, 5 do expect(server:receive(1)):eq(i) end
            server:close()
            client:close()
        end)
    end)

    describe("addresses", function()
        it("say when an interface's address is changed by hand", function()
            -- A wired modem which is only pretend: what's sent on it goes nowhere.
            local name = "net_spec_modem"
            local has_type, call = peripheral.hasType, peripheral.call
            stub(peripheral, "hasType", function(side, kind)
                if side == name then return kind == "modem" end
                return has_type(side, kind)
            end)
            stub(peripheral, "call", function(side, method, ...)
                if side == name then return method ~= "isWireless" and nil or false end
                return call(side, method, ...)
            end)
            -- Attach it, and let the network stack see it come.
            os.queueEvent("peripheral", name)
            local _, up, what
            repeat _, up, what = os.pullEvent("net_interface") until up == name and what == "up"

            local ok, err = pcall(function()
                expect(net.interfaces()):matches { { name = name } }
                expect(net.getAddress(name)):eq(nil)
                net.setAddress(name, "10.123.0.5/24")
                expect(net.getAddress(name)):eq("10.123.0.5/24")
                local _, changed, how
                repeat _, changed, how = os.pullEvent("net_interface") until changed == name
                expect(how):eq("address")

                -- Setting the same again changes nothing, and says nothing.
                net.setAddress(name, "10.123.0.5/24")
                os.queueEvent("net_spec_marker")
                expect(os.pullEvent()):eq("net_spec_marker")
            end)

            -- Take the pretend modem away again, and let the network stack see it go.
            os.queueEvent("peripheral_detach", name)
            os.queueEvent("net_spec_marker")
            os.pullEvent("net_spec_marker")
            expect(net.getAddress(name)):eq(nil)
            if not ok then error(err, 0) end
        end)
    end)

    describe("net.secure", function()
        -- The enclave is part of the mod, not the computer, so pretend to have one.
        local function with_enclave(fn)
            local keys, base = {}, "\9" .. ("\0"):rep(31)
            _G.enclave = {
                publicKey = function(name) return keys[name] and keys[name].public end,
                generate = function(name)
                    local private = crypto.generateKeyPair("x25519")
                    keys[name] = { private = private, public = crypto.exchange(private, base) }
                    return keys[name].public
                end,
                exchange = function(name, public) return crypto.exchange(keys[name].private, public) end,
            }
            local ok, err = pcall(fn)
            _G.enclave = nil
            fs.delete("/.net")
            if not ok then error(err, 0) end
        end

        -- Connect, with the listener accepting at the same time. When the client is expected to give up, the listener
        -- only waits a moment, rather than for the next client.
        local function connect(listener, options, accept_timeout)
            local client, server, err
            parallel.waitForAll(
                function() client, err = net.secure.connect("127.0.0.1", 4400, options) end,
                function() server = listener:accept(accept_timeout or 5) end
            )
            return client, server, err
        end

        it("connects securely to this computer, and remembers its key", function()
            with_enclave(function()
                local listener = assert(net.secure.listen(4400))
                local client, server = connect(listener)
                expect(client:getTrust()):eq("new")
                expect(client:getPeerKey()):eq(net.getIdentity())
                expect(server:getPeerKey()):eq(net.getIdentity())
                expect(net.knownHosts()["127.0.0.1"]):eq(net.getIdentity())
                expect(#net.fingerprint(net.getIdentity())):eq(24)

                client:send({ hello = "secure" })
                expect(server:receive(1)):same { hello = "secure" }
                local out = net.stream(server)
                out.write(("secret "):rep(5000))
                out.close()
                expect(net.stream(client).readAll()):eq(("secret "):rep(5000))
                client:close()

                -- The second time, it's known.
                client = connect(listener)
                expect(client:getTrust()):eq("known")
                client:abort()

                -- A pinned key must match.
                local _, _, err = connect(listener, { key = ("00"):rep(32) }, 0.5)
                expect(err):eq("The server's key isn't the one given")
                client = connect(listener, { key = net.getIdentity() })
                expect(client:getTrust()):eq("pinned")
                client:abort()

                -- A changed key is refused, until it's forgotten.
                local file = fs.open("/.net/known_hosts", "w")
                file.write(textutils.serialise({ ["127.0.0.1"] = ("ab"):rep(32) }))
                file.close()
                _, _, err = connect(listener, nil, 0.5)
                expect(err:find("The key for 127.0.0.1 has changed!", 1, true)):eq(1)
                expect(net.forgetHost("127.0.0.1")):eq(true)
                client = connect(listener)
                expect(client:getTrust()):eq("new")
                client:abort()

                listener:close()
            end)
        end)

        it("validates its options, and keys", function()
            expect.error(net.secure.connect, "127.0.0.1", 4400, { timeout = -1 }):eq("bad option timeout (invalid timeout)")
            expect.error(net.secure.connect, "127.0.0.1", 4400, { trust = "tofu" })
                :eq('bad option trust (expected "certificate" or nothing)')
            expect.error(net.fingerprint, "not a key"):eq("bad argument #1 (expected a key: 64 hexadecimal digits)")
            expect.error(net.fingerprint, ("ab"):rep(31)):eq("bad argument #1 (expected a key: 64 hexadecimal digits)")
        end)

        it("lists known hosts as it lists trusted authorities: only what's a name and a key", function()
            local file = fs.open("/.net/known_hosts", "w")
            file.write(textutils.serialise({
                ["good.home"] = ("AB"):rep(32), short = "abcd", [1] = ("ab"):rep(32), notkey = ("zz"):rep(32),
            }))
            file.close()
            local ok, err = pcall(function()
                expect(net.knownHosts()):same { ["good.home"] = ("ab"):rep(32) }
            end)
            fs.delete("/.net")
            if not ok then error(err, 0) end
        end)

        it("needs the enclave", function()
            expect.error(net.secure.listen, 4401):eq("Secure connections need the crypto and enclave APIs, which are turned off on this server")
        end)
    end)

    describe("net.cell", function()
        local FILES = { "/.net/sim", "/.net/phone", "/.net/messages" }
        local function write(path, value)
            local file = fs.open(path, "w")
            file.write(textutils.serialise(value))
            file.close()
        end
        local function clean()
            for _, path in ipairs(FILES) do fs.delete(path) end
        end
        before_each(clean)

        it("validates its arguments", function()
            expect.error(net.cell.setEnabled, "yes"):eq("bad argument #1 (boolean expected, got string)")
            expect.error(net.cell.setNetwork, 5):eq("bad argument #1 (string expected, got number)")
            expect.error(net.cell.markRead, "all"):eq("bad argument #1 (number expected, got string)")
            expect.error(net.cell.deleteMessage):eq("bad argument #1 (number expected, got nil)")
            expect.error(net.cell.send, "1"):eq("bad argument #2 (string expected, got nil)")
        end)

        it("sees files changed by another program, though it keeps what it read", function()
            write("/.net/messages", { { from = "1", text = "new", time = 1000, read = false, n = 1 } })
            expect(net.cell.info().unread):eq(1)
            expect(net.cell.info().unread):eq(1)
            write("/.net/messages", {
                { from = "1", text = "new", time = 1000, read = false, n = 1 },
                { from = "2", text = "newer", time = 2000, read = false, n = 2 },
            })
            expect(net.cell.info().unread):eq(2)
            fs.delete("/.net/messages")
            expect(net.cell.info().unread):eq(0)
            write("/.net/phone", { network = "BETA" })
            expect(net.cell.info().selection):eq("BETA")
        end)

        it("keeps messages, numbered, with whether they've been read and how sending went", function()
            -- An older version's messages have no numbers, and count as read.
            write("/.net/messages", {
                { from = "1", text = "old", time = 1000 },
                { from = "2", text = "new", time = 2000, read = false, n = 7 },
                { to = "3", text = "on its way", time = 3000, n = 8, id = 99, status = "sending" },
                { to = "3", text = "there", time = 4000, n = 9, id = 98, status = "sent" },
                "junk",
            })
            expect(net.cell.info().unread):eq(1)
            expect(net.cell.messages()):same {
                { n = 10, from = "1", text = "old", time = 1000, read = true },
                { n = 7, from = "2", text = "new", time = 2000, read = false },
                -- The computer restarted before the network took this one.
                { n = 8, to = "3", text = "on its way", time = 3000, status = "failed", error = "Not sent" },
                { n = 9, to = "3", text = "there", time = 4000, status = "sent" },
            }

            expect(net.cell.markRead(99)):eq(0)
            expect(net.cell.markRead(7)):eq(1)
            expect(net.cell.markRead()):eq(0)
            expect(net.cell.info().unread):eq(0)
            expect(net.cell.deleteMessage(8)):eq(true)
            expect(net.cell.deleteMessage(8)):eq(false)
            local left = {}
            for i, message in ipairs(net.cell.messages()) do left[i] = message.text end
            expect(left):same { "old", "new", "there" }
            clean()
            expect(net.cell.messages()):same {}
        end)

        it("says when the messages it keeps change", function()
            write("/.net/messages", {
                { from = "2", text = "new", time = 2000, read = false, n = 7 },
                { from = "2", text = "newer", time = 3000, read = false, n = 8 },
            })
            local queued = {}
            stub(os, "queueEvent", function(name) queued[#queued + 1] = name end)

            -- Nothing is said when nothing changed.
            net.cell.markRead(99)
            net.cell.deleteMessage(99)
            expect(queued):same {}

            net.cell.markRead(7)
            expect(queued):same { "cell_messages" }
            net.cell.markRead(7)
            expect(queued):same { "cell_messages" }
            net.cell.markRead()
            net.cell.deleteMessage(8)
            expect(queued):same { "cell_messages", "cell_messages", "cell_messages" }
        end)

        it("manages a core, if there's one to manage", function()
            expect.error(net.cell.manage, 5):eq("bad argument #1 (string expected, got number)")
            expect.error(net.cell.manage, "10.0.0.1", "wait"):eq("bad argument #2 (function expected, got string)")
            if crypto and enclave then
                -- This computer isn't a core.
                expect({ net.cell.manage() }):same { nil, "Connection refused" }
            end
        end)

        it("lists networks the SIM treats as its own with it", function()
            write("/.net/sim", {
                network = "ACME", key = ("ab"):rep(32), signing = ("cd"):rep(32), id = "ACME-1", number = "1",
                roaming = { BETA = ("ef"):rep(32), GAMMA = ("01"):rep(32) }, equivalent = { BETA = true, DELTA = true },
            })
            expect(net.cell.setEnabled(false)):eq(true)
            local info = net.cell.info()
            expect({ info.partners, info.equivalent }):same { { BETA = true, GAMMA = true }, { BETA = true } }
            expect(net.cell.networks()):same {
                { name = "ACME", kind = "home", allowed = true, serving = false, selected = false },
                { name = "BETA", kind = "home", allowed = true, serving = false, selected = false, equivalent = true },
                { name = "GAMMA", kind = "partner", allowed = true, serving = false, selected = false },
            }
            clean()
        end)

        it("can be turned off, and told which network to use", function()
            expect(net.cell.info().state):eq("none")
            expect(net.cell.info().enabled):eq(true)
            expect({ net.cell.send("1", "hello") }):same { nil, "No SIM" }

            write("/.net/sim", { network = "ACME", key = ("ab"):rep(32), signing = ("cd"):rep(32), id = "ACME-1", number = "1" })
            expect(net.cell.setEnabled(false)):eq(true)
            local info = net.cell.info()
            expect({ info.state, info.enabled, info.network, info.selection, info.roaming }):same { "off", false, "ACME", "auto", false }
            expect(info.subscriber):same { id = "ACME-1", number = "1" }
            expect({ net.cell.send("1", "hello") }):same { nil, "Cell service is turned off" }

            -- Its own network is always listed, in range or not.
            expect(net.cell.networks()):same {
                { name = "ACME", kind = "home", allowed = true, serving = false, selected = false },
            }
            -- Any network may be chosen, even one it knows of no agreement with: the phone tries it.
            expect({ net.cell.setNetwork("NOT A NAME") }):same { nil, "Network names are letters, digits and dashes, up to 32 of them" }
            expect(net.cell.setNetwork("BETA")):eq(true)
            expect(net.cell.networks()):same {
                { name = "ACME", kind = "home", allowed = true, serving = false, selected = false },
                { name = "BETA", kind = "other", allowed = false, serving = false, selected = true },
            }
            expect(net.cell.setNetwork("ACME")):eq(true)
            expect(net.cell.info().selection):eq("ACME")
            expect(net.cell.networks()[1].selected):eq(true)
            expect(net.cell.setNetwork("auto")):eq(true)
            expect(net.cell.info().selection):eq("auto")
            clean()
        end)
    end)

    describe("net.ping", function()
        it("validates its arguments", function()
            expect.error(net.ping, nil):eq("bad argument #1 (string expected, got nil)")
            expect.error(net.ping, "127.0.0.1", 0 / 0):eq("bad argument #2 (invalid timeout)")
            for _, ttl in ipairs { 0, 256, 1.5, 0 / 0, math.huge } do
                expect.error(net.ping, "127.0.0.1", 1, ttl):eq("bad argument #3 (TTL must be a whole number from 1 to 255)")
            end
        end)
    end)

    describe("net.pinger", function()
        it("validates its arguments", function()
            expect.error(net.pinger, nil):eq("bad argument #1 (string expected, got nil)")
            for _, ttl in ipairs { 0, 256, 1.5, 0 / 0, math.huge } do
                expect.error(net.pinger, "127.0.0.1", ttl):eq("bad argument #2 (TTL must be a whole number from 1 to 255)")
            end
            local pinger = assert(net.pinger("127.0.0.1"))
            expect.error(pinger.receive, pinger, 0 / 0):eq("bad argument #1 (invalid timeout)")
            pinger:close()
        end)

        it("pings this computer, numbering each request", function()
            local pinger = assert(net.pinger("127.0.0.1"))
            expect(pinger:getAddress()):eq("127.0.0.1")
            expect({ pinger:send() }):same { 1 }
            expect({ pinger:send() }):same { 2 }
            expect(pinger:receive(1)):matches { seq = 1, from = "127.0.0.1", duplicate = false }
            local reply = pinger:receive(1)
            expect(reply):matches { seq = 2, from = "127.0.0.1", duplicate = false }
            expect(type(reply.time)):eq("number")
            expect(pinger:receive(0.1)):eq(nil)

            pinger:close()
            expect({ pinger:send() }):same { nil, "Pinger is closed" }
            expect(pinger:receive()):eq(nil)
        end)
    end)
end)
