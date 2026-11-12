-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Roaming: two operators, ACME and BETA, whose cells cover different places. ACME's phones may use BETA's cells.

    ACME: cells 11 (at 0) and 12 (at 100), core 50, phones' addresses in 10.64.0.0/16
    BETA: cells 21 (at 300) and 22 (at 400), core 51, phones' addresses in 10.65.0.0/16

A cell is heard up to 100 away, so ACME covers up to 200, and BETA from 200 on.
]]

describe("Roaming", function()
    local codec = require "cc.net.codec"
    local address = require "cc.net.address"
    local tcp = require "cc.internal.net.tcp"
    local certificate = require "cc.internal.net.certificate"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local function ip(text) return (address.parse(text)) end
    local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
    local function copy(value) return codec.decode(codec.encode(value)) end

    local function yield()
        os.queueEvent("roaming_yield")
        os.pullEvent("roaming_yield")
    end

    local function operators(acme_cells, beta_cells, agreement)
        local acme = operator(acme_cells or { 0, 100 })
        local beta = operator(beta_cells or { 300, 400 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
        })
        if agreement ~= false then acme.roam_on(beta) end
        return acme, beta, acme.net
    end

    local function wait_until(net, test, limit, what)
        local deadline = net.time + (limit or 30)
        while net.time < deadline do
            if test() then return end
            net.advance(0.1)
            yield()
        end
        error(("%s didn't happen within %d seconds"):format(what or "Something", limit or 30), 2)
    end

    local function reaches_server(net, stack)
        local result = net.ping(stack, ip("10.0.0.60"), nil, 1)
        return result ~= nil and result.error == nil
    end

    local function event_kinds(phone)
        local result = {}
        for i, event in ipairs(phone:info().events) do result[i] = event.kind .. (event.roaming and " roaming" or "") end
        return result
    end

    it("lets a phone attach through a partner's cell, with its own network's address", function()
        math.randomseed(1)
        local acme, beta, net = operators()
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)

        expect(phone.state):eq("attached")
        expect(phone.cell):eq(21)
        expect(phone:roaming()):eq(true)
        expect(phone.subscriber):same { id = "ACME-1", number = "1" }
        expect(address.format(stack.interfaces.cell.address)):eq("10.64.0.2")
        local info = phone:info()
        expect({ info.roaming, info.network, info.partners }):same { true, "ACME", { BETA = true } }
        expect(event_kinds(phone)):same { "attached roaming" }

        -- Its packets go through its own network's gateway, wherever it is.
        local result = net.ping(stack, ip("10.0.0.60"))
        expect(result and result.error):eq(nil)
        expect(result.ttl):eq(31)

        -- Each core knows what it needs to: the phone's own, who it is and which network carries it; the other, only
        -- that a phone of ACME is at one of its cells.
        local session = acme.core:info()[1]
        expect({ session.address, session.cell, session.attached, session.roaming }):same { "10.64.0.2", 21, true, "BETA" }
        expect(beta.core:visitor_info()):same { { network = "ACME", cell = 21, address = "10.64.0.2" } }
        expect(#beta.core:info()):eq(0)
        expect(net.errors):same {}
    end)

    it("carries a phone's packets when its own core answers from another address than the one it's reached at", function()
        -- As when the other core reaches ours at our gateway's address: our core sends down the tunnel from its
        -- backhaul address, which is the one it has towards the other.
        math.randomseed(1)
        local acme, beta, net = operators(nil, nil, false)
        beta.core_stack:add_route { network = ip("10.64.0.0"), prefix = 16, gateway = ip(acme.core_address), source = "static" }
        acme.roam_on(beta, { dial = ip("10.64.0.1") })
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 21 }

        local function answer(target)
            local result = net.ping(stack, ip(target))
            return result and (result.error or "answered") or "no answer"
        end
        expect(answer("10.0.0.60")):eq("answered")
        expect(answer("10.64.0.1")):eq("answered")
        expect(net.errors):same {}
    end)

    it("carries a phone's packets when its own core reaches ours at another address than the one ours sends from", function()
        -- As when the phone's core connected to ours, at our gateway's address: ours sends up the tunnel from its
        -- backhaul address, which is the one it has towards the other.
        math.randomseed(1)
        local acme, beta, net = operators(nil, nil, false)
        acme.core_stack:add_route { network = ip("10.65.0.0"), prefix = 16, gateway = ip(beta.core_address), source = "static" }
        acme.roam_on(beta, { tower_address = ip("10.65.0.1") })
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 21 }

        local function answer(target)
            local result = net.ping(stack, ip(target))
            return result and (result.error or "answered") or "no answer"
        end
        expect(answer("10.0.0.60")):eq("answered")
        expect(answer("10.64.0.1")):eq("answered")
        expect(net.errors):same {}
    end)

    it("is learnt from the phone's own network, and keeps a connection open across the border and back", function()
        math.randomseed(2)
        local acme, beta, net = operators()
        local partners
        local phone, stack = acme.add_phone(1, 10, true, { on_partners = function(list) partners = list end })
        net.advance(5)
        expect(phone.cell):eq(11)
        expect(partners):same { BETA = beta.signing_public }
        local addr = stack.interfaces.cell.address

        local listener = assert(tcp.listen(acme.server, 80))
        local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
        net.advance(1)
        local server = assert(listener:accept())
        local sent, got, cells = 0, {}, { phone.cell }
        local function step(position)
            acme.positions[1] = position
            if client:send(sent + 1) then sent = sent + 1 end
            net.advance(0.5)
            yield()
            while true do
                local ok, value = server:take()
                if not ok then break end
                got[#got + 1] = value
            end
            if phone.state == "attached" and phone.cell ~= cells[#cells] then cells[#cells + 1] = phone.cell end
        end

        -- Out of ACME's coverage, into BETA's, and on to its far cell.
        for position = 10, 400, 2 do step(position) end
        expect(cells):same { 11, 12, 21, 22 }
        expect(phone:roaming()):eq(true)
        -- And back home.
        for position = 400, 10, -2 do step(position) end
        for _ = 1, 40 do step(10) end
        expect(cells):same { 11, 12, 21, 22, 21, 12, 11 }
        expect(phone:roaming()):eq(false)

        expect(client.error):eq(nil)
        expect(client.state):eq("established")
        expect(stack.interfaces.cell.address):eq(addr)
        expect(#got):eq(sent)
        for i = 1, sent do expect(got[i]):eq(i) end
        -- BETA has forgotten the phone.
        expect(beta.core:visitor_info()):same {}
        expect(next(beta.towers[1].tower.phones)):eq(nil)
        expect(net.errors):same {}
    end)

    it("prefers the phone's own network, and goes back to it once it's stronger", function()
        math.randomseed(3)
        -- Both networks cover the same place, BETA better.
        local acme, beta, net = operators({ 0 }, { 30 })
        local phone = acme.add_phone(1, 25, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect(phone.cell):eq(11)
        net.advance(30)
        expect(phone.cell):eq(11)
        expect(event_kinds(phone)):same { "attached" }

        -- Its own network's cell fails: it roams. When the cell is back, the phone stays, as BETA's cell is stronger.
        net.remove(acme.towers[1].stack)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 21 end, 30, "Roaming")
        table.insert(net.stacks, acme.towers[1].stack)
        net.advance(30)
        expect(phone.cell):eq(21)

        -- Where ACME's cell is only a little stronger, it still stays.
        acme.positions[1] = 16
        net.advance(30)
        expect(phone.cell):eq(21)

        -- Once ACME's cell is clearly stronger, it goes home after a few seconds.
        acme.positions[1] = 10
        net.advance(3)
        expect(phone.cell):eq(21)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 30, "Going home")
        expect(event_kinds(phone)):same { "attached", "lost", "attached roaming", "home", "attached" }
    end)

    it("doesn't settle for a partner's cell before it has heard its own network's, after starting", function()
        math.randomseed(46)
        -- The phone starts where it only hears BETA's cell, and is in ACME's a moment later, where both networks
        -- cover it, BETA the better.
        local acme, beta, net = operators({ 0 }, { 30 })
        local phone = acme.add_phone(1, 125, true, { partners = { BETA = beta.signing_public } })
        net.advance(1.5)
        expect(phone.state):eq("searching")
        acme.positions[1] = 25
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        expect(event_kinds(phone)):same { "attached" }
    end)

    it("tries a network it hasn't heard is a partner, and learns that it is", function()
        math.randomseed(31)
        -- The agreement was made after the phone last attached, so it doesn't know BETA carries it.
        local acme, beta, net = operators()
        local partners
        local phone, stack = acme.add_phone(1, 310, true, { on_partners = function(list) partners = list end })
        net.advance(10)

        expect(phone.state):eq("attached")
        expect(phone.cell):eq(21)
        expect(phone:roaming()):eq(true)
        expect(partners):same { BETA = beta.signing_public }
        expect(event_kinds(phone)):same { "attached roaming" }
        expect(reaches_server(net, stack)):eq(true)

        -- Now it knows BETA's key, it checks its cells, and moves between them.
        net.advance(2)
        local heard = phone:info().heard[1]
        expect({ heard.id, heard.verified }):same { 21, true }
        expect(phone.cells[21].networks.BETA.unverified):eq(nil)
        for position = 310, 400, 2 do
            acme.positions[1] = position
            net.advance(0.5)
            yield()
        end
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 22 }
        expect(net.errors):same {}
    end)

    it("only tries other networks once it has searched for its own for a while", function()
        math.randomseed(33)
        -- Both networks cover the same place, BETA better, but the phone hasn't heard of BETA as a partner. At first
        -- it only hears BETA, as a phone which has just been activated has yet to check its own network's cells.
        local acme, beta, net = operators({ 0 }, { 30 })
        local phone = acme.add_phone(1, 125)
        net.advance(1.5)
        expect(phone.state):eq("searching")
        expect(phone:info().heard[1].network):eq("BETA")

        -- It hears its own network before it has searched for long: it uses that, and doesn't try BETA.
        acme.positions[1] = 25
        net.advance(10)
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        expect(event_kinds(phone)):same { "attached" }
        expect(beta.core:visitor_info()):same {}
    end)

    it("leaves a network which turned it away alone for a while, then tries again", function()
        math.randomseed(32)
        local acme, beta, net = operators(nil, nil, false)
        local phone, stack = acme.add_phone(1, 310)
        net.advance(10)
        expect(phone.rejected):eq("BETA doesn't carry phones of that network")
        expect(phone.state):eq("searching")
        expect(phone.forbidden:get("BETA") ~= nil):eq(true)

        -- It doesn't ask again for a minute, though it hears BETA all the while.
        net.advance(40)
        expect(event_kinds(phone)):same { "rejected" }

        -- Meanwhile the networks agree, and the next time the phone tries, it's carried.
        acme.roam_on(beta)
        wait_until(net, function() return phone.state == "attached" end, 30, "Trying BETA again")
        expect(phone.cell):eq(21)
        expect(phone.partners.BETA):eq(beta.signing_public)
        expect(phone.forbidden:get("BETA")):eq(nil)
        expect(reaches_server(net, stack)):eq(true)
        expect(event_kinds(phone)):same { "rejected", "attached roaming" }
    end)

    it("uses the one network the phone is told to", function()
        math.randomseed(4)
        local acme, beta, net = operators({ 0 }, { 30 })
        local phone, stack = acme.add_phone(1, 25, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect(phone.cell):eq(11)

        phone:select("BETA")
        wait_until(net, function() return phone.state == "attached" and phone.cell == 21 end, 10, "Moving to BETA")
        expect(phone:roaming()):eq(true)
        expect(reaches_server(net, stack)):eq(true)
        -- It stays, though it hears its own network.
        net.advance(30)
        expect(phone.cell):eq(21)

        -- Where the chosen network has no cells, there's no service, even with another in range.
        net.remove(beta.towers[1].stack)
        net.advance(20)
        expect(phone.state):eq("searching")
        expect(reaches_server(net, stack)):eq(false)

        -- Left to choose again, it goes home.
        phone:select(nil)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 10, "Going home")
        expect(reaches_server(net, stack)):eq(true)

        phone:select("ACME")
        net.advance(5)
        expect(phone.cell):eq(11)
    end)

    it("tries a network it's told to use, though it knows of no agreement", function()
        math.randomseed(41)
        -- Both networks cover the phone. It hasn't heard BETA carries it, but it's told to use BETA, so it tries.
        local acme, beta, net = operators({ 0 }, { 30 })
        local partners
        local phone, stack = acme.add_phone(1, 25, true, { selection = "BETA", on_partners = function(list) partners = list end })
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 21 }
        expect(phone:roaming()):eq(true)
        expect(partners):same { BETA = beta.signing_public }
        expect(event_kinds(phone)):same { "attached roaming" }
        expect(reaches_server(net, stack)):eq(true)

        -- A network which turns it away, it keeps trying, as it was told to.
        local other = beta.add_phone(2, 5, true, { selection = "ACME" })
        net.advance(30)
        local rejections = 0
        for _, event in ipairs(other:info().events) do
            expect(event.kind):eq("rejected")
            expect(event.reason):eq("ACME doesn't carry phones of that network")
            rejections = rejections + 1
        end
        expect(rejections >= 3):eq(true)
        expect(acme.core:visitor_info()):same {}
        expect(net.errors):same {}
    end)

    it("roams where its own network's cell doesn't hear it, and leaves that cell alone for longer each time", function()
        math.randomseed(42)
        -- Both networks cover the phone, ACME the better. But ACME's cell doesn't hear the phone, as at the edge of a
        -- cell, where the phone hears the cell and the cell doesn't hear the phone's weaker radio.
        local acme, beta, net = operators({ 20 }, { 40 })
        local reach, deaf = net.reach, true
        net.reach = function(link, sender, receiver)
            if deaf and sender and sender.id == 1 and receiver.id == 11 then return false end
            return reach(link, sender, receiver)
        end
        local phone, stack = acme.add_phone(1, 25, true, { partners = { BETA = beta.signing_public } })
        wait_until(net, function() return phone.state == "attached" end, 20, "Roaming")
        expect(phone.cell):eq(21)
        expect(reaches_server(net, stack)):eq(true)

        -- Its own network's cell is stronger, but the phone doesn't go back to it for a while.
        net.advance(25)
        expect(phone.cell):eq(21)
        expect(event_kinds(phone)):same { "attached roaming" }

        -- Then it does, finds the cell still doesn't hear it, and leaves it alone for longer.
        net.advance(60)
        expect(phone.cell):eq(21)
        expect(event_kinds(phone)):same { "attached roaming", "home", "attached roaming" }

        -- Once the cell hears it, it goes home (when it next tries).
        deaf = false
        wait_until(net, function() return phone.state == "attached" and phone.cell == 11 end, 60, "Going home")
        expect(event_kinds(phone)):same { "attached roaming", "home", "attached roaming", "home", "attached" }
        expect(reaches_server(net, stack)):eq(true)
        expect(net.errors):same {}
    end)

    it("treats a partner its network says is as good as home as home", function()
        math.randomseed(43)
        -- Both networks cover the same place, BETA better. ACME's phones treat BETA as home, as for national roaming.
        local acme, beta, net = operators({ 0 }, { 30 }, false)
        acme.roam_on(beta, { home = true })
        local partners, equivalent
        local phone, stack = acme.add_phone(1, 10, true, {
            on_partners = function(list, home) partners, equivalent = list, home end,
        })
        net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 11 }
        expect(partners):same { BETA = beta.signing_public }
        expect(equivalent):same { BETA = true }

        -- Its own network's cell fails: it goes to BETA's, and isn't roaming there.
        net.remove(acme.towers[1].stack)
        wait_until(net, function() return phone.state == "attached" and phone.cell == 21 end, 30, "Moving to BETA")
        expect(phone:roaming()):eq(false)
        local info = phone:info()
        expect({ info.roaming, info.equivalent, info.partners }):same { false, { BETA = true }, { BETA = true } }
        expect(reaches_server(net, stack)):eq(true)

        -- With its own network's cell back, and stronger, it stays: as on its own network, it stays until it loses
        -- BETA's.
        table.insert(net.stacks, acme.towers[1].stack)
        acme.positions[1] = 5
        net.advance(30)
        expect(phone.cell):eq(21)
        expect(event_kinds(phone)):same { "attached", "lost", "attached" }

        -- A subscriber who mayn't roam may still use BETA.
        net.remove(acme.towers[1].stack)
        acme.subscribers[hex(phone.sim.public)].roaming = false
        acme.core:detach(hex(phone.sim.public))
        wait_until(net, function()
            local session = acme.core:info()[1]
            return session ~= nil and session.attached
        end, 30, "Attaching again")
        expect({ phone.state, phone.cell }):same { "attached", 21 }
        expect(reaches_server(net, stack)):eq(true)
        expect(net.errors):same {}
    end)

    it("lets a network with no cells use partners' as home, and activate phones through them", function()
        math.randomseed(44)
        -- MVNO has a core, but no cells: ACME carries its phones, which treat ACME as home. BETA doesn't carry them.
        local acme, _, net = operators({ 0 }, { 30 }, false)
        local mvno = operator({}, { join = acme, name = "MVNO", core_id = 52, core_host = 3, cell_base = 30, prefix = "10.66.0.0/16" })
        mvno.roam_on(acme, { home = true })
        local activated
        local phone, stack = mvno.add_phone(1, 25, false, { activated = false, on_activated = function(info) activated = info end })
        local code = mvno.core:add_code("MVNO-1", "1")
        net.advance(3)

        -- It tries BETA's cell first, the strongest, which turns it away; then ACME's, which passes it on.
        assert(phone:activate("MVNO", code))
        wait_until(net, function() return phone.state == "attached" end, 30, "Activating and attaching")
        expect(activated.network):eq("MVNO")
        expect(activated.partners):same { { network = "ACME", signing = acme.signing_public, home = true } }
        expect(phone.cell):eq(11)
        expect(phone:roaming()):eq(false)
        expect(address.format(stack.interfaces.cell.address)):eq("10.66.0.2")
        expect(reaches_server(net, stack)):eq(true)
        expect(event_kinds(phone)):same { "activated", "attached" }
        expect(acme.core:visitor_info()):same { { network = "MVNO", cell = 11, address = "10.66.0.2" } }

        -- A network nobody here carries can't be reached.
        local lost = mvno.add_phone(2, 25, false, { activated = false })
        net.advance(2)
        assert(lost:activate("NOWHERE", code))
        wait_until(net, function() return lost.state == "inactive" end, 30, "Giving up")
        expect(lost.activation_error):eq("ACME doesn't carry phones of that network")
        expect(net.errors):same {}
    end)

    it("tries other networks next, when its own network's cell doesn't answer", function()
        math.randomseed(45)
        -- ACME's cell doesn't hear the phone, and the phone hasn't heard BETA carries it.
        local acme, beta, net = operators({ 20 }, { 40 })
        local reach = net.reach
        net.reach = function(link, sender, receiver)
            if sender and sender.id == 1 and receiver.id == 11 then return false end
            return reach(link, sender, receiver)
        end
        local phone = acme.add_phone(1, 25)
        -- It has searched for long enough once its attach through ACME's cell gets no answer, so tries BETA next.
        net.advance(11)
        expect({ phone.state, phone.cell }):same { "attached", 21 }
        expect(phone.partners.BETA):eq(beta.signing_public)
        expect(net.errors):same {}
    end)

    it("needs both networks to agree", function()
        math.randomseed(5)
        local acme, beta, net = operators(nil, nil, false)
        -- A phone which hasn't been told about BETA tries its cells, in case, and is turned away by BETA's core.
        local unaware = acme.add_phone(1, 310)
        -- So is one which has been told (of an agreement since ended, say).
        local stale = acme.add_phone(2, 320, true, { partners = { BETA = beta.signing_public } })
        net.advance(10)
        expect(unaware.rejected):eq("BETA doesn't carry phones of that network")
        expect(unaware:info().heard[1].verified):eq(nil)
        expect(stale.state):eq("rejected")
        expect(stale.rejected):eq("BETA doesn't carry phones of that network")

        -- BETA's own phones are no concern of ACME's, and can't use its cells.
        local other = beta.add_phone(3, 50)
        net.advance(10)
        expect(other.state):eq("searching")
        expect(other.rejected):eq("ACME doesn't carry phones of that network")
        expect(beta.core:info()):same {}
        expect(acme.core:visitor_info()):same {}
        expect(net.errors):same {}
    end)

    it("is refused for subscribers who mayn't roam, and for phones the home network doesn't know", function()
        math.randomseed(6)
        local acme, beta, net = operators()
        local phone = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        acme.subscribers[hex(phone.sim.public)].roaming = false
        local stranger = acme.add_phone(2, 320, false, { partners = { BETA = beta.signing_public } })
        net.advance(10)
        expect(phone.rejected):eq("This subscription doesn't include roaming")
        expect(stranger.rejected):eq("Not a subscriber of ACME")
        expect(beta.core:visitor_info()):same {}

        -- At home, the first is welcome.
        acme.positions[1] = 10
        wait_until(net, function() return phone.state == "attached" end, 90, "Attaching at home")
        expect(phone.cell):eq(11)
    end)

    it("ignores cells which claim to be a partner's, but aren't", function()
        math.randomseed(7)
        local acme, beta, net = operators()
        net.remove(beta.towers[1].stack)
        net.remove(beta.towers[2].stack)
        local rogue = net.stack(66)
        net.connect(rogue, "air", nil, "wireless")
        acme.positions[66] = 300
        local rogue_private, rogue_public = crypto.generateKeyPair("ed25519")
        local fake = certificate.encode(certificate.issue {
            name = common.cell_name("BETA", 66), key = rogue_public, expires = acme.now() + 1e9, issuer = rogue_public,
            sign = function(data) return crypto.sign(rogue_private, data) end,
        })
        local function beacon()
            rogue:schedule(1, beacon)
            rogue:send_frame("air", -1, common.FRAME, common.make_sib {
                network = "BETA", cell = 66, area = 1, load = 0, time = acme.now(), certificate = fake,
                sign = function(data) return crypto.sign(rogue_private, data) end,
            })
        end
        beacon()

        local phone = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(10)
        expect(phone.state):eq("searching")
        local heard = phone:info().heard[1]
        expect({ heard.id, heard.network, heard.verified }):same { 66, "BETA", false }
    end)

    it("carries messages to and from a roaming phone, on a bad radio link", function()
        math.randomseed(8)
        local acme, beta, net = operators()
        net.loss.air = 0.2
        local home_inbox, away_inbox = {}, {}
        local home = acme.add_phone(1, 10, true, { on_message = function(from, text) home_inbox[#home_inbox + 1] = from .. ": " .. text end })
        local away = acme.add_phone(2, 310, true, {
            partners = { BETA = beta.signing_public },
            on_message = function(from, text) away_inbox[#away_inbox + 1] = from .. ": " .. text end,
        })
        wait_until(net, function() return home.state == "attached" and away.state == "attached" end, 60, "Attaching")
        expect(away:roaming()):eq(true)

        local to_home, to_away = {}, {}
        for i = 1, 10 do
            assert(home:send_message("2", "out " .. i))
            assert(away:send_message("1", "back " .. i))
            to_away[i], to_home[i] = "1: out " .. i, "2: back " .. i
            net.advance(0.5)
        end
        wait_until(net, function() return #home_inbox >= 10 and #away_inbox >= 10 end, 120, "Delivering messages")
        -- And for the phones to say they have them.
        net.advance(60)
        table.sort(home_inbox)
        table.sort(away_inbox)
        table.sort(to_home)
        table.sort(to_away)
        expect(home_inbox):same(to_home)
        expect(away_inbox):same(to_away)
        expect(#acme.core.messages):eq(0)
        expect(net.errors):same {}
    end)

    it("comes back by itself when either core restarts", function()
        math.randomseed(9)
        local acme, beta, net = operators()
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect(reaches_server(net, stack)):eq(true)

        -- The network carrying the phone restarts, and joins the phone's own again.
        beta.restart_core()
        acme.roam_on(beta)
        wait_until(net, function() return phone.state == "attached" and reaches_server(net, stack) end, 30, "Service after BETA restarted")
        expect(address.format(stack.interfaces.cell.address)):eq("10.64.0.2")

        -- The phone's own network restarts.
        acme.restart_core()
        acme.roam_on(beta)
        wait_until(net, function() return phone.state == "attached" and reaches_server(net, stack) end, 30, "Service after ACME restarted")
        expect(phone:roaming()):eq(true)
        expect(#beta.core:visitor_info()):eq(1)
        expect(net.errors):same {}
    end)

    it("ends when the agreement does", function()
        math.randomseed(10)
        local acme, beta, net = operators()
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect(phone:roaming()):eq(true)

        -- BETA stops carrying ACME's phones. The phone finds out, and is turned away when it tries again.
        beta.core:remove_partner("ACME")
        acme.core:remove_tower(51)
        acme.core:set_partner_keys({})
        wait_until(net, function() return phone.state == "rejected" end, 30, "Losing service")
        expect(reaches_server(net, stack)):eq(false)
        expect(beta.core:visitor_info()):same {}
        expect(next(beta.towers[1].tower.phones)):eq(nil)

        -- Back home, it's told BETA is no longer a partner, and forgets its cells.
        acme.positions[1] = 10
        wait_until(net, function() return phone.state == "attached" end, 90, "Attaching at home")
        expect(phone:info().partners):same {}
        expect(net.errors):same {}
    end)

    it("doesn't let the network carrying a phone do more than carry it", function()
        math.randomseed(11)
        local acme, beta, net = operators()
        local inbox = {}
        local roamer = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        local home, home_stack = acme.add_phone(2, 10, true, { on_message = function(from, text) inbox[#inbox + 1] = from .. ": " .. text end })
        net.advance(5)
        local roamer_session = acme.core.sessions[hex(roamer.sim.public)]
        local home_session = acme.core.sessions[hex(home.sim.public)]
        expect(roamer_session.cell):eq(51)
        expect(home_session.cell):eq(11)

        -- BETA's core says what a cell would, about a phone which isn't with it: nothing comes of it.
        local teid = home_session.teid
        acme.core:control(51, { op = "sms", teid = teid, id = 1, to = "2", text = "from 2, says BETA" })
        acme.core:control(51, { op = "handover", teid = teid, target = 21 })
        acme.core:control(51, { op = "path_switch", teid = teid, cell = 21 })
        acme.core:control(51, { op = "sms_ack", teid = teid, id = 1 })
        net.advance(2)
        expect(inbox):same {}
        expect(home_session.cell):eq(11)
        expect(home_session.visited_cell):eq(nil)
        expect(reaches_server(net, home_stack)):eq(true)

        -- Nor can it attach a phone without the phone: it can't finish the handshake.
        acme.core:control(51, { op = "attach", phone = 9, handshake = ("x"):rep(96), cell = 21 })
        acme.core:control(51, { op = "attach_complete", phone = 9, data = ("x"):rep(40), cell = 21 })
        acme.core:control(51, { op = "attach_complete", phone = 1, data = ("x"):rep(40), cell = 21 })
        net.advance(2)
        expect(#acme.core:info()):eq(2)

        -- Packets it sends up its tunnel as from a phone of ACME's which isn't with it are dropped.
        local forwarded = acme.core_stack.forwarded
        local partner = beta.core.partners.ACME
        local packet = { v = 1, src = home_stack.interfaces.cell.address, dst = ip("10.0.0.60"), ttl = 32, proto = "udp", id = 1, body = { sp = 1, dp = 9, data = "x" } }
        local sealed = partner.sealer:seal({ teid = roamer_session.teid, packet = codec.encode(packet) })
        assert(beta.core_stack:udp_send(beta.core.roam_socket, partner.address, common.TUNNEL_PORT, sealed))
        net.advance(1)
        expect(acme.core_stack.forwarded):eq(forwarded)
        expect(net.errors):same {}
    end)

    it("works through a relay of the network carrying the phone", function()
        math.randomseed(14)
        local acme, beta, net = operators()
        -- A relay of BETA's, further out: a computer which is a phone of BETA and a cell of BETA.
        local relay = beta.add_relay(30, 480)
        wait_until(net, function() return relay.tower ~= nil and #relay.tower.links.BETA.path == 1 end, 60, "The relay joining")

        -- A phone of ACME's which only hears the relay.
        local phone, stack = acme.add_phone(1, 560, true, { partners = { BETA = beta.signing_public } })
        wait_until(net, function() return phone.state == "attached" end, 30, "Attaching")
        expect(phone.cell):eq(30)
        expect(address.format(stack.interfaces.cell.address)):eq("10.64.0.2")
        expect(reaches_server(net, stack)):eq(true)
        expect(beta.core:visitor_info()):same { { network = "ACME", cell = 30, address = "10.64.0.2" } }
        expect(net.errors):same {}
    end)

    it("keeps a roaming phone's connection open between the visited network's cells, on a bad radio link", function()
        math.randomseed(15)
        local acme, beta, net = operators()
        net.loss.air = 0.15
        local phone, stack = acme.add_phone(1, 300, true, { partners = { BETA = beta.signing_public } })
        wait_until(net, function() return phone.state == "attached" end, 60, "Attaching")

        local listener = assert(tcp.listen(acme.server, 80))
        local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
        local server
        wait_until(net, function()
            server = server or listener:accept()
            return server ~= nil and client.state == "established"
        end, 60, "Connecting")

        local sent, got = 0, {}
        local function drain()
            while true do
                local ok, value = server:take()
                if not ok then break end
                got[#got + 1] = value
            end
        end
        -- Back and forth between BETA's two cells, three times.
        for trip = 1, 6 do
            for step = 1, 50 do
                acme.positions[1] = trip % 2 == 1 and 300 + step * 2 or 400 - step * 2
                if client:send(sent + 1) then sent = sent + 1 end
                net.advance(0.5)
                drain()
            end
        end
        wait_until(net, function()
            drain()
            return phone.state == "attached" and #got >= sent
        end, 120, "Delivering everything")
        expect(client.error):eq(nil)
        for i, value in ipairs(got) do expect(value):eq(i) end
        expect(phone:roaming()):eq(true)
        expect(net.errors):same {}
    end)

    it("keeps room for new visitors when old ones never said goodbye", function()
        math.randomseed(13)
        local acme, beta, net = operators()
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        expect(reaches_server(net, stack)):eq(true)

        -- 300 more phones of ACME's attach at BETA's cell, as far as BETA's core can tell, and are never heard of again.
        for id = 1000, 1299 do
            assert(beta.core:remember_roamer("ACME", id, 21))
            beta.core:partner_control("ACME", {
                op = "context", phone = id, teid = id, cell = 21, key = ("k"):rep(32), address = ip("10.64.1.0") + id - 1000,
            })
            -- One every tenth of a second: only so many may be attaching at once.
            net.advance(0.1)
        end
        net.advance(1)
        expect(#beta.core:visitor_info()):eq(256)
        local count = 0
        for _ in pairs(beta.core.visitors_by_phone) do count = count + 1 end
        expect(count):eq(256)

        -- The real phone was the oldest, so it was forgotten. It finds out, and attaches again.
        wait_until(net, function() return phone.state == "attached" and reaches_server(net, stack) end, 30, "Service")
        expect(#beta.core:visitor_info()):eq(256)
        expect(net.errors):same {}
    end)

    it("survives control messages with something unexpected in them, between the cores", function()
        math.randomseed(12)
        local acme, beta, net = operators()
        local phone, stack = acme.add_phone(1, 310, true, { partners = { BETA = beta.signing_public } })
        net.advance(5)
        local session = acme.core.sessions[hex(phone.sim.public)]
        local visitor = next(beta.core.visitors)

        -- (Not tables which contain themselves: connections between cores don't carry them.)
        local NIL = {}
        local bad = { NIL, 0 / 0, math.huge, -math.huge, 1e18, -1, 0.5, 2 ^ 32, "x", {}, true, { 1, { 2 } }, ("y"):rep(5000) }
        local template = {
            phone = 1, teid = session.teid, cell = 21, target = 22, handshake = ("h"):rep(96), data = ("d"):rep(40),
            key = ("k"):rep(32), address = ip("10.64.0.2"), handover = true, reason = "r", id = 1, to = "2", from = "2",
            text = "hello", ok = true, error = "e", network = "ACME", path = { 1 },
        }
        local ops = {
            "attach", "attach_complete", "attach_reply", "reject", "context", "handover", "handover_go", "path_switch",
            "sms", "sms_ack", "sms_sent", "release", "path", "nonsense",
        }
        local failures = {}
        local function try(what, fn, ...)
            local ok, err = pcall(fn, ...)
            if not ok then failures[#failures + 1] = what .. ": " .. tostring(err) end
        end
        for _, op in ipairs(ops) do
            for field in pairs(template) do
                for i, value in ipairs(bad) do
                    local message = {}
                    for k, v in pairs(template) do message[k] = v end
                    if value == NIL then message[field] = nil else message[field] = value end
                    message.op = op
                    local what = ("%s with bad %s (%d)"):format(op, field, i)
                    -- From BETA's core to ACME's, from ACME's to BETA's, and from BETA's cell about the visitor.
                    try(what .. " at home", acme.core.control, acme.core, 51, message)
                    try(what .. " at the partner", beta.core.partner_control, beta.core, "ACME", message)
                    message.teid = message.teid == session.teid and visitor or message.teid
                    try(what .. " from a cell", beta.core.control, beta.core, 21, message)
                end
            end
            net.advance(0.2)
            yield()
        end
        expect(failures):same {}
        net.advance(15)
        expect(net.errors):same {}

        -- The phone may have been thrown off by all that, but it gets service again.
        wait_until(net, function() return phone.state == "attached" and reaches_server(net, stack) end, 90, "Service")
        expect(copy(acme.core:info())[1].address):eq("10.64.0.2")
    end)
end)
