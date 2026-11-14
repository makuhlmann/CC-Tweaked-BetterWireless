-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Phones, with and without a SIM, given made-up system information: anyone can send it, as from as many cells and
networks as they like, saying anything. Nothing they say may break a phone, nor make it remember without bound. ]]

describe("Phones, given made-up system information,", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator
    local common = require "cc.internal.net.cell.common"
    local bands = require "cc.internal.net.bands"
    local bar = require "cc.internal.net.cell.bar"
    local yield = require "support.yield"

    local count, NIL, BAD = helpers.count, helpers.NIL, helpers.bad_values()

    local BEACONS = {}
    for _, channel in ipairs(bands.beacon_channels()) do BEACONS[channel] = true end

    -- A phone (with a SIM, attached) and a computer without one (listening), side by side near ACME's cell.
    local function world(seed)
        math.randomseed(seed)
        local acme = operator { 0 }
        local phone, stack = acme.add_phone(1, 10)
        local listener = acme.add_phone(2, 12, false, { activated = false })
        acme.net.advance(8)
        expect({ phone.state, listener.state }):same { "attached", "inactive" }
        -- Made-up frames aren't sent from anywhere: say how strongly they're heard.
        local reach = acme.net.reach
        acme.net.reach = function(link, sender, receiver)
            if not sender then return acme.fake_signal or -70 end
            return reach(link, sender, receiver)
        end
        return acme, phone, stack, listener
    end

    -- System information from a made-up cell, with some of it changed (NIL takes a field away).
    local function sib(acme, id, changes, part)
        local body = {
            op = "sib", cell = id, area = 1, load = 0, time = acme.now(), ul = acme.uplink, interval = 1,
            networks = { { network = "EVIL" } },
        }
        for key, value in pairs(changes or {}) do
            if value == NIL then body[key] = nil else body[key] = value end
        end
        for key, value in pairs(part or {}) do
            if value == NIL then body.networks[1][key] = nil else body.networks[1][key] = value end
        end
        return body
    end

    local function send(acme, phone, body)
        acme.inject(phone.stack, { net = 1, src = body.cell, dst = -1, type = common.FRAME, body = body })
    end

    local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end

    -- Everything anyone may ask of a phone still works, and says something sane.
    local function check(phone, what)
        local ok, err = pcall(function()
            local info = phone:info()
            for _, cell in ipairs(info.heard) do
                assert(finite(cell.signal), "A cell's signal isn't a number")
                if cell.pos then assert(common.is_position(cell.pos), "A cell's position isn't one") end
                if cell.distance ~= nil then assert(finite(cell.distance) and cell.distance >= 0, "A cell's distance") end
                assert(cell.service == nil or cell.service == "sms", "A cell's service")
            end
            if info.strongest then assert(finite(info.strongest.signal), "The strongest cell's signal") end
            info.unread, info.enabled = 0, true
            for _, width in ipairs { 26, 51 } do
                local text, fg, bg = bar.line(info, width, true)
                assert(#text == width and #fg == width and #bg == width, "The bar's width")
            end
            local x, y, z, off = phone:locate()
            if x then
                assert(finite(x) and finite(y) and finite(z), "A position which isn't one")
                assert(off == math.huge or (finite(off) and off >= 0), "An error which isn't one")
            else
                assert(type(y) == "string", "No reason for not knowing where it is")
            end
            for channel in pairs(phone.listening) do
                assert(BEACONS[channel] or channel == phone.here.dl, "Listening on channel " .. tostring(channel))
            end
        end)
        if not ok then error(("%s: %s"):format(what, tostring(err)), 0) end
    end

    it("ignore odd values in what's new in version 4, with a SIM and without", function()
        local acme, phone, stack, listener = world(1)
        local events = #phone.events
        local id = 900

        local changes = {}
        for _, bad in ipairs(BAD) do
            for _, field in ipairs { "ul", "interval", "pos", "service", "area", "load", "time" } do
                changes[#changes + 1] = { what = field .. " " .. bad[1], fields = { [field] = bad[2] } }
            end
            changes[#changes + 1] = { what = "carriers " .. bad[1], part = { carriers = bad[2] } }
        end
        local function also(what, fields, part) changes[#changes + 1] = { what = what, fields = fields, part = part } end
        local beacon = bands.beacon_channels()[1]
        for _, pos in ipairs {
            { 1 }, { 1, 2 }, { "a", "b", "c" }, { 0 / 0, 1, 1 }, { math.huge, 1, 1 }, { 1e308, 1, 1 }, { 1.5, 2, 3 },
            { 1, 2, 3, 4 }, { 1, 2, 3, x = 1 }, { [1] = 1, [3] = 3 }, { 2 ^ 31 + 1, 0, 0 },
        } do
            also("pos " .. textutils.serialise(pos, { compact = true, allow_repetitions = true }), { pos = pos })
        end
        for _, ul in ipairs { 1.5, -1, 70000, beacon, 1400, 2 ^ 53, 65533 } do also("ul " .. ul, { ul = ul }) end
        for _, interval in ipairs { 0, 0.49, 10.01, -1, "1" } do also("interval " .. interval, { interval = interval }) end
        for _, service in ipairs { "SMS", "full", "", 1 } do also("service " .. tostring(service), { service = service }) end
        local many = {}
        for i = 1, 500 do many[i] = beacon end
        for _, carriers in ipairs {
            { -1 }, { 70000 }, { 1.5 }, { 0 / 0 }, many, { [2] = beacon }, { acme.uplink }, { beacon, x = 1 },
        } do
            also("carriers " .. #carriers, nil, { carriers = carriers })
        end
        -- And the most a cell may say: everything at its limits.
        local carriers = {}
        for i = 1, 8 do carriers[i] = bands.beacon_channels()[i * 7] end
        also("limits", { pos = { 2 ^ 31, -2 ^ 31, 0 }, interval = 10, service = "sms", area = 2 ^ 53, load = 1 }, { carriers = carriers })
        also("smallest", { pos = { -2 ^ 31, 2 ^ 31, -1 }, interval = 0.5, area = -1, load = -1 })

        for i, change in ipairs(changes) do
            id = id + 1
            for _ = 1, 3 do
                for _, who in ipairs { phone, listener } do send(acme, who, sib(acme, id, change.fields, change.part)) end
            end
            acme.net.advance(0.1)
            if i % 10 == 0 then
                check(phone, change.what)
                check(listener, change.what)
                yield()
            end
        end
        acme.net.advance(5)
        check(phone, "afterwards")
        check(listener, "afterwards")

        expect(phone.state):eq("attached")
        expect(#phone.events):describe("Nothing happened to the phone"):eq(events)
        expect(listener.state):eq("inactive")
        expect(helpers.reaches_server(acme.net, stack)):eq(true)
        expect(acme.net.errors):same {}
    end)

    -- Each made-up cell is of networks of its own, which name every carrier there is between them.
    local function flood(acme, phones, cells, from)
        local channels = bands.beacon_channels()
        for i = 1, cells do
            local id = from + i
            local networks = {}
            for n = 1, 8 do
                local named = {}
                for c = 1, 8 do named[c] = channels[(i * 8 + n * 3 + c) % #channels + 1] end
                networks[n] = { network = ("FAKE-%d-%d"):format(id, n), carriers = named }
            end
            for _, who in ipairs(phones) do
                send(acme, who, {
                    op = "sib", cell = id, area = 1, load = 0, time = acme.now(), ul = acme.uplink, interval = 1,
                    networks = networks,
                })
            end
            if i % 25 == 0 then
                acme.net.advance(0.2)
                yield()
            end
        end
    end

    local function carrier_entries(phone)
        local n = 0
        for _, networks in pairs(phone.carriers) do n = n + count(networks) end
        return n
    end

    it("remember a limited amount, however many cells and networks are made up", function()
        local acme, phone, stack, listener = world(2)
        -- One more of ACME's phones, out of reach of its cell, searching all the while.
        local searching = acme.add_phone(3, 500)
        acme.net.advance(2)
        expect(searching.state):eq("searching")

        -- Stronger than the real cell, so each is remembered, if only for a moment.
        acme.fake_signal = -50
        local phones = { phone, listener, searching }
        flood(acme, phones, 600, 2000)
        acme.net.advance(3)
        for _, who in ipairs(phones) do
            local name = ("Phone %d (%s)"):format(who.stack.id, who.state)
            expect(count(who.heard) <= 32):describe(name .. ": cells heard"):eq(true)
            expect(count(who.uplinks) <= 40):describe(name .. ": uplinks, " .. count(who.uplinks)):eq(true)
            expect(carrier_entries(who) <= 1000):describe(name .. ": carriers' networks, " .. carrier_entries(who)):eq(true)
            expect(count(who.listening) <= #bands.beacon_channels() + 1):describe(name .. ": channels"):eq(true)
            check(who, name)
        end
        expect(phone.state):eq("attached")
        expect(listener.state):eq("inactive")

        -- Once they stop, the real cell is still there, and everything made up goes in time.
        acme.fake_signal = nil
        acme.net.advance(40)
        expect(helpers.reaches_server(acme.net, stack)):eq(true)
        expect(listener:info().strongest.id):eq(11)
        for _, who in ipairs(phones) do
            expect(count(who.heard) <= 2):describe("Cells still remembered"):eq(true)
            expect(count(who.uplinks) <= 2):describe("Uplinks still remembered, " .. count(who.uplinks)):eq(true)
        end
        expect(acme.net.errors):same {}
    end)

    it("say where they are without breaking, whatever distances they're given", function()
        math.randomseed(3)
        -- Four cells which say where they are, around a phone and a computer without a SIM.
        local cells = { { 0, 80, 0 }, { 60, 100, 0 }, { 0, 60, 60 }, { 60, 90, 60 } }
        local acme = operator(cells)
        local phone = acme.add_phone(1, { 20, 64, 30 })
        local listener = acme.add_phone(2, { 22, 64, 30 }, false, { activated = false })
        acme.net.advance(5)
        expect({ phone:locate() }):same { 20, 64, 30, 0 }

        local distance = acme.net.distance
        for _, bad in ipairs { 0 / 0, -5, math.huge, -math.huge, 1e300, 0, "far", true } do
            acme.net.distance = function(link, sender, receiver)
                if sender.id == 12 then return bad end
                return distance(link, sender, receiver)
            end
            acme.net.advance(3)
            check(phone, "distance " .. tostring(bad))
            check(listener, "distance " .. tostring(bad))
        end
        acme.net.distance = distance
        acme.net.advance(12)
        expect({ phone:locate() }):same { 20, 64, 30, 0 }
        expect({ listener:locate() }):same { 22, 64, 30, 0 }
        expect(acme.net.errors):same {}
    end)
end)
