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

        it("listens before anything else has started the network stack, as a startup program may", function()
            -- A copy of the API as a computer has it when it starts: nothing has loaded the network stack yet.
            local env = setmetatable({}, { __index = _G })
            assert(loadfile("/rom/apis/net.lua", nil, env))()
            local listener = assert(env.tcp.listen(4326))
            listener:close()
            -- rshd listens securely, where secure connections can be made.
            if crypto and enclave then
                local secure = assert(env.secure.listen(4327))
                secure:close()
            end
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
        --[[ Run a function with a wired modem which is only pretend: what's sent on it is kept, in `sent`, and goes
        nowhere. The network stack sees it come before the function runs, and go afterwards. ]]
        local function with_modem(fn)
            local name, sent = "net_spec_modem", {}
            local has_type, call = peripheral.hasType, peripheral.call
            stub(peripheral, "hasType", function(side, kind)
                if side == name then return kind == "modem" end
                return has_type(side, kind)
            end)
            stub(peripheral, "call", function(side, method, ...)
                if side == name then
                    if method == "transmit" then sent[#sent + 1] = select(3, ...) end
                    return method ~= "isWireless" and nil or false
                end
                return call(side, method, ...)
            end)
            -- Attach it, and let the network stack see it come.
            os.queueEvent("peripheral", name)
            local _, up, what
            repeat _, up, what = os.pullEvent("net_interface") until up == name and what == "up"

            local ok, err = pcall(fn, name, sent)

            -- Take the pretend modem away again, and let the network stack see it go.
            os.queueEvent("peripheral_detach", name)
            os.queueEvent("net_spec_marker")
            os.pullEvent("net_spec_marker")
            expect(net.getAddress(name)):eq(nil)
            if not ok then error(err, 0) end
        end

        -- Every event queued so far, up to a marker.
        local function events()
            os.queueEvent("net_spec_marker")
            local list = {}
            while true do
                local event = table.pack(os.pullEvent())
                if event[1] == "net_spec_marker" then return list end
                list[#list + 1] = event
            end
        end

        local function route_to(network)
            for _, route in ipairs(net.routes()) do
                if route.network == network then return route end
            end
            return nil
        end

        it("say when an interface's address is changed by hand", function()
            with_modem(function(name)
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
        end)

        it("are sent encrypted on an interface with a passphrase, and not without", function()
            expect.error(net.setPassphrase, "net_spec_none", "x"):eq("No interface named 'net_spec_none'")
            with_modem(function(name, sent)
                net.setAddress(name, "10.123.0.5/24")
                expect(sent[#sent].type):ne("sealed")

                -- The address is announced again, sealed, for the computers which share the passphrase.
                local before = #sent
                net.setPassphrase(name, "open sesame")
                expect(#sent > before):eq(true)
                for i = before + 1, #sent do expect(sent[i].type):eq("sealed") end

                before = #sent
                net.setPassphrase(name, nil)
                expect(#sent > before):eq(true)
                expect(sent[#sent].type):ne("sealed")
            end)
        end)

        it("give the routes to the networks they're on, and those set up, once they're applied", function()
            with_modem(function(name)
                net.setAddress(name, "10.123.0.5/24")
                expect(route_to("10.123.0.0/24")):matches { interface = name, source = "connected" }
                expect(route_to("10.5.0.0/16")):eq(nil)

                settings.set("net.routes", { "10.5.0.0/16 via 10.123.0.1" })
                local ok, err = pcall(function()
                    -- Not until they're applied.
                    expect(route_to("10.5.0.0/16")):eq(nil)
                    net.reload()
                    expect(route_to("10.5.0.0/16")):matches { gateway = "10.123.0.1", source = "static" }
                end)
                settings.unset("net.routes")
                net.reload()
                if not ok then error(err, 0) end
                expect(route_to("10.5.0.0/16")):eq(nil)
            end)
        end)

        it("are seen in the frames captured while that's asked for", function()
            with_modem(function(name)
                net.capture(true)
                local ok, err = pcall(function()
                    net.setAddress(name, "10.123.0.5/24")
                    local captured = 0
                    for _, event in ipairs(events()) do
                        if event[1] == "net_frame" then
                            expect({ event[2], event[3], type(event[4]) }):same { "out", name, "table" }
                            captured = captured + 1
                        end
                    end
                    expect(captured > 0):eq(true)
                end)
                net.capture(false)
                if not ok then error(err, 0) end

                -- Not once it's stopped.
                net.setAddress(name, "10.123.0.6/24")
                for _, event in ipairs(events()) do expect(event[1]):ne("net_frame") end
            end)
        end)
    end)

    describe("names", function()
        it("are this computer's own, as set, or from its label", function()
            settings.set("net.hostname", "Relay 7!")
            local ok, err = pcall(function() expect(net.getHostname()):eq("relay-7") end)
            settings.unset("net.hostname")
            if not ok then error(err, 0) end
            if not os.getComputerLabel() then expect(net.getHostname()):eq("computer-" .. os.getComputerID()) end
        end)

        it("are found as addresses, fixed names, and this computer's own", function()
            expect(net.resolve("10.1.2.3")):eq("10.1.2.3")
            settings.set("net.hosts", { bank = "10.9.9.9" })
            local ok, err = pcall(function() expect(net.resolve("bank")):eq("10.9.9.9") end)
            settings.unset("net.hosts")
            if not ok then error(err, 0) end
            expect(net.resolve(net.getHostname())):ne(nil)
        end)

        -- Finding services others offer is tested in dns_spec, on a network with others on it.
        it("of services nobody offers aren't found", function()
            net.host("net-spec-service", 4567)
            net.unhost("net-spec-service")
            expect(net.lookup("net-spec-nobody", 0.2)):same {}
        end)
    end)

    it("keeps errors for debugging, giving a copy of them", function()
        local errors = net.getErrors()
        expect(type(errors)):eq("table")
        for _, err in ipairs(errors) do expect(type(err)):eq("string") end
        errors[#errors + 1] = "Not one of the network stack's"
        expect(#net.getErrors()):eq(#errors - 1)
    end)

    describe("net.secure", function()
        -- The enclave is part of the mod, not the computer, so pretend to have one.
        local with_enclave = require "support.net_helpers".with_enclave

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

        it("lists trusted authorities: only keys, with what they're called", function()
            local file = fs.open("/.net/trust", "w")
            file.write(textutils.serialise({
                [("AB"):rep(32)] = "Bank", short = "x", [("zz"):rep(32)] = "junk", [1] = "a number",
            }))
            file.close()
            local ok, err = pcall(function()
                expect(net.trusted()):same { [("ab"):rep(32)] = "Bank" }
            end)
            fs.delete("/.net")
            if not ok then error(err, 0) end
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

        it("keeps messages sent while cell service is off, to send once it's on", function()
            expect({ net.cell.send("0007", "Hello") }):same { nil, "No SIM" }

            write("/.net/sim", { network = "ACME", key = ("ab"):rep(32), signing = ("cd"):rep(32) })
            write("/.net/phone", { off = true })
            write("/.net/messages", { { to = "3", text = "earlier", time = 1000, n = 1, id = 41, status = "sent" } })
            -- It's numbered after the phone's own, and waits.
            expect({ net.cell.send("0007", "Later") }):same { true, 42 }
            local list = net.cell.messages()
            expect({ list[2].to, list[2].text, list[2].status }):same { "0007", "Later", "waiting" }
            expect({ net.cell.send("", "x") }):same { nil, "Numbers are up to 32 characters" }

            -- As many may wait as the phone keeps.
            for i = 1, 19 do assert(net.cell.send("0007", "More " .. i)) end
            expect({ net.cell.send("0007", "One too many") }):same { nil, "Too many messages are waiting to be sent" }
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

        describe("a cell's settings", function()
            local CELL = "/.cell/cell"
            local function contents()
                local file = fs.open(CELL, "r")
                if not file then return nil end
                local text = file.readAll()
                file.close()
                return text
            end
            -- Run a test with no cell set up, and none afterwards.
            local function fresh(fn)
                fs.delete("/.cell")
                local ok, err = pcall(fn)
                fs.delete("/.cell")
                if not ok then error(err, 0) end
            end
            local function settings_of(info)
                return {
                    cores = info.cores, enabled = info.enabled, area = info.area, band = info.band, interval = info.interval,
                    pos = info.pos, power = info.power, service = info.service,
                }
            end

            it("change one at a time, keeping everything else", function()
                fresh(function()
                    expect(settings_of(net.cell.cellInfo())):same { enabled = true, area = 0 }
                    expect({ net.cell.configureCell({ cores = { "core.acme" } }) }):same { true, false }
                    expect({ net.cell.configureCell({ pos = { 1, 2, 3 } }) }):same { true, false }
                    expect({ net.cell.configureCell({ band = "B3" }) }):same { true, false }
                    expect({ net.cell.configureCell({ interval = 4, power = 30, service = "sms", area = 2 }) }):same { true, false }
                    local info = net.cell.cellInfo()
                    expect(info.state):eq("stopped")
                    expect(settings_of(info)):same {
                        cores = { "core.acme" }, enabled = true, area = 2, band = "b3", interval = 4, pos = { 1, 2, 3 },
                        power = 30, service = "sms",
                    }

                    -- Cores once each, whatever case they're written in.
                    net.cell.configureCell({ cores = { "core.acme", "CORE.ACME", "core.beta" } })
                    expect(net.cell.cellInfo().cores):same { "core.acme", "core.beta" }
                    -- One it has, spelt another way, stays as it was (so a running cell wouldn't drop its network).
                    net.cell.configureCell({ cores = { "Core.Beta", "CORE.ACME", "core.gamma" } })
                    expect(net.cell.cellInfo().cores):same { "core.beta", "core.acme", "core.gamma" }
                    net.cell.configureCell({ cores = { "core.acme", "core.beta" } })

                    -- Each back as it is when it's not set, and the cores stay.
                    net.cell.configureCell({ area = false, band = false, interval = false, pos = false, power = false, service = false })
                    expect(settings_of(net.cell.cellInfo())):same { cores = { "core.acme", "core.beta" }, enabled = true, area = 0 }

                    -- With no cores, there's nothing to start.
                    net.cell.configureCell({ cores = {} })
                    expect(net.cell.cellInfo().cores):eq(nil)
                    expect({ net.cell.startCell() }):same { nil, "The cell has no cores to connect to" }
                end)
            end)

            it("change nothing when anything won't do", function()
                fresh(function()
                    net.cell.configureCell({ cores = { "core.acme" }, band = "b20", pos = { 1, 2, 3 }, interval = 2 })
                    local before = contents()
                    local nine = {}
                    for i = 1, 9 do nine[i] = "core" .. i end
                    for _, case in ipairs {
                        { { band = "b33" }, "There's no cellular band called b33: they're b31, b28, b20, b8, b3, b1 and b7" },
                        { { band = "low" }, "There's no cellular band called low: they're b31, b28, b20, b8, b3, b1 and b7" },
                        { { interval = 0.1 }, "A cell sends its system information every 0.5 to 10 seconds" },
                        { { interval = 11 }, "A cell sends its system information every 0.5 to 10 seconds" },
                        { { pos = { 1.5, 2, 3 } }, "A cell's position is three whole numbers: its computer's x, y and z" },
                        { { pos = { 1, 2 } }, "A cell's position is three whole numbers: its computer's x, y and z" },
                        { { power = 0 / 0 }, "A cell's power is a number of dBm" },
                        { { power = math.huge }, "A cell's power is a number of dBm" },
                        { { service = "full" }, "A cell's service is \"sms\" (messages only), or everything" },
                        { { area = -1 }, "A cell's area is a whole number, 0 or more" },
                        { { area = 1.5 }, "A cell's area is a whole number, 0 or more" },
                        { { cores = { "core acme" } }, "Core 1 isn't a name or an address" },
                        { { cores = { "core.acme", "" } }, "Core 2 isn't a name or an address" },
                        { { cores = nine }, "A cell serves at most 8 networks" },
                        -- One which would do, with one which won't: neither.
                        { { pos = { 4, 5, 6 }, band = "b33" }, "There's no cellular band called b33: they're b31, b28, b20, b8, b3, b1 and b7" },
                    } do
                        expect({ net.cell.configureCell(case[1]) }):describe(case[2]):same { nil, case[2] }
                        expect(contents()):describe(case[2]):eq(before)
                    end

                    expect.error(net.cell.configureCell, "x"):eq("bad argument #1 (table expected, got string)")
                    expect.error(net.cell.configureCell, { cores = "core.acme" }):eq("bad field 'cores' (table expected, got string)")
                    expect.error(net.cell.configureCell, { cores = { 5 } }):eq("bad field 'cores' (core 1 is a number, not a string)")
                    expect.error(net.cell.configureCell, { area = "1" }):eq("bad field 'area' (number or false expected, got string)")
                    expect.error(net.cell.configureCell, { pos = true }):eq("bad field 'pos' (table or false expected, got boolean)")
                    expect(contents()):eq(before)
                end)
            end)

            it("take a list of bands and carriers, for a cell on each", function()
                fresh(function()
                    net.cell.configureCell({ cores = { "core.acme" } })
                    expect({ net.cell.configureCell({ band = { "B20", "b3/2", "b3" } }) }):same { true, false }
                    expect(net.cell.cellInfo().band):same { "b20", "b3/2", "b3" }
                    -- A list of one band is that band, as it always was; a carrier by name stays a list.
                    net.cell.configureCell({ band = { "B3" } })
                    expect(net.cell.cellInfo().band):eq("b3")
                    net.cell.configureCell({ band = "B3/1" })
                    expect(net.cell.cellInfo().band):same { "b3/1" }

                    local before = contents()
                    local nine = {}
                    for i = 1, 9 do nine[i] = "b3" end
                    for _, case in ipairs {
                        { { band = {} }, "A cell's band is a band, or a list of bands and carriers" },
                        { { band = { "b3", "b33" } }, "There's no cellular band called b33: they're b31, b28, b20, b8, b3, b1 and b7" },
                        { { band = { "b3/1", "B3/1" } }, "b3/1 is there twice: a computer has one cell on a carrier" },
                        { { band = "b3/99" }, "There's no carrier called b3/99: a band's carriers are numbered from 1, as in b20/1" },
                        { { band = { "b3", 5 } }, "Band 2 isn't a band's name" },
                        { { band = nine }, "A computer runs at most 8 cells" },
                    } do
                        expect({ net.cell.configureCell(case[1]) }):describe(case[2]):same { nil, case[2] }
                        expect(contents()):describe(case[2]):eq(before)
                    end
                    expect.error(net.cell.configureCell, { band = 5 }):eq("bad field 'band' (string or false expected, got number)")
                    expect.error(net.cell.startCell, "core.acme", { band = 5 }):eq("bad field 'band' (string expected, got number)")

                    net.cell.configureCell({ band = false })
                    expect(net.cell.cellInfo().band):eq(nil)
                end)
            end)

            it("are read from older versions' files, keeping what makes sense", function()
                fresh(function()
                    write(CELL, { core = "core.old", area = 3, band = "b33", pos = "here", interval = 2, enabled = false })
                    expect(settings_of(net.cell.cellInfo())):same { cores = { "core.old" }, enabled = false, area = 3, interval = 2 }
                    expect(net.cell.configureCell({ power = 20 })):eq(true)
                    local saved = textutils.unserialise(contents())
                    expect(saved):same { cores = { "core.old" }, area = 3, interval = 2, power = 20, enabled = false }
                end)
            end)
        end)

        it("copes with files it can't make sense of", function()
            for _, path in ipairs(FILES) do
                local file = fs.open(path, "w")
                file.write("not { a table")
                file.close()
            end
            local info = net.cell.info()
            expect({ info.state, info.enabled, info.selection, info.unread }):same { "none", false, "auto", 0 }
            expect(net.cell.messages()):same {}

            -- Tables, with nothing in them as it should be.
            write("/.net/phone", { listen = "yes", off = 1, network = 5 })
            write("/.net/sim", { network = {}, key = 5, signing = true, roaming = { "x", [true] = 1 }, equivalent = 3, id = {} })
            write("/.net/messages", { 1, "two", { text = 3 }, { from = {}, text = "odd", time = "now" } })
            info = net.cell.info()
            expect({ info.state, info.enabled, info.selection, info.network }):same { "none", false, "auto", nil }
            expect(net.cell.networks()):same {}
            expect(#net.cell.messages()):eq(1)
            expect({ net.cell.send("1", "hello") }):same { nil, "No SIM" }
            clean()
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
            -- Without a SIM, it's off until it's told to listen for cells.
            expect(net.cell.info().enabled):eq(false)
            expect({ net.cell.send("1", "hello") }):same { nil, "No SIM" }

            write("/.net/sim", { network = "ACME", key = ("ab"):rep(32), signing = ("cd"):rep(32), id = "ACME-1", number = "1" })
            expect(net.cell.setEnabled(false)):eq(true)
            local info = net.cell.info()
            expect({ info.state, info.enabled, info.network, info.selection, info.roaming }):same { "off", false, "ACME", "auto", false }
            expect(info.subscriber):same { id = "ACME-1", number = "1" }
            -- A message sent while it's off waits until it's on again.
            expect((net.cell.send("1", "hello"))):eq(true)
            expect(net.cell.messages()[1].status):eq("waiting")

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

        -- A modem's block may be replaced while the computer runs on, as when Sable moves it: the modem goes, and
        -- comes back as a new peripheral. The phone's interface goes with it, and once stayed gone, so the phone heard
        -- no cells.
        it("keeps its phone on the air when its modem is replaced", function()
            if not crypto then return end
            local with_enclave = require "support.net_helpers".with_enclave
            local getupvalue = require "support.debug_ext".getupvalue
            local s = getupvalue(net.run, "load")()
            local cellular = getupvalue(net.run, "cellular_api")
            local function phone() return getupvalue(cellular.start_phone, "phone_instance") end

            -- Pretend wireless modems, which the network stack sees come and go.
            local present = {}
            local has_type, call = peripheral.hasType, peripheral.call
            stub(peripheral, "hasType", function(side, kind)
                if present[side] then return kind == "modem" end
                return has_type(side, kind)
            end)
            stub(peripheral, "call", function(side, method, ...)
                if present[side] then return method == "isWireless" or nil end
                return call(side, method, ...)
            end)
            local function attach(name)
                present[name] = true
                os.queueEvent("peripheral", name)
                local _, up, what
                repeat _, up, what = os.pullEvent("net_interface") until up == name and what == "up"
            end
            local function detach(name)
                present[name] = nil
                os.queueEvent("peripheral_detach", name)
                os.queueEvent("net_spec_marker")
                os.pullEvent("net_spec_marker")
            end

            with_enclave(function()
                local ok, err = pcall(function()
                    write("/.net/sim", { network = "ACME", key = ("ab"):rep(32), signing = ("cd"):rep(32), id = "ACME-1", number = "1" })
                    attach("net_spec_radio")
                    expect(net.cell.setEnabled(true)):eq(true)
                    expect(s.interfaces["cell.phone"].modem):eq("net_spec_radio")

                    -- The same modem comes back: the phone is on it again.
                    detach("net_spec_radio")
                    expect(s.interfaces["cell.phone"]):eq(nil)
                    attach("net_spec_radio")
                    expect(phone().modem):eq("net_spec_radio")
                    expect(s.interfaces["cell.phone"].modem):eq("net_spec_radio")

                    -- Another takes its place: the phone moves onto that.
                    detach("net_spec_radio")
                    attach("net_spec_other")
                    expect(phone().modem):eq("net_spec_other")
                    expect(s.interfaces["cell.phone"].modem):eq("net_spec_other")
                end)

                net.cell.setEnabled(false)
                for name in pairs(present) do detach(name) end
                clean()
                if not ok then error(err, 0) end
            end)
        end)

        it("listens for cells without a SIM, once told to, from when the computer starts too", function()
            if not crypto then return end
            local with_enclave = require "support.net_helpers".with_enclave
            local getupvalue = require "support.debug_ext".getupvalue
            local s = getupvalue(net.run, "load")()
            local cellular = getupvalue(net.run, "cellular_api")
            local function phone() return getupvalue(cellular.start_phone, "phone_instance") end
            local function read(path)
                local file = fs.open(path, "r")
                if not file then return nil end
                local value = textutils.unserialise(file.readAll())
                file.close()
                return value
            end

            -- A pretend wireless modem, which the network stack sees come and go.
            local present = {}
            local has_type, call = peripheral.hasType, peripheral.call
            stub(peripheral, "hasType", function(side, kind)
                if present[side] then return kind == "modem" end
                return has_type(side, kind)
            end)
            stub(peripheral, "call", function(side, method, ...)
                if present[side] then return method == "isWireless" or nil end
                return call(side, method, ...)
            end)
            local function attach(name)
                present[name] = true
                os.queueEvent("peripheral", name)
                local _, up, what
                repeat _, up, what = os.pullEvent("net_interface") until up == name and what == "up"
            end
            local function detach(name)
                present[name] = nil
                os.queueEvent("peripheral_detach", name)
                os.queueEvent("net_spec_marker")
                os.pullEvent("net_spec_marker")
            end

            with_enclave(function()
                local ok, err = pcall(function()
                    -- Nothing another test left listening.
                    net.cell.setEnabled(false)
                    clean()

                    -- Without a SIM, nothing starts, even with a modem.
                    attach("net_spec_radio")
                    expect(phone()):eq(nil)
                    expect({ net.cell.info().state, net.cell.info().enabled }):same { "none", false }

                    -- Told to, it listens, and keeps that.
                    expect(net.cell.setEnabled(true)):eq(true)
                    local info = net.cell.info()
                    expect({ info.state, info.enabled, info.network }):same { "inactive", true, nil }
                    expect(phone().operator):eq(nil)
                    expect(s.interfaces["cell.phone"].modem):eq("net_spec_radio")
                    expect(read("/.net/phone")):same { listen = true }

                    -- Turned off, it stops, and doesn't start with the computer.
                    expect(net.cell.setEnabled(false)):eq(true)
                    expect(phone()):eq(nil)
                    expect({ net.cell.info().state, net.cell.info().enabled }):same { "none", false }
                    expect(read("/.net/phone")):same { off = true }
                    cellular.start_phone()
                    expect(phone()):eq(nil)

                    -- Told to listen, it starts listening with the computer.
                    write("/.net/phone", { listen = true })
                    cellular.start_phone()
                    expect(phone().state):eq("inactive")

                    -- Told to without a modem, it keeps that, and starts once one comes.
                    net.cell.setEnabled(false)
                    detach("net_spec_radio")
                    expect({ net.cell.setEnabled(true) }):same { nil, "This needs a wireless modem" }
                    expect(read("/.net/phone")):same { listen = true }
                    expect(net.cell.info().enabled):eq(true)
                    attach("net_spec_radio")
                    expect(phone().state):eq("inactive")
                end)

                net.cell.setEnabled(false)
                for name in pairs(present) do detach(name) end
                clean()
                if not ok then error(err, 0) end
            end)
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

    describe("net.run", function()
        it("keeps one timer for the stack, even when its timers come late", function()
            local s = require "support.debug_ext".getupvalue(net.run, "load")()

            -- Something for the stack to do shortly, and then a test which runs on without yielding, for longer than
            -- the background process lets a timer be late.
            local ran = false
            s:schedule(0.05, function() ran = true end)
            local finish = os.clock() + 1.5
            while os.clock() < finish do end

            -- The background process sees every event. Count the timers it starts while a few go by: it once started
            -- one for each, and then one for each of those, until the computer's event queue was full of them.
            local started, start_timer = 0, os.startTimer
            stub(os, "startTimer", function(...)
                if debug.getinfo(2, "S").short_src:find("apis/net.lua", 1, true) then started = started + 1 end
                return start_timer(...)
            end)
            for _ = 1, 50 do
                os.queueEvent("net_spec_late")
                os.pullEvent("net_spec_late")
            end
            local deadline = os.clock() + 2
            while not ran and os.clock() < deadline do sleep(0.05) end

            expect(ran):eq(true)
            expect(started < 10):describe(("started %d timers"):format(started)):eq(true)
        end)
    end)
end)
