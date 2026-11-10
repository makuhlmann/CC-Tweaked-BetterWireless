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
end)
