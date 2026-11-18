-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.dns", function()
    local helpers = require "support.net_helpers"
    local dns = require "cc.internal.net.dns"
    local network = require "support.virtual_network"

    local ip = helpers.ip

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

    describe("relay", function()
        local client = { "the client" }

        -- A server for "home" and "shop.home", which forwards to these servers, with a clock and IDs of its own.
        local function setup(forward)
            local now, ids = 0, 100
            local relay = dns.relay {
                zones = {
                    dns.server("home", { bank = ip("10.0.0.5"), ["@"] = ip("10.0.0.3") }),
                    dns.server("shop.home", { till = ip("10.0.0.7") }),
                },
                forward = function() return forward or {} end,
                clock = function() return now end,
                random = function()
                    ids = ids + 1
                    return ids
                end,
            }
            return relay, function(seconds) now = now + seconds end
        end

        local function answer_for(id, code, records)
            return { { client = client, answer = { id = id, code = code, records = records } } }
        end

        local bank_away = { { name = "bank.away", type = "A", value = ip("10.9.0.5"), ttl = 60 } }

        it("answers names in its zones at once, from the most specific", function()
            local relay = setup { ip("10.0.0.9") }
            expect(relay:question({ id = 1, name = "bank.home", type = "A" }, client))
                :same(answer_for(1, "ok", { { name = "bank.home", type = "A", value = ip("10.0.0.5"), ttl = 60 } }))
            expect(relay:question({ id = 2, name = "till.shop.home", type = "A" }, client)[1].answer.records[1].value)
                :eq(ip("10.0.0.7"))
            -- shop.home has no "bank", whatever home has.
            expect(relay:question({ id = 3, name = "bank.shop.home", type = "A" }, client)):same(answer_for(3, "not_found"))
            expect(relay:busy()):eq(false)
        end)

        it("refuses names elsewhere when it has nowhere to forward them", function()
            local relay = setup()
            expect(relay:question({ id = 1, name = "bank.away", type = "A" }, client)):same(answer_for(1, "refused"))
        end)

        it("forwards names elsewhere, passes the answer back, and keeps it as long as it says", function()
            local relay, advance = setup { ip("10.0.0.9") }
            expect(relay:question({ id = 7, name = "Bank.Away", type = "A" }, client)):same {
                { server = ip("10.0.0.9"), question = { id = 101, name = "bank.away", type = "A", hops = 1 } },
            }
            expect(relay:busy()):eq(true)
            expect(relay:answer({ id = 101, code = "ok", records = bank_away }, ip("10.0.0.9")))
                :same(answer_for(7, "ok", bank_away))
            expect(relay:busy()):eq(false)

            -- Asked again, it answers itself, until the answer is a minute old.
            advance(59)
            expect(relay:question({ id = 8, name = "bank.away", type = "A" }, client)):same(answer_for(8, "ok", bank_away))
            advance(2)
            expect(relay:question({ id = 9, name = "bank.away", type = "A" }, client)[1].server):eq(ip("10.0.0.9"))
        end)

        it("passes on that a name doesn't exist, and remembers it briefly", function()
            local relay, advance = setup { ip("10.0.0.9") }
            relay:question({ id = 1, name = "nobody.away", type = "A" }, client)
            expect(relay:answer({ id = 101, code = "not_found" }, ip("10.0.0.9"))):same(answer_for(1, "not_found"))
            expect(relay:question({ id = 2, name = "nobody.away", type = "A" }, client)):same(answer_for(2, "not_found"))
            advance(11)
            expect(relay:question({ id = 3, name = "nobody.away", type = "A" }, client)[1].server):eq(ip("10.0.0.9"))
        end)

        it("asks the next server when one refuses or doesn't answer, and refuses when none will, without keeping that", function()
            local relay, advance = setup { ip("10.0.0.8"), ip("10.0.0.9") }
            relay:question({ id = 1, name = "bank.away", type = "A" }, client)
            expect(relay:answer({ id = 101, code = "refused" }, ip("10.0.0.8"))):same {
                { server = ip("10.0.0.9"), question = { id = 102, name = "bank.away", type = "A", hops = 1 } },
            }
            -- The second doesn't answer in time.
            advance(0.5)
            expect(relay:expire()):same {}
            advance(0.1)
            expect(relay:expire()):same(answer_for(1, "refused"))
            expect(relay:busy()):eq(false)
            -- A late answer is too late.
            expect(relay:answer({ id = 102, code = "ok", records = bank_away }, ip("10.0.0.9"))):same {}
            -- And the refusal isn't kept: the next question is forwarded again.
            expect(relay:question({ id = 2, name = "bank.away", type = "A" }, client)[1].server):eq(ip("10.0.0.8"))
        end)

        it("ignores answers from servers it didn't ask, and about nothing it asked", function()
            local relay = setup { ip("10.0.0.9") }
            relay:question({ id = 1, name = "bank.away", type = "A" }, client)
            expect(relay:answer({ id = 101, code = "ok", records = bank_away }, ip("10.0.0.66"))):same {}
            expect(relay:answer({ id = 555, code = "ok", records = bank_away }, ip("10.0.0.9"))):same {}
            expect(relay:answer("rubbish", ip("10.0.0.9"))):same {}
            expect(relay:answer({ id = 101, code = "ok", records = bank_away }, ip("10.0.0.9"))):same(answer_for(1, "ok", bank_away))
        end)

        it("forwards a question only so many times, with less time each time", function()
            local relay, advance = setup { ip("10.0.0.8"), ip("10.0.0.9") }
            -- Forwarded twice already: it may go once more, and waits only 0.4 seconds for it, whoever's left to ask.
            expect(relay:question({ id = 1, name = "bank.away", type = "A", hops = 2 }, client)[1].question.hops):eq(3)
            advance(0.4)
            expect(relay:expire()):same(answer_for(1, "refused"))

            -- Forwarded three times, or nonsense: no further.
            for _, hops in ipairs { 3, 7, -1, 0.5, "x" } do
                expect(relay:question({ id = 2, name = "bank.away", type = "A", hops = hops }, client))
                    :same(answer_for(2, "refused"))
            end
        end)

        -- A relay on a computer of a virtual network, as dnsd runs one.
        local function relay_on(stack, zones, forward)
            local relay = dns.relay { zones = zones, forward = function() return forward end, clock = stack.clock }
            local socket, upstream, ticking
            local send
            local function tick()
                send(relay:expire())
                if relay:busy() then stack:schedule(0.1, tick) else ticking = false end
            end
            function send(items)
                for _, item in ipairs(items) do
                    if item.client then
                        stack:udp_send(socket, item.client.address, item.client.port, item.answer)
                    else
                        stack:udp_send(upstream, item.server, dns.DNS_PORT, item.question)
                        if not ticking then
                            ticking = true
                            stack:schedule(0.1, tick)
                        end
                    end
                end
            end
            socket = stack:udp_open(dns.DNS_PORT, function(question, from, port)
                send(relay:question(question, { address = from, port = port }))
            end)
            upstream = stack:udp_open(nil, function(answer, from) send(relay:answer(answer, from)) end)
            return relay
        end

        it("lets a client find names in another zone through the one server it knows", function()
            local net = network()
            local a = computer(net, 1, "10.0.0.1/24", "alpha")
            relay_on(net.add(3, "10.0.0.3/24"), { dns.server("home", { bank = ip("10.0.0.5") }) }, { ip("10.0.0.4") })
            relay_on(net.add(4, "10.0.0.4/24"), { dns.server("shop", { till = ip("10.0.0.7") }) }, {})
            net.run()

            local options = { servers = { ip("10.0.0.3") } }
            expect(resolve(net, a, "bank.home", options)):eq(ip("10.0.0.5"))
            expect(resolve(net, a, "till.shop", options)):eq(ip("10.0.0.7"))
            expect({ resolve(net, a, "nothing.shop", options) }):same { nil, "Name not found" }
            expect({ resolve(net, a, "bank.away", options) }):same { nil, "Name not found" }
        end)

        it("finds names along a chain of servers", function()
            local net = network()
            local a = computer(net, 1, "10.0.0.1/24", "alpha")
            relay_on(net.add(3, "10.0.0.3/24"), { dns.server("one", {}) }, { ip("10.0.0.4") })
            relay_on(net.add(4, "10.0.0.4/24"), { dns.server("two", {}) }, { ip("10.0.0.5") })
            relay_on(net.add(5, "10.0.0.5/24"), { dns.server("three", { far = ip("10.0.0.9") }) }, {})
            net.run()

            expect(resolve(net, a, "far.three", { servers = { ip("10.0.0.3") } })):eq(ip("10.0.0.9"))
        end)

        it("doesn't pass a question round in circles", function()
            local net = network()
            local a = computer(net, 1, "10.0.0.1/24", "alpha")
            local x = net.add(3, "10.0.0.3/24")
            local y = net.add(4, "10.0.0.4/24")
            relay_on(x, { dns.server("home", {}) }, { ip("10.0.0.4") })
            relay_on(y, { dns.server("shop", {}) }, { ip("10.0.0.3") })
            net.run()

            local started, frames = net.time, net.total_frames()
            expect({ resolve(net, a, "bank.away", { servers = { ip("10.0.0.3") } }) }):same { nil, "Name not found" }
            -- Refused well before the client would give up on the server, after going round three times: the
            -- question, three forwards, and a refusal back along each.
            expect(net.time - started <= 1.5):eq(true)
            expect(net.total_frames() - frames <= 12):eq(true)
        end)
    end)

    it("reads zone files", function()
        local records, errors = dns.parse_zone("# My zone\nbank 10.0.0.5\n@ 10.0.0.1 # the server\n\nnonsense\n")
        expect(records):same { bank = ip("10.0.0.5"), ["@"] = ip("10.0.0.1") }
        expect(errors):same { "Line 5: expected a name and an address" }
    end)
end)
