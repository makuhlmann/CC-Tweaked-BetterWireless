-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The nslookup program", function()
    local capture = require "test_helpers".capture_program
    local function run(...) return capture("/rom/programs/net/nslookup.lua", ...) end

    it("finds names' addresses", function()
        expect(run("10.1.2.3")):matches { ok = true, output = "10.1.2.3: 10.1.2.3\n" }
        settings.set("net.hosts", { bank = "10.9.9.9" })
        local ok, err = pcall(function()
            expect(run("bank")):matches { ok = true, output = "bank: 10.9.9.9\n" }
        end)
        settings.unset("net.hosts")
        if not ok then error(err, 0) end
    end)

    it("says when nobody offers a service", function()
        expect(run("service", "nslookup-spec")):matches { ok = true, error = "Nobody on the local network offers nslookup-spec\n" }
    end)

    it("says how it's used", function()
        expect(run().output):str_match("^Usages:\n")
        expect(run("a", "b").output):str_match("^Usages:\n")
    end)
end)
