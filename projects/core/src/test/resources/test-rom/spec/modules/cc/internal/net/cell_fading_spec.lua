-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Cellular phones whose cell goes quiet for a while", function()
    local helpers = require "support.net_helpers"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local ip = helpers.ip

    -- Put a phone out of reach of some cells, both ways, as behind a hill. Returns a function to bring it back.
    local function shadow(setup, phone, cells)
        local reach, hidden = setup.net.reach, {}
        for _, id in ipairs(cells) do hidden[id] = true end
        setup.net.reach = function(link, sender, receiver, ...)
            if sender and ((sender.id == phone and hidden[receiver.id]) or (hidden[sender.id] and receiver.id == phone)) then
                return false
            end
            return reach(link, sender, receiver, ...)
        end
        return function() setup.net.reach = reach end
    end

    -- What happened to a phone since some point, by kind.
    local function kinds_since(phone, count)
        local kinds = {}
        for i = count + 1, #phone.events do kinds[phone.events[i].kind] = (kinds[phone.events[i].kind] or 0) + 1 end
        return kinds
    end

    -- The core's session for a phone.
    local function session_of(setup, id)
        for _, session in pairs(setup.core.by_teid) do
            if session.phone == id then return session end
        end
    end

    -- An attached phone, at 20 along the line, near the first cell.
    local function attached(cells)
        local setup = operator(cells)
        local phone, stack = setup.add_phone(1, 20)
        setup.net.advance(5)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(setup.towers[1].tower.id)
        return setup, phone, stack
    end

    it("stays attached through a short shadow, showing no bars", function()
        local setup, phone, stack = attached { 0 }
        local cell, events = phone.cell, #phone.events

        local back = shadow(setup, stack.id, { cell })
        setup.net.advance(10)
        -- Longer than it used to take to give up on a cell.
        expect(phone.state):eq("attached")
        expect(phone:info().fading):eq(true)

        back()
        setup.net.advance(3)
        expect(phone.state):eq("attached")
        expect(phone:info().fading):eq(nil)
        expect(phone.cell):eq(cell)
        -- It never lost service, nor attached again.
        expect(kinds_since(phone, events)):same {}
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("gives up on a cell which stays quiet, when there's nowhere else to go", function()
        local setup, phone, stack = attached { 0 }
        local events = #phone.events
        shadow(setup, stack.id, { phone.cell })
        setup.net.advance(15)
        expect(phone.state):eq("attached")
        setup.net.advance(10)
        expect(phone.state ~= "attached"):eq(true)
        expect(kinds_since(phone, events).lost):eq(1)
    end)

    it("carries on through another cell when its own goes quiet, without attaching again", function()
        local setup, phone, stack = attached { 0, 60 }
        local first, other = setup.towers[1].tower.id, setup.towers[2].tower.id
        local events = #phone.events

        shadow(setup, stack.id, { first })
        setup.net.advance(6)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(other)
        expect(phone:info().fading):eq(nil)
        expect(kinds_since(phone, events)):same { handover = 1 }
        expect(session_of(setup, stack.id).cell):eq(other)
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("attaches again when its network doesn't know it any more", function()
        local setup, phone, stack = attached { 0, 60 }
        local session = session_of(setup, stack.id)
        -- The core forgets the phone (as when it restarts), but the cells don't.
        setup.core.by_teid[session.teid] = nil
        local events = #phone.events

        shadow(setup, stack.id, { phone.cell })
        setup.net.advance(10)
        expect(phone.state):eq("attached")
        expect(phone.cell):eq(setup.towers[2].tower.id)
        local kinds = kinds_since(phone, events)
        expect(kinds.lost):eq(1)
        expect(kinds.attached):eq(1)
    end)

    it("isn't made to attach again by someone else's refusal", function()
        local setup, phone, stack = attached { 0, 60 }
        local first, other = setup.towers[1].tower.id, setup.towers[2].tower.id
        -- Whenever the phone asks a cell to take it, someone says no in that cell's name, before the cell answers.
        local to_cell, asked = phone.to_cell, 0
        phone.to_cell = function(self, cell, message)
            to_cell(self, cell, message)
            if message.op == "resume" then
                asked = asked + 1
                setup.inject(stack, {
                    net = 1, src = cell, dst = stack.id, type = common.FRAME, body = { op = "reject", reason = "Go away" },
                })
            end
        end
        local events = #phone.events

        shadow(setup, stack.id, { first })
        setup.net.advance(6)
        expect(asked):eq(1)
        expect(phone.cell):eq(other)
        expect(kinds_since(phone, events)):same { handover = 1 }
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("goes where it asked to resume, if the answer comes after its own cell is back", function()
        local setup, phone, stack = attached { 0, 60 }
        local first, other = setup.towers[1].tower.id, setup.towers[2].tower.id
        -- The core is slow to get the request.
        local resume, late = setup.core.resume, nil
        setup.core.resume = function(self, tower, id, sealed)
            late = function() return resume(self, tower, id, sealed) end
        end

        local back = shadow(setup, stack.id, { first })
        for _ = 1, 50 do
            if late then break end
            setup.net.advance(0.1)
        end
        expect(late ~= nil):eq(true)
        -- Its cell is back by its next beacon, and the phone sees so at its next check: within two seconds, before it
        -- would try another cell.
        back()
        for _ = 1, 25 do
            if not phone:info().fading then break end
            setup.net.advance(0.1)
        end
        expect(phone:info().fading):eq(nil)
        expect(phone.cell):eq(first)

        -- The core moves the phone, and the other cell takes it: the phone goes too.
        setup.core.resume = resume
        late()
        setup.net.advance(1)
        expect(phone.cell):eq(other)
        expect(session_of(setup, stack.id).cell):eq(other)
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("refuses a recording of a resume", function()
        local setup, phone, stack = attached { 0, 60 }
        local first, other = setup.towers[1].tower.id, setup.towers[2].tower.id
        local resume, recorded, recorded_at = setup.core.resume, nil, nil
        setup.core.resume = function(self, tower, id, sealed)
            if tower.id == other then recorded, recorded_at = sealed, setup.net.time end
            return resume(self, tower, id, sealed)
        end
        local function wait_for(cell)
            for _ = 1, 60 do
                if phone.cell == cell then return end
                setup.net.advance(0.1)
            end
        end

        local back = shadow(setup, stack.id, { first })
        wait_for(other)
        expect(phone.cell):eq(other)
        expect(recorded ~= nil):eq(true)

        -- Its new cell goes quiet at once, and the first is back: the phone resumes through that.
        back()
        local back_again = shadow(setup, stack.id, { other })
        wait_for(first)
        expect(phone.cell):eq(first)
        expect(session_of(setup, stack.id).cell):eq(first)

        -- Someone sends the recording again, soon enough that the clock alone doesn't say it's old: the phone's packets
        -- mustn't move to where it isn't.
        expect(setup.net.time - recorded_at < 5):describe("Recorded " .. (setup.net.time - recorded_at) .. "s ago"):eq(true)
        resume(setup.core, setup.core.towers[other], stack.id, recorded)
        expect(session_of(setup, stack.id).cell):eq(first)

        -- Nor later.
        back_again()
        setup.net.advance(10)
        resume(setup.core, setup.core.towers[other], stack.id, recorded)
        expect(session_of(setup, stack.id).cell):eq(first)
        expect(phone.cell):eq(first)
        expect(setup.net.ping(stack, ip("10.0.0.60")).error):eq(nil)
    end)

    it("holds what it sends while its cell is quiet, and gets what was sent to it meanwhile", function()
        local setup, phone, stack = attached { 0 }
        local to_server, to_phone = {}, {}
        local server_socket = assert(setup.server:udp_open(7000, function(message) to_server[#to_server + 1] = message end))
        local phone_socket = assert(stack:udp_open(7001, function(message) to_phone[#to_phone + 1] = message end))

        local back = shadow(setup, stack.id, { phone.cell })
        -- Once the phone takes it that its cell has gone quiet.
        setup.net.advance(3)
        expect(phone:info().fading):eq(true)
        for i = 1, 3 do
            assert(stack:udp_send(phone_socket, ip("10.0.0.60"), 7000, "up " .. i))
            assert(setup.server:udp_send(server_socket, phone.address, 7001, "down " .. i))
            setup.net.advance(1)
        end
        expect(to_server):same {}
        expect(to_phone):same {}

        back()
        setup.net.advance(3)
        expect(to_server):same { "up 1", "up 2", "up 3" }
        expect(to_phone):same { "down 1", "down 2", "down 3" }
    end)

    it("gets answers to what it held only once", function()
        local setup, phone, stack = attached { 0 }
        local to_phone = {}
        local server_socket
        server_socket = assert(setup.server:udp_open(7000, function(message, from, port)
            assert(setup.server:udp_send(server_socket, from, port, "re: " .. message))
        end))
        local phone_socket = assert(stack:udp_open(7001, function(message) to_phone[#to_phone + 1] = message end))
        -- The core gets the phone's asking for what it missed late: after the answers to what it held.
        local replay, asked = setup.core.replay, {}
        setup.core.replay = function(...) asked[#asked + 1] = table.pack(...) end

        local back = shadow(setup, stack.id, { phone.cell })
        setup.net.advance(3)
        expect(phone:info().fading):eq(true)
        for i = 1, 3 do
            assert(stack:udp_send(phone_socket, ip("10.0.0.60"), 7000, "up " .. i))
            setup.net.advance(1)
        end
        assert(setup.server:udp_send(server_socket, phone.address, 7001, "down"))
        setup.net.advance(1)

        back()
        setup.net.advance(3)
        expect(to_phone):same { "re: up 1", "re: up 2", "re: up 3" }
        expect(#asked):eq(1)
        setup.core.replay = replay
        replay(table.unpack(asked[1], 1, asked[1].n))
        setup.net.advance(1)
        expect(to_phone):same { "re: up 1", "re: up 2", "re: up 3", "down" }
    end)

    it("gets what was sent to it after attaching again, too", function()
        local setup, phone, stack = attached { 0 }
        local to_server, to_phone = {}, {}
        local server_socket = assert(setup.server:udp_open(7000, function(message) to_server[#to_server + 1] = message end))
        local phone_socket = assert(stack:udp_open(7001, function(message) to_phone[#to_phone + 1] = message end))
        local events = #phone.events

        -- Gone long enough that the phone gives up on its cell, and searches.
        local back = shadow(setup, stack.id, { phone.cell })
        setup.net.advance(23)
        expect(phone.state ~= "attached"):eq(true)
        assert(stack:udp_send(phone_socket, ip("10.0.0.60"), 7000, "up"))
        assert(setup.server:udp_send(server_socket, phone.address, 7001, "down"))
        setup.net.advance(1)

        back()
        setup.net.advance(7)
        expect(phone.state):eq("attached")
        local kinds = kinds_since(phone, events)
        expect({ kinds.lost, kinds.attached }):same { 1, 1 }
        expect(to_server):same { "up" }
        expect(to_phone):same { "down" }
    end)

    it("doesn't send what was held too long to be any use", function()
        local setup, phone, stack = attached { 0 }
        local to_server, to_phone = {}, {}
        local server_socket = assert(setup.server:udp_open(7000, function(message) to_server[#to_server + 1] = message end))
        local phone_socket = assert(stack:udp_open(7001, function(message) to_phone[#to_phone + 1] = message end))

        local back = shadow(setup, stack.id, { phone.cell })
        setup.net.advance(3)
        expect(phone:info().fading):eq(true)
        assert(stack:udp_send(phone_socket, ip("10.0.0.60"), 7000, "old"))
        assert(setup.server:udp_send(server_socket, phone.address, 7001, "old"))
        setup.net.advance(9)
        assert(stack:udp_send(phone_socket, ip("10.0.0.60"), 7000, "new"))
        assert(setup.server:udp_send(server_socket, phone.address, 7001, "new"))
        setup.net.advance(2)
        expect(phone.state):eq("attached")

        back()
        setup.net.advance(3)
        expect(to_server):same { "new" }
        expect(to_phone):same { "new" }
    end)
end)
