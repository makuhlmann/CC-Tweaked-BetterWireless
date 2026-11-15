-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The celld program", function()
    local capture = require "test_helpers".capture_program

    -- A cell as net.cell describes it. What celld asks net.cell to do is kept in `calls`; it may say no.
    local function setup(info, refuse)
        if not crypto then stub(_G, "crypto", {}) end
        if not enclave then stub(_G, "enclave", {}) end
        local calls = {}
        stub(net.cell, "cellInfo", function() return info end)
        stub(net.cell, "configureCell", function(changes)
            calls[#calls + 1] = { "configure", changes }
            if refuse then return nil, refuse end
            return true, false
        end)
        stub(net.cell, "startCell", function(...)
            calls[#calls + 1] = { "start", ... }
            return true
        end)
        stub(net.cell, "stopCell", function() calls[#calls + 1] = { "stop" } end)
        return calls
    end

    local function serving(cores, networks)
        local links = {}
        for i, core in ipairs(cores) do links[i] = { core = core, state = "serving", network = networks[i] } end
        return {
            state = "serving", id = 11, area = 3, cores = cores, enabled = true, links = links, carrier = "b20/1", ul = 8320,
            core = cores[1], network = networks[1],
        }
    end

    local function run(...) return capture("celld", ...) end

    it("changes nothing when a command or value is mistyped", function()
        local calls = setup(serving({ "core.acme" }, { "ACME" }))
        for _, case in ipairs {
            { { "core.acme" }, "There's no command called core.acme. To serve a core's network, use 'celld add <core>'.\n" },
            { { "set", "pwer", "30" }, "There's no setting called pwer. They're area, band, interval, pos, power and service.\n" },
            {
                { "set", "band", "b33" },
                "There's no cellular band called b33. They're b31 (450MHz), b28 (700MHz), b20 (800MHz), b8 (900MHz), "
                    .. "b3 (1800MHz), b1 (2100MHz), b7 (2600MHz).\n",
            },
            {
                { "set", "band", "b20", "b3x" },
                "There's no cellular band called b3x. They're b31 (450MHz), b28 (700MHz), b20 (800MHz), b8 (900MHz), "
                    .. "b3 (1800MHz), b1 (2100MHz), b7 (2600MHz).\n",
            },
            { { "set", "band", "b20", "b3/99" }, "There's no carrier called b3/99. A band's carriers are numbered from 1, as in b20/1.\n" },
            { { "set", "band" }, "Usage: celld set band <band>...\n" },
            { { "set", "band", "b3", "b3", "b3", "b3", "b3", "b3", "b3", "b3", "b3" }, "Usage: celld set band <band>...\n" },
            { { "set", "power", "lots" }, "Expected a number, not lots.\n" },
            { { "set", "pos", "1", "2" }, "Usage: celld set pos <x> <y> <z>\n" },
            { { "set", "pos", "1", "2", "z" }, "A cell's position is three whole numbers: its computer's x, y and z.\n" },
            { { "set", "area", "3", "4" }, "Usage: celld set area <number>\n" },
            { { "set", "service", "everything" }, "A cell's service is sms (it only carries messages) or full.\n" },
            { { "unset", "colour" }, "There's no setting called colour. They're area, band, interval, pos, power and service.\n" },
            { { "remove", "core.acmr" }, "This cell doesn't connect to core.acmr. Its cores are core.acme.\n" },
            { { "add", "CORE.ACME" }, "This cell connects to core.acme already.\n" },
        } do
            local result = run(table.unpack(case[1]))
            expect(result):describe(table.concat(case[1], " ")):matches { ok = false, error = case[2] }
        end
        -- Too many or too few words only show how to use it.
        for _, words in ipairs { { "add" }, { "add", "a", "b" }, { "remove" }, { "set" }, { "unset", "pos", "x" }, { "stop", "now" } } do
            expect(run(table.unpack(words)).output):describe(table.concat(words, " ")):str_match("^Usages:\n")
        end
        expect(calls):same {}
    end)

    it("takes cores called anything, and adds them to those it has", function()
        local calls = setup(serving({ "core.acme" }, { "ACME" }))
        for _, core in ipairs { "band", "power", "3", "stop", "sms", "10.0.0.9" } do
            expect(run("add", core)):describe(core):matches { ok = true, error = "" }
        end
        expect(calls):same {
            { "configure", { cores = { "core.acme", "band" } } },
            { "configure", { cores = { "core.acme", "power" } } },
            { "configure", { cores = { "core.acme", "3" } } },
            { "configure", { cores = { "core.acme", "stop" } } },
            { "configure", { cores = { "core.acme", "sms" } } },
            { "configure", { cores = { "core.acme", "10.0.0.9" } } },
        }
    end)

    it("starts a cell when its first core is added, but not one which was stopped", function()
        local calls = setup({ state = "stopped", id = 11, enabled = true })
        expect(run("add", "core.acme")):matches { ok = true, error = "" }
        expect(calls):same { { "configure", { cores = { "core.acme" } } }, { "start" } }

        calls = setup({ state = "stopped", id = 11, enabled = false, cores = { "core.acme" } })
        expect(run("add", "core.beta")):matches {
            ok = true, output = "Added core.beta. The cell is stopped: 'celld start' starts it.\n",
        }
        expect(calls):same { { "configure", { cores = { "core.acme", "core.beta" } } } }
    end)

    it("removes a core by its name or its network, and carries on serving the others", function()
        local calls = setup(serving({ "core.acme", "10.0.0.9" }, { "ACME", "BETA" }))
        expect(run("remove", "beta")):matches {
            ok = true, output = "Removed 10.0.0.9: the cell no longer serves its network, and carries on serving the others.\n",
        }
        expect(run("remove", "Core.Acme").ok):eq(true)
        expect(calls):same { { "configure", { cores = { "core.acme" } } }, { "configure", { cores = { "10.0.0.9" } } } }

        calls = setup(serving({ "core.acme" }, { "ACME" }))
        expect(run("remove", "core.acme")):matches {
            ok = true, output = "Removed core.acme. The cell has no cores left, so it stopped. 'celld add <core>' starts it again.\n",
        }
        expect(calls):same { { "configure", { cores = {} } } }
    end)

    it("sets and unsets one setting at a time", function()
        local calls = setup(serving({ "core.acme" }, { "ACME" }))
        for _, words in ipairs {
            { "set", "band", "1800" }, { "set", "band", "B3" }, { "set", "band", "3" }, { "set", "band", "1800MHz" },
            { "set", "area", "4" }, { "set", "interval", "0.5" }, { "set", "pos", "1", "-2", "3" }, { "set", "power", "30" },
            { "set", "service", "sms" }, { "set", "service", "full" }, { "unset", "band" }, { "unset", "pos" },
        } do
            expect(run(table.unpack(words))):describe(table.concat(words, " ")):matches { ok = true, error = "" }
        end
        expect(calls):same {
            { "configure", { band = "b3" } }, { "configure", { band = "b3" } }, { "configure", { band = "b3" } },
            { "configure", { band = "b3" } }, { "configure", { area = 4 } }, { "configure", { interval = 0.5 } },
            { "configure", { pos = { 1, -2, 3 } } }, { "configure", { power = 30 } }, { "configure", { service = "sms" } },
            { "configure", { service = false } }, { "configure", { band = false } }, { "configure", { pos = false } },
        }
        expect(run("set", "pos", "1", "-2", "3").output):eq("The cell says it's at 1, -2, 3.\n")
    end)

    it("takes several bands and carriers, for a cell on each", function()
        local calls = setup(serving({ "core.acme" }, { "ACME" }))
        expect(run("set", "band", "b20", "1800", "B3/2", "3")):matches {
            ok = true, error = "",
            output = "The computer has its cells on b20 (800MHz), b3 (1800MHz), b3/2, b3 (1800MHz) already, and they stay there.\n",
        }
        -- One carrier, by name, is a list too: only a band alone is as it always was.
        expect(run("set", "band", "1800mhz/2")):matches { ok = true, error = "" }
        expect(run("set", "band", "800")):matches { ok = true, error = "" }
        expect(calls):same {
            { "configure", { band = { "b20", "b3", "b3/2", "b3" } } }, { "configure", { band = { "b3/2" } } },
            { "configure", { band = "b20" } },
        }
    end)

    it("says why net.cell wouldn't change something", function()
        setup(serving({ "core.acme" }, { "ACME" }), "No network this cell serves has a carrier in band b7, only in b20")
        expect(run("set", "band", "b7")):matches {
            ok = false, output = "", error = "No network this cell serves has a carrier in band b7, only in b20\n",
        }
    end)

    it("shows how the cell is doing, with its settings", function()
        local info = serving({ "core.acme" }, { "ACME" })
        info.band, info.current_interval, info.pos, info.power, info.service = "b3", 2, { 1, 2, -3 }, 30, "sms"
        setup(info)
        expect(run("status")):matches {
            ok = true,
            output = table.concat({
            "Cell #11, area 3.",
            "On b20/1, reached on channel 8320.",
            "core.acme: serving ACME.",
            "Settings ('celld set <setting> <value>'):",
            "  area      3",
            "  band      b3 (1800MHz)",
            "  interval  as its core says (2 seconds)",
            "  pos       1 2 -3",
            "  power     30 dBm",
            "  service   messages only",
            "",
        }, "\n"),
        }

        -- A computer with a cell on each of several carriers, one of whose networks has no carrier for all it wants.
        info = serving({ "core.acme", "core.beta" }, { "ACME", "BETA" })
        info.band = { "b20", "b3/2", "b7" }
        info.cells = {
            { id = 11, carrier = "b20/1", ul = 8320 }, { id = 18125 * 2 ^ 31 + 11, carrier = "b3/2", ul = 17150 },
        }
        info.links[2].unplaced = { "b7" }
        setup(info)
        expect(run("status").output):eq(table.concat({
            "Cell #11, area 3.",
            "On b20/1, reached on channel 8320.",
            "On b3/2, reached on channel 17150.",
            "core.acme: serving ACME.",
            "core.beta: serving BETA.",
            "BETA has no carrier for b7: the cell isn't on it.",
            "Settings ('celld set <setting> <value>'):",
            "  area      3",
            "  band      b20 (800MHz), b3/2, b7 (2600MHz)",
            "  interval  as its core says",
            "  pos       not said",
            "  power     the modem's own",
            "  service   full",
            "",
        }, "\n"))

        setup({ state = "stopped", id = 11, enabled = false, cores = { "core.acme", "core.beta" }, area = 0, interval = 4 })
        expect(run("status").output):eq(table.concat({
            "The cell is stopped. It starts again with 'celld start'.",
            "Cores: core.acme, core.beta",
            "Settings ('celld set <setting> <value>'):",
            "  area      0",
            "  band      any (its core picks)",
            "  interval  4 seconds",
            "  pos       not said",
            "  power     the modem's own",
            "  service   full",
            "",
        }, "\n"))

        setup({ state = "stopped", id = 11, enabled = true })
        expect(run("status").output):str_match("^This computer isn't running a cell. Start one with 'celld add <core>'.\n")
    end)

    it("starts, stops and starts the cell again", function()
        local calls = setup({ state = "stopped", id = 11, enabled = false, cores = { "core.acme" } })
        expect(run("start").ok):eq(true)
        expect(run("stop")):matches { ok = true, output = "Stopped the cell. It starts again with 'celld start'.\n" }
        expect(calls):same { { "start" }, { "stop" } }

        calls = setup(serving({ "core.acme" }, { "ACME" }))
        expect(run("start")):matches { ok = true, output = "The cell is running. 'celld restart' connects to its cores again.\n" }
        expect(run("restart").ok):eq(true)
        expect(calls):same { { "stop" }, { "start" } }

        calls = setup({ state = "stopped", id = 11, enabled = true })
        expect(run("start")):matches {
            ok = false, error = "The cell has no cores to connect to. Add one with 'celld add <core>'.\n",
        }
        expect(calls):same {}
    end)
end)
