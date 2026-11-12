-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.dns", function()
    local dns = require "cc.internal.net.dns"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    local function computer(net, id, addr, name, services)
        local stack = net.add(id, addr)
        dns.respond(stack, { hostname = function() return name end, services = services or {} })
        return stack
    end

    local function resolve(net, stack, name, options)
        options = options or {}
        options.hostname = options.hostname or "alpha"
        options.cache = options.cache or {}
        return net.await(function(callback) dns.resolve(stack, name, options, callback) end)
    end

    -- A DNS server for "home", as dnsd runs it.
    local function serve(stack, records)
        local server = dns.server("home", records)
        local socket
        socket = stack:udp_open(dns.DNS_PORT, function(question, from, port)
            local answer = server:handle(question)
            if answer then stack:udp_send(socket, from, port, answer) end
        end)
    end

    it("resolves .local names", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        computer(net, 2, "10.0.0.2/24", "beta")
        net.run()

        expect(resolve(net, a, "beta.local")):eq(ip("10.0.0.2"))
        expect(resolve(net, a, "BETA.local.")):eq(ip("10.0.0.2"))
        -- Names without dots are tried as .local names.
        expect(resolve(net, a, "beta")):eq(ip("10.0.0.2"))
    end)

    it("resolves addresses, fixed names and its own name without asking", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        net.run()

        expect(resolve(net, a, "10.0.0.7")):eq(ip("10.0.0.7"))
        expect(resolve(net, a, "bank", { hosts = { bank = "10.0.0.9" } })):eq(ip("10.0.0.9"))
        expect(resolve(net, a, "alpha.local")):eq(ip("10.0.0.1"))
        expect(#net.queue):eq(0)
    end)

    it("gives up on names nobody has", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        net.run()

        expect({ resolve(net, a, "nobody.local") }):same { nil, "Name not found" }
        expect({ resolve(net, a, "bank.home") }):same { nil, "No DNS server" }
    end)

    it("asks DNS servers", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        serve(net.add(3, "10.0.0.3/24"), { bank = ip("10.0.0.5"), ["@"] = ip("10.0.0.3") })
        net.run()

        local options = { servers = { ip("10.0.0.3") }, domain = "home" }
        expect(resolve(net, a, "bank.home", options)):eq(ip("10.0.0.5"))
        -- Names without dots are tried in the search domain.
        expect(resolve(net, a, "bank", { servers = options.servers, domain = "home" })):eq(ip("10.0.0.5"))
        expect({ resolve(net, a, "safe.home", options) }):same { nil, "Name not found" }
    end)

    it("tries the next DNS server if one doesn't answer", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        net.add(4, "10.0.0.4/24") -- Has no DNS server.
        serve(net.add(3, "10.0.0.3/24"), { bank = ip("10.0.0.5") })
        net.run()

        expect(resolve(net, a, "bank.home", { servers = { ip("10.0.0.4"), ip("10.0.0.3") } })):eq(ip("10.0.0.5"))
    end)

    it("caches answers", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        computer(net, 2, "10.0.0.2/24", "beta")
        net.run()

        local cache = {}
        resolve(net, a, "beta.local", { cache = cache })
        expect(cache["beta.local"].address):eq(ip("10.0.0.2"))
    end)

    it("forgets answers which have expired, and keeps no more than so many", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        computer(net, 2, "10.0.0.2/24", "beta")
        net.run()

        local now = a.clock()
        local cache = { old = { address = 1, expires = now - 1 }, fresh = { address = 2, expires = now + 100 } }
        resolve(net, a, "beta.local", { cache = cache })
        expect({ cache.old, cache.fresh ~= nil, cache["beta.local"].address }):same { nil, true, ip("10.0.0.2") }

        for i = 1, 300 do cache["name" .. i] = { address = i, expires = now + 100 } end
        cache["beta.local"] = nil
        resolve(net, a, "beta.local", { cache = cache })
        local count = 0
        for _ in pairs(cache) do count = count + 1 end
        expect(count):eq(1)
    end)

    it("finds services", function()
        local net = network()
        local a = computer(net, 1, "10.0.0.1/24", "alpha")
        computer(net, 2, "10.0.0.2/24", "beta", { chat = 5000 })
        computer(net, 3, "10.0.0.3/24", "gamma", { chat = 6000, mail = 25 })
        net.run()

        local found = net.await(function(callback) dns.lookup(a, "chat", 1, callback) end)
        table.sort(found, function(x, y) return x.port < y.port end)
        expect(found):same {
            { host = "beta.local", address = ip("10.0.0.2"), port = 5000 },
            { host = "gamma.local", address = ip("10.0.0.3"), port = 6000 },
        }
    end)

    describe("server", function()
        local server = dns.server("Home", { bank = ip("10.0.0.5"), ["@"] = ip("10.0.0.3") }, function() return { laptop = ip("10.0.0.100") } end)

        it("answers for its zone", function()
            expect(server:handle({ id = 1, name = "bank.home", type = "A" })):same {
                id = 1, code = "ok", records = { { name = "bank.home", type = "A", value = ip("10.0.0.5"), ttl = 60 } },
            }
            expect(server:handle({ id = 2, name = "laptop.home", type = "A" }).code):eq("ok")
            expect(server:handle({ id = 4, name = "home", type = "A" }).records[1].value):eq(ip("10.0.0.3"))
            expect(server:handle({ id = 3, name = "safe.home", type = "A" })):same { id = 3, code = "not_found" }
        end)

        it("refuses other zones", function()
            expect(server:handle({ id = 1, name = "bank.away", type = "A" })):same { id = 1, code = "refused" }
            expect(server:handle({ id = 1, name = "notreallyhome", type = "A" })):same { id = 1, code = "refused" }
        end)

        it("ignores rubbish", function()
            expect(server:handle("hello")):eq(nil)
            expect(server:handle({ name = "bank.home" })):eq(nil)
        end)
    end)

    it("reads zone files", function()
        local records, errors = dns.parse_zone("# My zone\nbank 10.0.0.5\n@ 10.0.0.1 # the server\n\nnonsense\n")
        expect(records):same { bank = ip("10.0.0.5"), ["@"] = ip("10.0.0.1") }
        expect(errors):same { "Line 5: expected a name and an address" }
    end)
end)
