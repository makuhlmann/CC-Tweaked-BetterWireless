-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The ifconfig program", function()
    local capture = require "test_helpers".capture_program
    local SETTING = "net.net_spec_none.address"

    local function run(...)
        local ok, result = pcall(capture, "/rom/programs/net/ifconfig.lua", ...)
        settings.unset(SETTING)
        settings.save()
        if not ok then error(result, 0) end
        return result
    end

    it("keeps an address for an interface which isn't there yet", function()
        local function kept(...)
            local result = run(...)
            return result, settings.get(SETTING)
        end
        local result
        result = run("net_spec_none", "10.0.0.5/24")
        expect(result):matches { ok = true, error = "", output = "No interface named net_spec_none yet. The setting will be used once it's added.\n" }

        -- Only if it's an address which can be used.
        for _, bad in ipairs {
            { "10.0.0.0/24", "10.0.0.0/24 is the address of the network itself, or its broadcast address\n" },
            { "127.0.0.1", "127.0.0.1 can't be a computer's address\n" },
            { "10.0.0.5/0", "The prefix length must be from 1 to 32\n" },
            { "10.0.0", "Invalid address '10.0.0'\n" },
        } do
            settings.unset(SETTING)
            local refused, setting = kept("net_spec_none", bad[1])
            expect(refused):matches { ok = true, output = "", error = bad[2] }
            expect(setting):eq(nil)
        end
    end)
end)
