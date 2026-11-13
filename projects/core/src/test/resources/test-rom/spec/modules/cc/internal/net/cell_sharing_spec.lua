-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ A cell shared by two operators, ACME and BETA, each with its own core (as `celld` with both cores has it).

    ACME: cells 11 (at 0) and 12 (at 100), core 50, phones' addresses in 10.64.0.0/16
    BETA: cell 21 (at 200), and ACME's cell 12, which it shares; core 51, phones' addresses in 10.65.0.0/16

A cell is heard up to 120 away, and fit to use up to 100 away.
]]

describe("Shared cells", function()
    local helpers = require "support.net_helpers"
    local address = require "cc.net.address"
    local tcp = require "cc.internal.net.tcp"
    local operator = require "support.cell_network".operator

    local ip = helpers.ip

    local yield = require "support.yield"

    local function operators()
        local acme = operator({ 0, 100 })
        local beta = operator({ 200 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
        })
        local link = acme.share_cell(2, beta)
        return acme, beta, acme.net, link
    end

    local wait_until = helpers.wait_until

    local reaches_server = helpers.reaches_server

    -- The networks a phone hears a cell serve, and whether each one's part checked out.
    local function heard_at(phone, id)
        local result = {}
        for _, cell in ipairs(phone:info().heard) do
            if cell.id == id and cell.age <= 4 then result[#result + 1] = cell.network .. ":" .. tostring(cell.verified) end
        end
        table.sort(result)
        return result
    end

    local function event_kinds(phone)
        local result = {}
        for i, event in ipairs(phone:info().events) do result[i] = event.kind .. (event.roaming and " roaming" or "") end
        return result
    end

    it("serves each network's phones, through each network's core", function()
        math.randomseed(61)
        local acme, beta, net = operators()
        local a, a_stack = acme.add_phone(1, 110)
        local b, b_stack = beta.add_phone(2, 90)
        net.advance(5)

        expect({ a.state, a.cell, a.via }):same { "attached", 12, "ACME" }
        expect({ b.state, b.cell, b.via }):same { "attached", 12, "BETA" }
        expect({ a:roaming(), b:roaming() }):same { false, false }
        expect(address.format(a_stack.interfaces.cell.address)):eq("10.64.0.2")
        expect(address.format(b_stack.interfaces.cell.address)):eq("10.65.0.2")
        expect(reaches_server(net, a_stack)):eq(true)
        expect(reaches_server(net, b_stack)):eq(true)

        -- Each core knows its own phone, at the cell, and nothing of the other's.
        expect({ acme.core:info()[1].cell, #acme.core:info() }):same { 12, 1 }
        expect({ beta.core:info()[1].cell, #beta.core:info() }):same { 12, 1 }
        expect(acme.core:visitor_info()):same {}

        -- Phones hear the cell serve both networks, and check the parts they can.
        expect(heard_at(b, 12)):same { "ACME:nil", "BETA:true" }
        expect(heard_at(a, 12)):same { "ACME:true", "BETA:nil" }
        expect(b:info().networks):same { "ACME", "BETA" }
        expect(net.errors):same {}
    end)

    it("hands a phone over between a shared cell and its network's own, with a connection open", function()
        math.randomseed(62)
        local _, beta, net = operators()
        local phone, stack = beta.add_phone(2, 90)
        net.advance(5)
        expect(phone.cell):eq(12)
        local addr = stack.interfaces.cell.address

        local listener = assert(tcp.listen(beta.server, 80))
        local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
        net.advance(1)
        local server = assert(listener:accept())
        local sent, got = 0, {}
        local function step(position)
            beta.positions[2] = position
            if client:send(sent + 1) then sent = sent + 1 end
            net.advance(0.5)
            yield()
            while true do
                local ok, value = server:take()
                if not ok then break end
                got[#got + 1] = value
            end
        end

        for position = 100, 200, 2 do step(position) end
        for _ = 1, 10 do step(200) end
        expect({ phone.state, phone.cell, phone.via }):same { "attached", 21, "BETA" }
        for position = 200, 100, -2 do step(position) end
        for _ = 1, 10 do step(100) end
        expect({ phone.state, phone.cell, phone.via }):same { "attached", 12, "BETA" }
        expect(event_kinds(phone)):same { "attached", "handover", "handover" }

        expect(client.state):eq("established")
        expect(stack.interfaces.cell.address):eq(addr)
        expect(#got):eq(sent)
        expect(net.errors):same {}
    end)

    it("lets a phone roam on the other network at a shared cell, and go home through it", function()
        math.randomseed(63)
        local acme, beta, net = operators()
        acme.roam_on(beta)
        local phone, stack = acme.add_phone(1, 90, true, { partners = { BETA = beta.signing_public }, selection = "BETA" })
        net.advance(5)
        expect({ phone.state, phone.cell, phone.via }):same { "attached", 12, "BETA" }
        expect(phone:roaming()):eq(true)
        expect(beta.core:visitor_info()):same { { network = "ACME", cell = 12, address = "10.64.0.2" } }
        expect(reaches_server(net, stack)):eq(true)

        -- Left to choose, it goes home through the same cell, though its own network's part is no stronger there.
        phone:select(nil)
        wait_until(net, function() return phone.state == "attached" and phone.via == "ACME" end, 15, "Going home")
        expect({ phone.cell, phone:roaming() }):same { 12, false }
        expect(event_kinds(phone)):same { "attached roaming", "home", "attached" }
        expect(reaches_server(net, stack)):eq(true)
        wait_until(net, function() return #beta.core:visitor_info() == 0 end, 10, "BETA forgetting the phone")
        expect(net.errors):same {}
    end)

    it("stops naming a network whose core it loses, and serves the other", function()
        math.randomseed(64)
        local acme, beta, net, link = operators()
        local a = acme.add_phone(1, 110)
        local b = beta.add_phone(2, 90)
        net.advance(5)
        expect({ a.cell, b.cell }):same { 12, 12 }
        -- BETA's phone moves to where it hears BETA's own cell too, though the shared one is stronger.
        beta.positions[2] = 110
        net.advance(5)
        expect(b.cell):eq(12)

        -- The cell loses BETA's core: BETA's phone moves to BETA's own cell, ACME's stays.
        link:stop()
        net.advance(15)
        expect({ b.state, b.cell }):same { "attached", 21 }
        expect({ a.state, a.cell }):same { "attached", 12 }
        expect(heard_at(a, 12)):same { "ACME:true" }
        expect(event_kinds(a)):same { "attached" }
        expect(net.errors):same {}
    end)

    it("takes a phone to the network it names, and to its only one only if it names none", function()
        local cell_tower = require "cc.internal.net.cell.tower"
        -- The cell only needs a stack to start, here.
        local stack = { id = 7, log = function() end, clock = function() return 0 end }
        function stack:on_frame() return {} end
        function stack:udp_open() return {} end
        function stack:schedule() return {} end
        function stack:send_frame() end

        local tower = cell_tower.new {
            stack = stack, crypto = crypto, interface = "radio", sign = function() return "" end, epoch = function() return 0 end,
        }
        local function serve(name)
            return tower:add_network(name, { certificate = "c", core = 1, tunnel_key = ("k"):rep(32), control = function() end })
        end

        local acme = serve("ACME")
        expect(tower:link_for("ACME")):eq(acme)
        expect(tower:link_for(nil)):eq(acme)
        -- One it doesn't serve (any longer) isn't taken to ACME.
        expect(tower:link_for("BETA")):eq(nil)

        local beta = serve("BETA")
        expect(tower:link_for("BETA")):eq(beta)
        expect(tower:link_for(nil)):eq(nil)
    end)
end)
