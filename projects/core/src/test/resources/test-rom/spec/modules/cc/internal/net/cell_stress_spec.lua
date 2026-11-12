-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cellular networks on bad radio links, with cells and cores which restart, and with computers which misbehave.
Whatever happens, a phone with coverage ends up with service again by itself, messages arrive once, and nothing grows
without limit. ]]

describe("Cellular networks, under stress,", function()
    local codec = require "cc.net.codec"
    local address = require "cc.net.address"
    local tcp = require "cc.internal.net.tcp"
    local common = require "cc.internal.net.cell.common"
    local noise = require "cc.internal.net.noise"
    local cell_core = require "cc.internal.net.cell.core"
    local cell_network = require "support.cell_network"
    local operator, x25519 = cell_network.operator, cell_network.x25519

    local function ip(text) return (address.parse(text)) end
    local function copy(value) return codec.decode(codec.encode(value)) end
    local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

    local function count(list)
        local total = 0
        for _ in pairs(list) do total = total + 1 end
        return total
    end

    local NIL = {}
    local recursive = {}
    recursive.self = recursive
    local BAD = {
        { "nil", NIL }, { "NaN", 0 / 0 }, { "inf", math.huge }, { "-inf", -math.huge }, { "1e18", 1e18 },
        { "-1", -1 }, { "0.5", 0.5 }, { "2^32", 2 ^ 32 }, { "a string", "x" }, { "a table", {} }, { "true", true },
        { "a recursive table", recursive }, { "a long string", ("y"):rep(5000) },
    }

    local function with(template, key, value)
        local result = {}
        for k, v in pairs(template) do result[k] = v end
        if value == NIL then result[key] = nil else result[key] = value end
        return result
    end

    local yield = require "support.yield"

    -- Let time pass until something is true, or fail. (The test may take time itself, such as to wait for a ping.)
    local function wait_until(setup, test, limit, what)
        local deadline = setup.net.time + (limit or 30)
        while setup.net.time < deadline do
            if test() then return end
            setup.net.advance(0.1)
            yield()
        end
        error(("%s didn't happen within %d seconds"):format(what or "Something", limit or 30), 2)
    end

    local function reaches_server(setup, stack)
        local result = setup.net.ping(stack, ip("10.0.0.60"), nil, 1)
        return result ~= nil and result.error == nil
    end

    -- A frame on the air which says it's from a computer it isn't from.
    local function spoof(setup, target, src, body)
        setup.net.inject("air", target.interfaces.air.unicast, { net = 1, src = src, dst = target.id, type = common.FRAME, body = body })
    end

    describe("with someone pretending to be a phone's cell,", function()
        -- Run something each time a phone sends its cell a message of some kind. What it puts on the air arrives
        -- before the cell's answer does.
        local function after_sending(phone, op, fn)
            local to_cell, count = phone.to_cell, 0
            phone.to_cell = function(self, cell, message)
                to_cell(self, cell, message)
                if message.op == op then
                    count = count + 1
                    fn(message)
                end
            end
            return function() return count end
        end

        it("phones still attach", function()
            -- Before a phone has attached, nothing its cell sends can be checked but the handshake's answer itself. So
            -- anything else which claims to be an answer mustn't stop the real one being heard.
            math.randomseed(1)
            local setup = operator { 0 }
            local phone, stack = setup.add_phone(1, 10)
            local stranger = x25519()
            local tries = after_sending(phone, "attach", function()
                spoof(setup, stack, 11, { op = "reject", reason = "Go away" })
                spoof(setup, stack, 11, { op = "attach_reply", handshake = ("x"):rep(96) })
                spoof(setup, stack, 11, { op = "attach_reply", handshake = "" })
                spoof(setup, stack, 11, { op = "accept", sealed = { ctr = 1, ct = ("x"):rep(40) } })
                -- And a request to attach which says it's from the phone, but is someone else's: the core answers
                -- it too (by refusing it).
                local handshake = noise.new {
                    crypto = crypto, pattern = "IK", initiator = true, prologue = cell_core.PROLOGUE .. "ACME",
                    static = stranger, remote_static = setup.operator_key.public,
                }
                spoof(setup, setup.towers[1].stack, 1, { op = "attach", network = "ACME", handshake = handshake:write(codec.encode({ v = 1 })) })
            end)
            setup.net.advance(4)
            expect(tries()):eq(1)
            expect(phone.state):eq("attached")
            expect(reaches_server(setup, stack)):eq(true)
            expect(setup.net.errors):same {}
        end)

        it("phones are still activated", function()
            math.randomseed(2)
            local setup = operator { 0 }
            local code = setup.core:add_code("ACME-0007", "0007")
            local phone, stack = setup.add_phone(1, 10, false, { activated = false })
            setup.net.advance(3)
            local tries = after_sending(phone, "activate", function()
                spoof(setup, stack, 11, { op = "activate_reply", handshake = ("x"):rep(120) })
                spoof(setup, stack, 11, { op = "activate_accept", data = ("x"):rep(120) })
            end)
            after_sending(phone, "activate_finish", function()
                spoof(setup, stack, 11, { op = "activate_accept", data = ("x"):rep(120) })
            end)
            assert(phone:activate("ACME", code))
            setup.net.advance(8)
            expect(tries()):eq(1)
            expect(phone.activation_error):eq(nil)
            expect(phone.state):eq("attached")
            expect(phone.subscriber):same { id = "ACME-0007", number = "0007" }
        end)

        it("phones ignore every kind of frame with something unexpected in it", function()
            local setup = operator { 0 }
            local phone, stack = setup.add_phone(1, 10)
            setup.net.advance(5)
            expect(phone.state):eq("attached")

            local template = {
                network = "ACME", handshake = "h", data = "d", tag = "TAG1", cell = 11, area = 1, load = 0, time = setup.now(),
                sealed = { ctr = 1, ct = "c" }, cert = "c", sig = ("s"):rep(64), reason = "r", path = { 1 },
            }
            local ops = {
                "sib", "attach_reply", "accept", "data", "handover", "reject", "activate_reply", "activate_accept", "nonsense",
            }
            local sent = 0
            for _, op in ipairs(ops) do
                for field in pairs(template) do
                    for _, bad in ipairs(BAD) do
                        local message = with(template, field, bad[2])
                        message.op = op
                        -- From its cell, and (for system information) as a broadcast from anyone.
                        spoof(setup, stack, 11, message)
                        setup.net.inject("air", stack.interfaces.air.broadcast, {
                            net = 1, src = 77, dst = -1, type = common.FRAME, body = with(message, "cell", 77),
                        })
                        sent = sent + 2
                    end
                end
                setup.net.advance(0.3)
                yield()
            end
            -- Frames whose sender isn't a computer's ID at all.
            for _, bad in ipairs(BAD) do
                if bad[2] ~= NIL then
                    setup.net.inject("air", stack.interfaces.air.broadcast, {
                        net = 1, src = bad[2], dst = -1, type = common.FRAME, body = with(template, "op", "sib"),
                    })
                end
            end
            setup.net.advance(2)

            expect(sent > 1000):eq(true)
            expect(setup.net.errors):same {}
            expect(phone.state):eq("attached")
            expect(reaches_server(setup, stack)):eq(true)
        end)
    end)

    describe("with cells and a core which send odd things,", function()
        it("phones ignore sealed messages with something unexpected in them", function()
            -- A phone's cell has the key they share, so can send it anything. A phone doesn't choose its operator's
            -- software, and a cell mustn't be able to break a phone, only refuse to serve it.
            local setup = operator { 0 }
            local inbox = {}
            local phone, stack = setup.add_phone(1, 10, true, { on_message = function(from, text) inbox[#inbox + 1] = { from, text } end })
            setup.net.advance(5)
            local sealer = setup.towers[1].tower.phones[1].sealer

            local values = {}
            for _, bad in ipairs(BAD) do
                local value = bad[2]
                if value ~= NIL and value ~= recursive then
                    values[#values + 1] = value
                    values[#values + 1] = { p = value }
                    values[#values + 1] = { sms = value }
                    values[#values + 1] = { target = value }
                    values[#values + 1] = { address = value }
                    values[#values + 1] = { sms = { id = value, from = "5", text = "id is " .. bad[1] } }
                    values[#values + 1] = { sms = { id = 900, from = value, text = "x" } }
                    values[#values + 1] = { sms = { id = 901, from = "5", text = value } }
                    values[#values + 1] = { p = codec.encode(value) }
                end
            end
            values[#values + 1] = { sms = { from = "5", text = "no id" } }
            for i, value in ipairs(values) do
                for _, op in ipairs { "data", "handover", "accept" } do
                    setup.towers[1].stack:send_frame("air", 1, common.FRAME, { op = op, sealed = sealer:seal(value) })
                end
                if i % 20 == 0 then setup.net.advance(0.2) end
            end
            setup.net.advance(2)

            expect(setup.net.errors):same {}
            expect(phone.state):eq("attached")
            expect(phone.cell):eq(11)
            expect(reaches_server(setup, stack)):eq(true)
            -- Messages are only shown if they're whole: a sender and text.
            for _, message in ipairs(inbox) do
                expect(type(message[1])):eq("string")
                expect(type(message[2])):eq("string")
            end
        end)

        it("cells and the core ignore sealed messages from phones with something unexpected in them", function()
            local setup = operator { 0, 100 }
            local phone, stack = setup.add_phone(1, 10)
            setup.net.advance(5)

            local values = {}
            for _, bad in ipairs(BAD) do
                local value = bad[2]
                if value ~= NIL and value ~= recursive then
                    for _, made in ipairs {
                        value, { p = value }, { sms = value }, { sms = { to = value, text = "x" } }, { sms = { to = "2", text = value } },
                        { sms_ack = value }, { target = value }, { confirm = value }, { p = codec.encode(value) },
                    } do
                        values[#values + 1] = made
                    end
                end
            end
            for i, value in ipairs(values) do
                for _, op in ipairs { "data", "confirm" } do
                    stack:send_frame("air", 11, common.FRAME, { op = op, sealed = phone.here.sealer:seal(value) })
                end
                if i % 20 == 0 then setup.net.advance(0.2) end
            end
            setup.net.advance(2)

            expect(setup.net.errors):same {}
            expect(phone.state):describe("The phone's state"):eq("attached")
            expect(reaches_server(setup, stack)):describe("Reaches the server"):eq(true)
            -- Nobody has the numbers those messages were for.
            expect(#setup.core.messages):describe("Messages kept"):eq(0)
        end)

        it("the core ignores control messages with something unexpected in them", function()
            local setup = operator { 0, 100 }
            local phone, stack = setup.add_phone(1, 10)
            setup.net.advance(5)
            local session = setup.core.sessions[hex(phone.sim.public)]
            setup.core:add_code("ACME-0009", "0009")
            local tag = next(setup.core.codes)

            local template = {
                phone = 1, teid = session.teid, handshake = ("h"):rep(96), data = ("d"):rep(40), target = 12, tag = tag,
                to = "2", text = "hello", id = 1,
            }
            local ops = { "attach", "attach_complete", "handover", "path_switch", "activate", "activate_finish", "sms", "sms_ack", "nonsense" }
            local failures = {}
            for _, op in ipairs(ops) do
                for field in pairs(template) do
                    for _, bad in ipairs(BAD) do
                        local message = with(template, field, bad[2])
                        message.op = op
                        for _, from in ipairs { 11, 12, 99 } do
                            local ok, err = pcall(setup.core.control, setup.core, from, message)
                            if not ok then failures[#failures + 1] = ("%s with %s = %s: %s"):format(op, field, bad[1], tostring(err)) end
                        end
                    end
                end
                setup.net.advance(0.2)
                yield()
            end
            for _, bad in ipairs(BAD) do
                local ok, err = pcall(setup.core.control, setup.core, 11, bad[2] ~= NIL and bad[2] or nil)
                if not ok then failures[#failures + 1] = ("A message of %s: %s"):format(bad[1], tostring(err)) end
            end
            expect(failures):same {}
            setup.net.advance(15)
            expect(setup.net.errors):same {}

            -- The phone may have been moved about by all that, but it has service.
            wait_until(setup, function() return phone.state == "attached" and reaches_server(setup, stack) end, 60, "Service")
        end)

        it("cells ignore control messages with something unexpected in them", function()
            local setup = operator { 0 }
            local phone, stack = setup.add_phone(1, 10)
            setup.net.advance(5)
            local tower = setup.towers[1].tower
            local context = tower.phones[1]

            local template = {
                phone = 1, teid = context.teid, handshake = "h", data = "d", reason = "r", key = ("k"):rep(32), address = ip("10.64.0.9"),
                handover = true, target = 12, path = { 1 }, id = 1, from = "2", text = "hello",
            }
            local ops = {
                "attach_reply", "reject", "activate_reply", "activate_accept", "sms", "handover_go", "path", "nonsense",
            }
            local failures = {}
            for _, op in ipairs(ops) do
                for field in pairs(template) do
                    for _, bad in ipairs(BAD) do
                        local message = with(template, field, bad[2])
                        message.op = op
                        local ok, err = pcall(tower.control, tower, message)
                        if not ok then failures[#failures + 1] = ("%s with %s = %s: %s"):format(op, field, bad[1], tostring(err)) end
                    end
                end
            end
            -- Contexts for other phones, with bad fields.
            for field in pairs(template) do
                for _, bad in ipairs(BAD) do
                    local message = with(with(template, "phone", 2), field, bad[2])
                    message.op, message.teid = "context", message.teid ~= context.teid and message.teid or 5
                    local ok, err = pcall(tower.control, tower, message)
                    if not ok then failures[#failures + 1] = ("context with %s = %s: %s"):format(field, bad[1], tostring(err)) end
                end
            end
            expect(failures):same {}
            setup.net.advance(3)
            expect(setup.net.errors):same {}
            wait_until(setup, function() return phone.state == "attached" and reaches_server(setup, stack) end, 60, "Service")
        end)
    end)

    describe("on a bad radio link,", function()
        it("phones attach, and keep a connection open while moving from cell to cell", function()
            math.randomseed(4)
            local setup = operator { 0, 100, 200 }
            setup.net.loss.air = 0.15
            local phone, stack = setup.add_phone(1, 0)
            wait_until(setup, function() return phone.state == "attached" end, 60, "Attaching")

            local listener = assert(tcp.listen(setup.server, 80))
            local client = assert(tcp.connect(stack, ip("10.0.0.60"), 80))
            local server
            wait_until(setup, function()
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
            for step = 1, 200 do
                setup.positions[1] = step
                if client:send(sent + 1) then sent = sent + 1 end
                setup.net.advance(0.5)
                drain()
            end
            -- At the far end, with only the last cell in range, everything gets through.
            wait_until(setup, function()
                while client:send(sent + 1) do sent = sent + 1 end
                drain()
                return phone.state == "attached" and phone.cell == 13 and #got >= 200
            end, 120, "Delivering everything")
            expect(client.error):eq(nil)
            for i, value in ipairs(got) do expect(value):eq(i) end
            expect(setup.net.errors):same {}
        end)

        it("phones aren't left without service by a lost frame, anywhere in a handover", function()
            -- Walk back and forth between two cells, many times. Each time the phone ends up on the nearer cell, and
            -- can reach the network.
            math.randomseed(6)
            local setup = operator { 0, 100 }
            setup.net.loss.air = 0.25
            local phone, stack = setup.add_phone(1, 0)
            wait_until(setup, function() return phone.state == "attached" end, 60, "Attaching")

            for trip = 1, 12 do
                local to = trip % 2 == 1 and 100 or 0
                local cell = trip % 2 == 1 and 12 or 11
                for step = 1, 20 do
                    setup.positions[1] = (100 - to) + (to - (100 - to)) * step / 20
                    setup.net.advance(0.5)
                end
                wait_until(setup, function()
                    return phone.state == "attached" and phone.cell == cell and reaches_server(setup, stack)
                end, 60, "Service on trip " .. trip)
            end
            expect(setup.net.errors):same {}
        end)

        it("messages aren't lost, or delivered twice", function()
            math.randomseed(8)
            local setup = operator { 0 }
            setup.net.loss.air = 0.25
            local inbox = {}
            local a = setup.add_phone(1, 10)
            local b = setup.add_phone(2, 20, true, { on_message = function(from, text) inbox[#inbox + 1] = from .. ": " .. text end })
            wait_until(setup, function() return a.state == "attached" and b.state == "attached" end, 60, "Attaching")

            local expected = {}
            for i = 1, 30 do
                assert(a:send_message("2", "message " .. i))
                expected[i] = "1: message " .. i
                setup.net.advance(0.3)
            end
            wait_until(setup, function() return #inbox >= 30 end, 180, "Delivering 30 messages")
            setup.net.advance(60)
            table.sort(inbox)
            table.sort(expected)
            expect(inbox):same(expected)
            expect(#setup.core.messages):eq(0)
        end)
    end)

    describe("when things restart,", function()
        it("phones find out their cell has forgotten them, and attach again", function()
            math.randomseed(9)
            local setup = operator { 0 }
            local phone, stack = setup.add_phone(1, 10)
            setup.net.advance(5)
            expect(reaches_server(setup, stack)):eq(true)
            local addr = stack.interfaces.cell.address

            -- The cell restarts, and is back before the phone would notice it had gone quiet.
            setup.restart_cell(1)
            wait_until(setup, function() return phone.state == "attached" and reaches_server(setup, stack) end, 30, "Service")
            expect(stack.interfaces.cell.address):eq(addr)
            expect(setup.net.errors):same {}
        end)

        it("phones find out the core has forgotten them, and attach again", function()
            math.randomseed(10)
            local setup = operator { 0, 100 }
            local a, a_stack = setup.add_phone(1, 10)
            local b, b_stack = setup.add_phone(2, 90)
            setup.net.advance(5)
            expect(reaches_server(setup, a_stack) and reaches_server(setup, b_stack)):eq(true)

            setup.restart_core()
            wait_until(setup, function()
                return a.state == "attached" and b.state == "attached" and reaches_server(setup, a_stack) and reaches_server(setup, b_stack)
            end, 30, "Service")
            -- Phones can reach each other again, too.
            local result = setup.net.ping(a_stack, b_stack.interfaces.cell.address, nil, 3)
            expect(result and result.error):eq(nil)
            expect(setup.net.errors):same {}
        end)

        it("messages still arrive after the core restarts, though it numbers them from the start again", function()
            math.randomseed(11)
            local setup = operator { 0 }
            local inbox = {}
            local a = setup.add_phone(1, 10)
            local b = setup.add_phone(2, 20, true, { on_message = function(_, text) inbox[#inbox + 1] = text end })
            setup.net.advance(5)
            for i = 1, 3 do assert(a:send_message("2", "before " .. i)) end
            setup.net.advance(5)
            expect(#inbox):eq(3)

            setup.restart_core()
            wait_until(setup, function() return a.state == "attached" and b.state == "attached" end, 30, "Service")
            for i = 1, 3 do assert(a:send_message("2", "after " .. i)) end
            wait_until(setup, function() return #inbox >= 6 end, 60, "Delivering messages")
            table.sort(inbox)
            expect(inbox):same { "after 1", "after 2", "after 3", "before 1", "before 2", "before 3" }
        end)
    end)

    describe("with many phones, messages and cells,", function()
        it("serves sixty phones through one cell", function()
            math.randomseed(12)
            local setup = operator { 0 }
            local phones = {}
            for i = 1, 60 do
                local phone, stack = setup.add_phone(100 + i, i % 20)
                phones[i] = { phone = phone, stack = stack }
            end
            wait_until(setup, function()
                for _, entry in ipairs(phones) do
                    if entry.phone.state ~= "attached" then return false end
                end
                return true
            end, 60, "Sixty phones attaching")

            local addresses = {}
            for i, entry in ipairs(phones) do
                local addr = entry.stack.interfaces.cell.address
                expect(addresses[addr]):describe("Phone " .. i .. "'s address"):eq(nil)
                addresses[addr] = true
                if i % 6 == 0 then expect(reaches_server(setup, entry.stack)):describe("Phone " .. i):eq(true) end
            end
            -- Tunnel IDs are all different, however the dice fall.
            expect(count(setup.core.by_teid)):eq(60)
            expect(count(setup.towers[1].tower.links.ACME.by_teid)):eq(60)
            expect(setup.net.errors):same {}
        end)

        it("never gives two phones the same tunnel", function()
            -- Tunnel IDs are picked at random. Make every pick the same, and they must still differ.
            local setup = operator { 0 }
            local a, a_stack = setup.add_phone(1, 10)
            local b, b_stack = setup.add_phone(2, 12)
            local random = math.random
            local ok, err = pcall(function()
                local same = 0
                math.random = function(low, high) -- luacheck: ignore
                    if low == 1 and high == 0x7FFFFFFF and same < 2 then
                        same = same + 1
                        return 4
                    end
                    return random(low, high)
                end
                setup.net.advance(8)
            end)
            math.random = random -- luacheck: ignore
            if not ok then error(err, 0) end

            expect(a.state):eq("attached")
            expect(b.state):eq("attached")
            expect(count(setup.core.by_teid)):eq(2)
            expect(reaches_server(setup, a_stack) and reaches_server(setup, b_stack)):eq(true)
        end)

        it("keeps a limited number of messages for phones which can't be reached", function()
            local setup = operator { 0 }
            local taken, refused = 0, {}
            local a = setup.add_phone(1, 10, true, {
                on_sent = function(_, ok, reason)
                    if ok then taken = taken + 1 else refused[reason] = (refused[reason] or 0) + 1 end
                end,
            })
            setup.subscribers[("ab"):rep(32)] = { id = "ACME-2", number = "2" }
            setup.net.advance(5)

            -- To a subscriber who is never there, and to numbers nobody has. The phone is told what became of each.
            local sent = 0
            for i = 1, 400 do
                if a:send_message("2", "are you there? " .. i) then sent = sent + 1 end
                if a:send_message(tostring(1000 + i), "wrong number") then sent = sent + 1 end
                setup.net.advance(0.1)
            end
            setup.net.advance(5)
            expect(#a.outbox):eq(0)
            expect(taken):eq(50)
            expect(#setup.core.messages):eq(50)
            expect(refused["Too many messages are waiting for 2"]):eq(350)
            expect(taken + 350 + 400):eq(sent)
            expect(setup.net.errors):same {}

            -- A phone which doesn't wait to be told can only have so many messages on their way.
            local accepted = 0
            for i = 1, 100 do
                if a:send_message("2", "all at once " .. i) then accepted = accepted + 1 end
            end
            expect(accepted):eq(20)
            expect({ a:send_message("2", "one more") }):same { nil, "Too many messages are waiting to be sent" }
            setup.net.advance(5)
            expect(#a.outbox):eq(0)
            expect(#setup.core.messages):eq(50)

            -- Messages nobody collects are forgotten after a week. (Skip the week, rather than live through it.)
            setup.net.time = setup.net.time + 8 * 24 * 60 * 60
            setup.net.advance(15)
            expect(#setup.core.messages):eq(0)
        end)

        it("forgets activations which never finish", function()
            local setup = operator { 0 }
            local code = setup.core:add_code("ACME-0009", "0009")
            local tag = code:sub(1, 4)
            -- A real phone's first message, sent again as if from 2,000 phones.
            local phone = setup.add_phone(1, 10, false, { activated = false })
            setup.net.advance(2)
            assert(phone:activate("ACME", code))
            local first
            for _, item in ipairs(setup.net.queue) do
                local body = item.frame.body
                if item.frame.type == common.FRAME and type(body) == "table" and body.op == "activate" then first = copy(body) end
            end
            expect(first ~= nil):eq(true)
            expect(first.tag):eq(tag)
            for id = 1000, 2999 do
                setup.core:control(11, { op = "activate", phone = id, tag = tag, handshake = first.handshake })
            end
            expect(count(setup.core.activating) <= 64):describe(count(setup.core.activating) .. " activations kept"):eq(true)

            -- The real phone still gets through.
            setup.net.advance(10)
            if phone.state ~= "attached" then
                assert(phone:activate("ACME", code))
                setup.net.advance(10)
            end
            expect(phone.state):eq("attached")
            setup.net.advance(120)
            expect(count(setup.core.activating)):eq(0)
        end)

        it("phones remember the strongest cells when hundreds are about", function()
            -- Anyone can send system information. A phone only remembers so many cells, and they should be the ones
            -- it can use: with 300 made-up cells further away, it still finds the real one.
            local setup = operator { 0 }
            local code = setup.core:add_code("ACME-0010", "0010")
            -- Made-up frames aren't sent from anywhere: say how strongly they're heard.
            local reach = setup.net.reach
            setup.net.reach = function(link, sender, receiver)
                if not sender then return -85 end
                return reach(link, sender, receiver)
            end
            local phone = setup.add_phone(1, 10, false, { activated = false })
            for _ = 1, 6 do
                for id = 2000, 2299 do
                    setup.net.inject("air", phone.stack.interfaces.air.broadcast, {
                        net = 1, src = id, dst = -1, type = common.FRAME,
                        body = {
                            op = "sib", cell = id, area = 1, load = 0, time = setup.now(),
                            networks = { { network = "FAKE" .. id % 7 }, { network = "FAKE" .. id % 5 } },
                        },
                    })
                end
                setup.net.advance(1)
            end

            expect(count(phone.heard) <= 32):eq(true)
            local info = phone:info()
            local found = false
            for _, name in ipairs(info.networks) do found = found or name == "ACME" end
            expect(found):describe("The real network is listed"):eq(true)
            assert(phone:activate("ACME", code))
            setup.net.advance(10)
            expect(phone.state):eq("attached")
        end)
    end)
end)
