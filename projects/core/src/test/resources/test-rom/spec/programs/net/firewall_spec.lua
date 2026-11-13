-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The firewall program", function()
    local capture = require "test_helpers".capture_program

    -- Run the program, which changes the rules: they aren't saved, and are as they were afterwards.
    local function with_rules(fn)
        stub(settings, "save", function() return true end)
        local ok, err = pcall(fn)
        settings.unset("net.firewall")
        net.reload()
        if not ok then error(err, 0) end
    end
    local function run(...) return capture("/rom/programs/net/firewall.lua", ...) end

    it("adds, lists and deletes rules", function()
        with_rules(function()
            expect(run()):matches { ok = true, output = "No rules: everything is forwarded.\n" }
            expect(run("allow", "proto", "tcp", "port", "22")):matches { output = "Added rule 1: allow tcp port 22\n" }
            expect(run("deny", "from", "10.2.0.0/16", "on", "back")):matches { output = "Added rule 2: deny from 10.2.0.0/16 on back\n" }
            expect(settings.get("net.firewall")):same {
                { action = "allow", proto = "tcp", port = 22 }, { action = "deny", from = "10.2.0.0/16", on = "back" },
            }
            expect(run()):matches { output = "1. allow tcp port 22\n2. deny from 10.2.0.0/16 on back\nAnything else is forwarded.\n" }

            expect(run("delete", "1")):matches { output = "Deleted: allow tcp port 22\n" }
            expect(run()):matches { output = "1. deny from 10.2.0.0/16 on back\nAnything else is forwarded.\n" }
            expect(run("clear")):matches { output = "Deleted every rule.\n" }
            expect(settings.get("net.firewall")):eq(nil)
        end)
    end)

    it("only takes rules which make sense", function()
        with_rules(function()
            expect(run("allow", "port", "70000")):matches { error = "Ports must be whole numbers from 1 to 65535\n" }
            expect(run("allow", "proto", "carrier-pigeon")):matches { error = "Expected a protocol of udp, tcp or icmp\n" }
            expect(run("deny", "to", "somewhere")):matches { error = "Expected an address or network, such as 10.2.0.0/16\n" }
            for _, args in ipairs { { "allow", "port" }, { "allow", "colour", "red" }, { "delete", "1" }, { "panic" } } do
                expect(run(table.unpack(args)).output):str_match("^Usages:\n")
            end
            expect(settings.get("net.firewall")):eq(nil)
        end)
    end)
end)
