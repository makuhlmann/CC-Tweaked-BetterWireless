-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cells which only carry messages, as satellites do: for when there's nothing better, such as off the grid. A cell is
heard up to 120 away, and gives service up to 100. ]]

describe("Cells which only carry messages", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator

    local ip = helpers.ip
    local wait_until = helpers.wait_until

    local function beta(join, cells, options)
        options = options or {}
        options.join, options.name, options.core_id, options.core_host = join, "BETA", 51, 2
        options.cell_base, options.prefix = 20, "10.65.0.0/16"
        return operator(cells, options)
    end

    it("carries phones' messages, but not their packets", function()
        math.randomseed(1)
        local acme = operator({ 0 }, { services = { "sms" } })
        local net = acme.net
        local inbox = {}
        local one, one_stack = acme.add_phone(1, 10)
        acme.add_phone(2, 20, true, { on_message = function(from, text) inbox[#inbox + 1] = { from, text } end })
        net.advance(8)
        expect(one.state):eq("attached")
        expect(acme.towers[1].tower.service):eq("sms")
        expect(one:info().messages_only):eq(true)

        -- No route for packets: programs hear so at once.
        local ok, err = net.ping(one_stack, ip("10.0.0.60"))
        expect(ok):eq(nil)
        expect(type(err)):eq("string")

        -- Messages go through.
        assert(one:send_message("2", "Stuck on the ridge, send help"))
        net.advance(3)
        expect(inbox):same { { "1", "Stuck on the ridge, send help" } }

        -- And a phone which sends packets anyway gets nowhere: the cell carries none.
        one_stack:add_route { network = 0, prefix = 0, interface = "cell", metric = 5, source = "test" }
        expect(net.ping(one_stack, ip("10.0.0.60"))):eq(nil)
        expect(net.errors):same {}
    end)

    it("prefers its network's cells which carry everything, and goes back to one as soon as it can", function()
        math.randomseed(2)
        -- Cell 11 at 0 carries everything; cell 12 at 30, nearer the phone, only messages.
        local acme = operator({ 0, 30 }, { services = { nil, "sms" } })
        local net = acme.net
        local phone, stack = acme.add_phone(1, 25)
        net.advance(8)
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }

        -- Further away, 11 is weaker than 12, but it stays: never over to a cell which only carries messages.
        acme.positions[1] = 95
        net.advance(10)
        expect(phone.cell):eq(11)

        -- Once 11 is out of reach, 12 will do, for messages.
        acme.positions[1] = 125
        wait_until(net, function() return phone.state == "attached" and phone.cell == 12 end, 30, "Using the cell for messages")
        net.advance(2)
        expect(phone:info().messages_only):eq(true)
        expect(select(1, net.ping(stack, ip("10.0.0.60")))):eq(nil)

        -- Back in reach of 11, however weakly, it's handed over there, and has a route again.
        acme.positions[1] = 90
        wait_until(net, function() return phone.cell == 11 end, 20, "Going back to the cell which carries everything")
        net.advance(2)
        expect(phone:info().messages_only):eq(nil)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)

    it("uses another network's only when nothing else will do, and not for longer than it must", function()
        math.randomseed(3)
        -- ACME's cell at 0 carries everything; BETA's satellite at 100 only messages. ACME's phones may roam on BETA.
        local acme = operator { 0 }
        local other = beta(acme, { 100 }, { services = { "sms" } })
        acme.roam_on(other)
        local net = acme.net
        local phone, stack = acme.add_phone(1, 40)
        net.advance(8)
        expect({ phone.state, phone.cell }):same { "attached", 11 }

        -- Out of ACME's reach, BETA's satellite will do.
        acme.positions[1] = 180
        wait_until(net, function() return phone.state == "attached" and phone.cell == 21 end, 30, "Roaming on the satellite")
        expect(phone:roaming()):eq(true)
        expect(phone:info().messages_only):eq(true)

        -- Back in ACME's reach, however weakly, it goes back.
        acme.positions[1] = 95
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 30, "Going home")
        local kinds = {}
        for _, event in ipairs(phone.events) do kinds[event.kind] = true end
        expect(kinds.home):eq(true)
        net.advance(2)
        expect(net.ping(stack, ip("10.0.0.60"))):matches { done = true }

        -- Unless it's told to use BETA.
        phone:select("BETA")
        wait_until(net, function() return phone.state == "attached" and phone.cell == 21 end, 30, "Using BETA, as told")
        net.advance(15)
        expect(phone.cell):eq(21)
        expect(net.errors):same {}
    end)

    it("uses a partner's cell which carries everything before its own network's which only carries messages", function()
        math.randomseed(4)
        local acme = operator({ 0 }, { services = { "sms" } })
        acme.roam_on(beta(acme, { 20 }))
        local phone = acme.add_phone(1, 10)
        wait_until(acme.net, function() return phone.state == "attached" end, 15, "Attaching")
        acme.net.advance(8)
        expect({ phone.cell, phone:roaming(), phone:info().messages_only }):same { 21, true, nil }
        expect(acme.net.errors):same {}
    end)
end)
