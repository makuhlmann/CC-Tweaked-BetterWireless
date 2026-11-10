-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Cellular networks", function()
    local codec = require "cc.net.codec"
    local address = require "cc.net.address"
    local noise = require "cc.internal.net.noise"
    local tcp = require "cc.internal.net.tcp"
    local certificate = require "cc.internal.net.certificate"
    local common = require "cc.internal.net.cell.common"
    local cell_core = require "cc.internal.net.cell.core"
    local cell_tower = require "cc.internal.net.cell.tower"
    local cell_phone = require "cc.internal.net.cell.phone"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end
    local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
    local function copy(value) return codec.decode(codec.encode(value)) end

    local function x25519()
        local private = crypto.generateKeyPair("x25519")
        return { public = noise.public_key(crypto, private), exchange = function(public) return crypto.exchange(private, public) end }
    end

    --[[ An operator, ACME, with a core (computer 50, which is also the gateway) and cells along a line, all on a wired
    backhaul with a server (computer 60). Phones are on the radio link "air", and hear cells depending on how far away
    they are: positions[id] is where each computer is along the line. ]]
    local function operator(cell_positions, options)
        options = options or {}
        local net = network()
        net.frame_limit = 5000
        local positions = {}
        net.reach = function(link, sender, receiver)
            if link ~= "air" or not sender then return -50 end
            local a, b = positions[sender.id], positions[receiver.id]
            if not a or not b then return false end
            local signal = -50 - math.abs(a - b) * 0.5
            if signal < -110 then return false end
            return signal
        end

        local operator_key = x25519()
        local signing_private, signing_public = crypto.generateKeyPair("ed25519")
        local now = function() return 1.7e12 + net.time * 1000 end

        local core_stack = net.stack(50)
        net.connect(core_stack, "backhaul", "10.0.0.1/24")
        core_stack.forwarding = true
        local subscribers = {}
        local events = {}
        local core = cell_core.new {
            stack = core_stack, crypto = crypto, network = "ACME", operator = operator_key, signing = signing_public,
            prefix = "10.64.0.0/16",
            subscribers = subscribers, secret = crypto.random(32),
            on_event = function(...) events[#events + 1] = { ... } end,
        }

        local server = net.stack(60)
        net.connect(server, "backhaul", "10.0.0.60/24")
        server:add_route { network = ip("10.64.0.0"), prefix = 16, gateway = ip("10.0.0.1"), source = "static" }

        -- Cells, each with a key of its own, certified by the operator.
        local towers = {}
        for i, position in ipairs(cell_positions) do
            local id = 10 + i
            local stack = options.core_is_cell and i == 1 and core_stack or net.stack(id)
            id = stack.id
            if stack ~= core_stack then net.connect(stack, "backhaul", "10.0.0." .. (10 + i) .. "/24") end
            net.connect(stack, "air", nil, "wireless")
            positions[id] = position

            local cell_private, cell_public = crypto.generateKeyPair("ed25519")
            local cert = certificate.encode(certificate.issue {
                name = common.cell_name("ACME", id), key = cell_public, expires = now() + 86400000, issuer = signing_public,
                sign = function(data) return crypto.sign(signing_private, data) end,
            })

            local tower
            local cell_address = stack.interfaces.backhaul.address
            local tunnel_key = core:add_tower(id, cell_address, function(message)
                stack:schedule(0.01, function() if towers[i] then tower:control(copy(message)) end end)
            end)
            tower = cell_tower.new {
                stack = stack, crypto = crypto, interface = "air", network = "ACME", area = 1, certificate = cert,
                sign = function(data) return crypto.sign(cell_private, data) end, epoch = now,
                core = ip("10.0.0.1"), tunnel_key = tunnel_key,
                control = function(message) core_stack:schedule(0.01, function() core:control(id, copy(message)) end) end,
            }
            towers[i] = { id = id, stack = stack, tower = tower }
        end

        local function add_phone(id, position, subscribed, phone_options)
            phone_options = phone_options or {}
            local stack = net.stack(id)
            net.connect(stack, "air", nil, "wireless")
            positions[id] = position
            local sim = x25519()
            if subscribed ~= false then subscribers[hex(sim.public)] = { id = "ACME-" .. id, number = tostring(id) } end
            local phone = cell_phone.new {
                stack = stack, crypto = crypto, interface = "air", epoch = now, sim = sim,
                operator = phone_options.activated ~= false and { network = "ACME", key = operator_key.public, signing = signing_public } or nil,
                on_message = phone_options.on_message, on_activated = phone_options.on_activated,
            }
            return phone, stack
        end

        return {
            net = net, core = core, core_stack = core_stack, server = server, towers = towers, positions = positions,
            events = events, add_phone = add_phone, signing_public = signing_public, now = now,
            operator_key = operator_key, subscribers = subscribers,
        }
    end

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

        local phone = setup.add_phone(1, 0)
        setup.net.advance(5)
        expect(phone.cells[66]):eq(nil)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(11)
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

    it("works with the core on one of the cells", function()
        local setup = operator({ 0, 100 }, { core_is_cell = true })
        local phone, stack = setup.add_phone(1, 5)
        setup.net.advance(5)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(50)
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)
end)
