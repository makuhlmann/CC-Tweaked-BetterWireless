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

        it("needs the enclave", function()
            expect.error(net.secure.listen, 4401):eq("Secure connections need the crypto and enclave APIs, which are turned off on this server")
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
end)
