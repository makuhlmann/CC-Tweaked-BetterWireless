-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Several cellular networks at once, on bad radio links, with things which restart and computers which misbehave:
two operators which carry each other's phones, share a cell and exchange messages. Whatever happens, phones with
coverage end up with service by themselves, messages arrive once, and nothing grows without limit.

    ACME (numbers 555...): cells 11 (at 0) and 12 (at 100, shared with BETA), core 50
    BETA (numbers 666...): cells 21 (at 200) and 22 (at 300), core 51
]]

describe("Several cellular networks, under stress,", function()
    local address = require "cc.net.address"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local function ip(text) return (address.parse(text)) end

    local function count(list)
        local total = 0
        for _ in pairs(list) do total = total + 1 end
        return total
    end

    local function yield()
        os.queueEvent("cell_networks_yield")
        os.pullEvent("cell_networks_yield")
    end

    -- Let time pass, without keeping the computer to ourselves.
    local function advance(net, seconds)
        while seconds > 0 do
            net.advance(math.min(seconds, 5))
            seconds = seconds - 5
            yield()
        end
    end

    local function reaches_server(net, stack)
        local result = net.ping(stack, ip("10.0.0.60"), nil, 1)
        return result ~= nil and result.error == nil
    end

    -- A frame on the air which says it's from a computer it isn't from.
    local function spoof(net, target, src, body)
        net.inject("air", target.interfaces.air.unicast, { net = 1, src = src, dst = target.id, type = common.FRAME, body = body })
    end

    local NIL = {}
    local BAD = {
        { "nil", NIL }, { "NaN", 0 / 0 }, { "inf", math.huge }, { "-inf", -math.huge }, { "1e18", 1e18 },
        { "-1", -1 }, { "0.5", 0.5 }, { "2^32", 2 ^ 32 }, { "a string", "x" }, { "a table", {} }, { "true", true },
        { "a long string", ("y"):rep(5000) }, { "a network's name", "BETA" }, { "our network's name", "ACME" },
    }

    local function with(template, key, value)
        local result = {}
        for k, v in pairs(template) do result[k] = v end
        if value == NIL then result[key] = nil else result[key] = value end
        return result
    end

    local function operators(options)
        options = options or {}
        local acme = operator({ 0, 100 }, { numbers = "555" })
        local beta = operator({ 200, 300 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16", numbers = "666",
        })
        local world = { acme = acme, beta = beta, net = acme.net }
        if options.roaming ~= false then
            acme.roam_on(beta)
            beta.roam_on(acme)
        end
        if options.sharing ~= false then world.shared = acme.share_cell(2, beta) end
        if options.peering ~= false then world.peering = acme.peer_with(beta) end
        return world
    end

    describe("with everything happening at once,", function()
        --[[ Phones of both networks wander along the line on a radio which loses frames, sending each other messages,
        while cells restart, the shared cell loses and regains its second network, the cores lose and find each other,
        and phones are told which network to use. Then everything is mended, and left alone for a while. ]]
        local function storm(seed, rounds)
            math.randomseed(seed)
            local world = operators()
            local acme, beta, net = world.acme, world.beta, world.net
            local log = {}
            local function note(...) log[#log + 1] = ("%6.1f %s"):format(net.time, table.concat({ ... }, " ")) end

            -- Each phone, the messages it got (by text), and what it was told of those it sent (by ID).
            local phones = {}
            local messages, next_text = {}, 0
            local function add(network, id, position)
                local entry = { id = id, network = network, got = {}, notices = {}, sent = {} }
                entry.phone, entry.stack = network.add_phone(id, position, true, {
                    on_message = function(from, text)
                        if text:find("^Not delivered") then
                            entry.notices[#entry.notices + 1] = text
                        else
                            entry.got[text] = (entry.got[text] or 0) + 1
                            local message = messages[text]
                            if message and message.shown_from[from] == nil then
                                error(("Message %q for %d came from %s"):format(text, id, from), 0)
                            end
                        end
                    end,
                    on_sent = function(message, ok, reason)
                        local sent = entry.sent[message]
                        if sent then sent.ok, sent.reason = ok, reason end
                    end,
                })
                entry.full = (network == acme and "555" or "666") .. id
                phones[#phones + 1] = entry
            end
            add(acme, 1, 10)
            add(acme, 2, 90)
            add(beta, 4, 210)
            add(beta, 5, 290)
            advance(net, 8)

            net.loss.air = 0.15
            local peered, shared_on = true, true
            local function share()
                world.shared = acme.share_cell(2, beta)
                shared_on = true
            end

            for _ = 1, rounds do
                for _, entry in ipairs(phones) do
                    local position = acme.positions[entry.id] + math.random(-25, 25)
                    acme.positions[entry.id] = math.max(-40, math.min(340, position))
                end

                local what = math.random(1, 100)
                if what <= 8 then
                    local network, i = math.random(1, 2) == 1 and acme or beta, math.random(1, 2)
                    note("restart cell", network.name, i)
                    network.restart_cell(i)
                    -- A cell which restarts connects to each of its cores again.
                    if network == acme and i == 2 and shared_on then share() end
                elseif what <= 16 then
                    note(peered and "cores lose each other" or "cores find each other")
                    if peered then world.peering.cut() else world.peering.mend() end
                    peered = not peered
                elseif what <= 22 then
                    note(shared_on and "shared cell loses BETA" or "shared cell serves BETA")
                    if shared_on then
                        world.shared:stop()
                        shared_on = false
                    else
                        share()
                    end
                elseif what <= 32 then
                    local entry = phones[math.random(1, #phones)]
                    local choice = ({ false, "ACME", "BETA" })[math.random(1, 3)]
                    note("phone", entry.id, "uses", tostring(choice))
                    entry.phone:select(choice or nil)
                end

                if math.random(1, 2) == 1 then
                    local from, to = phones[math.random(1, #phones)], phones[math.random(1, #phones)]
                    -- By its number alone within a network, or in full; in full to the other network.
                    local number = tostring(to.id)
                    if from.network ~= to.network or math.random(1, 2) == 1 then number = to.full end
                    next_text = next_text + 1
                    local text = "message " .. next_text
                    local ok, id = from.phone:send_message(number, text)
                    if ok then
                        local message = {
                            text = text, from = from, to = to,
                            -- The recipient sees the number alone from its own network, and in full from the other.
                            shown_from = { [from.network == to.network and tostring(from.id) or from.full] = true },
                        }
                        messages[text], from.sent[id] = message, message
                        note("phone", from.id, "sends", text, "to", number)
                    end
                end
                advance(net, 2)
            end

            -- Mend everything, and leave it alone.
            expect(next_text >= rounds / 4):describe("Messages sent"):eq(true)
            note("mending")
            net.loss.air = 0
            if not peered then world.peering.mend() end
            if not shared_on then share() end
            for _, entry in ipairs(phones) do entry.phone:select(nil) end
            advance(net, 200)

            local ok, err = pcall(function()
                for _, entry in ipairs(phones) do
                    local phone = entry.phone
                    expect(phone.state):describe(("Phone %d's state"):format(entry.id)):eq("attached")
                    expect(reaches_server(net, entry.stack)):describe(("Phone %d reaches the server"):format(entry.id)):eq(true)
                    local prefix = entry.network == acme and "10.64." or "10.65."
                    expect(address.format(phone.address):sub(1, 6)):describe(("Phone %d's address"):format(entry.id)):eq(prefix)
                    expect(#phone.outbox):describe(("Messages phone %d is still sending"):format(entry.id)):eq(0)
                    -- What it remembers is bounded by what's around.
                    expect(count(phone.heard) <= 5):describe(("Cells phone %d heard"):format(entry.id)):eq(true)
                    expect(count(phone.failed) <= 5):describe(("Cells phone %d gave up on"):format(entry.id)):eq(true)
                    expect(count(phone.forbidden) <= 2):describe(("Networks phone %d leaves alone"):format(entry.id)):eq(true)
                end
                for text, message in pairs(messages) do
                    local got = message.to.got[text] or 0
                    if got > 1 then fail(("%q arrived %d times"):format(text, got)) end
                    if message.ok == true and got ~= 1 then
                        -- Unless its sender was told it wasn't delivered after all.
                        local told = false
                        for _, notice in ipairs(message.from.notices) do told = told or notice:find(message.to.full, 1, true) ~= nil end
                        if not told then fail(("%q was taken, but never arrived"):format(text)) end
                    end
                    if message.ok == nil then fail(("Phone %d never heard what became of %q"):format(message.from.id, text)) end
                end
                for _, network in ipairs { acme, beta } do
                    local core = network.core
                    expect(#core.messages):describe(network.name .. "'s messages still kept"):eq(0)
                    expect(core.held_count):describe(network.name .. "'s messages for the other network"):eq(0)
                    expect(count(core.held)):describe(network.name .. "'s messages for the other network"):eq(0)
                    expect(count(core.sessions) <= 2):describe(network.name .. "'s sessions"):eq(true)
                    expect(count(core.visitors) <= 2):describe(network.name .. "'s visitors"):eq(true)
                    expect(count(core.pending)):describe(network.name .. "'s unfinished attaches"):eq(0)
                    for _, entry in ipairs(network.towers) do
                        expect(count(entry.tower.phones) <= #phones):describe("Phones at cell " .. entry.id):eq(true)
                    end
                end
                expect(net.errors):same {}
            end)
            if not ok then
                local from = math.max(1, #log - 40)
                error(("%s\nSeed %d. The last things to happen:\n%s"):format(
                    type(err) == "table" and err.message or tostring(err), seed, table.concat(log, "\n", from)), 0)
            end
        end

        for seed = 1, 4 do
            it(("phones end up with service and every message arrives once (storm %d)"):format(seed), function()
                storm(7000 + seed, 36)
            end)
        end
    end)

    describe("with someone making up cells and networks,", function()
        -- Made-up system information: so many cells, each naming so many networks, with names which keep changing.
        local function flood(net, target, round, cells, names)
            for i = 1, cells do
                local id = 3000 + (round * cells + i) % 5000
                local networks = {}
                for n = 1, names do networks[n] = { network = ("FAKE%d-%d"):format(round, (i * names + n) % 977) } end
                net.inject("air", target.interfaces.air.broadcast, {
                    net = 1, src = id, dst = -1, type = common.FRAME,
                    body = { op = "sib", cell = id, area = 1, load = 0, time = 1.7e12 + net.time * 1000, networks = networks },
                })
            end
        end

        it("a phone without service remembers a limited amount, and attaches once its network is back", function()
            math.randomseed(81)
            local world = operators { roaming = false, sharing = false, peering = false }
            local acme, net = world.acme, world.net
            -- Made-up frames aren't sent from anywhere: they're heard well.
            local reach = net.reach
            net.reach = function(link, sender, receiver)
                if not sender then return -60 end
                return reach(link, sender, receiver)
            end
            -- Out of reach of every real cell.
            local phone, stack = acme.add_phone(1, 600)
            for round = 1, 400 do
                flood(net, stack, round, 12, 8)
                net.advance(1)
                if round % 10 == 0 then yield() end
            end
            expect(phone.state ~= "attached"):eq(true)
            expect(count(phone.heard) <= 32):describe(count(phone.heard) .. " cells heard"):eq(true)
            expect(count(phone.cells) <= 32):describe(count(phone.cells) .. " cells to use"):eq(true)
            expect(count(phone.failed) <= 64):describe(count(phone.failed) .. " cells given up on"):eq(true)
            expect(count(phone.forbidden) <= 32):describe(count(phone.forbidden) .. " networks left alone"):eq(true)

            -- Back in reach of its own network, with the made-up cells still about (and heard better), it attaches soon.
            acme.positions[1] = 10
            local attached
            for round = 401, 430 do
                flood(net, stack, round, 12, 8)
                net.advance(1)
                if phone.state == "attached" then
                    attached = round - 400
                    break
                end
            end
            expect(attached ~= nil and attached <= 15):describe("Attached after " .. tostring(attached) .. " seconds"):eq(true)
            expect(phone.via):eq("ACME")
            expect(net.errors):same {}
        end)

        it("a phone with service stays where it is", function()
            math.randomseed(82)
            local world = operators { roaming = false, sharing = false, peering = false }
            local acme, net = world.acme, world.net
            local reach = net.reach
            net.reach = function(link, sender, receiver)
                if not sender then return -40 end
                return reach(link, sender, receiver)
            end
            local phone, stack = acme.add_phone(1, 60)
            advance(net, 5)
            expect(phone.state):eq("attached")
            local events = #phone.events
            for round = 1, 120 do
                flood(net, stack, round, 12, 8)
                -- Some say they're our own network's, or our cell, without being able to sign for it.
                net.inject("air", stack.interfaces.air.broadcast, {
                    net = 1, src = 3000 + round, dst = -1, type = common.FRAME,
                    body = { op = "sib", cell = 3000 + round, area = 1, load = 0, time = acme.now(), networks = { { network = "ACME" } } },
                })
                net.inject("air", stack.interfaces.air.broadcast, {
                    net = 1, src = phone.cell, dst = -1, type = common.FRAME,
                    body = { op = "sib", cell = phone.cell, area = 1, load = 0, time = acme.now(), networks = { { network = "FAKE" } } },
                })
                net.advance(1)
                if round % 10 == 0 then yield() end
            end
            expect(phone.state):eq("attached")
            expect(#phone.events):describe("Nothing happened to the phone"):eq(events)
            expect(reaches_server(net, stack)):eq(true)
            expect(net.errors):same {}
        end)
    end)

    describe("with one phone sending all it can,", function()
        it("other phones' messages for another network are still taken", function()
            math.randomseed(83)
            local world = operators { roaming = false, sharing = false }
            local acme, beta, net = world.acme, world.beta, world.net
            local sent = {}
            local greedy = acme.add_phone(1, 10)
            local other = acme.add_phone(2, 20, true, { on_sent = function(id, ok, reason) sent[id] = { ok, reason } end })
            beta.add_phone(4, 210)
            advance(net, 5)

            -- BETA's core can't be reached, so ACME's keeps what's for it.
            world.peering.cut()
            for round = 1, 120 do
                for _ = 1, 20 do greedy:send_message("6664", "More") end
                net.advance(1)
                if round % 10 == 0 then yield() end
            end
            local _, id = assert(other:send_message("6664", "Just the one"))
            advance(net, 3)
            expect(sent[id]):describe("What became of the other phone's message"):same { true }
            expect(acme.core.held_count):describe("Messages kept for BETA"):eq(51)

            -- Once BETA's core is back, they all go, and there's room again.
            world.peering.mend()
            advance(net, 5)
            expect(acme.core.held_count):eq(0)
            expect(count(acme.core.held_from)):eq(0)
            assert(greedy:send_message("6664", "More"))
            expect(net.errors):same {}
        end)
    end)

    describe("with phones, cells and cores which send odd things,", function()
        it("phones ignore system information with something unexpected in it", function()
            math.randomseed(84)
            local world = operators()
            local acme, net = world.acme, world.net
            local phone, stack = acme.add_phone(1, 90)
            advance(net, 5)
            expect(phone.state):eq("attached")
            local events = #phone.events

            -- What a real cell would send: here, the shared one's, signed.
            local entry = acme.towers[2]
            local function sib()
                return common.make_sib {
                    cell = entry.id, area = 1, load = 0, time = acme.now(), sign = entry.sign,
                    networks = { { network = "ACME", certificate = entry.certificate } },
                }
            end
            local function send(body)
                net.inject("air", stack.interfaces.air.broadcast, { net = 1, src = entry.id, dst = -1, type = common.FRAME, body = body })
            end
            local sent = 0
            for _, bad in ipairs(BAD) do
                for _, field in ipairs { "cell", "area", "load", "time", "networks" } do
                    send(with(sib(), field, bad[2]))
                    sent = sent + 1
                end
                for _, field in ipairs { "network", "path", "cert", "sig" } do
                    local message = sib()
                    message.networks[1] = with(message.networks[1], field, bad[2])
                    send(message)
                    -- The same in a second network's part, after a good one.
                    message = sib()
                    message.networks[2] = with(message.networks[1], field, bad[2])
                    send(message)
                    sent = sent + 2
                end
                -- Parts which aren't parts.
                local message = sib()
                message.networks = { bad[2] ~= NIL and bad[2] or false, message.networks[1] }
                send(message)
                net.advance(0.2)
            end
            -- Far more parts than a cell may have, the same network many times, and paths which aren't paths.
            local many = sib()
            for i = 2, 2000 do many.networks[i] = { network = "N" .. i } end
            send(many)
            local twice = sib()
            for i = 2, 8 do twice.networks[i] = twice.networks[1] end
            send(twice)
            local long = sib()
            long.networks[1].path = {}
            for i = 1, 5000 do long.networks[1].path[i] = i end
            send(long)
            local sparse = sib()
            sparse.networks[1].path = { [1] = 5, [3] = 7, x = 1 }
            send(sparse)
            advance(net, 10)

            expect(sent > 100):eq(true)
            expect(phone.state):eq("attached")
            expect(#phone.events):describe("Nothing happened to the phone"):eq(events)
            expect(count(phone.heard) <= 32):eq(true)
            for _, heard in pairs(phone.heard) do expect(count(heard.networks) <= 8):eq(true) end
            expect(reaches_server(net, stack)):eq(true)
            expect(net.errors):same {}
        end)

        it("a shared cell ignores phones' frames with something unexpected in them", function()
            math.randomseed(85)
            local world = operators()
            local acme, beta, net = world.acme, world.beta, world.net
            local a, a_stack = acme.add_phone(1, 90)
            local b, b_stack = beta.add_phone(4, 110)
            advance(net, 5)
            expect({ a.state, b.state, a.cell, b.cell }):same { "attached", "attached", 12, 12 }

            local cell = acme.towers[2].stack
            local templates = {
                { op = "attach", network = "ACME", via = "ACME", handshake = ("h"):rep(96) },
                { op = "attach", network = "BETA", via = "ACME", handshake = ("h"):rep(96) },
                { op = "attach", network = "GAMMA", via = "BETA", handshake = ("h"):rep(96) },
                { op = "activate", network = "ACME", via = "BETA", tag = "ABCD", handshake = ("h"):rep(48) },
                { op = "activate", network = "GAMMA", via = "ACME", tag = "ABCD", handshake = ("h"):rep(48) },
                { op = "attach_complete", via = "BETA", data = ("d"):rep(32) },
                { op = "activate_finish", via = "ACME", handshake = ("h"):rep(64) },
                { op = "data", sealed = { ctr = 1, ct = ("c"):rep(40) } },
                { op = "confirm", sealed = { ctr = 1, ct = ("c"):rep(40) } },
            }
            local sent = 0
            for _, template in ipairs(templates) do
                for field in pairs(template) do
                    for _, bad in ipairs(BAD) do
                        -- As a stranger, and as each of the phones it serves.
                        for _, src in ipairs { 999, 1, 4 } do
                            spoof(net, cell, src, with(template, field, bad[2]))
                            sent = sent + 1
                        end
                    end
                end
                for _, src in ipairs { 999, 1, 4 } do spoof(net, cell, src, template) end
                net.advance(1)
                yield()
            end
            advance(net, 30)

            expect(sent > 500):eq(true)
            -- Both phones have service, whether or not they had to attach again.
            expect({ a.state, b.state }):same { "attached", "attached" }
            expect(reaches_server(net, a_stack)):eq(true)
            expect(reaches_server(net, b_stack)):eq(true)
            for _, network in ipairs { acme, beta } do
                expect(count(network.core.pending) <= 8):describe(network.name .. "'s unfinished attaches"):eq(true)
                expect(count(network.core.sessions)):describe(network.name .. "'s sessions"):eq(1)
            end
            expect(count(acme.towers[2].tower.phones)):eq(2)
            expect(net.errors):same {}
        end)

        it("a network's core can't take another network's phone at a shared cell", function()
            math.randomseed(87)
            local world = operators { roaming = false, peering = false }
            local acme, beta, net = world.acme, world.beta, world.net
            local phone, stack = acme.add_phone(1, 90)
            advance(net, 5)
            expect({ phone.state, phone.cell, phone.via }):same { "attached", 12, "ACME" }
            local events = #phone.events

            -- BETA's core says the phone is its own, here and as handed over from elsewhere.
            for teid = 1, 20 do
                world.shared:control({ op = "context", phone = 1, teid = teid, key = ("k"):rep(32), address = 5 })
                world.shared:control({ op = "context", phone = 1, teid = 100 + teid, key = ("k"):rep(32), handover = true })
                net.advance(1)
            end
            advance(net, 15)
            expect(phone.state):eq("attached")
            expect(#phone.events):describe("Nothing happened to the phone"):eq(events)
            expect(reaches_server(net, stack)):eq(true)

            -- A phone which does move from one network to the other at the cell is taken, as before.
            beta.roam_on(acme)
            acme.roam_on(beta)
            local visitor, visitor_stack = beta.add_phone(4, 90, true, { selection = "ACME" })
            advance(net, 10)
            expect({ visitor.state, visitor.cell, visitor.via }):same { "attached", 12, "ACME" }
            visitor:select(nil)
            advance(net, 15)
            expect({ visitor.state, visitor.cell, visitor.via }):same { "attached", 12, "BETA" }
            expect(reaches_server(net, visitor_stack)):eq(true)
            expect(net.errors):same {}
        end)

        it("cores ignore activations passed between them with something unexpected in them", function()
            math.randomseed(86)
            local world = operators { sharing = false, peering = false }
            local acme, beta, net = world.acme, world.beta, world.net
            local phone, stack = acme.add_phone(1, 210)
            advance(net, 10)
            expect({ phone.state, phone.via }):same { "attached", "BETA" }

            -- From one of BETA's cells to its core, for ACME's phones; and from ACME's core back.
            local up = {
                { op = "activate", phone = 77, network = "ACME", tag = "ABCD", handshake = ("h"):rep(48) },
                { op = "activate_finish", phone = 77, handshake = ("h"):rep(64) },
            }
            local down = {
                { op = "activate_reply", phone = 77, cell = 21, handshake = ("h"):rep(96) },
                { op = "activate_accept", phone = 77, cell = 21, data = ("d"):rep(64) },
                { op = "reject", phone = 77, cell = 21, reason = "No" },
            }
            local sent = 0
            for _, bad in ipairs(BAD) do
                for _, template in ipairs(up) do
                    for field in pairs(template) do
                        beta.core:control(21, with(template, field, bad[2]))
                        -- And at ACME's core, as from BETA's (which says which of its cells the phone is at).
                        acme.core:control(51, with(with(template, "cell", 21), field, bad[2]))
                        sent = sent + 2
                    end
                    beta.core:control(21, template)
                end
                for _, template in ipairs(down) do
                    for field in pairs(template) do
                        beta.core:partner_control("ACME", with(template, field, bad[2]))
                        sent = sent + 1
                    end
                end
                net.advance(1)
            end
            advance(net, 40)

            expect(sent > 100):eq(true)
            expect(phone.state):eq("attached")
            expect(reaches_server(net, stack)):eq(true)
            expect(count(acme.core.activating) <= 64):eq(true)
            expect(count(beta.core.roam_pending) <= 256):eq(true)
            expect(net.errors):same {}
        end)
    end)
end)
