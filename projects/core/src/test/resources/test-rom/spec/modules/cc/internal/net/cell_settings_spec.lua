-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ A cell's settings, changed while it runs, as `celld set` has them: what the cell says about itself changes on the
air, and its phones keep their service. ]]

describe("A cell's settings, changed while it runs,", function()
    local helpers = require "support.net_helpers"
    local operator = require "support.cell_network".operator

    it("change what it says on the air, and its phones keep their service", function()
        math.randomseed(71)
        local acme = operator { 0 }
        local phone, stack = acme.add_phone(1, 10)
        acme.net.advance(5)
        expect(phone.state):eq("attached")
        local entry, events = acme.towers[1], #phone.events
        local function heard()
            for _, cell in ipairs(phone:info().heard) do
                if cell.id == entry.id and cell.fresh then return { cell.interval, cell.pos, cell.service } end
            end
            return {}
        end
        expect(heard()):same { 1 }

        -- Where it is, that it only carries messages, and how often it sends its system information.
        entry.service:configure { area = 1, pos = { 0, 64, 0 }, service = "sms", interval = 3 }
        acme.net.advance(7)
        expect(heard()):same { 3, { 0, 64, 0 }, "sms" }
        expect({ phone.state, phone:info().messages_only }):same { "attached", true }
        expect(helpers.reaches_server(acme.net, stack)):eq(false)

        -- And back: as often as its core says, carrying everything.
        entry.service:configure { area = 1 }
        acme.net.advance(5)
        expect(heard()):same { 1 }
        expect(helpers.reaches_server(acme.net, stack)):eq(true)
        expect({ phone.state, phone.cell, #phone.events }):same { "attached", entry.id, events }

        -- What its core says about the interval counts again too ('cellcore beacon 2' says it so).
        acme.core:send(entry.id, { op = "interval", interval = 2 })
        acme.net.advance(5)
        expect(heard()):same { 2 }

        -- Told how often while its core says otherwise, and then not: it goes back to what the core said last.
        entry.service:configure { area = 1, interval = 0.5 }
        acme.net.advance(3)
        expect(heard()):same { 0.5 }
        entry.service:configure { area = 1 }
        acme.net.advance(5)
        expect(heard()):same { 2 }
        expect(acme.net.errors):same {}
    end)
end)
