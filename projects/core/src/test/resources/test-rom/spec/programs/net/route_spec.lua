-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The route program", function()
    local capture = require "test_helpers".capture_program
    local SETTINGS = { "net.routes", "net.gateway", "net.forwarding", "net.rip", "net.rip.default" }

    -- Run the program, which changes settings: they aren't saved, and are as they were afterwards.
    local function with_settings(fn)
        stub(settings, "save", function() return true end)
        local ok, err = pcall(fn)
        for _, name in ipairs(SETTINGS) do settings.unset(name) end
        net.reload()
        if not ok then error(err, 0) end
    end
    local function run(...) return capture("/rom/programs/net/route.lua", ...) end

    it("adds and deletes fixed routes", function()
        with_settings(function()
            expect(run("add", "10.5.1.7/16", "10.0.0.1", "3")):matches { ok = true, output = "Added 10.5.0.0/16 via 10.0.0.1 metric 3\n" }
            expect(run("add", "10.6.0.0/16", "10.0.0.1")):matches { ok = true, output = "Added 10.6.0.0/16 via 10.0.0.1\n" }
            expect(settings.get("net.routes")):same { "10.5.0.0/16 via 10.0.0.1 metric 3", "10.6.0.0/16 via 10.0.0.1" }

            expect(run("delete", "10.5.0.0/16")):matches { ok = true, output = "Deleted the route to 10.5.0.0/16\n" }
            expect(run("delete", "10.5.0.0/16")):matches { ok = true, output = "No fixed route to 10.5.0.0/16\n" }
            expect(settings.get("net.routes")):same { "10.6.0.0/16 via 10.0.0.1" }
            run("delete", "10.6.0.0/16")
            expect(settings.get("net.routes")):eq(nil)

            expect(run("add", "10.5.0.0", "10.0.0.1")):matches { ok = true, error = "Expected a network such as 10.5.0.0/16\n" }
            expect(settings.get("net.routes")):eq(nil)
        end)
    end)

    it("sets the default gateway, forwarding and RIP", function()
        with_settings(function()
            expect(run("default", "10.0.0.1")):matches { ok = true, output = "Default gateway: 10.0.0.1\n" }
            expect(settings.get("net.gateway")):eq("10.0.0.1")
            -- Deleting the default route forgets the gateway too.
            expect(run("delete", "0.0.0.0/0")):matches { output = "Deleted the route to 0.0.0.0/0\n" }
            expect(settings.get("net.gateway")):eq(nil)
            run("default", "10.0.0.1")
            expect(run("default", "none")):matches { output = "No default gateway\n" }
            expect(settings.get("net.gateway")):eq(nil)

            expect(run("forwarding", "on")):matches { output = "This computer now forwards packets: it is a router.\n" }
            expect(settings.get("net.forwarding")):eq(true)
            expect(run().output):str_match("Forwarding packets for other computers%.\n$")
            run("forwarding", "off")
            expect(settings.get("net.forwarding")):eq(false)

            expect(run("rip", "default")):matches { output = "Learning routes from other routers, and offering a default route.\n" }
            expect({ settings.get("net.rip"), settings.get("net.rip.default") }):same { true, true }
            expect(run("rip", "off")):matches { output = "No longer learning routes from other routers.\n" }
            expect({ settings.get("net.rip"), settings.get("net.rip.default") }):same { false, false }
        end)
    end)

    it("says how it's used", function()
        with_settings(function()
            for _, args in ipairs { { "add", "10.5.0.0/16" }, { "default", "nowhere" }, { "rip", "maybe" }, { "fly" } } do
                expect(run(table.unpack(args)).output):str_match("^Usages:\n")
            end
            expect(settings.get("net.routes")):eq(nil)
        end)
    end)
end)
