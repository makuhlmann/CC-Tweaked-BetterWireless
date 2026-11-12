-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Messages between two networks' phones: ACME (numbers 555...) and BETA (numbers 666...), whose cores exchange
messages (as `cellcore peer` has them do over a connection). Their cells are far apart, and they don't carry each other's
phones.

    ACME: cell 11 (at 0), core 50
    BETA: cell 21 (at 300), core 51
]]

describe("Messages between networks", function()
    local operator = require "support.cell_network".operator

    local function operators(peered)
        local acme = operator({ 0 }, { numbers = "555" })
        local beta = operator({ 300 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16", numbers = "666",
        })
        local connection = peered ~= false and acme.peer_with(beta) or nil
        return acme, beta, acme.net, connection
    end

    -- A phone, and what it's told: the messages it gets, and what became of those it sent.
    local function phone(network, id, position)
        local inbox, sent = {}, {}
        local new = network.add_phone(id, position, true, {
            on_message = function(from, text) inbox[#inbox + 1] = { from, text } end,
            on_sent = function(message, ok, reason) sent[message] = { ok, reason } end,
        })
        return new, inbox, sent
    end

    local function count(list)
        local total = 0
        for _ in pairs(list) do total = total + 1 end
        return total
    end

    it("passes messages between the networks' phones, both ways, by number prefix", function()
        math.randomseed(51)
        local acme, beta, net = operators()
        local a, a_inbox, a_sent = phone(acme, 1, 10)
        local b, b_inbox, b_sent = phone(beta, 2, 310)
        net.advance(5)
        expect({ a.state, b.state }):same { "attached", "attached" }
        -- Each phone knows how other networks' phones reach it.
        expect(a.subscriber):same { id = "ACME-1", number = "1", full = "5551" }
        expect(b.subscriber.full):eq("6662")

        local _, id = assert(a:send_message("6662", "Hello from ACME"))
        net.advance(3)
        expect(a_sent[id]):same { true }
        expect(b_inbox):same { { "5551", "Hello from ACME" } }

        -- The answer finds its way back.
        local _, reply = assert(b:send_message("5551", "Hello from BETA"))
        net.advance(3)
        expect(b_sent[reply]):same { true }
        expect(a_inbox):same { { "6662", "Hello from BETA" } }

        -- A network's own numbers may be written so too.
        local _, own = assert(a:send_message("5551", "To myself"))
        net.advance(3)
        expect(a_sent[own]):same { true }
        expect(a_inbox[2]):same { "1", "To myself" }

        -- A number nobody has is refused by the network whose prefix it has. One with no prefix we know can't be
        -- reached at all.
        local _, nobody = assert(a:send_message("6669", "Anyone?"))
        local _, nowhere = assert(a:send_message("7771", "Anyone?"))
        net.advance(3)
        expect(a_sent[nobody]):same { false, "Nobody has the number 6669" }
        expect(a_sent[nowhere]):same { false, "Destination not reachable" }
        expect(net.errors):same {}
    end)

    it("keeps a message sent without service, and sends it once the phone has service", function()
        math.randomseed(57)
        local acme, beta, net = operators()
        -- Out of reach of every cell.
        local a, _, a_sent = phone(acme, 1, -500)
        local _, b_inbox = phone(beta, 2, 310)
        net.advance(5)
        expect(a.state):eq("searching")
        local _, id = assert(a:send_message("6662", "Sent from nowhere"))
        net.advance(60)
        expect(b_inbox):same {}
        expect(a_sent[id]):eq(nil)

        -- In reach, it attaches, and sends the message: once.
        acme.positions[1] = 10
        net.advance(10)
        expect(a.state):eq("attached")
        expect(a_sent[id]):same { true }
        expect(b_inbox):same { { "5551", "Sent from nowhere" } }
        net.advance(20)
        expect(#b_inbox):eq(1)
        expect(net.errors):same {}
    end)

    it("doesn't deliver a message twice when a phone which restarted sends it again", function()
        math.randomseed(58)
        local acme, beta, net = operators()
        local a, _, a_sent = phone(acme, 1, 10)
        local _, b_inbox = phone(beta, 2, 310)
        net.advance(5)
        local _, id = assert(a:send_message("6662", "Only once"))
        net.advance(3)
        expect(a_sent[id]):same { true }

        -- The phone restarts (as if it hadn't heard the network had the message) and sends it again, with its ID.
        a:stop()
        local again_sent = {}
        local again = acme.add_phone(3, 10, false, {
            sim = a.sim, on_sent = function(message, ok) again_sent[message] = ok end,
        })
        net.advance(5)
        expect(again.state):eq("attached")
        assert(again:send_message("6662", "Only once", id))
        expect({ again:send_message("6662", "Only once", id) }):same { nil, "That message is being sent already" }
        net.advance(5)
        expect(again_sent[id]):eq(true)
        expect(b_inbox):same { { "5551", "Only once" } }

        -- The messages it numbers itself come after it.
        local _, next_id = assert(again:send_message("6662", "And this"))
        expect(next_id > id):eq(true)
        net.advance(5)
        expect(b_inbox):same { { "5551", "Only once" }, { "5551", "And this" } }
        expect(net.errors):same {}
    end)

    it("keeps a message for a phone of the other network until it's reachable", function()
        math.randomseed(52)
        local acme, beta, net = operators()
        local a, _, a_sent = phone(acme, 1, 10)
        -- BETA's subscriber, whose phone is out of range.
        local _, b_inbox = phone(beta, 2, 1000)
        net.advance(5)
        local _, id = assert(a:send_message("6662", "Are you there?"))
        net.advance(3)
        -- BETA's core has it, for a phone which isn't attached.
        expect(a_sent[id]):same { true }
        expect(#beta.core.messages):eq(1)

        beta.positions[2] = 310
        net.advance(15)
        expect(b_inbox):same { { "5551", "Are you there?" } }
        expect(#beta.core.messages):eq(0)
        expect(net.errors):same {}
    end)

    it("keeps messages while the other network's core can't be reached, and sends them once it can", function()
        math.randomseed(53)
        local acme, beta, net, connection = operators()
        local a, a_inbox, a_sent = phone(acme, 1, 10)
        local _, b_inbox = phone(beta, 2, 310)
        net.advance(5)

        -- The cores lose each other. ACME's keeps the message, and says it has it.
        connection.cut()
        local _, id = assert(a:send_message("6662", "Are you there?"))
        local _, nobody = assert(a:send_message("6669", "Anyone?"))
        net.advance(3)
        expect(a_sent[id]):same { true }
        expect(a_sent[nobody]):same { true }
        expect(acme.core:held_info()):same { BETA = 2 }
        net.advance(60)
        expect(b_inbox):same {}

        -- Once they're connected again, the messages go. The one for a number nobody has is refused then, so ACME's
        -- network tells its sender.
        connection.mend()
        net.advance(5)
        expect(b_inbox):same { { "5551", "Are you there?" } }
        expect(acme.core:held_info()):same {}
        expect(a_inbox):same { { "ACME", "Not delivered to 6669: Nobody has the number 6669" } }
        expect(net.errors):same {}
    end)

    it("tells the phone it has a message when the other core doesn't answer, and sends it until it does", function()
        math.randomseed(54)
        local acme, _, net = operators(false)
        local a, a_inbox, a_sent = phone(acme, 1, 10)
        net.advance(5)

        -- BETA's core is connected, but doesn't answer.
        local passed = {}
        local function silent(message) passed[#passed + 1] = message end
        acme.core:add_peer("BETA", "666", silent)
        local _, id = assert(a:send_message("6662", "Hello?"))
        net.advance(10)
        expect(a_sent[id]):eq(nil)
        expect(#passed):eq(1)
        net.advance(25)
        expect(a_sent[id]):same { true }
        net.advance(30)
        -- It sent the message again, as the same message.
        expect(#passed >= 2):eq(true)
        expect(passed[2]):same(passed[1])
        expect(passed[1]):same { op = "sms", id = passed[1].id, from = "5551", to = "2", text = "Hello?" }

        -- The core answers at last: that was all.
        acme.core:peer_control("BETA", { op = "sms_reply", id = passed[1].id, ok = true }, silent)
        expect(acme.core:held_info()):same {}
        net.advance(5)
        expect(a_inbox):same {}

        -- A message kept too long, and one for a network the agreement with which has ended, are given up on. Their
        -- sender heard the network had them, so gets a message saying so.
        local _, old = assert(a:send_message("6663", "Old"))
        local _, ended = assert(a:send_message("6664", "Ended"))
        net.advance(35)
        expect({ a_sent[old], a_sent[ended] }):same { { true }, { true } }
        for _, held in pairs(acme.core.held) do
            if held.to == "3" then held.expires = 0 end
        end
        net.advance(15)
        acme.core:forget_peer("BETA")
        net.advance(5)
        expect(a_inbox):same {
            { "ACME", "Not delivered to 6663: BETA couldn't be reached" },
            { "ACME", "Not delivered to 6664: BETA is no longer reachable" },
        }
        -- And its numbers can't be reached now.
        local _, gone = assert(a:send_message("6662", "Hello?"))
        net.advance(3)
        expect(a_sent[gone]):same { false, "Destination not reachable" }
        expect(net.errors):same {}
    end)

    it("only takes messages from a network for its own phones' numbers, and each once", function()
        math.randomseed(55)
        local acme, _, net = operators()
        local _, a_inbox = phone(acme, 1, 10)
        net.advance(5)

        local replies = {}
        local function reply(message) replies[#replies + 1] = message end
        -- BETA's core says messages come from one of ACME's own numbers, a number of no network, or another network.
        acme.core:peer_control("BETA", { op = "sms", id = 1, from = "5552", to = "1", text = "Fake" }, reply)
        acme.core:peer_control("BETA", { op = "sms", id = 2, from = "2", to = "1", text = "Fake" }, reply)
        acme.core:peer_control("BETA", { op = "sms", id = 3, from = "6662", to = "9", text = "Nobody" }, reply)
        acme.core:peer_control("GAMMA", { op = "sms", id = 4, from = "6662", to = "1", text = "Not a peer" }, reply)
        acme.core:peer_control("BETA", { op = "sms", id = 5, from = "6662", to = "1", text = "Real" }, reply)
        -- A message which comes again is answered again, and kept once.
        acme.core:peer_control("BETA", { op = "sms", id = 5, from = "6662", to = "1", text = "Real" }, reply)
        -- Nor are answers taken for messages which weren't passed to that network.
        acme.core:peer_control("BETA", { op = "sms_reply", id = 12345, ok = true }, reply)
        net.advance(3)
        expect(replies):same {
            { op = "sms_reply", id = 1, ok = false, error = "That message can't be sent" },
            { op = "sms_reply", id = 2, ok = false, error = "That message can't be sent" },
            { op = "sms_reply", id = 3, ok = false, error = "Nobody has the number 5559" },
            { op = "sms_reply", id = 5, ok = true },
            { op = "sms_reply", id = 5, ok = true },
        }
        expect(a_inbox):same { { "6662", "Real" } }
        expect(net.errors):same {}
    end)

    it("survives messages from the other core with something unexpected in them", function()
        math.randomseed(56)
        local acme, _, net = operators()
        local a = phone(acme, 1, 10)
        net.advance(5)
        local _, id = assert(a:send_message("6662", "Hello"))

        local BAD = { false, true, 0, -1, 1.5, 2 ^ 60, 0 / 0, math.huge, "", ("x"):rep(2000), {}, { 1, 2 } }
        local templates = {
            { op = "sms", id = 7, from = "6662", to = "1", text = "Hi" },
            { op = "sms_reply", id = 1, ok = true, error = "Why" },
        }
        local answers = 0
        for _, template in ipairs(templates) do
            for field in pairs(template) do
                for _, bad in ipairs(BAD) do
                    local message = {}
                    for k, v in pairs(template) do message[k] = v end
                    message[field] = bad
                    acme.core:peer_control("BETA", message, function() answers = answers + 1 end)
                end
            end
        end
        for _, bad in ipairs(BAD) do acme.core:peer_control("BETA", bad, function() end) end
        net.advance(3)
        expect(answers > 0):eq(true)
        -- The phone's message still went through.
        expect(count(acme.core.held)):eq(0)
        expect(id):type("number")
        expect(net.errors):same {}
    end)
end)
