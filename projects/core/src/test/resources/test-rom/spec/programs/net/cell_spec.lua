-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local with_window = require "test_helpers".with_window

describe("The cell program", function()
    describe("monitor", function()
        -- Run the monitor on a pocket computer's screen, and get what it shows after its first drawing.
        local function show(info, events)
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            stub(net.cell, "listen", function() return true end)
            stub(net.cell, "info", function() return info end)

            local lines, colours, finished = {}, {}, nil
            with_window(26, 20, function()
                local co = coroutine.create(shell.run)
                assert(coroutine.resume(co, "/rom/programs/net/cell.lua", "monitor"))
                assert(coroutine.resume(co, "cell_state", info.state))
                for i = 1, 20 do
                    local text, fg = term.current().getLine(i)
                    lines[i], colours[i] = text:gsub(" +$", ""), fg:sub(1, 1)
                end
                for _, event in ipairs(events or { { "char", "q" } }) do
                    assert(coroutine.resume(co, table.unpack(event)))
                end
                finished = coroutine.status(co) == "dead"
            end)
            return lines, colours, finished
        end

        it("fits everything on a pocket computer", function()
            local now = os.epoch("utc")
            local info = {
                state = "attached", network = "ACME", subscriber = { id = "ACME-0042", number = "0042" },
                address = "10.64.0.2", cell = 12,
                heard = {
                    { id = 12, network = "ACME", signal = -71.6, age = 0.5, verified = true, serving = true, area = 1 },
                    { id = 11, network = "ACME", signal = -83, age = 1, verified = true, serving = false },
                    { id = 66, network = "ACME", signal = -60, age = 1, verified = false, serving = false },
                    { id = 77, network = "BETA-NETWORK-WITH-A-LONG-NAME", signal = -95, age = 2, serving = false },
                    { id = 13, network = "ACME", signal = -99, age = 10, verified = true, serving = false },
                },
                events = {
                    { kind = "attached", cell = 11, time = now - 60000 },
                    { kind = "handover", from = 11, to = 12, time = now - 5000 },
                },
            }
            local lines, colours, finished = show(info)

            expect(lines[1]):str_match("^ Cell monitor    %d%d:%d%d:%d%d$")
            expect({ table.unpack(lines, 2, 12) }):same {
                "Attached             |||.",
                "Net  ACME",
                "No.  0042 (ACME-0042)",
                "IP   10.64.0.2",
                "Cell #12, -72 dBm",
                " Cells                  5",
                ">#12   ACME            -72",
                " #11   ACME            -83",
                "!#66   ACME            -60",
                " #77   BETA-NETWORK-W  -95",
                " #13   ACME            -99",
            }
            expect({ table.unpack(lines, 13, 20) }):same {
                " Events",
                os.date("%H:%M:%S ", math.floor((now - 5000) / 1000)) .. "Moved #11 > #12",
                os.date("%H:%M:%S ", math.floor((now - 60000) / 1000)) .. "Attached #11",
                "", "", "", "",
                "Press Q to quit",
            }
            if term.isColour() then
                -- In use, a fake, and one which has gone quiet.
                expect({ colours[8], colours[10], colours[12] }):same { "5", "e", "7" }
            end

            -- Q quits, and leaves the screen clear.
            expect(finished):eq(true)
        end)

        it("shares the screen between many cells and events", function()
            local now = os.epoch("utc")
            local info = { state = "searching", network = "ACME", heard = {}, events = {} }
            for i = 1, 12 do
                info.heard[i] = { id = i, network = "ACME", signal = -60 - i, age = 1, verified = true, serving = false }
                info.events[i] = { kind = "lost", cell = i, time = now }
            end
            local lines = show(info)
            expect(lines[2]):eq("Searching")
            expect(lines[6]):eq("Cell -")
            -- Twelve lines are left: six each, the last cell's line saying how many more there are.
            expect(lines[7]):eq(" Cells                 12")
            expect(lines[12]):eq(" #5    ACME            -65")
            expect(lines[13]):eq("  and 7 more")
            expect(lines[14]):eq(" Events")
            expect(lines[15]):str_match("Lost #12$")
            expect(lines[20]):str_match("Lost #7$")
        end)

        it("works before the phone is activated", function()
            local lines = show({ state = "inactive", heard = {}, events = {} })
            expect({ table.unpack(lines, 2, 11) }):same {
                "Not activated",
                "Net  -",
                "No.  -",
                "IP   -",
                "Cell -",
                " Cells                  0",
                "None heard",
                " Events",
                "Nothing yet",
                "",
            }
        end)

        it("shows a phone which is roaming", function()
            local now = os.epoch("utc")
            local lines = show {
                state = "attached", network = "ACME", subscriber = { id = "ACME-0042", number = "0042" },
                address = "10.64.0.2", cell = 31, roaming = true, serving_network = "OTHER",
                heard = { { id = 31, network = "OTHER", signal = -75, age = 0, serving = true } },
                events = {
                    { kind = "attached", cell = 31, roaming = "OTHER", time = now },
                    { kind = "home", from = 31, time = now },
                },
            }
            expect(lines[2]):eq("Roaming              |||.")
            expect(lines[3]):eq("Net  ACME (on OTHER)")
            expect(lines[10]:sub(10)):eq("Home from #31")
            expect(lines[11]:sub(10)):eq("Roaming #31 OTHER")
        end)

        it("keeps running until Q is pressed", function()
            local _, _, finished = show({ state = "inactive", heard = {}, events = {} }, {
                { "char", "x" }, { "cell_state", "inactive" }, { "term_resize" },
            })
            expect(finished):eq(false)
        end)

        it("says why it can't listen", function()
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            stub(net.cell, "listen", function() return nil, "This needs a wireless modem" end)
            local capture = require "test_helpers".capture_program
            expect(capture("/rom/programs/net/cell.lua monitor"))
                :matches { ok = true, output = "", error = "This needs a wireless modem\n" }
        end)
    end)

    describe("commands", function()
        local capture = require "test_helpers".capture_program

        local function fake_phone()
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            local phone = { info = { state = "attached", network = "ACME", selection = "auto", roaming = false }, calls = {} }
            stub(net.cell, "listen", function() return true end)
            stub(net.cell, "info", function() return phone.info end)
            stub(net.cell, "networks", function() return phone.networks or {} end)
            stub(net.cell, "setNetwork", function(name)
                phone.calls[#phone.calls + 1] = { "setNetwork", name }
                if name == "BETA" then return nil, "This SIM can't use BETA" end
                return true
            end)
            stub(net.cell, "setEnabled", function(enabled)
                phone.calls[#phone.calls + 1] = { "setEnabled", enabled }
                if enabled and phone.no_modem then return nil, "This needs a wireless modem" end
                return true
            end)
            stub(net.cell, "send", function() return nil, "No SIM" end)
            return phone
        end

        it("lists the networks", function()
            local phone = fake_phone()
            expect(capture("/rom/programs/net/cell.lua networks"))
                :matches { ok = true, output = "The phone chooses the network.\nNo networks in range.\n", error = "" }

            phone.info.selection = "OTHER"
            phone.networks = {
                { name = "ACME", kind = "home", allowed = true, serving = false, selected = false },
                { name = "OTHER", kind = "partner", allowed = true, signal = -75.4, serving = true, selected = true },
                { name = "BETA", kind = "other", allowed = false, signal = -99.6, serving = false, selected = false },
            }
            expect(capture("/rom/programs/net/cell.lua networks")):matches {
                ok = true, error = "",
                output = "The phone only uses OTHER.\n" ..
                    "  ACME         home               -\n" ..
                    "> OTHER        partner      -75 dBm\n" ..
                    "  BETA         not allowed -100 dBm\n",
            }
        end)

        it("chooses a network, or lets the phone choose", function()
            local phone = fake_phone()
            expect(capture("/rom/programs/net/cell.lua network OTHER"))
                :matches { ok = true, output = "The phone only uses OTHER.\n", error = "" }
            expect(capture("/rom/programs/net/cell.lua network auto"))
                :matches { ok = true, output = "The phone chooses the network.\n", error = "" }
            expect(capture("/rom/programs/net/cell.lua network BETA"))
                :matches { ok = true, output = "", error = "This SIM can't use BETA\n" }
            expect(phone.calls):same { { "setNetwork", "OTHER" }, { "setNetwork", "auto" }, { "setNetwork", "BETA" } }
        end)

        it("turns cell service off and on", function()
            local phone = fake_phone()
            expect(capture("/rom/programs/net/cell.lua off"))
                :matches { ok = true, output = "Cell service is turned off.\n", error = "" }
            expect(capture("/rom/programs/net/cell.lua on"))
                :matches { ok = true, output = "Cell service is turned on.\n", error = "" }
            phone.no_modem = true
            expect(capture("/rom/programs/net/cell.lua on"))
                :matches { ok = true, output = "", error = "This needs a wireless modem\n" }
            expect(phone.calls):same { { "setEnabled", false }, { "setEnabled", true }, { "setEnabled", true } }
        end)

        it("says why a message can't be sent, without waiting", function()
            fake_phone()
            expect(capture("/rom/programs/net/cell.lua send 0042 Hello there"))
                :matches { ok = true, output = "", error = "No SIM\n" }
        end)

        it("says when the phone is roaming, or kept to one network", function()
            local phone = fake_phone()
            phone.info.roaming, phone.info.serving_network, phone.info.selection = true, "OTHER", "OTHER"
            expect(capture("/rom/programs/net/cell.lua")):matches {
                ok = true, error = "",
                output = "Attached\nNetwork:  ACME\nRoaming:  on OTHER\nOnly uses OTHER\n",
            }
        end)

        it("is completed", function()
            fake_phone().networks = {
                { name = "ACME", kind = "home", allowed = true },
                { name = "BETA", kind = "other", allowed = false },
            }
            expect(shell.complete("cell n")):same { "etworks", "etwork " }
            expect(shell.complete("cell o")):same { "n", "ff" }
            expect(shell.complete("cell network ")):same { "auto", "ACME" }
        end)
    end)
end)
