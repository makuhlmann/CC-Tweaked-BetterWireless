-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Cellular networks", function()
    local helpers = require "support.net_helpers"
    local address = require "cc.net.address"
    local tcp = require "cc.internal.net.tcp"
    local certificate = require "cc.internal.net.certificate"
    local common = require "cc.internal.net.cell.common"
    local message = require "cc.internal.net.message"

    local ip = helpers.ip
    -- A phone's events, without their times.
    local function event_kinds(phone)
        local result = {}
        for i, event in ipairs(phone:info().events) do
            event.time = nil
            result[i] = event
        end
        return result
    end
    local hex = helpers.hex
    local copy = helpers.copy

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
        -- It tries again every so often, so wait for a refusal.
        for _ = 1, 50 do
            if phone.state == "rejected" then break end
            setup.net.advance(0.1)
        end
        expect(phone.state):eq("rejected")
        expect(phone.rejected):eq("Not a subscriber of ACME")
        expect(phone.address):eq(nil)
    end)

    it("says when the cells around speak a newer version of the network than it does", function()
        -- Its own network's cell is out of reach: there's only a newer one, which says things this phone can't read.
        local setup = operator { 1000 }
        local newer = setup.net.stack(66)
        local radio = setup.radio(newer)
        setup.positions[66] = 0
        for t = 0, 4 do
            newer:schedule(t, function()
                newer:send_frame(radio, -1, common.FRAME, { op = "sib", v = common.VERSION + 1, cell = 66, layout = "new" })
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
            ul = 8320, interval = 1,
        }
        expect(sib.v):eq(common.VERSION)
        expect({ common.is_newer(common.VERSION), common.is_newer(common.VERSION + 1), common.is_newer("3") }):same {
            false, true, false,
        }
    end)

    it("checks a cell's certificate once, until it expires", function()
        local operator_private, operator_public = crypto.generateKeyPair("ed25519")
        local cell_private, cell_public = crypto.generateKeyPair("ed25519")
        local now = 1.7e12
        local cert = certificate.encode(certificate.issue {
            name = common.cell_name("ACME", 5), key = cell_public, expires = now + 60000, issuer = operator_public,
            sign = function(data) return crypto.sign(operator_private, data) end,
        })
        local function sib(time, load)
            return common.make_sib {
                network = "ACME", cell = 5, area = 1, load = load or 0, time = time, certificate = cert,
                sign = function(data) return crypto.sign(cell_private, data) end, ul = 8320, interval = 1,
            }
        end

        local verified = 0
        local counting = setmetatable({
            verify = function(...)
                verified = verified + 1
                return crypto.verify(...)
            end,
        }, { __index = crypto })
        local store = common.new_certificates()
        local function check(message, at)
            return common.check_sib(counting, message, message.networks[1], {
                network = "ACME", signing = operator_public, now = at, sender = 5, certificates = store,
            })
        end

        -- The certificate, then the signature: and from then on, only the signature.
        expect(check(sib(now), now)):eq(true)
        expect(verified):eq(2)
        expect(check(sib(now + 1000), now + 1000)):eq(true)
        expect(verified):eq(3)
        -- The same again, as a cell sends it until something in it changes: nothing more to check.
        expect(check(sib(now + 1000), now + 1500)):eq(true)
        expect(verified):eq(3)
        -- A signature which doesn't match still doesn't.
        local forged = sib(now + 2000)
        forged.load = 1
        expect({ check(forged, now + 2000) }):same { nil, "bad signature" }
        expect(verified):eq(4)
        -- Nor does the signature of the one checked before, with only the time changed.
        forged = sib(now + 1000)
        forged.time = now + 2500
        expect({ check(forged, now + 2500) }):same { nil, "bad signature" }
        expect(verified):eq(5)
        -- And the one which checked out still needn't be checked again.
        expect(check(sib(now + 1000), now + 3000)):eq(true)
        expect(verified):eq(5)
        -- Once the certificate has expired, it's checked again, and refused.
        expect({ check(sib(now + 61000), now + 61000) }):same { nil, "certificate has expired" }
    end)

    it("signs system information again only once more than the time changes, or it's old", function()
        local signed = 0
        local base = {
            network = "ACME", cell = 5, area = 1, load = 0, time = 1.7e12, certificate = "c", ul = 8320, interval = 1,
            path = { 7 }, carriers = { 8300 },
            sign = function()
                signed = signed + 1
                return ("s"):rep(63) .. string.char(signed)
            end,
        }
        local function make(changes, last)
            local options = {}
            for key, value in pairs(base) do options[key] = value end
            for key, value in pairs(changes) do options[key] = value end
            return common.make_sib(options, last)
        end

        local first, last = make {}
        expect(signed):eq(1)
        -- A moment later, with nothing but the time changed, the same table again, still with the time it was signed.
        local again, still = make({ time = base.time + 1000 }, last)
        expect(again):eq(first)
        expect(still):eq(last)
        expect(again.time):eq(base.time)
        expect(signed):eq(1)
        expect(make({ time = base.time + common.SIB_RESIGN - 1 }, last)):eq(first)
        expect(signed):eq(1)

        -- Anything else changed is signed afresh.
        for _, change in ipairs {
            { load = 1 / 32 }, { area = 2 }, { ul = 8321 }, { interval = 2 }, { pos = { 1, 2, 3 } }, { service = "sms" },
            { name = "HILL" }, { certificate = "d" }, { path = { 8 } }, { path = {} }, { carriers = { 8350 } },
            { network = "BETA" }, { cell = 6 },
        } do
            change.time = base.time + 2000
            local before = signed
            local changed = make(change, last)
            expect(changed == first):describe(textutils.serialise(change)):eq(false)
            expect(changed.time):eq(base.time + 2000)
            expect(signed):describe(textutils.serialise(change)):eq(before + 1)
        end

        -- And so is the same, once it was signed ten seconds ago, or if the clock went back.
        local before = signed
        local renewed, next_last = make({ time = base.time + common.SIB_RESIGN }, last)
        expect(renewed == first):eq(false)
        expect(renewed.time):eq(base.time + common.SIB_RESIGN)
        expect(signed):eq(before + 1)
        expect(make({ time = base.time + common.SIB_RESIGN + 500 }, next_last)):eq(renewed)
        expect(make({ time = base.time - 1 }, last) == first):eq(false)
        expect(signed):eq(before + 2)
    end)

    it("ignores cells without a certificate from the operator", function()
        local setup = operator { 80 }
        -- A rogue tower, closer, with a certificate it made itself.
        local rogue = setup.net.stack(66)
        local rogue_radio = setup.radio(rogue)
        setup.positions[66] = 0
        local rogue_private, rogue_public = crypto.generateKeyPair("ed25519")
        local fake = certificate.encode(certificate.issue {
            name = common.cell_name("ACME", 66), key = rogue_public, expires = setup.now() + 1e9, issuer = rogue_public,
            sign = function(data) return crypto.sign(rogue_private, data) end,
        })
        for t = 0, 4 do
            rogue:schedule(t, function()
                rogue:send_frame(rogue_radio, -1, common.FRAME, common.make_sib {
                    network = "ACME", cell = 66, area = 1, load = 0, time = setup.now(), certificate = fake,
                    sign = function(data) return crypto.sign(rogue_private, data) end, ul = setup.uplink, interval = 1,
                })
            end)
        end

        -- And a cell of another network.
        local other = setup.net.stack(77)
        local other_radio = setup.radio(other)
        setup.positions[77] = 40
        local other_private, other_public = crypto.generateKeyPair("ed25519")
        local other_certificate = certificate.encode(certificate.issue {
            name = common.cell_name("BETA", 77), key = other_public, expires = setup.now() + 1e9, issuer = other_public,
            sign = function(data) return crypto.sign(other_private, data) end,
        })
        for t = 0, 4 do
            other:schedule(t, function()
                other:send_frame(other_radio, -1, common.FRAME, common.make_sib {
                    network = "BETA", cell = 77, area = 2, load = 0.5, time = setup.now(), certificate = other_certificate,
                    sign = function(data) return crypto.sign(other_private, data) end, ul = setup.uplink - 1, interval = 1,
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

    it("is handed over to a cell which will do, before a stronger one which didn't answer it lately", function()
        math.randomseed(3)
        local setup = operator { 0, 120, 150 }
        local phone = setup.add_phone(1, 0)
        setup.net.advance(5)
        expect({ phone.state, phone.cell }):same { "attached", 11 }

        -- An attach through cell 12 got no answer a moment ago: it may not hear the phone. Now the phone hears both 12
        -- and 13 far better than its own cell, 12 the better of the two.
        phone.failed:add(12, { count = 1, time = phone.stack.clock() })
        setup.positions[1] = 95
        setup.net.advance(10)
        expect(event_kinds(phone)[2]):same { kind = "handover", from = 11, to = 13 }
    end)

    it("carries on through another cell when its cell fails, without attaching again", function()
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
        -- Our network knows us, so the other cell asks it to take us, as for a handover.
        expect(event_kinds(phone)):same {
            { kind = "attached", cell = 11 }, { kind = "handover", from = 11, to = 12 },
        }
        -- The cell which went quiet is listed after the ones still heard, until it's forgotten.
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

        setup.inject(setup.towers[1].stack, captured, "cell")
        local changed = copy(captured)
        changed.body.sealed.ct = changed.body.sealed.ct:sub(1, -2) .. "x"
        setup.inject(setup.towers[1].stack, changed, "cell")
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

    -- Two unrelated networks called ACME: this one, with cells 11 (at 0) and 12 (at 20), and another, whose cell 21 (at
    -- 15) is the strongest a phone at 9 hears. Only this one made the code.
    local function same_names()
        local setup = operator { 0, 20 }
        local other = operator({ 15 }, { join = setup, core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16" })
        return setup, other
    end
    -- The cells a phone asks to pass its activation on, in order.
    local function activations_sent(phone)
        local cells, to_cell = {}, phone.to_cell
        function phone.to_cell(self, cell, body)
            if body.op == "activate" then cells[#cells + 1] = cell end
            return to_cell(self, cell, body)
        end
        return cells
    end

    it("activates on the network which made the code, when another has the same name", function()
        math.randomseed(3)
        local setup = same_names()
        -- This network's cell 11 doesn't hear the phone, so it's cell 12 which gets through.
        local reach = setup.net.reach
        setup.net.reach = function(link, sender, receiver)
            if sender and sender.id == 1 and receiver.id == 11 then return false end
            return reach(link, sender, receiver)
        end
        local code = setup.core:add_code("ACME-0007", "0007")
        local activated
        local phone = setup.add_phone(1, 9, false, { activated = false, on_activated = function(info) activated = info end })
        local asked = activations_sent(phone)
        setup.net.advance(3)
        expect(phone:info().networks):same { "ACME" }

        -- The other network's core doesn't know the code, so doesn't answer; nor does cell 11. Cell 12 does.
        assert(phone:activate("ACME", code))
        helpers.wait_until(setup.net, function() return phone.state == "attached" end, 40, "Activating and attaching")
        expect(asked):same { 21, 11, 12 }
        expect(activated.signing):eq(setup.signing_public)
        expect(phone.subscriber):same { id = "ACME-0007", number = "0007" }
        expect(phone.cell):eq(12)

        -- From then on, the other network's cell shows as a fake.
        setup.net.advance(2)
        local verified = {}
        for _, cell in ipairs(phone:info().heard) do verified[cell.id] = cell.verified end
        expect(verified):same { [11] = true, [12] = true, [21] = false }
        expect(setup.net.errors):same {}
    end)

    it("counts a wrong code once, though another network has the same name", function()
        math.randomseed(4)
        local setup = same_names()
        local code = setup.core:add_code("ACME-0008", "0008")
        local tag = code:sub(1, 4)
        local phone = setup.add_phone(1, 9, false, { activated = false })
        local asked = activations_sent(phone)
        setup.net.advance(3)

        -- The other network doesn't answer. This one's cell 11 does, and the core doesn't take the code; so cell 12,
        -- whose core would say the same, isn't asked.
        assert(phone:activate("ACME", tag .. "-0000-0000-0000-0000"))
        helpers.wait_until(setup.net, function() return phone.state == "inactive" end, 30, "Giving up")
        expect(asked):same { 21, 11 }
        expect(phone.activation_error):eq("No answer: check the code")
        expect(setup.core.codes[tag].tries):eq(1)

        -- The right code still works.
        assert(phone:activate("ACME", code))
        helpers.wait_until(setup.net, function() return phone.state == "attached" end, 30, "Activating and attaching")
        expect(asked):same { 21, 11, 21, 11 }
        expect(setup.net.errors):same {}
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

    it("says when it last sent and received a packet, for the status bar, but not for messages", function()
        local setup = operator { 0 }
        local a, a_stack = setup.add_phone(1, 10, true)
        local b = setup.add_phone(2, 20, true)
        setup.net.advance(5)
        local function quiet(phone)
            local info = phone:info()
            return (info.sent_age == nil or info.sent_age > 2) and (info.received_age == nil or info.received_age > 2)
        end

        -- A message, then long enough without anything else that each phone asks its cell whether it still knows it.
        assert(a:send_message("2", "Hello, B"))
        setup.net.advance(12)
        expect({ quiet(a), quiet(b) }):same { true, true }

        expect(setup.net.ping(a_stack, ip("10.0.0.60")).error):eq(nil)
        local info = a:info()
        expect({ info.sent_age < 1, info.received_age < 1 }):same { true, true }
        expect(quiet(b)):eq(true)
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
                    for _, target in ipairs { { setup.towers[1].stack, "cell" }, { stack, "phone" } } do
                        setup.inject(target[1], {
                            net = 1, src = 9, dst = target[1].id, type = common.FRAME, body = message,
                        }, target[2])
                        count = count + 1
                    end
                end
            end
            setup.net.advance(0.2)
        end
        for _, value in ipairs(bad) do
            setup.inject(stack, { net = 1, src = 11, dst = 1, type = common.FRAME, body = value })
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

    it("gives a cell a new tunnel key each time it joins", function()
        -- The same key with counters starting again would seal different packets with the same nonce, and packets
        -- from before could be replayed.
        local setup = operator { 0 }
        setup.net.advance(0.1)
        local first = setup.core:add_tower(99, ip("10.0.0.99"), function() end)
        local second = setup.core:add_tower(99, ip("10.0.0.99"), function() end)
        expect(#first):eq(32)
        expect(first ~= second):eq(true)
    end)

    it("answers a phone attaching again on the beacon channel, whatever its earlier frames say when they arrive", function()
        local setup = operator { 0 }
        local phone, stack = setup.add_phone(1, 5)
        setup.net.advance(5)
        expect(phone.state):eq("attached")
        local tower = setup.towers[1].tower
        local context = tower.phones[stack.id]
        expect(tower:channel_to(stack.id)):eq(context.dl)
        -- The core is elsewhere: only what the cell does with the phone's frames matters here.
        tower.links.ACME.control_send = function() end

        -- A frame saying the phone listens on its own channel, held back on the way...
        local held = phone.here.sealer:seal({ dl = context.dl })
        setup.net.advance(0.5)
        -- ...comes after the phone asks to attach again, when it only listens on the beacon channel.
        tower:radio(stack.id, { op = "attach", network = "ACME", via = "ACME", handshake = "hello" })
        expect(tower:channel_to(stack.id)):eq(tower.carrier)
        tower:radio(stack.id, { op = "data", sealed = held })
        expect(tower:channel_to(stack.id)):eq(tower.carrier)

        -- Someone else may have sent that attach for the phone, which carries on as before: its next frame counts.
        setup.net.advance(0.1)
        tower:radio(stack.id, { op = "data", sealed = phone.here.sealer:seal({ dl = context.dl }) })
        expect(tower:channel_to(stack.id)):eq(context.dl)
    end)

    it("keeps a handed-over phone's confirmation which comes before the core's word", function()
        local setup = operator { 0 }
        -- Once the cell has joined its core.
        setup.net.advance(0.1)
        local tower = setup.towers[1].tower
        local sent = {}
        tower.links.ACME.control_send = function(message) sent[#sent + 1] = message end
        local function confirm(phone, key)
            local sealer = common.new_sealer(crypto, key, common.UPLINK, common.DOWNLINK, tower.epoch)
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
            expect(first.phone.here.candidate):eq(nil)
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
            -- Each phone waits a while for its cell to come back first, as there's no other.
            setup.positions[30] = 130
            wait_until(setup, function() return first.phone.state ~= "attached" and second.phone.state ~= "attached" end, 60)
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
