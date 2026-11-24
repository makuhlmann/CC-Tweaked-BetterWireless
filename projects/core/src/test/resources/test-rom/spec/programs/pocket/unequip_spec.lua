-- SPDX-FileCopyrightText: 2019 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local capture = require "test_helpers".capture_program

describe("The pocket unequip program", function()
    it("errors when not a pocket computer", function()
        stub(_G, "pocket", nil)
        expect(capture("/rom/programs/pocket/unequip.lua"))
            :matches { ok = true, output = "", error = "Requires a Pocket Computer\n" }
    end)

    it("unequips an upgrade", function()
        stub(_G, "pocket", {
            unequipBack = function() return true end,
        })

        expect(capture("/rom/programs/pocket/unequip.lua"))
            :matches { ok = true, output = "Item unequipped\n", error = "" }
    end)

    it("handles when an upgrade cannot be equipped", function()
        stub(_G, "pocket", {
            unequipBack = function() return false, "Nothing to remove." end,
        })

        expect(capture("/rom/programs/pocket/unequip.lua"))
            :matches { ok = true, output = "", error = "Nothing to remove.\n" }
    end)

    it("unequips each side", function()
        for _, side in ipairs { "top", "back", "left", "right" } do
            local called
            local fn = "unequip" .. side:sub(1, 1):upper() .. side:sub(2)
            stub(_G, "pocket", { [fn] = function() called = side return true end })

            expect(capture("/rom/programs/pocket/unequip.lua", side))
                :matches { ok = true, output = "Item unequipped\n", error = "" }
            expect(called):eq(side)
        end
    end)

    it("errors on an unknown side", function()
        stub(_G, "pocket", {})
        expect(capture("/rom/programs/pocket/unequip.lua", "bottom"))
            :matches { ok = true, output = "", error = "Unknown side. Expected 'top', 'back', 'left' or 'right'.\n" }
    end)
end)
