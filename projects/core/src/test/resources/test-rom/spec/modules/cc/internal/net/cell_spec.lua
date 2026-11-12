-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Cellular networks", function()
    local codec = require "cc.net.codec"
    local address = require "cc.net.address"
    local tcp = require "cc.internal.net.tcp"
    local certificate = require "cc.internal.net.certificate"
    local common = require "cc.internal.net.cell.common"
    local message = require "cc.internal.net.message"

    local function ip(text) return (address.parse(text)) end
    -- A phone's events, without their times.
    local function event_kinds(phone)
        local result = {}
        for i, event in ipairs(phone:info().events) do
            event.time = nil
            result[i] = event
        end
        return result
    end
    local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
    local function copy(value) return codec.decode(codec.encode(value)) end

    local operator = require "support.cell_network".operator

    it("lets a phone attach and reach the network", function()
        math.randomseed(1)
        local setup = operator { 0, 100, 200 }
        local phone, stack = setup.add_phone(1, 10)
        setup.net.advance(5)

        expect(phone.state):eq("attached")
        expect(phone.cell):eq(11)
        expect(phone.subscriber):same { id = "ACME-1", number = "1" }
        expect(address.format(stack.interfaces.cell.address)):eq("10.64.0.2")

        local result = setup.net.ping(stack, ip("10.0.0.60"))
        expect(result and result.error):eq(nil)
        expect(result.ttl):eq(31) -- Through the gateway.
        expect(setup.events[#setup.events]):same { "attached", setup.core:info()[1].sim, "10.64.0.2", 11 }
    end)

    it("refuses phones which aren't subscribers", function()
        local setup = operator { 0 }
        local phone = setup.add_phone(1, 10, false)
        setup.net.advance(5)
        expect(phone.state):eq("rejected")
        expect(phone.rejected):eq("Not a subscriber of ACME")
        expect(phone.address):eq(nil)
    end)

    it("says when the cells around speak a newer version of the network than it does", function()
        -- Its own network's cell is out of reach: there's only a newer one, which says things this phone can't read.
        local setup = operator { 1000 }
        local newer = setup.net.stack(66)
        setup.net.connect(newer, "air", nil, "wireless")
        setup.positions[66] = 0
        for t = 0, 4 do
            newer:schedule(t, function()
                newer:send_frame("air", -1, common.FRAME, { op = "sib", v = common.VERSION + 1, cell = 66, layout = "new" })
            end)
        end
        local phone = setup.add_phone(1, 0)
        setup.net.advance(5)
        expect(phone.state):eq("searching")
        expect(phone:info().newer):eq(true)

        -- It forgets, once it no longer hears it.
        setup.net.advance(35)
        expect(phone:info().newer):eq(false)

        -- Cells say which version they speak.
        local sib = common.make_sib {
            network = "ACME", cell = 1, area = 0, load = 0, time = 0, certificate = "c", sign = function() return "" end,
        }
        expect(sib.v):eq(common.VERSION)
        expect({ common.is_newer(common.VERSION), common.is_newer(common.VERSION + 1), common.is_newer("3") }):same {
            false, true, false,
        }
    end)

    it("ignores cells without a certificate from the operator", function()
        local setup = operator { 80 }
        -- A rogue tower, closer, with a certificate it made itself.
        local rogue = setup.net.stack(66)
        setup.net.connect(rogue, "air", nil, "wireless")
        setup.positions[66] = 0
        local rogue_private, rogue_public = crypto.generateKeyPair("ed25519")
        local fake = certificate.encode(certificate.issue {
            name = common.cell_name("ACME", 66), key = rogue_public, expires = setup.now() + 1e9, issuer = rogue_public,
            sign = function(data) return crypto.sign(rogue_private, data) end,
        })
        for t = 0, 4 do
            rogue:schedule(t, function()
                rogue:send_frame("air", -1, common.FRAME, common.make_sib {
                    network = "ACME", cell = 66, area = 1, load = 0, time = setup.now(), certificate = fake,
                    sign = function(data) return crypto.sign(rogue_private, data) end,
                })
            end)
        end

        -- And a cell of another network.
        local other = setup.net.stack(77)
        setup.net.connect(other, "air", nil, "wireless")
        setup.positions[77] = 40
        local other_private, other_public = crypto.generateKeyPair("ed25519")
        local other_certificate = certificate.encode(certificate.issue {
            name = common.cell_name("BETA", 77), key = other_public, expires = setup.now() + 1e9, issuer = other_public,
            sign = function(data) return crypto.sign(other_private, data) end,
        })
        for t = 0, 4 do
            other:schedule(t, function()
                other:send_frame("air", -1, common.FRAME, common.make_sib {
                    network = "BETA", cell = 77, area = 2, load = 0.5, time = setup.now(), certificate = other_certificate,
                    sign = function(data) return crypto.sign(other_private, data) end,
                })
            end)
        end

        local phone = setup.add_phone(1, 0)
        setup.net.advance(5)
        expect(phone.cells[66]):eq(nil)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(11)

        -- The phone still lists them all: the rogue as a fake, and the other network's cell as unchecked.
        local info = phone:info()
        local heard = {}
        for _, cell in ipairs(info.heard) do
            heard[cell.id] = { network = cell.network, verified = cell.verified, serving = cell.serving, area = cell.area }
        end
        expect(heard):same {
            [11] = { network = "ACME", verified = true, serving = true, area = 1 },
            [66] = { network = "ACME", verified = false, serving = false, area = 1 },
            [77] = { network = "BETA", serving = false, area = 2 },
        }
        expect(info.networks):same { "ACME", "BETA" }
        -- Strongest first: the rogue is next to the phone, and our cell furthest away.
        expect({ info.heard[1].id, info.heard[2].id, info.heard[3].id }):same { 66, 77, 11 }
    end)

    it("keeps a connection open while the phone moves from cell to cell", function()
        math.randomseed(2)
        local setup = operator { 0, 100, 200 }
        local phone, stack = setup.add_phone(1, 0)
        setup.net.advance(5)
        expect(phone.state):eq("attached")
        local first_address = stack.interfaces.cell.address

        local listener = assert(tcp.listen(setup.server, 80))
        local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
        setup.net.advance(1)
        local server = assert(listener:accept())

        -- Walk from the first cell to the last, sending a message every half second.
        local sent, got, cells = 0, {}, { phone.cell }
        for step = 1, 200 do
            setup.positions[1] = step
            if step % 1 == 0 then
                sent = sent + 1
                assert(client:send(sent))
            end
            setup.net.advance(0.5)
            while true do
                local ok, value = server:take()
                if not ok then break end
                got[#got + 1] = value
            end
            if phone.cell ~= cells[#cells] then cells[#cells + 1] = phone.cell end
        end
        setup.net.advance(10)
        while true do
            local ok, value = server:take()
            if not ok then break end
            got[#got + 1] = value
        end

        expect(cells):same { 11, 12, 13 }
        expect(client.state):eq("established")
        expect(stack.interfaces.cell.address):eq(first_address)
        expect(#got):eq(sent)
        for i = 1, sent do expect(got[i]):eq(i) end
        -- The core switched the phone's tunnel each time.
        local handovers = {}
        for _, event in ipairs(setup.events) do
            if event[1] == "handover" then handovers[#handovers + 1] = { event[3], event[4] } end
        end
        expect(handovers):same { { 11, 12 }, { 12, 13 } }
        -- The phone remembers it too.
        expect(event_kinds(phone)):same {
            { kind = "attached", cell = 11 },
            { kind = "handover", from = 11, to = 12 },
            { kind = "handover", from = 12, to = 13 },
        }
    end)

    it("attaches again through another cell when its cell fails, keeping its address", function()
        math.randomseed(3)
        local setup = operator { 0, 60 }
        local phone, stack = setup.add_phone(1, 20)
        setup.net.advance(5)
        expect(phone.cell):eq(11)
        local first_address = stack.interfaces.cell.address

        setup.net.remove(setup.towers[1].stack)
        setup.net.advance(20)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(12)
        expect(stack.interfaces.cell.address):eq(first_address)
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
        expect(event_kinds(phone)):same {
            { kind = "attached", cell = 11 }, { kind = "lost", cell = 11 }, { kind = "attached", cell = 12 },
        }
        -- The failed cell is listed after the ones still heard, until it's forgotten.
        local heard = phone:info().heard
        expect({ heard[1].id, heard[1].serving, heard[2].id, heard[2].serving }):same { 12, true, 11, false }
        expect(heard[2].age > 4):eq(true)
        setup.net.advance(20)
        heard = phone:info().heard
        expect(#heard):eq(1)
        expect(heard[1].id):eq(12)
    end)

    it("refuses data which was changed or replayed", function()
        local setup = operator { 0 }
        local phone, stack = setup.add_phone(1, 10)
        setup.net.advance(5)

        -- Watch a data frame go up, then send it again, and a changed copy.
        stack:echo(ip("10.0.0.60"))
        local captured
        for _, item in ipairs(setup.net.queue) do
            local body = item.frame.body
            if item.frame.type == common.FRAME and type(body) == "table" and body.op == "data" then captured = copy(item.frame) end
        end
        expect(captured ~= nil):eq(true)
        setup.net.run()
        local forwarded = setup.core_stack.forwarded

        setup.net.inject("air", setup.towers[1].stack.interfaces.air.unicast, captured)
        local changed = copy(captured)
        changed.body.sealed.ct = changed.body.sealed.ct:sub(1, -2) .. "x"
        setup.net.inject("air", setup.towers[1].stack.interfaces.air.unicast, changed)
        setup.net.advance(1)
        expect(setup.core_stack.forwarded):eq(forwarded)
        expect(phone.state):eq("attached")
    end)

    it("activates a phone over the air with a code", function()
        local setup = operator { 0 }
        local code = setup.core:add_code("ACME-0007", "0007")
        expect(code:match("^%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w$") ~= nil):eq(true)

        local activated
        local phone = setup.add_phone(1, 10, false, { activated = false, on_activated = function(info) activated = info end })
        setup.net.advance(3)
        expect(phone.state):eq("inactive")
        expect(phone:info().networks):same { "ACME" }

        -- Typed sloppily: lower case, spaces instead of dashes.
        assert(phone:activate("ACME", code:lower():gsub("%-", " ")))
        setup.net.advance(5)
        expect(activated.id):eq("ACME-0007")
        expect(activated.key):eq(setup.operator_key.public)
        expect(activated.signing):eq(setup.signing_public)
        expect(phone.state):eq("attached")
        expect(phone.subscriber):same { id = "ACME-0007", number = "0007" }

        -- A code works once.
        local second = setup.add_phone(2, 10, false, { activated = false })
        setup.net.advance(2)
        assert(second:activate("ACME", code))
        setup.net.advance(12)
        expect(second.state):eq("inactive")
    end)

    it("refuses wrong codes, and cancels a code after three", function()
        local setup = operator { 0 }
        local code = setup.core:add_code("ACME-0008", "0008")
        local tag = code:sub(1, 4)
        local phone = setup.add_phone(1, 10, false, { activated = false })
        setup.net.advance(2)

        for _ = 1, 3 do
            assert(phone:activate("ACME", tag .. "-0000-0000-0000-0000"))
            setup.net.advance(12)
            expect(phone.state):eq("inactive")
        end
        -- Now even the right code doesn't work.
        assert(phone:activate("ACME", code))
        setup.net.advance(12)
        expect(phone.state):eq("inactive")
        expect({ phone:activate("ACME", "not a code") }):same { nil, "That isn't an activation code" }
    end)

    it("delivers messages, keeping them until the phone is reachable", function()
        local setup = operator { 0 }
        local inbox_a, inbox_b = {}, {}
        local a = setup.add_phone(1, 10, true, { on_message = function(from, text) inbox_a[#inbox_a + 1] = { from, text } end })
        local b, b_stack = setup.add_phone(2, 20, true, { on_message = function(from, text) inbox_b[#inbox_b + 1] = { from, text } end })
        setup.net.advance(5)

        assert(a:send_message("2", "Hello, B"))
        setup.net.advance(2)
        expect(inbox_b):same { { "1", "Hello, B" } }

        -- B goes out of range. The message waits.
        setup.net.remove(b_stack)
        setup.net.advance(1)
        assert(a:send_message("2", "Are you there?"))
        setup.net.advance(15)
        expect(#inbox_b):eq(1)

        table.insert(setup.net.stacks, b_stack)
        setup.net.advance(30)
        expect(inbox_b):same { { "1", "Hello, B" }, { "1", "Are you there?" } }
        expect(b.state):eq("attached")
        expect(#setup.core.messages):eq(0)
        expect(#inbox_a):eq(0)
    end)

    it("survives bad frames, at cells and phones", function()
        local setup = operator { 0 }
        local phone, stack = setup.add_phone(1, 10)
        setup.net.advance(5)
        expect(phone.state):eq("attached")

        local recursive = {}
        recursive.self = recursive
        local bad = { false, 0 / 0, math.huge, -1, 0.5, 2 ^ 53 + 2, "x", {}, true, recursive, ("y"):rep(5000) }
        local template = {
            network = "ACME", handshake = "h", data = "d", tag = "TAG1", cell = 11, area = 1, load = 0, time = setup.now(),
            sealed = { ctr = 1, ct = "c" }, cert = "c", sig = ("s"):rep(64), reason = "r",
        }
        local ops = {
            "sib", "attach", "attach_complete", "attach_reply", "accept", "data", "confirm", "handover", "reject",
            "activate", "activate_finish", "activate_reply", "activate_accept", "nonsense",
        }
        local count = 0
        for _, op in ipairs(ops) do
            for field in pairs(template) do
                for _, value in ipairs(bad) do
                    local message = { op = op }
                    for k, v in pairs(template) do message[k] = v end
                    message[field] = value
                    for _, target in ipairs { setup.towers[1].stack, stack } do
                        setup.net.inject("air", target.interfaces.air.unicast, {
                            net = 1, src = 9, dst = target.id, type = common.FRAME, body = message,
                        })
                        count = count + 1
                    end
                end
            end
            setup.net.advance(0.2)
        end
        for _, value in ipairs(bad) do
            setup.net.inject("air", stack.interfaces.air.unicast, { net = 1, src = 11, dst = 1, type = common.FRAME, body = value })
        end
        setup.net.advance(2)

        expect(count > 600):eq(true)
        expect(setup.net.errors):same {}
        expect(phone.state):eq("attached")
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("works with the core on one of the cells", function()
        local setup = operator({ 0, 100 }, { core_is_cell = true })
        local phone, stack = setup.add_phone(1, 5)
        setup.net.advance(5)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(50)
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("keeps a handed-over phone's confirmation which comes before the core's word", function()
        local setup = operator { 0 }
        local tower = setup.towers[1].tower
        local sent = {}
        tower.links.ACME.control_send = function(message) sent[#sent + 1] = message end
        local function confirm(phone, key)
            local sealer = common.new_sealer(crypto, key, common.UPLINK, common.DOWNLINK)
            tower:radio(phone, { op = "confirm", sealed = sealer:seal({ confirm = true }) })
        end

        -- The phone gets here first, then the core says it's coming: the cell takes it at once.
        local key = crypto.random(32)
        confirm(5, key)
        expect(sent):same {}
        tower:control({ op = "context", phone = 5, teid = 77, key = key, handover = true })
        expect(sent):same { { op = "path_switch", teid = 77 } }

        -- A confirmation kept too long is forgotten, and so is one which doesn't open.
        local late = crypto.random(32)
        confirm(6, late)
        setup.net.advance(6)
        tower:control({ op = "context", phone = 6, teid = 78, key = late, handover = true })
        confirm(7, crypto.random(32))
        tower:control({ op = "context", phone = 7, teid = 79, key = crypto.random(32), handover = true })
        expect(#sent):eq(1)
        expect(tower.phones[6].active):eq(false)
        expect(tower.phones[7].active):eq(false)
    end)

    describe("relays", function()
        -- Let time pass until something is true.
        local function wait_until(setup, test, limit)
            for _ = 1, (limit or 30) * 10 do
                if test() then return end
                setup.net.advance(0.1)
            end
            error("Timed out", 2)
        end

        it("carry phones, with the relay's own phone as backhaul, while the relay moves between cells", function()
            math.randomseed(3)
            local setup = operator { 0, 100 }
            local relay = setup.add_relay(30, 30)
            wait_until(setup, function() return relay.tower ~= nil end)
            expect(relay.phone.cell):eq(11)

            -- A phone next to the relay uses it, and reaches the network through it. It may attach to the other cell first,
            -- then move: wait until the core has moved it too.
            local phone, stack = setup.add_phone(1, 35)
            wait_until(setup, function()
                local session = setup.core.sessions[hex(phone.sim.public)]
                return phone.state == "attached" and phone.cell == 30 and session and session.cell == 30
            end)
            expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
            expect(setup.core:path_of(30)):same { 11 }
            expect(relay.tower.links.ACME.path):same { 11 }

            local listener = assert(tcp.listen(setup.server, 80))
            local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
            setup.net.advance(1)
            local server = assert(listener:accept())

            -- The relay, and the phone with it, move until the relay's phone hands over to the other cell.
            local sent, got = 0, {}
            local function drain()
                while true do
                    local ok, value = server:take()
                    if not ok then break end
                    got[#got + 1] = value
                end
            end
            for step = 1, 60 do
                setup.positions[30], setup.positions[1] = 30 + step, 35 + step
                sent = sent + 1
                assert(client:send(sent))
                setup.net.advance(0.5)
                drain()
            end
            setup.net.advance(10)
            drain()

            expect(relay.cells):same { 11, 12 }
            expect(phone.cell):eq(30)
            expect(client.state):eq("established")
            expect(#got):eq(sent)
            for i = 1, sent do expect(got[i]):eq(i) end
            -- The relay now goes through the other cell, and says so.
            expect(setup.core:path_of(30)):same { 12 }
            expect(relay.tower.links.ACME.path):same { 12 }
            expect(setup.net.errors):same {}
        end)

        it("carry the biggest messages programs may send, through a chain of relays", function()
            math.randomseed(5)
            local setup = operator { 0 }
            -- A chain: each relay only hears the one before it.
            local relays = {}
            for i = 1, 3 do
                relays[i] = setup.add_relay(29 + i, i * 90)
                wait_until(setup, function() return relays[i].tower ~= nil and #relays[i].tower.links.ACME.path == i end, 60)
            end
            local phone, stack = setup.add_phone(1, 300)
            wait_until(setup, function()
                local session = setup.core.sessions[hex(phone.sim.public)]
                return phone.state == "attached" and session and session.cell == 32
            end)

            -- Record how big the core's tunnels to cells are: each layer wraps the one inside it.
            local sizes, seen = {}, {}
            local udp_send = setup.core_stack.udp_send
            setup.core_stack.udp_send = function(self, socket, dst, port, data, name)
                if port == common.CELL_TUNNEL_PORT then
                    local size, encoded = message.measure(data)
                    local biggest = math.max(size, encoded)
                    if biggest > message.MAX_MESSAGE and not seen[biggest] then
                        seen[biggest] = true
                        sizes[#sizes + 1] = biggest
                    end
                end
                return udp_send(self, socket, dst, port, data, name)
            end

            local listener = assert(tcp.listen(setup.server, 80))
            local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
            setup.net.advance(2)
            local server = assert(listener:accept())
            local biggest = ("x"):rep(message.MAX_MESSAGE - 2)
            assert(server:send(biggest))
            assert(client:send(biggest))
            local down, up
            wait_until(setup, function()
                local ok, value = client:take()
                if ok then down = value end
                ok, value = server:take()
                if ok then up = value end
                return down and up
            end)
            expect(down == biggest):eq(true)
            expect(up == biggest):eq(true)
            expect(setup.net.errors):same {}

            -- Four tunnels, one in another: to the last relay, and on to each before it and the first cell. Each relay
            -- adds the same, and the longest chain allowed still leaves room in the outermost tunnel.
            table.sort(sizes)
            expect(#sizes):eq(4)
            local per_relay = sizes[2] - sizes[1]
            expect(sizes[3] - sizes[2]):eq(per_relay)
            expect(sizes[4] - sizes[3]):eq(per_relay)
            expect(sizes[1] + common.MAX_PATH * per_relay <= message.TUNNEL.encoded):eq(true)
        end)

        it("limit how many relays a chain has", function()
            local old = common.MAX_PATH
            common.MAX_PATH = 1
            local ok, err = pcall(function()
                local setup = operator { 0 }
                local first = setup.add_relay(30, 90)
                wait_until(setup, function() return first.tower ~= nil and #first.tower.links.ACME.path == 1 end, 60)

                -- A second relay only hears the first, which is as far from the core as a cell may be: its phone
                -- doesn't use it. An ordinary phone does.
                local second = setup.add_relay(31, 180)
                second.phone.relay = function() return true end
                local phone = setup.add_phone(1, 185)
                wait_until(setup, function() return phone.state == "attached" and phone.cell == 30 end)
                setup.net.advance(5)
                expect(second.phone.state):eq("searching")
                expect(second.tower):eq(nil)

                -- Nor would the core let a relay's phone use it.
                expect(setup.core:refuse(1, 30)):eq(nil)
                setup.core.towers[31] = { id = 31, address = 0, send = function() end }
                expect(setup.core:refuse(31, 30)):eq("Too many relays")
                expect(setup.core:refuse(31, 11)):eq(nil)
                setup.core.towers[31] = nil

                -- A cell told it's too far from the core stops serving.
                first.tower:control({ op = "path", path = { 11, 99 } })
                wait_until(setup, function() return phone.state ~= "attached" end)
            end)
            common.MAX_PATH = old
            if not ok then error(err, 0) end
        end)

        it("keep their phones off cells behind them, and stop serving without service", function()
            math.randomseed(4)
            local setup = operator { 0 }
            local first = setup.add_relay(30, 60)
            wait_until(setup, function() return first.tower ~= nil end)
            -- A second relay, out of the cell's range, goes through the first.
            local second = setup.add_relay(31, 150)
            wait_until(setup, function() return second.tower ~= nil and #second.tower.links.ACME.path == 2 end)
            expect(second.phone.cell):eq(30)
            expect(second.tower.links.ACME.path):same { 30, 11 }

            -- The second relay comes right next to the first. The first's phone hears it far better than its own cell,
            -- but never uses it: that would be a loop.
            setup.positions[31] = 65
            setup.net.advance(10)
            expect(first.phone.cell):eq(11)
            expect(first.phone.candidate):eq(nil)
            expect(second.phone.cell):eq(30)
            -- Nor would the core allow it.
            expect(setup.core:would_loop(30, 31)):eq(true)
            expect(setup.core:would_loop(31, 30)):eq(false)
            local session = setup.core.sessions[hex(first.phone.sim.public)]
            setup.core:control(11, { op = "handover", teid = session.teid, target = 31 })
            expect(session.handover):eq(nil)

            -- The first relay moves out of its cell's range, still next to the second. It stops serving, so the second
            -- loses service too, rather than sending packets nowhere. Neither uses the other.
            setup.positions[31] = 150
            setup.net.advance(2)
            setup.positions[30] = 130
            wait_until(setup, function() return first.phone.state ~= "attached" and second.phone.state ~= "attached" end)
            setup.net.advance(5)
            expect(first.tower.can_serve()):eq(false)
            expect(second.tower.can_serve()):eq(false)
            expect(first.cells):same { 11 }

            -- Back in range, the first attaches again, and the second through it.
            setup.positions[30] = 60
            wait_until(setup, function() return second.phone.state == "attached" end, 60)
            expect(first.phone.cell):eq(11)
            expect(second.phone.cell):eq(30)
            expect(setup.net.ping(second.stack, ip("10.0.0.60")).error):eq(nil)
        end)
    end)
end)
