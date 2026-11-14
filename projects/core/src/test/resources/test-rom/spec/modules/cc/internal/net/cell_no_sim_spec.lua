-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Phones without a SIM, which only listen for cells: to show the strongest, see what's around, and work out where they
are. A cell is heard up to 120 away. ]]

describe("Phones without a SIM", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator
    local bands = require "cc.internal.net.bands"

    local wait_until = helpers.wait_until

    -- BETA, on its own carrier (b20/2: ACME's is b20/1), with its cells at the positions given.
    local function beta(join, cells)
        return operator(cells, {
            join = join, name = "BETA", core_id = 51, core_host = 2, cell_base = 20, prefix = "10.65.0.0/16",
        })
    end

    local function count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return n
    end

    it("hear every cell around, then only listen on their carriers, and on every one each minute", function()
        math.randomseed(1)
        local acme = operator { 0 }
        beta(acme, { 40 })
        local net = acme.net
        local all = #bands.beacon_channels()
        local phone = acme.add_phone(1, 10, false, { activated = false })
        expect(count(phone.listening)):eq(all)

        net.advance(3)
        local info = phone:info()
        expect({ info.state, info.networks }):same { "inactive", { "ACME", "BETA" } }
        -- ACME's cell is nearer, so stronger.
        expect({ info.strongest.id, info.strongest.network }):same { 11, "ACME" }
        expect(info.strongest.signal > info.heard[2].signal):eq(true)

        -- Once it has listened everywhere for a few seconds, it only listens where it heard cells, and hears them all.
        net.advance(4)
        expect(phone.listening):same { [bands.parse_carrier("b20/1")] = true, [bands.parse_carrier("b20/2")] = true }
        net.advance(20)
        expect(phone:info().networks):same { "ACME", "BETA" }

        -- A minute after it last listened everywhere, it does again, for a few seconds.
        net.advance(40)
        expect(count(phone.listening)):eq(all)
        net.advance(6)
        expect(count(phone.listening)):eq(2)
        expect(net.errors):same {}
    end)

    it("listen everywhere before activating on a network they haven't heard lately", function()
        math.randomseed(2)
        -- BETA's cell is far from ACME's, out of the phone's reach at first.
        local acme = operator { 0 }
        local other = beta(acme, { 300 })
        local net = acme.net
        local activated
        local phone = acme.add_phone(1, 10, false, { activated = false, on_activated = function(info) activated = info end })
        local code = other.core:add_code("BETA-0007", "0007")
        net.advance(8)
        expect(phone.listening):same { [bands.parse_carrier("b20/1")] = true }

        -- Next to BETA's cell, it doesn't hear it: it doesn't listen on its carrier.
        acme.positions[1] = 280
        net.advance(5)
        expect(phone:info().networks):same {}

        -- Asked to activate on BETA, it listens everywhere, and says there's no cell of it yet. Asked again once it has
        -- heard one, it activates.
        expect({ phone:activate("BETA", code) }):same { nil, "No cell of BETA in range" }
        net.advance(4)
        expect(phone:info().networks):same { "BETA" }
        assert(phone:activate("BETA", code))
        wait_until(net, function() return phone.state == "attached" end, 20, "Activating and attaching")
        expect(activated.network):eq("BETA")
        expect(phone.cell):eq(21)
        expect(net.errors):same {}
    end)
end)
