-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Messages between two networks' phones: ACME (numbers +555) and BETA (numbers +666), whose cores exchange messages
(as `cellcore peer` has them do over a connection). Their cells are far apart, and they don't carry each other's phones.

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
        if peered ~= false then acme.peer_with(beta) end
        return acme, beta, acme.net
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

    it("passes messages between the networks' phones, both ways, by number prefix", function()
        math.randomseed(51)
        local acme, beta, net = operators()
        local a, a_inbox, a_sent = phone(acme, 1, 10)
        local b, b_inbox, b_sent = phone(beta, 2, 310)
        net.advance(5)
        expect({ a.state, b.state }):same { "attached", "attached" }
        -- Each phone knows how other networks' phones reach it.
        expect(a.subscriber):same { id = "ACME-1", number = "1", full = "+5551" }
        expect(b.subscriber.full):eq("+6662")

        local _, id = assert(a:send_message("+6662", "Hello from ACME"))
        net.advance(3)
        expect(a_sent[id]):same { true }
        expect(b_inbox):same { { "+5551", "Hello from ACME" } }

        -- The answer finds its way back.
        local _, reply = assert(b:send_message("+5551", "Hello from BETA"))
        net.advance(3)
        expect(b_sent[reply]):same { true }
        expect(a_inbox):same { { "+6662", "Hello from BETA" } }

        -- A network's own numbers may be written so too.
        local _, own = assert(a:send_message("+5551", "To myself"))
        net.advance(3)
        expect(a_sent[own]):same { true }
        expect(a_inbox[2]):same { "1", "To myself" }

        -- Numbers nobody has are refused, by whichever network would have them.
        local _, nobody = assert(a:send_message("+6669", "Anyone?"))
        local _, nowhere = assert(a:send_message("+7771", "Anyone?"))
        net.advance(3)
        expect(a_sent[nobody]):same { false, "Nobody has the number +6669" }
        expect(a_sent[nowhere]):same { false, "Nobody has the number +7771" }
        expect(net.errors):same {}
    end)

    it("keeps a message for a phone of the other network until it's reachable", function()
        math.randomseed(52)
        local acme, beta, net = operators()
        local a, _, a_sent = phone(acme, 1, 10)
        -- BETA's subscriber, whose phone is out of range.
        local _, b_inbox = phone(beta, 2, 1000)
        net.advance(5)
        local _, id = assert(a:send_message("+6662", "Are you there?"))
        net.advance(3)
        -- BETA's core has it, for a phone which isn't attached.
        expect(a_sent[id]):same { true }
        expect(#beta.core.messages):eq(1)

        beta.positions[2] = 310
        net.advance(15)
        expect(b_inbox):same { { "+5551", "Are you there?" } }
        expect(#beta.core.messages):eq(0)
        expect(net.errors):same {}
    end)

    it("says when the other network can't be reached, or doesn't answer", function()
        math.randomseed(53)
        local acme, _, net = operators(false)
        local a, _, a_sent = phone(acme, 1, 10)
        net.advance(5)

        -- Without an agreement, the other network's numbers are nobody's.
        local _, unknown = assert(a:send_message("+6662", "Hello?"))
        net.advance(3)
        expect(a_sent[unknown]):same { false, "Nobody has the number +6662" }

        -- With a core which never answers, the phone hears so after a while.
        local function silent() end
        acme.core:add_peer("BETA", "666", silent)
        local _, ignored = assert(a:send_message("+6662", "Hello?"))
        net.advance(10)
        expect(a_sent[ignored]):eq(nil)
        net.advance(25)
        expect(a_sent[ignored]):same { false, "BETA didn't answer" }

        -- Once the connection has gone, BETA can't be reached.
        acme.core:remove_peer("BETA", silent)
        local _, gone = assert(a:send_message("+6662", "Hello?"))
        net.advance(3)
        expect(a_sent[gone]):same { false, "Can't reach BETA now" }

        -- A network with no number prefix can't send to others, as their phones couldn't answer.
        acme.core:add_peer("BETA", "666", silent)
        acme.core:set_number_prefix(nil)
        local _, unnamed = assert(a:send_message("+6662", "Hello?"))
        net.advance(3)
        expect(a_sent[unnamed]):same { false, "This network has no number prefix, so can't reach others" }
        expect(net.errors):same {}
    end)

    it("only takes messages from a network for its own phones' numbers", function()
        math.randomseed(54)
        local acme, _, net = operators()
        local _, a_inbox = phone(acme, 1, 10)
        net.advance(5)

        local replies = {}
        local function reply(message) replies[#replies + 1] = message end
        -- BETA's core says messages come from one of ACME's own numbers, a number of no network, or another network.
        acme.core:peer_control("BETA", { op = "sms", id = 1, from = "+5552", to = "1", text = "Fake" }, reply)
        acme.core:peer_control("BETA", { op = "sms", id = 2, from = "2", to = "1", text = "Fake" }, reply)
        acme.core:peer_control("BETA", { op = "sms", id = 3, from = "+6662", to = "9", text = "Nobody" }, reply)
        acme.core:peer_control("GAMMA", { op = "sms", id = 4, from = "+6662", to = "1", text = "Not a peer" }, reply)
        acme.core:peer_control("BETA", { op = "sms", id = 5, from = "+6662", to = "1", text = "Real" }, reply)
        -- Nor are answers taken for messages which weren't passed to that network.
        acme.core:peer_control("BETA", { op = "sms_reply", id = 12345, ok = true }, reply)
        net.advance(3)
        expect(replies):same {
            { op = "sms_reply", id = 1, ok = false, error = "That message can't be sent" },
            { op = "sms_reply", id = 2, ok = false, error = "That message can't be sent" },
            { op = "sms_reply", id = 3, ok = false, error = "Nobody has the number +5559" },
            { op = "sms_reply", id = 5, ok = true },
        }
        expect(a_inbox):same { { "+6662", "Real" } }
        expect(net.errors):same {}
    end)

    it("survives messages from the other core with something unexpected in them", function()
        math.randomseed(55)
        local acme, _, net = operators()
        local a = phone(acme, 1, 10)
        net.advance(5)
        local _, id = assert(a:send_message("+6662", "Hello"))

        local BAD = { false, true, 0, -1, 1.5, 2 ^ 60, 0 / 0, math.huge, "", ("x"):rep(2000), {}, { 1, 2 } }
        local templates = {
            { op = "sms", id = 7, from = "+6662", to = "1", text = "Hi" },
            { op = "sms_reply", id = 1, ok = true, error = "Why" },
        }
        local count = 0
        for _, template in ipairs(templates) do
            for field in pairs(template) do
                for _, bad in ipairs(BAD) do
                    local message = {}
                    for k, v in pairs(template) do message[k] = v end
                    message[field] = bad
                    acme.core:peer_control("BETA", message, function() count = count + 1 end)
                end
            end
        end
        for _, bad in ipairs(BAD) do acme.core:peer_control("BETA", bad, function() end) end
        net.advance(3)
        expect(count > 0):eq(true)
        -- The phone's message still went through.
        expect(#acme.core.outgoing == 0 and next(acme.core.outgoing) == nil):eq(true)
        expect(id):type("number")
        expect(net.errors):same {}
    end)
end)
