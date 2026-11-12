-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The traceroute program", function()
    local capture = require "test_helpers".capture_program

    it("checks its hop limit", function()
        for _, hops in ipairs { "0", "256", "1.5", "lots" } do
            expect(capture("/rom/programs/net/traceroute.lua", "127.0.0.1", hops))
                :matches { ok = true, output = "", error = "The hop limit must be a whole number from 1 to 255.\n" }
        end
    end)

    it("finds the way to this computer", function()
        expect(capture("/rom/programs/net/traceroute.lua", "127.0.0.1", "3"))
            :matches { ok = true, error = "", output = "Route to 127.0.0.1 (127.0.0.1)\n 1  127.0.0.1  0 ms\n" }
    end)
end)
