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

        it("asks a forwarded zone's own servers, and answers a more specific zone of its own", function()
            local ids = 100
            local relay = dns.relay {
                zones = {
                    dns.server("home", { bank = ip("10.0.0.5") }),
                    dns.forward("corp", { ip("10.1.0.53"), ip("10.1.0.54") }),
                    dns.forward("lab.home", { ip("10.2.0.53") }),
                    dns.server("x.corp", { y = ip("10.0.0.6") }),
                    dns.forward("nowhere", {}),
                },
                forward = function() return { ip("10.0.0.9") } end,
                clock = function() return 0 end,
                random = function()
                    ids = ids + 1
                    return ids
                end,
            }
            expect(relay:question({ id = 1, name = "mail.corp", type = "A" }, client)):same {
                { server = ip("10.1.0.53"), question = { id = 101, name = "mail.corp", type = "A", hops = 1 } },
            }
            expect(relay:answer({ id = 101, code = "refused" }, ip("10.1.0.53"))):same {
                { server = ip("10.1.0.54"), question = { id = 102, name = "mail.corp", type = "A", hops = 1 } },
            }
            expect(relay:question({ id = 2, name = "pc.lab.home", type = "A" }, client)[1].server):eq(ip("10.2.0.53"))
            expect(relay:question({ id = 3, name = "y.x.corp", type = "A" }, client)[1].answer.records[1].value)
                :eq(ip("10.0.0.6"))
            expect(relay:question({ id = 4, name = "bank.home", type = "A" }, client)[1].answer.records[1].value)
                :eq(ip("10.0.0.5"))
            -- Other names go upstream, and a forwarded zone with no servers (only this computer, say) is refused.
            expect(relay:question({ id = 5, name = "bank.away", type = "A" }, client)[1].server):eq(ip("10.0.0.9"))
            expect(relay:question({ id = 6, name = "a.nowhere", type = "A" }, client)):same(answer_for(6, "refused"))
        end)
    end)

    describe("aliases", function()
        local client = { "the client" }

        local function answer_for(id, code, records)
            return { { client = client, answer = { id = id, code = code, records = records } } }
        end

        local function a(name, addr) return { name = name, type = "A", value = ip(addr), ttl = 60 } end
        local function cname(name, target) return { name = name, type = "CNAME", value = target, ttl = 60 } end

        --[[ A server for "home" (with names registered there too) and "shop.home", which forwards "corp" to 10.0.0.8,
        and other names to 10.0.0.9. ]]
        local function setup(records)
            local ids, home = 100, {
                bank = ip("10.0.0.5"), www = "bank.home", cash = "till.shop.home", notebook = "laptop.home",
                mail = "mail.corp", news = "news.away", gone = "nobody.home", loop1 = "loop2.home", loop2 = "loop1.home",
            }
            for name, value in pairs(records or {}) do home[name] = value end
            local zones = {
                dns.server("home", home, function() return { laptop = ip("10.0.0.100") } end),
                dns.server("shop.home", { till = ip("10.0.0.7") }),
                dns.forward("corp", { ip("10.0.0.8") }),
            }
            return dns.relay {
                zones = zones,
                forward = function() return { ip("10.0.0.9") } end,
                clock = function() return 0 end,
                random = function()
                    ids = ids + 1
                    return ids
                end,
            }, zones
        end

        it("are answered by a zone's server with the name they're for", function()
            local server = dns.server("home", { www = "bank.home" })
            expect(server:handle({ id = 1, name = "WWW.home", type = "A" })):same {
                id = 1, code = "ok", records = { cname("www.home", "bank.home") },
            }
        end)

        it("are followed to names in its own zones, and names registered there", function()
            local relay = setup()
            expect(relay:question({ id = 1, name = "www.home", type = "A" }, client))
                :same(answer_for(1, "ok", { cname("www.home", "bank.home"), a("bank.home", "10.0.0.5") }))
            expect(relay:question({ id = 2, name = "cash.home", type = "A" }, client))
                :same(answer_for(2, "ok", { cname("cash.home", "till.shop.home"), a("till.shop.home", "10.0.0.7") }))
            expect(relay:question({ id = 3, name = "notebook.home", type = "A" }, client))
                :same(answer_for(3, "ok", { cname("notebook.home", "laptop.home"), a("laptop.home", "10.0.0.100") }))
            expect(relay:busy()):eq(false)
        end)

        it("are followed to other servers, and what they say is kept for the name itself", function()
            local relay = setup()
            expect(relay:question({ id = 7, name = "mail.home", type = "A" }, client)):same {
                { server = ip("10.0.0.8"), question = { id = 101, name = "mail.corp", type = "A", hops = 1 } },
            }
            expect(relay:answer({ id = 101, code = "ok", records = { a("mail.corp", "10.1.0.25") } }, ip("10.0.0.8")))
                :same(answer_for(7, "ok", { cname("mail.home", "mail.corp"), a("mail.corp", "10.1.0.25") }))

            -- Kept: asked again, through the alias or not, it answers itself.
            expect(relay:question({ id = 8, name = "mail.home", type = "A" }, client))
                :same(answer_for(8, "ok", { cname("mail.home", "mail.corp"), a("mail.corp", "10.1.0.25") }))
            expect(relay:question({ id = 9, name = "mail.corp", type = "A" }, client))
                :same(answer_for(9, "ok", { a("mail.corp", "10.1.0.25") }))

            -- Names in no zone here go upstream, and that one doesn't exist.
            expect(relay:question({ id = 10, name = "news.home", type = "A" }, client)[1].server):eq(ip("10.0.0.9"))
            expect(relay:answer({ id = 102, code = "not_found" }, ip("10.0.0.9"))):same(answer_for(10, "not_found"))
        end)

        it("aren't found when what they're for isn't, nor when they go round in a circle, or on too long", function()
            local chain = {}
            for i = 1, dns.MAX_ALIASES do chain["c" .. i] = i == dns.MAX_ALIASES and "bank.home" or ("c%d.home"):format(i + 1) end
            chain.c0 = "c1.home"
            local relay = setup(chain)
            expect(relay:question({ id = 1, name = "gone.home", type = "A" }, client)):same(answer_for(1, "not_found"))
            expect(relay:question({ id = 2, name = "loop1.home", type = "A" }, client)):same(answer_for(2, "not_found"))

            -- As many as there may be are followed, but no more.
            local answer = relay:question({ id = 3, name = "c1.home", type = "A" }, client)[1].answer
            expect({ answer.code, #answer.records, answer.records[#answer.records] })
                :same { "ok", dns.MAX_ALIASES + 1, a("bank.home", "10.0.0.5") }
            expect(relay:question({ id = 4, name = "c0.home", type = "A" }, client)):same(answer_for(4, "not_found"))
            expect(relay:busy()):eq(false)

            -- Which is said, for the names in the zones' files.
            local _, zones = setup(chain)
            expect(dns.bad_aliases(zones)):same {
                ("c0.home isn't found: it's an alias for an alias, more than %d times over"):format(dns.MAX_ALIASES),
                "loop1.home isn't found: its aliases go round in a circle",
                "loop2.home isn't found: its aliases go round in a circle",
            }
        end)

        it("can't be set by updates", function()
            local _, zones = setup()
            local names = dns.names({}, function() return 1.7e9 end)
            local answer = dns.handle_update(
                dns.update_message({ zone = "home", name = "www", address = ip("10.0.0.100"), lifetime = 60, owner = "computer 12" }, nil, 0),
                { zones = zones, names = names, allowed = true, epoch = 0, seen = {}, from = "10.0.0.1" })
            expect({ answer.code, answer.error }):same { "taken", "www.home is in the zone's file" }
        end)

        it("are read from zone files, for names in the same zone or written in full", function()
            local records, errors = dns.parse_zone("www bank\nmail mail.corp.\ntop @\nloop loop\nx 10.0.0.256\n", "Home")
            expect(records):same { www = "bank.home", mail = "mail.corp", top = "home" }
            expect(errors):same { "Line 4: loop is an alias for itself", "Line 5: 10.0.0.256 isn't an address" }
        end)

        it("are found by clients, which know nothing of them", function()
            local net = network()
            local a_stack = computer(net, 1, "10.0.0.1/24", "alpha")
            local relay = dns.relay {
                zones = { dns.server("home", { bank = ip("10.0.0.5"), www = "bank.home" }) },
                forward = function() return {} end, clock = function() return 0 end,
            }
            local server = net.add(3, "10.0.0.3/24")
            local socket
            socket = server:udp_open(dns.DNS_PORT, function(question, from, port)
                for _, item in ipairs(relay:question(question, { address = from, port = port })) do
                    server:udp_send(socket, item.client.address, item.client.port, item.answer)
                end
            end)
            expect(resolve(net, a_stack, "www.home", { servers = { ip("10.0.0.3") } })):eq(ip("10.0.0.5"))
            expect(resolve(net, a_stack, "www", { servers = { ip("10.0.0.3") }, domain = "home" })):eq(ip("10.0.0.5"))
        end)
    end)

    describe("updates", function()
        local address = require "cc.net.address"

        --[[ A server for "home" (with "bank" in its file) and "shop.home", which forwards "corp", and takes updates. Gives
        a function to send it an update (as one allowed to, unless told otherwise), one to make an update, the zones
        and names, and the time, which can be changed. ]]
        local function setup(key)
            local time = { now = 1.7e9 }
            local names = dns.names({}, function() return time.now end)
            local zones = {
                dns.server("home", { bank = ip("10.0.0.5") }, function() return names:lookup("home") end),
                dns.server("shop.home", {}),
                dns.forward("corp", { ip("10.1.0.53") }),
            }
            local seen = {}
            local function send(message, allowed)
                return dns.handle_update(message, {
                    zones = zones, names = names, allowed = allowed ~= false, key = key, epoch = time.now * 1000,
                    seen = seen, from = "10.0.0.1",
                })
            end
            local function make(fields, secret, at)
                fields.zone, fields.owner = fields.zone or "home", fields.owner or "computer 12"
                return dns.update_message(fields, secret, (at or time.now) * 1000)
            end
            local function lookup(name)
                local answer = zones[1]:handle({ id = 1, name = name, type = "A" })
                return answer.code == "ok" and answer.records[1].value or answer.code
            end
            return send, make, { zones = zones, names = names, time = time, lookup = lookup }
        end

        local function code(...) return (...).code end

        it("sets names, which are answered until they're deleted or expire", function()
            local send, make, env = setup()
            local answer, changed, log = send(make { name = "PC", address = ip("10.0.0.100"), lifetime = 60 })
            expect({ answer.code, changed, log }):same { "ok", true, "Set pc.home to 10.0.0.100 (computer 12, from 10.0.0.1)" }
            expect(env.lookup("pc.home")):eq(ip("10.0.0.100"))

            -- Set again, it lasts longer, and isn't logged unless it changed.
            env.time.now = env.time.now + 50
            expect({ select(2, send(make { name = "pc", address = ip("10.0.0.100"), lifetime = 60 })) }):same { true }
            env.time.now = env.time.now + 50
            expect(env.lookup("pc.home")):eq(ip("10.0.0.100"))
            local _, _, moved = send(make { name = "pc", address = ip("10.0.0.101"), lifetime = 60 })
            expect(moved):eq("Set pc.home to 10.0.0.101 (computer 12, from 10.0.0.1)")

            -- Only its owner may delete it.
            expect(code(send(make { name = "pc", owner = "computer 13" }))):eq("taken")
            expect({ code(send(make { name = "pc" })), env.lookup("pc.home") }):same { "ok", "not_found" }
            -- Deleting what isn't there changes nothing.
            expect({ select(2, send(make { name = "pc" })) }):same { false }

            -- It expires, and then anyone may have it.
            send(make { name = "laptop", address = ip("10.0.0.102"), lifetime = 30 })
            env.time.now = env.time.now + 31
            expect(env.lookup("laptop.home")):eq("not_found")
            expect(code(send(make { name = "laptop", address = ip("10.0.0.103"), lifetime = 30, owner = "computer 13" })))
                :eq("ok")
            expect(env.names.count):eq(1)
        end)

        it("refuses what it mustn't do, or doesn't make sense, changing nothing", function()
            local send, make, env = setup()
            send(make { name = "pc", address = ip("10.0.0.100"), lifetime = 60 })
            local function refused(message, allowed)
                local answer, changed, log = send(message, allowed)
                expect(changed):eq(false)
                expect(log):type("string")
                return answer.code, answer.error
            end

            expect({ refused(make { name = "x", address = ip("10.0.0.9"), lifetime = 60 }, false) })
                :same { "refused", "it may not update names here" }
            -- Not a zone of its own, nor a name it could answer.
            expect(refused(make { zone = "away", name = "x", address = ip("10.0.0.9"), lifetime = 60 })):eq("not_found")
            expect(refused(make { zone = "corp", name = "x", address = ip("10.0.0.9"), lifetime = 60 })):eq("not_found")
            expect({ refused(make { name = "shop", address = ip("10.0.0.9"), lifetime = 60 }) })
                :same { "taken", "shop.home is in the zone shop.home" }
            expect({ refused(make { name = "bank", address = ip("10.0.0.9"), lifetime = 60 }) })
                :same { "taken", "bank.home is in the zone's file" }
            expect({ refused(make { name = "pc", address = ip("10.0.0.9"), lifetime = 60, owner = "computer 13" }) })
                :same { "taken", "pc.home is computer 12's" }
            for _, bad in ipairs {
                { name = "a.b", address = ip("10.0.0.9"), lifetime = 60 },
                { name = "", address = ip("10.0.0.9"), lifetime = 60 },
                { name = ("x"):rep(64), address = ip("10.0.0.9"), lifetime = 60 },
                { name = "x", address = ip("10.0.0.9"), lifetime = 60, owner = "" },
                { name = "x", address = 0, lifetime = 60 },
                { name = "x", address = 0xFFFFFFFF, lifetime = 60 },
                { name = "x", address = ip("127.0.0.1"), lifetime = 60 },
                { name = "x", address = "10.0.0.9", lifetime = 60 },
                { name = "x", address = ip("10.0.0.9") },
                { name = "x", address = ip("10.0.0.9"), lifetime = 0 },
                { name = "x", address = ip("10.0.0.9"), lifetime = 0.5 },
                { name = "x", address = ip("10.0.0.9"), lifetime = 8 * 24 * 3600 },
            } do
                expect(refused(make(bad))):eq("invalid")
            end
            expect(env.lookup("pc.home")):eq(ip("10.0.0.100"))
            expect(env.names.count):eq(1)

            -- Not updates at all.
            for _, bad in ipairs { "x", {}, { op = "update" }, { op = "update", id = -1 }, { op = "other", id = 1 } } do
                expect(send(bad)):eq(nil)
            end
        end)

        it("keeps no more than so many names", function()
            local send, make, env = setup()
            for i = 1, dns.MAX_NAMES do
                expect(code(send(make { name = "n" .. i, address = ip("10.0.0.9"), lifetime = 60 }))):eq("ok")
            end
            local answer = send(make { name = "more", address = ip("10.0.0.9"), lifetime = 60 })
            expect({ answer.code, answer.error }):same { "refused", "there are too many names" }
            -- One already there may still be set again.
            expect(code(send(make { name = "n1", address = ip("10.0.0.8"), lifetime = 60 }))):eq("ok")
            expect(env.names.count):eq(dns.MAX_NAMES)
        end)

        it("takes only updates signed with its key, recently, and once", function()
            local send, make, env = setup("s3cret")
            local function why(message) return select(1, send(message)).error end
            expect(why(make { name = "pc", address = ip("10.0.0.100"), lifetime = 60 })):eq("it isn't signed")
            expect(why(make({ name = "pc", address = ip("10.0.0.100"), lifetime = 60 }, "wrong")))
                :eq("it's signed with another key")
            expect(why(make({ name = "pc", address = ip("10.0.0.100"), lifetime = 60 }, "s3cret", env.time.now - 61)))
                :eq("it was signed too long ago, or the clocks differ")
            expect(why(make({ name = "pc", address = ip("10.0.0.100"), lifetime = 60 }, "s3cret", env.time.now + 61)))
                :eq("it was signed too long ago, or the clocks differ")

            -- A change to what's signed spoils it.
            local message = make({ name = "pc", address = ip("10.0.0.100"), lifetime = 60 }, "s3cret")
            local copy = {}
            for k, v in pairs(message) do copy[k] = v end
            copy.address = ip("10.0.0.66")
            expect(why(copy)):eq("it's signed with another key")

            expect(code(send(message))):eq("ok")
            expect(why(message)):eq("it was sent before")
            expect(env.lookup("pc.home")):eq(ip("10.0.0.100"))

            -- A server without a key takes signed updates too.
            local plain_send = setup()
            expect(code(plain_send(make({ name = "pc", address = ip("10.0.0.100"), lifetime = 60 }, "s3cret")))):eq("ok")
        end)

        it("keeps names across restarts, and drops what doesn't make sense", function()
            local send, make, env = setup()
            send(make { name = "pc", address = ip("10.0.0.100"), lifetime = 60 })
            send(make { name = "old", address = ip("10.0.0.101"), lifetime = 10 })
            local saved = env.names:save()
            expect(saved["pc.home"]):same {
                zone = "home", name = "pc", address = "10.0.0.100", expires = env.time.now + 60, owner = "computer 12",
            }

            saved.rubbish, saved[1], saved.bad = "x", { name = "x" }, {
                zone = "home", name = "a.b", address = "10.0.0.5", expires = env.time.now + 60, owner = "computer 1",
            }
            saved.nan = { zone = "home", name = "nan", address = "10.0.0.5", expires = 0 / 0, owner = "computer 1" }
            saved.addr = { zone = "home", name = "addr", address = "nowhere", expires = env.time.now + 60, owner = "computer 1" }
            env.time.now = env.time.now + 20
            local again = dns.names(saved, function() return env.time.now end)
            expect(again:lookup("home")):same { pc = ip("10.0.0.100") }
            expect(again.count):eq(1)
            expect(dns.names("rubbish", function() return 0 end).count):eq(0)
        end)

        it("sends each name's latest change, one at a time, and says what went wrong", function()
            local sent, logs = {}, {}
            local updater = dns.updater {
                zone = "home", key = "s3cret", epoch = function() return 5000 end,
                log = function(text) logs[#logs + 1] = text end,
                send = function(make, done) sent[#sent + 1] = { message = make(), done = done } end,
            }
            updater:set("pc", ip("10.0.0.100"), 3600, "computer 12")
            -- While that's sent, the name changes twice: only the last is sent next.
            updater:set("pc", ip("10.0.0.101"), 3600, "computer 12")
            updater:delete("pc", "computer 12")
            updater:set("laptop", ip("10.0.0.102"), 1e9, "computer 13")
            expect(#sent):eq(2)
            expect({ sent[1].message.name, sent[1].message.address, sent[1].message.lifetime, sent[1].message.time })
                :same { "pc", ip("10.0.0.100"), 3600, 5000 }
            expect(sent[1].message.mac):type("string")
            expect({ sent[2].message.name, sent[2].message.lifetime }):same { "laptop", 7 * 24 * 3600 }

            sent[1].done({ id = sent[1].message.id, code = "ok" })
            expect(#sent):eq(3)
            expect({ sent[3].message.name, sent[3].message.address, sent[3].message.owner }):same { "pc", nil, "computer 12" }
            sent[2].done(nil, "Timed out")
            sent[3].done({ code = "taken", error = "pc.home is computer 9's" })
            expect(#sent):eq(3)
            expect(logs):same { "Couldn't set laptop.home: Timed out", "The DNS server wouldn't delete pc.home: pc.home is computer 9's" }

            -- Each try is made afresh.
            local made = {}
            dns.updater {
                zone = "home", epoch = function() return 0 end,
                send = function(make) made = { make(), make() } end,
            }:set("pc", ip("10.0.0.100"), 60, "computer 12")
            expect(made[1].id ~= made[2].id):eq(true)
        end)

        it("are sent over the network, and tried again when they go unanswered", function()
            local net = network()
            local a = computer(net, 1, "10.0.0.1/24", "alpha")
            local server = net.add(3, "10.0.0.3/24")
            local names = dns.names({}, function() return net.time end)
            local zone = dns.server("home", {}, function() return names:lookup("home") end)
            local received, socket = 0, nil
            socket = server:udp_open(dns.DNS_PORT, function(message, from, port)
                local answer
                if type(message) == "table" and message.op == "update" then
                    received = received + 1
                    answer = dns.handle_update(message, {
                        zones = { zone }, names = names, allowed = true, epoch = 0, seen = {}, from = address.format(from),
                    })
                    -- The first answer is lost.
                    if received == 1 then answer = nil end
                else
                    answer = zone:handle(message)
                end
                if answer then server:udp_send(socket, from, port, answer) end
            end)
            net.run()

            local function make() return dns.update_message({ zone = "home", name = "pc", address = ip("10.0.0.100"), lifetime = 60, owner = "computer 1" }, nil, 0) end
            local answer = net.await(function(done) dns.stack_sender(a, ip("10.0.0.3"))(make, done) end)
            expect({ answer.code, received }):same { "ok", 2 }
            expect(resolve(net, a, "pc.home", { servers = { ip("10.0.0.3") } })):eq(ip("10.0.0.100"))

            -- Nobody there: it gives up after a few tries.
            local gone, why = net.await(function(done) dns.stack_sender(a, ip("10.0.0.99"))(make, done) end, 20)
            expect({ gone, type(why) }):same { nil, "string" }
        end)
    end)

    it("reads zone files", function()
        local records, errors = dns.parse_zone("# My zone\nbank 10.0.0.5\n@ 10.0.0.1 # the server\n\nnonsense\n", "home")
        expect(records):same { bank = ip("10.0.0.5"), ["@"] = ip("10.0.0.1") }
        expect(errors):same { "Line 5: expected a name, then its address or the name it's an alias for" }
    end)
end)
