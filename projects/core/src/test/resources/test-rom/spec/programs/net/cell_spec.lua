-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local with_window = require "test_helpers".with_window
local bands = require "cc.internal.net.bands"
local b20_1, b3_1, b3_2, b7_1 = bands.parse_carrier("b20/1"), bands.parse_carrier("b3/1"), bands.parse_carrier("b3/2"),
    bands.parse_carrier("b7/1")

describe("The cell program", function()
    describe("monitor", function()
        -- Run the monitor on a pocket computer's screen (or one as wide as given), and get what it shows after its first
        -- drawing.
        local function show(info, events, width)
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            stub(net.cell, "listen", function() return true end)
            stub(net.cell, "info", function() return info end)

            local lines, colours, finished = {}, {}, nil
            with_window(width or 26, 20, function()
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
                    {
                        id = 12, network = "ACME", signal = -71.6, age = 0.5, fresh = true, verified = true, serving = true,
                        area = 1, band = "b20", carrier = b20_1,
                    },
                    {
                        id = 11, network = "ACME", signal = -83, age = 1, fresh = true, verified = true, serving = false,
                        band = "b3", carrier = b3_2,
                    },
                    -- Without a carrier: a cell always has one, but the band will do, or nothing.
                    { id = 66, network = "ACME", signal = -60, age = 1, fresh = true, verified = false, serving = false },
                    {
                        id = 77, network = "BETA-NETWORK-WITH-A-LONG-NAME", signal = -95, age = 2, fresh = true,
                        serving = false, band = "b20", carrier = b20_1, service = "sms",
                    },
                    {
                        id = 13, network = "ACME", signal = -99, age = 10, fresh = false, verified = true, serving = false,
                        band = "b7", carrier = b7_1,
                    },
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
                "Cell #12, b20/1, -72 dBm",
                " Cells                  5",
                ">#12   ACME     b20/1  -72",
                " #11   ACME     b3/2   -83",
                "!#66   ACME     -      -60",
                " #77   BE [SMS] b20/1  -95",
                " #13   ACME     b7/1   -99",
            }
            -- Each carrier cells were heard on, lowest first: whose, how many cells, and the strongest.
            expect({ table.unpack(lines, 13, 20) }):same {
                " Carriers               3",
                ">b20/1 ACME+1 2 cells  -72",
                " b3/2  ACME    1 cell  -83",
                " b7/1  ACME    1 cell  -99",
                " Events",
                os.date("%H:%M:%S ", math.floor((now - 5000) / 1000)) .. "Moved #11 > #12",
                os.date("%H:%M:%S ", math.floor((now - 60000) / 1000)) .. "Attached #11",
                "Press Q to quit",
            }
            if term.isColour() then
                -- In use, a fake, and one which has gone quiet; the carrier in use, and one only heard a while ago.
                expect({ colours[8], colours[10], colours[12], colours[14], colours[16] }):same { "5", "e", "7", "5", "7" }
            end

            -- Q quits, and leaves the screen clear.
            expect(finished):eq(true)
        end)

        it("shares the screen between many cells and events", function()
            local now = os.epoch("utc")
            local info = { state = "searching", network = "ACME", heard = {}, events = {} }
            -- Each on a carrier of its own: the first twelve, the strongest on the lowest.
            local carriers = bands.beacon_channels()
            for i = 1, 12 do
                info.heard[i] = {
                    id = i, network = "ACME", signal = -60 - i, age = 1, fresh = true, verified = true, serving = false,
                    carrier = carriers[i],
                }
                info.events[i] = { kind = "lost", cell = i, time = now }
            end
            local lines = show(info)
            expect(lines[2]):eq("Searching")
            expect(lines[6]):eq("Cell -")
            -- Eleven lines are left: three for the carriers, and four each for the cells and the events, the last
            -- cell's and carrier's lines saying how many more there are.
            expect({ table.unpack(lines, 7, 16) }):same {
                " Cells                 12",
                " #1    ACME     b31/1  -61",
                " #2    ACME     b28/1  -62",
                " #3    ACME     b28/2  -63",
                "  and 9 more",
                " Carriers              12",
                " b31/1 ACME    1 cell  -61",
                " b28/1 ACME    1 cell  -62",
                "  and 10 more",
                " Events",
            }
            expect(lines[17]):str_match("Lost #12$")
            expect(lines[20]):str_match("Lost #9$")
        end)

        it("works before the phone is activated", function()
            local lines = show({ state = "inactive", heard = {}, events = {} })
            expect({ table.unpack(lines, 2, 13) }):same {
                "No SIM",
                "Net  -",
                "No.  -",
                "IP   -",
                "Cell -",
                " Cells                  0",
                "None heard",
                " Carriers               0",
                "None heard",
                " Events",
                "Nothing yet",
                "",
            }
        end)

        it("shows the strongest cell without a SIM", function()
            local strongest = { id = 21, network = "BETA", signal = -64.6, age = 0, fresh = true, band = "b3", carrier = b3_1 }
            local lines = show {
                state = "inactive", strongest = strongest,
                heard = {
                    strongest, { id = 11, network = "ACME", signal = -90, age = 0, fresh = true, band = "b20", carrier = b20_1 },
                },
                events = {},
            }
            expect({ table.unpack(lines, 2, 12) }):same {
                "No SIM               ||||",
                "Net  -",
                "No.  -",
                "IP   -",
                "Cell #21 BETA, -65 dBm",
                " Cells                  2",
                " #21   BETA     b3/1   -65",
                " #11   ACME     b20/1  -90",
                " Carriers               2",
                " b20/1 ACME    1 cell  -90",
                " b3/1  BETA    1 cell  -65",
            }
        end)

        it("shows the names cell sites say", function()
            local heard = {
                {
                    id = 12, network = "ACME", signal = -71.6, age = 0.5, fresh = true, verified = true, serving = true,
                    band = "b20", carrier = b20_1, name = "HILL-1",
                },
                { id = 11, network = "ACME", signal = -83, age = 1, fresh = true, verified = true, band = "b3", carrier = b3_2 },
                {
                    id = 77, network = "Beta Mobile Group Ltd", signal = -95, age = 2, fresh = true, band = "b20",
                    carrier = b20_1, service = "sms", name = "Old Mill",
                },
            }
            local info = { state = "attached", network = "ACME", cell = 12, heard = heard, events = {} }

            -- On a pocket computer, in place of the IDs: as wide as the longest name. [SMS] takes the network's place
            -- where there's no room for both.
            local lines = show(info)
            expect({ table.unpack(lines, 7, 10) }):same {
                " Cells                  3",
                ">HILL-1   ACME  b20/1  -72",
                " #11      ACME  b3/2   -83",
                " Old Mill [SMS] b20/1  -95",
            }
            heard[3].name = nil
            lines = show(info)
            expect({ table.unpack(lines, 8, 10) }):same {
                ">HILL-1 ACME    b20/1  -72",
                " #11    ACME    b3/2   -83",
                " #77    B [SMS] b20/1  -95",
            }

            -- Beside the IDs where there's room. A network cut short ends without a space.
            heard[3].name = "Old Mill"
            lines = show(info, nil, 51)
            expect({ table.unpack(lines, 8, 10) }):same {
                (">#12   HILL-1   %-24s b20/1  -72"):format("ACME"),
                (" #11            %-24s b3/2   -83"):format("ACME"),
                (" #77   Old Mill %-24s b20/1  -95"):format("Beta Mobile Group [SMS]"),
            }
        end)

        it("shows a phone which is roaming", function()
            local now = os.epoch("utc")
            local lines = show {
                state = "attached", network = "ACME", subscriber = { id = "ACME-0042", number = "0042" },
                address = "10.64.0.2", cell = 31, roaming = true, serving_network = "OTHER",
                heard = { { id = 31, network = "OTHER", signal = -75, age = 0, fresh = true, serving = true } },
                events = {
                    { kind = "attached", cell = 31, roaming = "OTHER", time = now },
                    { kind = "home", from = 31, time = now },
                },
            }
            expect(lines[2]):eq("Roaming              |||.")
            expect(lines[3]):eq("Net  ACME (on OTHER)")
            expect(lines[12]:sub(10)):eq("Home from #31")
            expect(lines[13]:sub(10)):eq("Roaming #31 OTHER")
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
                if #name > 32 then return nil, "Network names are up to 32 letters" end
                return true
            end)
            stub(net.cell, "setEnabled", function(enabled)
                phone.calls[#phone.calls + 1] = { "setEnabled", enabled }
                if enabled and phone.no_modem then return nil, "This needs a wireless modem" end
                return true
            end)
            stub(net.cell, "send", function() return nil, "No SIM" end)
            stub(net.cell, "setBands", function(list)
                phone.calls[#phone.calls + 1] = { "setBands", list or "any" }
                if list and list[1] == "b33" then return nil, "There's no cellular band called b33" end
                phone.info.bands = list
                return true
            end)
            stub(net.cell, "pinCell", function(cell)
                phone.calls[#phone.calls + 1] = { "pinCell", cell or "none" }
                phone.info.pinned = cell
                return true
            end)
            phone.power = { default = 23, device = "pocket computer", kind = "wireless", now = 23, least = -30, most = 23 }
            stub(net.cell, "transmitPower", function() return phone.power end)
            stub(net.cell, "setPower", function(power)
                phone.calls[#phone.calls + 1] = { "setPower", power or "default" }
                if power and power > 23 then return nil, "This pocket computer sends with -30 to 23 dBm" end
                phone.power.power = power
                return true
            end)
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
                    "  BETA         unknown     -100 dBm\n",
            }
        end)

        it("chooses a network, or lets the phone choose", function()
            local phone = fake_phone()
            phone.networks = { { name = "BETA", kind = "other", allowed = false, signal = -80, serving = false, selected = false } }
            expect(capture("/rom/programs/net/cell.lua network OTHER"))
                :matches { ok = true, output = "The phone only uses OTHER.\n", error = "" }
            expect(capture("/rom/programs/net/cell.lua network auto"))
                :matches { ok = true, output = "The phone chooses the network.\n", error = "" }
            -- One it knows of no agreement with, it tries.
            expect(capture("/rom/programs/net/cell.lua network BETA")):matches {
                ok = true, error = "",
                output = "The phone only uses BETA.\nIt doesn't know whether BETA carries its network's phones, so it tries.\n",
            }
            expect(capture("/rom/programs/net/cell.lua network " .. ("X"):rep(33)))
                :matches { ok = true, output = "", error = "Network names are up to 32 letters\n" }
            -- A name with spaces, in quotes or not.
            expect(capture("/rom/programs/net/cell.lua network Old Mill, Inc."))
                :matches { ok = true, output = "The phone only uses Old Mill, Inc..\n", error = "" }
            expect(capture('/rom/programs/net/cell.lua network "Old Mill"'))
                :matches { ok = true, output = "The phone only uses Old Mill.\n", error = "" }
            expect(phone.calls):same {
                { "setNetwork", "OTHER" }, { "setNetwork", "auto" }, { "setNetwork", "BETA" }, { "setNetwork", ("X"):rep(33) },
                { "setNetwork", "Old Mill, Inc." }, { "setNetwork", "Old Mill" },
            }
        end)

        it("activates on a network whose name has spaces, without quotes", function()
            local phone = fake_phone()
            phone.info.state = "inactive"
            stub(net.cell, "activate", function(network, code)
                phone.calls[#phone.calls + 1] = { network, code }
                return nil, "Not now"
            end)
            for _, words in ipairs {
                "ACME 7Q2M-K4XD-9PRB-T6WN-HJ3C", "Old Mill Mobile 7Q2M-K4XD-9PRB-T6WN-HJ3C",
                "Old Mill 7q2m k4xd 9prb t6wn hj3c", '"Old Mill" 7Q2M-K4XD-9PRB-T6WN-HJ3C', "ACME not a code",
            } do
                expect(capture("/rom/programs/net/cell.lua activate " .. words))
                    :matches { ok = true, output = "", error = "Not now\n" }
            end
            expect(phone.calls):same {
                { "ACME", "7Q2M-K4XD-9PRB-T6WN-HJ3C" }, { "Old Mill Mobile", "7Q2M-K4XD-9PRB-T6WN-HJ3C" },
                { "Old Mill", "7q2m k4xd 9prb t6wn hj3c" }, { "Old Mill", "7Q2M-K4XD-9PRB-T6WN-HJ3C" },
                { "ACME", "not a code" },
            }
        end)

        it("says which bands the phone may use, and pins it to a cell", function()
            local phone = fake_phone()
            local function run(words) return capture("/rom/programs/net/cell.lua " .. words) end
            expect(run("bands")):matches { ok = true, output = "The phone uses any band.\n", error = "" }
            expect(run("bands b20 1800 B3 2100MHz"))
                :matches { ok = true, output = "The phone only uses the bands b20, b3, b3, b1.\n", error = "" }
            expect(run("bands b33")):matches { ok = true, output = "", error = "There's no cellular band called b33\n" }
            expect(run("bands all")):matches { ok = true, output = "The phone uses any band.\n", error = "" }

            expect(run("pin")):matches { ok = true, output = "The phone chooses its cell.\n", error = "" }
            expect(run("pin 12")):matches {
                ok = true, output = "The phone only uses cell #12, and has no service where it can't hear it.\n", error = "",
            }
            expect(run("pin #12 b3/1")):matches {
                ok = true, output = "The phone only uses cell #12 b3/1, and has no service where it can't hear it.\n", error = "",
            }
            expect(run("pin twelve")):matches { ok = true, output = "", error = "Expected a cell's ID, as 'cell status' lists them: 12, or 12 b3/1.\n" }
            expect(run("pin 12 b3/99").error):eq("Expected a cell's ID, as 'cell status' lists them: 12, or 12 b3/1.\n")
            expect(run("pin off")):matches { ok = true, output = "The phone chooses its cell.\n", error = "" }
            expect(phone.calls):same {
                { "setBands", { "b20", "b3", "b3", "b1" } }, { "setBands", { "b33" } }, { "setBands", "any" },
                { "pinCell", 12 }, { "pinCell", 18075 * 2 ^ 31 + 12 }, { "pinCell", "none" },
            }

            -- How much power it sends with, and what it may send with.
            phone.calls = {}
            expect(run("power")):matches {
                ok = true, error = "",
                output = "The phone sends with 23 dBm, the default.\nThis pocket computer may send with -30 to 23 dBm.\n",
            }
            expect(run("power 17dBm")):matches {
                ok = true, error = "",
                output = "The phone sends with 17 dBm.\nThis pocket computer may send with -30 to 23 dBm.\n",
            }
            expect(run("power 30")):matches { ok = true, output = "", error = "This pocket computer sends with -30 to 23 dBm\n" }
            expect(run("power loud")):matches { ok = true, output = "", error = "Expected a number of dBm, or 'default'.\n" }
            expect(run("power default").output):str_match("^The phone sends with 23 dBm, the default.\n")
            phone.power.cell = 30
            expect(run("power").output):str_match("^The phone sends with this computer's cell's power, 30 dBm.\n")
            expect(phone.calls):same { { "setPower", 17 }, { "setPower", 30 }, { "setPower", "default" } }

            -- What it was told is in what it says about itself: and, for a router, the network behind it.
            phone.info.bands, phone.info.pinned = { "b20", "b3" }, 12
            phone.info.address = "10.64.0.9"
            phone.info.subscriber = { id = "ACME-7", number = "107", routed = { kind = "range", network = "10.64.5.0/28" } }
            local output = capture("/rom/programs/net/cell.lua", "status").output
            expect(output):str_match("\nOnly uses the bands b20, b3\nPinned to cell #12\n")
            expect(output):str_match("\nAddress:  10%.64%.0%.9\nRoutes:   10%.64%.5%.0/28 %(a range of the network's addresses%)\n")
            phone.info.subscriber.routed = { kind = "subnet", network = "192.168.5.0/24" }
            expect(capture("/rom/programs/net/cell.lua", "status").output):str_match("\nRoutes:   192%.168%.5%.0/24 %(a network of its own%)\n")
        end)

        it("turns cell service off and on", function()
            local phone = fake_phone()
            expect(capture("/rom/programs/net/cell.lua off"))
                :matches { ok = true, output = "Cell service is turned off.\n", error = "" }
            expect(capture("/rom/programs/net/cell.lua on"))
                :matches { ok = true, output = "Cell service is turned on.\n", error = "" }
            -- Without a SIM, it listens for cells.
            phone.info = { state = "inactive", enabled = true, selection = "auto", roaming = false }
            expect(capture("/rom/programs/net/cell.lua on"))
                :matches { ok = true, output = "No SIM: listening for cells, from when the computer starts too.\n", error = "" }
            phone.info = { state = "attached", network = "ACME", selection = "auto", roaming = false }
            phone.no_modem = true
            expect(capture("/rom/programs/net/cell.lua on"))
                :matches { ok = true, output = "", error = "This needs a wireless modem\n" }
            expect(phone.calls):same {
                { "setEnabled", false }, { "setEnabled", true }, { "setEnabled", true }, { "setEnabled", true },
            }
        end)

        it("says why a message can't be sent, without waiting", function()
            fake_phone()
            expect(capture("/rom/programs/net/cell.lua send 0042 Hello there"))
                :matches { ok = true, output = "", error = "No SIM\n" }
        end)

        it("says which cell is strongest without a SIM", function()
            local phone = fake_phone()
            phone.info = {
                state = "inactive", enabled = true, selection = "auto", roaming = false, networks = { "ACME", "BETA" },
                strongest = { id = 21, network = "BETA", signal = -64.6 },
            }
            expect(capture("/rom/programs/net/cell.lua", "status")):matches {
                ok = true, error = "",
                output = "No SIM: listening for cells\nStrongest: #21 BETA, -65 dBm\nNetworks in range: ACME, BETA\n",
            }
            phone.info = { state = "none", enabled = false, selection = "auto", roaming = false }
            expect(capture("/rom/programs/net/cell.lua", "status")):matches {
                ok = true, error = "",
                output = "No SIM: activate one with 'cell activate', or listen for cells with 'cell on'\n",
            }
            -- With a SIM, but no modem to run the phone on.
            phone.info = { state = "none", enabled = true, network = "ACME", selection = "auto", roaming = false }
            expect(capture("/rom/programs/net/cell.lua", "status")):matches {
                ok = true, error = "", output = "Not running: this needs a wireless modem\nNetwork:  ACME\n",
            }
        end)

        it("says when the phone is roaming, or kept to one network", function()
            local phone = fake_phone()
            phone.info.roaming, phone.info.serving_network, phone.info.selection = true, "OTHER", "OTHER"
            expect(capture("/rom/programs/net/cell.lua", "status")):matches {
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
