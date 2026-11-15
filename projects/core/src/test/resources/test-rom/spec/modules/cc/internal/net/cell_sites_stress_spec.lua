-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cell sites with several bands, phones told which cells they may use, and subscribers with networks of their own,
all at once and at random: with cells and cores which restart, links which lose frames, and settings which change
under everyone's feet. Whatever happens, nothing may go wrong inside, and once it's quiet everything must be as it
should be. ]]

describe("Cellular networks with several bands, under stress", function()
    local helpers = require "support.net_helpers"
    local address = require "cc.net.address"
    local bands = require "cc.internal.net.bands"
    local common = require "cc.internal.net.cell.common"
    local operator = require "support.cell_network".operator

    local ip, hex = helpers.ip, helpers.hex
    local wait_until = helpers.wait_until

    -- Random numbers which are the same each time the tests run, whatever else used the generator.
    local function random_numbers(seed)
        local state = seed
        return function(low, high)
            state = (state * 1103515245 + 12345) % 2147483648
            return low + math.floor(state / 2147483648 * (high - low + 1))
        end
    end

    -- Have higher bands fade sooner, as they do in the game: band 3 is 12dB weaker than band 20 everywhere.
    local function fade_band_3(net)
        local reach = net.reach
        net.reach = function(link, sender, receiver, channel)
            local signal = reach(link, sender, receiver)
            if signal and link == "air" and bands.of(channel) == "b3" then
                signal = signal - 12
                if signal < -110 then return false end
            end
            return signal
        end
    end

    -- Every cell an operator's computers run, by its ID, with the band it's on.
    local function bands_of(setup)
        local result = {}
        for _, entry in ipairs(setup.towers) do
            for id, tower in pairs(entry.towers or {}) do
                if not tower.stopped then result[id] = tower.band end
            end
        end
        return result
    end

    -- What must hold between a core, its cells and its phones once things are quiet.
    local function check_settled(setup, phones, what)
        local core, cell_bands = setup.core, bands_of(setup)
        -- The core knows just the cells which are running.
        local known = {}
        for id in pairs(core.towers) do known[id] = cell_bands[id] or "?" end
        expect(known):describe(what .. ": the core's cells"):same(cell_bands)
        local addresses = {}
        for i, phone in ipairs(phones) do
            local session = core.sessions[hex(phone.sim.public)]
            expect(phone.state):describe(("%s: phone %d"):format(what, i)):eq("attached")
            expect(session ~= nil and session.cell):describe(("%s: where the core has phone %d"):format(what, i)):eq(phone.cell)
            expect(cell_bands[phone.cell] ~= nil):describe(("%s: phone %d's cell runs"):format(what, i)):eq(true)
            expect(addresses[phone.address]):describe(("%s: phone %d's address"):format(what, i)):eq(nil)
            addresses[phone.address] = i
        end
        -- No cell keeps a phone which isn't there.
        for _, entry in ipairs(setup.towers) do
            for id, tower in pairs(entry.towers or {}) do
                for phone_id, context in pairs(tower.stopped and {} or tower.phones) do
                    local phone
                    for _, each in ipairs(phones) do
                        if each.stack.id == phone_id then phone = each end
                    end
                    if context.active then
                        expect(phone ~= nil and phone.cell):describe(("%s: cell %s has phone %d"):format(what, common.cell_label(id), phone_id)):eq(id)
                    end
                end
            end
        end
    end

    it("carry phones between bands and sites while cells and the core restart", function()
        local random = random_numbers(11)
        math.randomseed(11)
        local acme = operator({ 0, 80 }, {
            carriers = { "b20/1", "b20/2", "b3/1", "b3/2" }, bands = { { "b20", "b3", "b3" }, { "b3", "b20" } },
        })
        local net = acme.net
        fade_band_3(net)
        local phones, stacks = {}, {}
        for i = 1, 5 do phones[i], stacks[i] = acme.add_phone(i, random(0, 80)) end
        net.advance(8)

        net.loss.air = 0.1
        for round = 1, 36 do
            local what = random(1, 12)
            if what <= 8 then
                acme.positions[random(1, 5)] = random(-10, 95)
            elseif what <= 10 then
                acme.restart_cell(random(1, 2))
            elseif what == 11 and round > 10 and round < 25 then
                acme.restart_core()
            end
            net.advance(random(1, 3))
        end

        -- Quiet again, and everyone near a cell: it all comes back, as it should be.
        net.loss.air = nil
        for i = 1, 5 do acme.positions[i] = random(0, 80) end
        wait_until(net, function()
            for _, phone in ipairs(phones) do
                local session = acme.core.sessions[hex(phone.sim.public)]
                if phone.state ~= "attached" or not session or session.cell ~= phone.cell then return false end
            end
            return acme.towers[1].service:info().state == "serving" and acme.towers[2].service:info().state == "serving"
        end, 180, "Settling")
        net.advance(10)
        check_settled(acme, phones, "afterwards")
        expect(helpers.count(bands_of(acme))):eq(5)
        for i = 1, 5 do expect(net.ping(stacks[i], ip("10.0.0.60"))):describe("Phone " .. i):matches { done = true } end
        expect(net.errors):same {}
    end)

    it("keep phones to the bands and cells they were told, whatever they're told and wherever they go", function()
        local random = random_numbers(12)
        math.randomseed(12)
        local acme = operator({ 0, 60, 120 }, {
            carriers = { "b20/1", "b3/1" }, bands = { { "b20", "b3" }, "b20", { "b3", "b20" } },
        })
        local net = acme.net
        fade_band_3(net)
        local phones, stacks = {}, {}
        for i = 1, 4 do phones[i], stacks[i] = acme.add_phone(i, random(0, 120)) end
        net.advance(6)
        local cell_bands = bands_of(acme)
        local ids = {}
        for id in pairs(cell_bands) do ids[#ids + 1] = id end
        table.sort(ids)
        expect(#ids):eq(5)

        local told = {}
        local function check(round)
            for i, phone in ipairs(phones) do
                local now = told[i] or {}
                if phone.state == "attached" or phone.state == "attaching" then
                    local band = cell_bands[phone.cell]
                    local what = ("Round %d: phone %d on cell %s (%s), told %s and %s"):format(
                        round, i, common.cell_label(phone.cell), tostring(band), now.bands and table.concat(now.bands, "+") or "any band",
                        now.pinned and "cell " .. common.cell_label(now.pinned) or "any cell"
                    )
                    if now.pinned then expect(phone.cell):describe(what):eq(now.pinned) end
                    if now.bands then
                        local allowed = false
                        for _, name in ipairs(now.bands) do allowed = allowed or name == band end
                        expect(allowed):describe(what):eq(true)
                    end
                end
                -- It listens on nothing it may not use: but its own channel, on its cell's carrier.
                for channel in pairs(phone.listening) do
                    local band = bands.of(channel)
                    local allowed = not now.bands
                    for _, name in ipairs(now.bands or {}) do allowed = allowed or name == band end
                    expect(allowed):describe(("Round %d: phone %d listens on band %s"):format(round, i, tostring(band))):eq(true)
                end
            end
        end

        local choices = { { "b20" }, { "b3" }, { "b20", "b3" }, { "b7" }, { "b3", "b7", "b1" } }
        for round = 1, 60 do
            local i = random(1, 4)
            local what = random(1, 10)
            if what <= 4 then
                acme.positions[i] = random(-5, 125)
            else
                local now = told[i] or {}
                if what <= 7 then
                    now = { bands = random(1, 3) > 1 and choices[random(1, #choices)] or nil, pinned = now.pinned }
                else
                    -- A cell there is, a cell there isn't, or none.
                    local pick = random(1, #ids + 2)
                    now = { bands = now.bands, pinned = ids[pick] or (pick == #ids + 1 and 99 or nil) }
                end
                told[i] = now
                phones[i]:restrict(now.bands, now.pinned)
                check(round)
            end
            net.advance(random(1, 2))
            check(round)
        end

        -- Let go again, everyone finds a cell, and the core knows where they are.
        for i, phone in ipairs(phones) do
            told[i] = nil
            phone:restrict(nil, nil)
            acme.positions[i] = random(0, 120)
        end
        wait_until(net, function()
            for _, phone in ipairs(phones) do
                local session = acme.core.sessions[hex(phone.sim.public)]
                if phone.state ~= "attached" or not session or session.cell ~= phone.cell then return false end
            end
            return true
        end, 120, "Settling")
        net.advance(10)
        check_settled(acme, phones, "afterwards")
        for i = 1, 4 do expect(net.ping(stacks[i], ip("10.0.0.60"))):describe("Phone " .. i):matches { done = true } end
        expect(net.errors):same {}
    end)

    it("route subscribers' networks to just the phones which have them, however they change", function()
        local random = random_numbers(13)
        math.randomseed(13)
        local acme = operator { 0 }
        local net = acme.net
        local core = acme.core
        local phones, stacks, sims = {}, {}, {}
        for i = 1, 6 do
            phones[i], stacks[i] = acme.add_phone(i, random(2, 20))
            sims[i] = hex(phones[i].sim.public)
        end
        net.advance(6)

        local ranges = { "10.64.1.0/28", "10.64.1.16/28", "10.64.1.0/27", "10.64.2.0/24", "10.64.0.0/26", "10.64.0.128/25" }
        local subnets = { "192.168.1.0/24", "192.168.2.0/24", "192.168.0.0/22", "172.16.0.0/16", "10.0.0.0/24", "10.99.0.0/16" }
        local changed, refused = 0, 0
        for _ = 1, 70 do
            local i = random(1, 6)
            local what = random(1, 10)
            local ok
            if what <= 3 then
                ok = core:set_network(sims[i], "range", ranges[random(1, #ranges)])
            elseif what <= 6 then
                ok = core:set_network(sims[i], "subnet", subnets[random(1, #subnets)])
            elseif what == 7 then
                ok = core:set_network(sims[i], nil)
            elseif what == 8 then
                -- Barred, or no longer.
                acme.subscribers[sims[i]].barred = not acme.subscribers[sims[i]].barred or nil
                core:detach(sims[i])
            elseif what == 9 then
                core:detach(sims[i])
            else
                acme.positions[i] = random(2, 20)
            end
            if ok then changed = changed + 1 elseif ok == nil and what <= 7 then refused = refused + 1 end
            net.advance(random(0, 2))

            -- At every moment: a route for each phone which is attached and has a network, to that phone, and no other.
            local wanted, found = {}, {}
            for sim, session in pairs(core.sessions) do
                local subscriber = acme.subscribers[sim]
                local network = subscriber and not subscriber.barred and session.teid and (subscriber.range or subscriber.subnet)
                if network then wanted[#wanted + 1] = network .. " via " .. address.format(session.address) end
            end
            for _, route in ipairs(acme.core_stack.routes) do
                if route.source == "subscriber" or route.source == "subscriber-range" then
                    found[#found + 1] = address.format(route.network, route.prefix) .. " via " .. address.format(route.gateway)
                end
            end
            table.sort(wanted)
            table.sort(found)
            expect(found):same(wanted)
        end
        expect(changed > 10 and refused > 5):describe(("%d changed, %d refused"):format(changed, refused)):eq(true)

        -- Nobody is barred any more, and everyone attaches again as what they now are.
        for i = 1, 6 do acme.subscribers[sims[i]].barred = nil end
        wait_until(net, function()
            for i, phone in ipairs(phones) do
                local session = core.sessions[sims[i]]
                if phone.state ~= "attached" or not session or session.cell ~= phone.cell then return false end
            end
            return true
        end, 180, "Settling")
        net.advance(10)

        local networks = {}
        for i, phone in ipairs(phones) do
            local subscriber = acme.subscribers[sims[i]]
            local network, kind = subscriber.range or subscriber.subnet, subscriber.range and "range" or "subnet"
            -- Each phone knows what it has, and has an address which is nobody's range.
            expect(phone.subscriber.routed):describe("Phone " .. i):same(network and { kind = kind, network = network } or nil)
            for _, other in pairs(acme.subscribers) do
                if other.range then
                    local range, prefix = address.parse(other.range)
                    expect(address.contains(range, prefix, phone.address)):describe(("Phone %d in %s"):format(i, other.range)):eq(false)
                end
            end
            -- No two networks overlap, and none is the core's own, or one it's on.
            if network then
                local parsed, prefix = address.parse(network)
                for _, other in ipairs(networks) do
                    expect(address.contains(parsed, prefix, other[1]) or address.contains(other[1], other[2], parsed))
                        :describe(network .. " and " .. other[3]):eq(false)
                end
                networks[#networks + 1] = { parsed, prefix, network }
                expect(address.contains(parsed, prefix, ip("10.0.0.60"))):describe(network):eq(false)
                expect(address.contains(parsed, prefix, ip("10.64.0.1"))):describe(network):eq(false)
            end
            expect(net.ping(stacks[i], ip("10.0.0.60"))):describe("Phone " .. i):matches { done = true }
        end
        expect(#acme.core_stack.routes <= 6 + 1):eq(true)
        expect(net.errors):same {}
    end)

    it("serve whichever networks share a site's bands as they come and go", function()
        local random = random_numbers(14)
        math.randomseed(14)
        local acme = operator({ 0 }, { carriers = { "b20/1", "b3/1" }, bands = { { "b20", "b3" } } })
        local beta = operator({ 300 }, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
            carriers = { "b20/2", "b3/2" },
        })
        local net = acme.net
        local site = acme.towers[1]
        local ours, ours_stack = acme.add_phone(1, 10)
        local theirs, theirs_stack = beta.add_phone(2, 12)
        net.advance(5)
        beta.allow_cell(site.driver.identity, site.id)

        local shared = false
        for _ = 1, 16 do
            local what = random(1, 6)
            if what <= 2 and not shared then
                site.service:add_core(beta.core_address)
                shared = true
            elseif what == 3 and shared then
                site.service:remove_core(beta.core_address)
                shared = false
            elseif what == 4 then
                beta.restart_core()
            elseif what == 5 then
                acme.positions[2] = random(5, 60)
            end
            site.driver.poke()
            net.advance(random(1, 4))
            -- Whoever is served is served on a cell which runs: no network is left on a cell which stopped.
            for id, tower in pairs(site.towers or {}) do
                if tower.stopped then expect(next(tower.links)):describe("A stopped cell, " .. common.cell_label(id)):eq(nil) end
            end
        end

        if not shared then site.service:add_core(beta.core_address) end
        site.driver.poke()
        acme.positions[2] = 12
        local high = common.carrier_cell(11, bands.parse_carrier("b3/1"))
        wait_until(net, function()
            local low, upper = site.towers and site.towers[11], site.towers and site.towers[high]
            if not (low and upper and not low.stopped and not upper.stopped and low.links.ACME and low.links.BETA
                and upper.links.ACME and upper.links.BETA and ours.state == "attached" and theirs.state == "attached") then
                return false
            end
            -- And each core knows where its phone is, at a cell which knows the phone.
            for _, pair in ipairs { { acme, ours, 1 }, { beta, theirs, 2 } } do
                local session = pair[1].core.sessions[hex(pair[2].sim.public)]
                local context = site.towers[pair[2].cell] and site.towers[pair[2].cell].phones[pair[3]]
                if not session or session.cell ~= pair[2].cell or not context or not context.active then return false end
            end
            return true
        end, 180, "Both networks on both bands")
        -- ACME's core placed the cells, so they're where they always were: BETA follows.
        expect({ bands.carrier_name(site.towers[11].carrier), bands.carrier_name(site.towers[high].carrier) }):same { "b20/1", "b3/1" }
        expect(net.ping(ours_stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.ping(theirs_stack, ip("10.0.0.60"))):matches { done = true }
        expect(net.errors):same {}
    end)
end)
