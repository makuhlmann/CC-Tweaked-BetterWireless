-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Cellular networks on several carriers and bands, with cells which say where they are and a satellite which only
carries messages, phones roaming between them and a computer without a SIM listening, all moving about on a radio
which loses frames while cells restart and the networks lose each other.

Checked all along: what each computer's modem has open is what its interfaces listen on, within a modem's 128
channels; phones only listen on beacon channels and their own; a phone on a cell which only carries messages has no
route for packets; and nothing remembers without bound. Then everything is mended and left alone: every phone with a
SIM has service, on a full cell wherever one reaches it, every message arrives once, and each phone, standing still,
can say where it is. ]]

describe("Cellular networks on many carriers, under stress,", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator
    local bands = require "cc.internal.net.bands"
    local yield = require "support.yield"

    local count, reaches_server = helpers.count, helpers.reaches_server

    local BEACONS = {}
    for _, channel in ipairs(bands.beacon_channels()) do BEACONS[channel] = true end
    local STATES = { inactive = true, activating = true, searching = true, attaching = true, attached = true, rejected = true }

    local function advance(net, seconds)
        while seconds > 0 do
            net.advance(math.min(seconds, 5))
            seconds = seconds - 5
            yield()
        end
    end

    local function distance(a, b)
        return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    end

    local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end

    -- ACME: two cells on band 20, one on band 3 between them, and a satellite far out which only carries messages.
    -- BETA: two cells on its own carrier, between ACME's and the satellite. Each lets the other's phones roam, and
    -- they exchange messages. A cell gives service up to 100 blocks away.
    local ACME_CELLS = { { 0, 80, 0 }, { 90, 110, 30 }, { 170, 70, -20 }, { 400, 150, 0 } }
    local BETA_CELLS = { { 230, 90, 10 }, { 310, 80, -30 } }

    local function world()
        local acme = operator(ACME_CELLS, {
            numbers = "555", carriers = { "b20/1", "b3/1" }, bands = { "b20", "b3", "b20", "b20" },
            services = { nil, nil, nil, "sms" },
        })
        local net = acme.net

        -- What each computer's modems have open, as a real modem would: the stack says when it opens and closes them.
        local opened = {}
        local function hook(stack)
            local mine = {}
            for modem, channels in pairs(stack.listening) do
                mine[modem] = {}
                for channel in pairs(channels) do mine[modem][channel] = true end
            end
            opened[stack] = mine
            stack._open = function(modem, channel)
                mine[modem] = mine[modem] or {}
                mine[modem][channel] = true
            end
            stack._close = function(modem, channel)
                if mine[modem] then mine[modem][channel] = nil end
            end
        end
        for _, stack in ipairs(net.stacks) do hook(stack) end
        local make = net.stack
        net.stack = function(id)
            local stack = make(id)
            hook(stack)
            return stack
        end

        local beta = operator(BETA_CELLS, {
            join = acme, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16", numbers = "666",
        })
        acme.roam_on(beta)
        beta.roam_on(acme)
        return { acme = acme, beta = beta, net = net, opened = opened, peering = acme.peer_with(beta) }
    end

    -- What a computer's modems have open matches what its interfaces listen on, and each has no more than 128.
    local function check_stack(world, stack, what)
        local mine = world.opened[stack]
        if not mine then return end
        for modem, channels in pairs(stack.listening) do
            local n = 0
            for channel, interface in pairs(channels) do
                n = n + 1
                if not (mine[modem] and mine[modem][channel]) then error(("%s: listens on %d, which isn't open"):format(what, channel), 0) end
                if not interface.listen[channel] then error(("%s: %d is %s's, which doesn't listen there"):format(what, channel, interface.name), 0) end
                if stack.interfaces[interface.name] ~= interface then error(("%s: %d is a removed interface's"):format(what, channel), 0) end
            end
            if n > 128 then error(("%s: %d channels open on %s"):format(what, n, modem), 0) end
        end
        for modem, channels in pairs(mine) do
            for channel in pairs(channels) do
                if not (stack.listening[modem] and stack.listening[modem][channel]) then
                    error(("%s: %d is open on %s, but nothing listens there"):format(what, channel, modem), 0)
                end
            end
        end
    end

    local function check_phone(world, entry, what, locate)
        local phone, stack = entry.phone, entry.stack
        what = ("%s, phone %d (%s)"):format(what, entry.id, phone.state)
        if not STATES[phone.state] then error(what .. ": not a state", 0) end
        if entry.sim == false and phone.state ~= "inactive" then error(what .. ": without a SIM, it only listens", 0) end
        for channel in pairs(phone.listening) do
            if not BEACONS[channel] and channel ~= phone.here.dl then error(("%s: listens on %d"):format(what, channel), 0) end
        end
        if phone.state == "attached" then
            if not phone.cell or not phone.uplinks[phone.cell] then error(what .. ": attached, but to no cell it can reach", 0) end
            local routed = false
            for _, route in ipairs(stack.routes or {}) do
                if route.source == "cell" then routed = true end
            end
            if stack.interfaces.cell and phone:messages_only() == routed then
                error(("%s: on a cell which %s, %s a route"):format(what,
                    routed and "only carries messages" or "carries everything", routed and "with" or "without"), 0)
            end
        end
        if count(phone.heard) > 32 then error(what .. ": heard " .. count(phone.heard), 0) end
        if count(phone.uplinks) > count(phone.heard) + count(phone.cells) + 1 then error(what .. ": uplinks " .. count(phone.uplinks), 0) end
        if stack:timer_count() > 64 then error(what .. ": timers " .. stack:timer_count(), 0) end
        -- Working out where it is takes a while, so only when asked.
        local x, y, z, off
        if locate then x, y, z, off = phone:locate() end
        if x and not (finite(x) and finite(y) and finite(z) and (off == math.huge or finite(off))) then
            error(what .. ": located at something which isn't a position", 0)
        end
        check_stack(world, stack, what)
    end

    local function storm(seed, rounds)
        math.randomseed(seed)
        local world = world()
        local acme, beta, net = world.acme, world.beta, world.net
        local log = {}
        local function note(...) log[#log + 1] = ("%6.1f %s"):format(net.time, table.concat({ ... }, " ")) end

        local phones, messages, next_text = {}, {}, 0
        local function add(network, id, position, sim)
            local entry = { id = id, network = network, sim = sim, got = {}, notices = {}, sent = {} }
            entry.phone, entry.stack = network.add_phone(id, position, sim, {
                activated = sim,
                on_message = function(from, text)
                    if text:find("^Not delivered") then
                        entry.notices[#entry.notices + 1] = text
                    else
                        entry.got[text] = (entry.got[text] or 0) + 1
                    end
                end,
                on_sent = function(message, ok)
                    local sent = entry.sent[message]
                    if sent then sent.ok = ok end
                end,
            })
            entry.full = (network == acme and "555" or "666") .. id
            phones[#phones + 1] = entry
        end
        add(acme, 1, { 10, 64, 0 })
        add(acme, 2, { 340, 64, 0 })
        add(beta, 4, { 250, 64, 0 })
        -- Without a SIM: it only listens.
        add(acme, 6, { 100, 64, 10 }, false)
        advance(net, 8)

        local towers = {}
        for i in ipairs(ACME_CELLS) do towers[#towers + 1] = { acme, i } end
        for i in ipairs(BETA_CELLS) do towers[#towers + 1] = { beta, i } end

        local ok, err = pcall(function()
            net.loss.air = 0.1
            local peered = true
            for round = 1, rounds do
                for _, entry in ipairs(phones) do
                    local at = acme.positions[entry.id]
                    acme.positions[entry.id] = {
                        math.max(-40, math.min(460, at[1] + math.random(-25, 25))), 64,
                        math.max(-20, math.min(20, at[3] + math.random(-5, 5))),
                    }
                end

                local what = math.random(1, 100)
                if what <= 10 then
                    local tower = towers[math.random(1, #towers)]
                    note("restart", tower[1].name, "cell", tower[2])
                    tower[1].restart_cell(tower[2])
                elseif what <= 18 then
                    note(peered and "cores lose each other" or "cores find each other")
                    if peered then world.peering.cut() else world.peering.mend() end
                    peered = not peered
                elseif what <= 28 then
                    local entry = phones[math.random(1, 3)]
                    local choice = ({ false, "ACME", "BETA" })[math.random(1, 3)]
                    note("phone", entry.id, "uses", tostring(choice))
                    entry.phone:select(choice or nil)
                elseif what <= 45 then
                    -- Somewhere else entirely: by a satellite, between networks, or out of reach of everything.
                    local entry = phones[math.random(1, #phones)]
                    local x = math.random(-40, 460)
                    note("phone", entry.id, "goes to", x)
                    acme.positions[entry.id] = { x, 64, math.random(-20, 20) }
                end

                if math.random(1, 2) == 1 then
                    local from, to = phones[math.random(1, 3)], phones[math.random(1, 3)]
                    local number = from.network == to.network and tostring(to.id) or to.full
                    next_text = next_text + 1
                    local text = "message " .. next_text
                    local sent, id = from.phone:send_message(number, text)
                    if sent then
                        local message = { text = text, from = from, to = to }
                        messages[text], from.sent[id] = message, message
                        note("phone", from.id, "sends", text, "to", number)
                    end
                end

                advance(net, 2)
                local locating = math.random(1, #phones)
                for i, entry in ipairs(phones) do check_phone(world, entry, "Round " .. round, i == locating) end
                for _, tower in ipairs(towers) do
                    local cell = tower[1].towers[tower[2]]
                    check_stack(world, cell.stack, ("Round %d, %s's cell %d"):format(round, tower[1].name, tower[2]))
                    if cell.tower and count(cell.tower.phones) > #phones then error("Too many phones at a cell", 0) end
                end
            end

            -- Mend everything, and leave it alone, standing still.
            note("mending")
            net.loss.air = 0
            if not peered then world.peering.mend() end
            for _, entry in ipairs(phones) do entry.phone:select(nil) end
            advance(net, 90)

            for _, entry in ipairs(phones) do
                local phone, here = entry.phone, acme.positions[entry.id]
                check_phone(world, entry, "Afterwards", false)
                local name = ("Phone %d at %d,%d,%d"):format(entry.id, here[1], here[2], here[3])
                if entry.sim == false then
                    expect(phone.state):describe(name):eq("inactive")
                    -- It shows the strongest cell it hears.
                    local info, best = phone:info(), nil
                    for _, cell in ipairs(info.heard) do
                        if cell.fresh and (not best or cell.signal > best.signal) then best = cell end
                    end
                    expect(info.strongest and info.strongest.id):describe(name .. ": the strongest"):eq(best and best.id)
                else
                    -- A full cell of its network or a partner's in reach: it's on one.
                    local full = false
                    for i, cell in ipairs(ACME_CELLS) do
                        if i ~= 4 and distance(cell, here) < 95 then full = true end
                    end
                    for _, cell in ipairs(BETA_CELLS) do
                        if distance(cell, here) < 95 then full = true end
                    end
                    local in_reach = full or distance(ACME_CELLS[4], here) < 95
                    if in_reach then expect(phone.state):describe(name .. "'s state"):eq("attached") end
                    if full then
                        expect(phone:messages_only()):describe(name .. ": on the satellite"):eq(false)
                        expect(reaches_server(net, entry.stack)):describe(name .. " reaches the server"):eq(true)
                    end
                    expect(#phone.outbox == 0 or not in_reach):describe(name .. ": messages still being sent"):eq(true)
                end

                -- Standing still, where it is is exact, or within what it says.
                local x, y, z, off = phone:locate()
                if x then
                    local miss = distance({ x, y, z }, here)
                    expect(miss <= off + 0.02):describe(("%s: said %s,%s,%s within %s"):format(name, x, y, z, off)):eq(true)
                end
            end

            -- Every message whose sender was told it was taken arrived once, unless its sender heard it wasn't, or the
            -- phone it's for is out of reach.
            for text, message in pairs(messages) do
                local got = message.to.got[text] or 0
                if got > 1 then error(("%q arrived %d times"):format(text, got), 0) end
                if message.ok == true and got ~= 1 and #message.from.notices == 0 and message.to.phone.state == "attached" then
                    error(("%q was taken, but never arrived"):format(text), 0)
                end
            end
            expect(net.errors):same {}
        end)
        if not ok then
            error(("%s\nSeed %d. The last things to happen:\n%s"):format(
                type(err) == "table" and err.message or tostring(err), seed, table.concat(log, "\n", math.max(1, #log - 30))), 0)
        end
    end

    for seed = 1, 3 do
        it(("phones keep sane, and end up where they should (storm %d)"):format(seed), function()
            storm(8000 + seed, 20)
        end)
    end
end)
