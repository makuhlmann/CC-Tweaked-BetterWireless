-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local with_window = require "test_helpers".with_window
local capture = require "test_helpers".capture_program

--[[ The menus `celld` and `cellcore` open when they're run with nothing asked of them: what they show, and that what's
chosen in them asks `net.cell` (or the core) for just what the programs' commands do. ]]
describe("The menus of celld and cellcore", function()
    local CONFIG = "/.cell/config"

    -- Timers are made up, so tests choose when they go off.
    local function fake_timers()
        local timers, next_timer = {}, 1000000
        stub(os, "startTimer", function(seconds)
            next_timer = next_timer + 1
            timers[next_timer] = seconds
            return next_timer
        end)
        stub(os, "cancelTimer", function(id) timers[id] = nil end)
        return timers
    end

    --[[ Run a program on a screen of some size (a computer's, if not said), and give a function the means to use it:
    to press keys and type, and to read the screen. ]]
    local function run(args, options, body)
        if not crypto then stub(_G, "crypto", {}) end
        if not enclave then stub(_G, "enclave", {}) end
        local timers = fake_timers()
        with_window(options.width or 51, options.height or 19, function()
            local screen = term.current()
            local result
            local co = coroutine.create(function(...) result = shell.run(...) end)
            local app = {}

            function app.line(y) return (screen.getLine(y):gsub(" +$", "")) end
            function app.lines()
                local _, height = screen.getSize()
                local lines = {}
                for y = 1, height do lines[y] = app.line(y) end
                return lines
            end
            function app.text() return table.concat(app.lines(), "\n") end
            -- The first line with some text on it.
            function app.find(text)
                for y, line in ipairs(app.lines()) do
                    if line:find(text, 1, true) then return y, line end
                end
                return nil
            end
            -- What's written right across the screen, whichever lines it's broken over.
            function app.says(text)
                local all = table.concat(app.lines(), " "):gsub("%s+", " ")
                return all:find(text:gsub("%s+", " "), 1, true) ~= nil
            end
            function app.event(...)
                assert(coroutine.resume(co, ...))
                if coroutine.status(co) == "dead" and result ~= true then
                    error("The program failed:\n" .. app.text(), 0)
                end
            end
            function app.key(...)
                for _, key in ipairs({ ... }) do app.event("key", key, false) end
            end
            function app.type(text)
                for char in text:gmatch(".") do app.event("char", char) end
            end
            -- Type into a line, in place of what's there, and press Enter.
            function app.enter(text)
                app.key(keys.home)
                for _ = 1, 80 do app.key(keys.delete) end
                app.type(text)
                app.key(keys.enter)
            end
            -- Which line of a list is the chosen one: white, with black text.
            function app.chosen()
                local _, height = screen.getSize()
                for y = 2, height - 1 do
                    local _, _, bg = screen.getLine(y)
                    if bg:sub(1, 1) == "0" then return app.line(y), y end
                end
                return nil
            end
            -- Move to the item of a list which says something, and choose it.
            function app.choose(text)
                app.key(keys.home)
                for _ = 1, 40 do
                    local line = app.chosen()
                    if line and line:find(text, 1, true) then return app.key(keys.enter) end
                    app.key(keys.down)
                end
                error(("Nothing to choose says %q:\n%s"):format(text, app.text()), 2)
            end
            -- Let every timer go off, as when time passes.
            function app.tick()
                local due = {}
                for id in pairs(timers) do due[#due + 1] = id end
                table.sort(due)
                for _, id in ipairs(due) do
                    timers[id] = nil
                    app.event("timer", id)
                end
            end
            function app.finished() return coroutine.status(co) == "dead" end

            app.event("/rom/programs/net/" .. args[1] .. ".lua", table.unpack(args, 2))
            body(app)
        end)
    end

    -- Random numbers which are the same each time the tests run.
    local function random_numbers(seed)
        local state = seed
        return function(low, high)
            state = (state * 1103515245 + 12345) % 2147483648
            return low + math.floor(state / 2147483648 * (high - low + 1))
        end
    end

    local KEYS = {
        keys.up, keys.down, keys.down, keys.enter, keys.enter, keys.enter, keys.backspace, keys.tab, keys.home, keys["end"],
        keys.left, keys.right, keys.delete, keys.pageUp, keys.numPadEnter, keys.f1,
    }
    local TEXTS = { "q", "y", "n", "b3", "b20/1 b3/2", "5", "0.1", "ACME-9", "core.x", "10.0.0.1/8", " ", ("x"):rep(300), "\n" }

    -- Use a menu at random, on a screen of some size, while what it shows changes. It must neither fail nor hang.
    local function storm(args, width, height, seed, count, change)
        local random = random_numbers(seed)
        local done = {}
        local ok, err = pcall(run, args, { width = width, height = height }, function(app)
            for _ = 1, count do
                if app.finished() then break end
                local what = random(1, 10)
                if what <= 6 then
                    local key = KEYS[random(1, #KEYS)]
                    done[#done + 1] = "key " .. tostring(keys.getName(key))
                    app.event("key", key, random(1, 8) == 1)
                elseif what <= 8 then
                    local text = TEXTS[random(1, #TEXTS)]
                    done[#done + 1] = "type " .. text:sub(1, 12)
                    if random(1, 3) == 1 then app.event("paste", text) else app.type(text) end
                elseif what == 9 then
                    done[#done + 1] = "click"
                    app.event("mouse_click", random(1, 2), random(1, width), random(1, height))
                else
                    done[#done + 1] = "time"
                    change(random)
                    app.tick()
                end
            end
        end)
        if not ok then
            error(("%s\nafter: %s"):format(tostring(err), table.concat(done, ", ", math.max(1, #done - 30))), 0)
        end
    end

    it("keep what's typed while they wait for a core's answer, for themselves alone", function()
        local menu = require "cc.internal.net.cell.menu"
        local queued = {}
        stub(os, "queueEvent", function(...) queued[#queued + 1] = { ... } end)
        local screen = window.create(term.current(), 1, 1, 30, 10, false)
        local old = term.redirect(screen)
        local ok, err = pcall(function()
            -- Something which waits for one kind of event, as a request to a core does, and throws the others away:
            -- and then a line to type in.
            local co = coroutine.create(function()
                local asked, answer = menu.wait_for(function(asked)
                    local _, answer = os.pullEvent("answer")
                    return asked, answer
                end, "asked")
                return asked, answer, menu.input_screen { title = "Name" }
            end)
            assert(coroutine.resume(co))
            assert(coroutine.resume(co, "char", "a"))
            assert(coroutine.resume(co, "timer", 5))
            assert(coroutine.resume(co, "key", keys.left, false))
            assert(coroutine.resume(co, "char", "b"))
            -- What the user did is there for the menu afterwards, in order: before what they do next.
            assert(coroutine.resume(co, "answer", 42))
            expect(coroutine.status(co)):eq("suspended")
            expect(screen.getLine(3)):str_match("^ba ")
            assert(coroutine.resume(co, "char", "c"))
            expect({ coroutine.resume(co, "key", keys.enter, false) }):same { true, "asked", 42, "bca" }
            -- It's nobody else's: nothing went back on the computer's queue, for other programs to see twice.
            expect(queued):same {}

            -- An error while waiting is the caller's, and Ctrl+T ends it.
            expect.error(menu.wait_for, function() error("Lost the core", 0) end):eq("Lost the core")
            co = coroutine.create(function() return menu.wait_for(os.pullEvent, "answer") end)
            assert(coroutine.resume(co))
            expect({ coroutine.resume(co, "terminate") }):same { false, "Terminated" }
        end)
        term.redirect(old)
        if not ok then error(err, 0) end
    end)

    it("type a held key's letters into a line, again and again", function()
        local menu = require "cc.internal.net.cell.menu"
        local screen = window.create(term.current(), 1, 1, 30, 10, false)
        local old = term.redirect(screen)
        local ok, err = pcall(function()
            local co = coroutine.create(function() return menu.input_screen { title = "Name" } end)
            assert(coroutine.resume(co))
            assert(coroutine.resume(co, "key", keys.a, false))
            assert(coroutine.resume(co, "char", "a"))
            for _ = 1, 3 do
                assert(coroutine.resume(co, "key", keys.a, true))
                assert(coroutine.resume(co, "char", "a"))
            end
            -- Enter which is still held from the screen before doesn't give the text: a new press does.
            assert(coroutine.resume(co, "key", keys.enter, true))
            expect(coroutine.status(co)):eq("suspended")
            expect({ coroutine.resume(co, "key", keys.enter, false) }):same { true, "aaaa" }
        end)
        term.redirect(old)
        if not ok then error(err, 0) end
    end)

    it("draw only what changed, and nothing for events which change nothing", function()
        local menu = require "cc.internal.net.cell.menu"
        local screen = window.create(term.current(), 1, 1, 30, 10, false)
        -- Count what's written to the screen: over a remote shell, each time is something to send.
        local writes = 0
        local counting = setmetatable({}, { __index = screen })
        for _, method in ipairs { "write", "blit", "clear", "clearLine", "scroll" } do
            counting[method] = function(...)
                writes = writes + 1
                return screen[method](...)
            end
        end
        local timer = 0
        stub(os, "startTimer", function()
            timer = timer + 1
            return timer
        end)
        stub(os, "cancelTimer", function() end)
        -- What happens on a computer all the time, and is no screen's business.
        local noise = {
            { "timer", 999 }, { "modem_message", "top", 1, 2, "x", 3 }, { "key_up", keys.a }, { "rshd_output" },
            { "key", keys.leftShift, false }, { "cell_bar" },
        }
        local old = term.redirect(counting)
        local ok, err = pcall(function()
            local co = coroutine.create(function() return menu.input_screen { title = "Name", label = "Name:", note = "A note." } end)
            assert(coroutine.resume(co))
            expect(writes > 0):eq(true)
            writes = 0
            for _, event in ipairs(noise) do assert(coroutine.resume(co, table.unpack(event))) end
            expect(writes):eq(0)
            -- A character is the line, not the screen.
            assert(coroutine.resume(co, "char", "a"))
            expect(screen.getLine(3)):str_match("^Name: a +$")
            expect(writes <= 2):describe(writes .. " writes for a character"):eq(true)
            writes = 0
            assert(coroutine.resume(co, "key", keys.backspace, false))
            expect(screen.getLine(3)):str_match("^Name: +$")
            expect(writes <= 2):eq(true)
            -- Backspace in an empty line does nothing at all: it doesn't leave, however often it's pressed.
            writes = 0
            for _ = 1, 5 do assert(coroutine.resume(co, "key", keys.backspace, false)) end
            expect({ writes, coroutine.status(co) }):same { 0, "suspended" }
            expect({ coroutine.resume(co, "key", keys.tab, false) }):same { true }

            -- A list which looks again and finds the same writes nothing; one line changed is one line written.
            local items = { { text = "One", id = 1 }, { text = "Two", id = 2 }, { text = "Three", id = 3 } }
            co = coroutine.create(function()
                return menu.list_screen {
                    title = function() return "List" end, items = function() return items end, choose = function() end,
                    refresh = 1,
                }
            end)
            assert(coroutine.resume(co))
            writes = 0
            assert(coroutine.resume(co, "timer", timer))
            for _, event in ipairs(noise) do assert(coroutine.resume(co, table.unpack(event))) end
            expect(writes):eq(0)
            items[3] = { text = "Four", id = 3 }
            assert(coroutine.resume(co, "timer", timer))
            expect(writes):eq(1)
            expect(screen.getLine(5)):str_match("^Four +$")
            -- Moving along the list is the two lines it moves between.
            writes = 0
            assert(coroutine.resume(co, "key", keys.down, false))
            expect(writes):eq(2)
            -- Once something else drew on the screen, all of it is drawn again.
            menu.clear()
            writes = 0
            assert(coroutine.resume(co, "timer", timer))
            expect(writes >= 4):eq(true)
            expect(screen.getLine(1)):str_match("^List")
        end)
        term.redirect(old)
        if not ok then error(err, 0) end
    end)

    describe("celld", function()
        --[[ A cell behind net.cell, as `celld` would have set it up: it serves ACME through core.acme. What's asked of
        net.cell is kept in `calls`, and done to the cell, unless `refuse` says why not. ]]
        local function fake_cell(info)
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            local cell = {
                calls = {},
                info = info or {
                    state = "serving", id = 11, area = 3, cores = { "core.acme" }, enabled = true, core = "core.acme",
                    network = "ACME", carrier = "b20/1", ul = 8320, fingerprint = "aaaa bbbb cccc dddd eeee",
                    links = { { core = "core.acme", state = "serving", network = "ACME", carriers = { "b20/1", "b3/1", "b3/2" } } },
                },
            }
            stub(net.cell, "cellInfo", function() return cell.info end)
            stub(net.cell, "configureCell", function(changes)
                cell.calls[#cell.calls + 1] = { "configure", changes }
                if cell.refuse then return nil, cell.refuse end
                for key, value in pairs(changes) do
                    if key == "cores" then
                        cell.info.cores, cell.info.links = value[1] and value or nil, {}
                        for i, core in ipairs(value) do cell.info.links[i] = { core = core, state = "connecting" } end
                        if not value[1] then cell.info.state = "stopped" end
                    else
                        cell.info[key] = value or nil
                    end
                end
                return true, cell.restarts or false
            end)
            stub(net.cell, "startCell", function()
                cell.calls[#cell.calls + 1] = { "start" }
                if cell.refuse then return nil, cell.refuse end
                cell.info.state, cell.info.enabled = "connecting", true
                return true
            end)
            stub(net.cell, "stopCell", function()
                cell.calls[#cell.calls + 1] = { "stop" }
                cell.info.state, cell.info.enabled, cell.info.links = "stopped", false, nil
            end)
            return cell
        end

        it("shows the cell and what can be done with it, and leaves with Q", function()
            fake_cell()
            run({ "celld" }, {}, function(app)
                expect(app.line(1)):str_match("^Cell #11 +serving ACME$")
                expect(app.chosen()):str_match("^Status +serving ACME$")
                for _, text in ipairs { "Cores", "Settings", "Restart the cell", "Stop the cell" } do
                    expect(app.find(text) ~= nil):describe(text):eq(true)
                end
                expect(app.find("Start the cell")):eq(nil)
                app.type("q")
                expect(app.finished()):eq(true)
            end)
        end)

        it("shows how the cell is doing, as it changes", function()
            local cell = fake_cell()
            cell.info.cells = { { id = 11, carrier = "b20/1", ul = 8320 }, { id = 2 ^ 40, carrier = "b3/2", ul = 17150 } }
            run({ "celld" }, {}, function(app)
                app.choose("Status")
                expect(app.says("Cell #11, area 3")):eq(true)
                expect(app.says("b20/1, channel 8320")):eq(true)
                expect(app.says("b3/2, channel 17150")):eq(true)
                expect(app.says("core.acme: serving ACME")):eq(true)

                cell.info.state = "lost"
                cell.info.links[1] = { core = "core.acme", state = "lost", error = "No route to host", retry = 8 }
                app.tick()
                expect(app.says("core.acme: No route to host")):eq(true)
                expect(app.says("again in 8 s")):eq(true)

                -- Back to where it came from, which says so too.
                app.type("q")
                expect(app.line(1)):str_match("^Cell #11 +can't reach its core$")

                -- A network with no carrier for it has it wait, off the air: which is said, with what it does have.
                cell.info.state, cell.info.cells, cell.info.carrier = "unplaced", nil, nil
                cell.info.links[1] = { core = "core.acme", state = "unplaced", network = "ACME", carriers = {} }
                app.tick()
                expect(app.line(1)):str_match("^Cell #11 +no carrier$")
                expect(app.says("Off the air: ACME has no carriers yet.")):eq(true)
                cell.info.links[1] = { core = "core.acme", state = "unplaced", network = "ACME", carriers = { "b20/1" }, unplaced = { "b7", "b3/2" } }
                app.tick()
                expect(app.says("Off the air: ACME has no carrier for b7, b3/2.")):eq(true)
                app.choose("Status")
                expect(app.says("core.acme: ACME has no carrier for b7, b3/2")):eq(true)
                expect(app.says("offers b20/1")):eq(true)
            end)
        end)

        it("says how a cell which waits is allowed", function()
            local cell = fake_cell()
            cell.info.state, cell.info.links[1] = "waiting", { core = "core.acme", state = "waiting" }
            run({ "celld" }, {}, function(app)
                expect(app.says("Waiting to be allowed as #11: aaaa bbbb cccc dddd eeee")):eq(true)
            end)
        end)

        it("changes one setting at a time, and says what that did", function()
            local cell = fake_cell()
            run({ "celld" }, {}, function(app)
                app.choose("Settings")
                expect(app.find("interval")):ne(nil)
                expect(select(2, app.find("band"))):str_match("^band +any %(its core picks%)$")
                expect(select(2, app.find("override"))):str_match("^override +off$")

                app.choose("interval")
                expect(app.line(1)):eq("Set the interval")
                app.enter("4")
                expect(cell.calls):same { { "configure", { interval = 4 } } }
                expect(select(2, app.find("interval"))):str_match("^interval +4 seconds$")
                expect(app.says("interval: 4 seconds.")):eq(true)

                -- What it has is there to change, and an empty line puts it back as it is when it's not set.
                app.choose("interval")
                expect(app.line(3)):eq("interval: 4")
                app.enter("")
                expect(cell.calls[2]):same { "configure", { interval = false } }
                expect(select(2, app.find("interval"))):str_match("^interval +as its core says$")

                app.choose("pos")
                app.enter("1 -2 3")
                expect(cell.calls[3]):same { "configure", { pos = { 1, -2, 3 } } }
                app.choose("power")
                app.enter("30")
                expect(cell.calls[4]):same { "configure", { power = 30 } }

                app.choose("service")
                app.choose("Messages only")
                expect(cell.calls[5]):same { "configure", { service = "sms" } }
                expect(select(2, app.find("service"))):str_match("^service +messages only$")
                app.choose("service")
                app.choose("Full")
                expect(cell.calls[6]):same { "configure", { service = false } }
                expect(#cell.calls):eq(6)
            end)
        end)

        it("changes nothing when a value won't do, and says why", function()
            local cell = fake_cell()
            run({ "celld" }, {}, function(app)
                app.choose("Settings")
                app.choose("power")
                app.enter("lots")
                expect(app.says("Expected a number, not lots.")):eq(true)
                expect(app.line(1)):eq("Set the power")
                -- Net.cell may refuse what looked fine.
                cell.refuse = "This computer's modem sends with -30 to 50 dBm"
                app.enter("90")
                expect(app.says("This computer's modem sends with -30 to 50 dBm")):eq(true)
                expect(app.line(1)):eq("Set the power")
                app.key(keys.tab)
                expect(app.line(1)):str_match("^Settings")

                cell.refuse = nil
                app.choose("pos")
                app.enter("1 2")
                expect(app.says("Expected <x> <y> <z>.")):eq(true)
                app.enter("1 2 z")
                expect(app.says("A cell's position is three whole numbers")):eq(true)
                -- Backspace only ever takes a character away: in an empty line it doesn't leave the screen.
                app.key(keys.home)
                for _ = 1, 3 do app.key(keys.backspace) end
                app.event("key", keys["end"], false)
                for _ = 1, 8 do app.key(keys.backspace) end
                expect(app.line(3)):eq("pos:")
                expect(app.line(1)):eq("Set the pos")
                app.key(keys.tab)
                expect(app.line(1)):str_match("^Settings")
                expect(cell.calls):same { { "configure", { power = 90 } } }
            end)
        end)

        it("has its bands ticked from those its cores offer, and asks before a change which may start it again", function()
            local cell = fake_cell()
            cell.restarts = true
            cell.info.cells = { { id = 11, carrier = "b20/1", ul = 8320 } }
            run({ "celld" }, {}, function(app)
                app.choose("Settings")
                app.choose("band")
                expect(app.line(1)):str_match("^Bands +any$")
                expect(app.chosen()):str_match("^%[x%] Any band +its core picks$")
                -- Only the bands its core's network has a carrier in.
                expect(select(2, app.find("b20 "))):str_match("^b20  800 MHz +%-$")
                expect(select(2, app.find("b3 "))):str_match("^b3   1800 MHz +%-$")
                for _, band in ipairs { "b31", "b28", "b8 ", "b1 ", "b7 " } do expect(app.find(band)):describe(band):eq(nil) end

                app.choose("b20 ")
                expect(app.line(1)):str_match("^b20, 800 MHz")
                expect(app.find("b20/2")):eq(nil)
                app.choose("b20/1")
                -- Each carrier's frequencies, and the networks which have it.
                expect(app.chosen()):str_match("^%[x%] b20/1 +791%-796 MHz +ACME$")
                app.type("q")
                app.choose("b3 ")
                app.choose("Any carrier")
                expect(app.chosen()):str_match("^%[x%] Any carrier +its core picks$")
                app.choose("b3/2")
                -- Space ticks and unticks too.
                app.type(" ")
                expect(app.chosen()):str_match("^%[ %] b3/2 +1810%-1815 MHz +ACME$")
                app.type(" ")
                expect(app.line(1)):str_match("^b3, 1800 MHz +any /2$")
                app.key(keys.backspace)
                expect(app.line(1)):str_match("^Bands +3 chosen$")
                expect(app.chosen()):str_match("^b3   1800 MHz +any /2$")
                expect(app.find("[ ] Any band")):ne(nil)

                -- Nothing is the cell's until the screen is left: and then not without asking.
                expect(#cell.calls):eq(0)
                app.type("q")
                expect(app.line(1)):eq("Change the band")
                app.type("n")
                expect(#cell.calls):eq(0)
                expect(app.says("Nothing was changed.")):eq(true)

                app.choose("band")
                app.choose("b20 ")
                app.choose("b20/1")
                app.type("q")
                app.choose("b3 ")
                app.choose("b3/2")
                app.type("q")
                app.type("q")
                app.type("y")
                expect(cell.calls):same { { "configure", { band = { "b20/1", "b3/2" } } } }
                expect(app.says("The cell started again.")):eq(true)
                expect(select(2, app.find("band"))):str_match("^band +b20/1, b3/2$")

                -- Left as it was, nothing is asked. And any band again.
                app.choose("band")
                expect(app.line(1)):str_match("^Bands +2 chosen$")
                app.type("q")
                expect(app.line(1)):str_match("^Settings")
                expect(#cell.calls):eq(1)
                app.choose("band")
                app.choose("Any band")
                expect(app.line(1)):str_match("^Bands +any$")
                app.type("q")
                app.type("y")
                expect(cell.calls[2]):same { "configure", { band = false } }
                -- One band alone is that band.
                app.choose("band")
                app.choose("b3 ")
                app.choose("Any carrier")
                app.type("q")
                app.type("q")
                app.type("y")
                expect(cell.calls[3]):same { "configure", { band = "b3" } }

                app.choose("area")
                app.enter("5")
                app.key(keys.enter)
                expect(cell.calls[4]):same { "configure", { area = 5 } }
            end)
        end)

        it("offers what each of its networks has, and anything at all once that's overridden", function()
            local cell = fake_cell()
            cell.info.links = {
                { core = "core.acme", state = "serving", network = "ACME", carriers = { "b20/1" } },
                { core = "core.beta", state = "serving", network = "BETA", carriers = { "b20/1", "b3/2" } },
                { core = "core.gamma", state = "lost", error = "No route to host" },
            }
            -- It was set to a carrier none of them has (any more).
            cell.info.band = { "b20/1", "b7/3" }
            cell.info.cells = { { id = 11, carrier = "b20/1", ul = 8320 } }
            run({ "celld" }, {}, function(app)
                app.choose("Settings")
                app.choose("band")
                expect(app.line(1)):str_match("^Bands +2 chosen$")
                expect(select(2, app.find("b20 "))):str_match("^b20  800 MHz +/1$")
                expect(select(2, app.find("b3 "))):str_match("^b3   1800 MHz +%-$")
                expect(select(2, app.find("b7 "))):str_match("^b7   2600 MHz +/3$")
                expect(app.find("b1 ")):eq(nil)
                expect(select(2, app.find("Override"))):str_match("^Override +off$")

                app.choose("b20 ")
                expect(select(2, app.find("b20/1"))):str_match("^%[x%] b20/1 +791%-796 MHz +ACME, BETA$")
                app.type("q")
                app.choose("b3 ")
                expect(app.find("b3/1")):eq(nil)
                expect(select(2, app.find("b3/2"))):str_match("^%[ %] b3/2 +1810%-1815 MHz +BETA$")
                app.type("q")
                -- What's no longer offered is only there to be unticked.
                app.choose("b7 ")
                expect(app.find("Any carrier")):eq(nil)
                expect(app.chosen()):str_match("^%[x%] b7/3 +2630%-2635 MHz +not offered$")
                app.key(keys.enter)
                expect(app.says("None of its carriers is offered.")):eq(true)
                app.type("q")
                expect(app.find("b7 ")):eq(nil)

                -- The override says what it may do first, and is the cell's at once.
                app.choose("Override")
                expect(app.line(1)):eq("Band override")
                expect(app.says("This may violate network assignment agreements.")):eq(true)
                app.type("n")
                expect(#cell.calls):eq(0)
                expect(app.line(1)):str_match("^Bands")
                app.choose("Override")
                app.type("y")
                expect(cell.calls):same { { "configure", { override = true } } }
                expect(select(2, app.find("Override"))):str_match("^Override +on$")
                expect(app.says("Override: carriers its cores don't offer may be chosen.")):eq(true)
                -- Then every band is there, and every carrier.
                for _, band in ipairs { "b31", "b28", "b20", "b8 ", "b3 ", "b1 ", "b7 " } do expect(app.find(band)):describe(band):ne(nil) end
                app.choose("b1 ")
                app.choose("b1/2")
                expect(app.chosen()):str_match("^%[x%] b1/2 +2115%-2120 MHz +not offered$")
                app.type("q")
                app.type("q")
                app.type("y")
                expect(cell.calls[2]):same { "configure", { band = { "b20/1", "b1/2" } } }
                expect(select(2, app.find("override"))):str_match("^override +on$")

                -- Off again needs no asking.
                app.choose("override")
                expect(cell.calls[3]):same { "configure", { override = false } }
                expect(select(2, app.find("override"))):str_match("^override +off$")
                -- And on, from the settings: with the same warning.
                app.choose("override")
                expect(app.says("This may violate network assignment agreements.")):eq(true)
                app.type("y")
                expect(cell.calls[4]):same { "configure", { override = true } }
            end)

            -- A cell whose cores offer nothing (it isn't running, or their networks have no carriers yet) says so.
            cell = fake_cell({ state = "stopped", id = 11, enabled = false, cores = { "core.acme" }, area = 0 })
            run({ "celld" }, {}, function(app)
                app.choose("Settings")
                app.choose("band")
                expect(app.says("Its cores offer no carriers yet.")):eq(true)
                expect(app.find("b20")):eq(nil)
                -- No more may be chosen than a computer can run cells.
                cell.info.override = true
                app.tick()
                app.choose("b3 ")
                for i = 1, 8 do app.choose("b3/" .. i) end
                expect(app.line(1)):str_match("^b3, 1800 MHz +/1 /2 /3 /4 /5 /6 /7 /8$")
                app.choose("b3/9")
                expect(app.says("At most 8 may be chosen.")):eq(true)
                expect(app.chosen()):str_match("^%[ %] b3/9")
                app.key(keys.up, keys.enter)
                app.type("q")
                app.type("q")
                -- A cell which isn't running has nothing to start again, so nothing is asked.
                expect(cell.calls):same { { "configure", { band = { "b3/1", "b3/2", "b3/3", "b3/4", "b3/5", "b3/6", "b3/7" } } } }
                expect(app.line(1)):str_match("^Settings")
            end)
        end)

        it("adds and removes cores", function()
            local cell = fake_cell()
            run({ "celld" }, {}, function(app)
                app.choose("Cores")
                expect(app.chosen()):str_match("^core.acme +serving ACME$")
                app.choose("Add a core")
                app.enter("CORE.ACME")
                expect(app.says("This cell connects to core.acme already.")):eq(true)
                app.enter("")
                expect(app.says("Enter the core's name or address.")):eq(true)
                app.enter("core.beta")
                expect(cell.calls):same { { "configure", { cores = { "core.acme", "core.beta" } } } }
                expect(select(2, app.find("core.beta"))):str_match("^core.beta +connecting$")

                -- A core shows how it's doing, and can be removed: but not without asking.
                app.choose("core.acme")
                expect(app.line(1)):eq("core.acme")
                expect(app.says("core.acme: connecting")):eq(true)
                app.choose("Remove this core")
                expect(app.says("Its network's phones here lose service.")):eq(true)
                app.type("n")
                expect(#cell.calls):eq(1)
                app.choose("Remove this core")
                app.type("y")
                expect(cell.calls[2]):same { "configure", { cores = { "core.beta" } } }
                expect(app.line(1)):str_match("^Cores")
                expect(select(2, app.find("core.acme"))):eq("Removed core.acme.")

                -- The last one takes the cell off the air.
                app.choose("core.beta")
                app.choose("Remove this core")
                expect(app.says("The cell has no other cores: it stops")):eq(true)
                app.type("y")
                expect(cell.calls[3]):same { "configure", { cores = {} } }
                expect(app.says("Removed core.beta. The cell stopped.")):eq(true)
            end)
        end)

        it("starts a cell with its first core, and starts, stops and restarts it", function()
            local cell = fake_cell({ state = "stopped", id = 11, enabled = true })
            run({ "celld" }, {}, function(app)
                expect(app.says("No cell: add a core to start one.")):eq(true)
                expect(app.find("Start the cell")):eq(nil)
                app.choose("Cores")
                app.choose("Add a core")
                app.enter("10.0.0.1")
                expect(cell.calls):same { { "configure", { cores = { "10.0.0.1" } } }, { "start" } }
                app.type("q")

                app.choose("Stop the cell")
                app.type("y")
                expect(cell.calls[3]):same { "stop" }
                expect(app.says("Stopped the cell.")):eq(true)
                expect(app.find("Stop the cell")):eq(nil)
                app.choose("Start the cell")
                expect(cell.calls[4]):same { "start" }
                app.choose("Restart the cell")
                app.key(keys.enter)
                expect({ cell.calls[5], cell.calls[6] }):same { { "stop" }, { "start" } }
                -- Starting may fail, which is said.
                cell.refuse = "A cell needs a wireless modem"
                app.choose("Restart the cell")
                app.type("y")
                expect(app.says("A cell needs a wireless modem")):eq(true)
            end)

            -- A cell which was stopped stays stopped when a core is added.
            cell = fake_cell({ state = "stopped", id = 11, enabled = false, cores = { "core.acme" } })
            run({ "celld" }, {}, function(app)
                app.choose("Cores")
                app.choose("Add a core")
                app.enter("core.beta")
                expect(cell.calls):same { { "configure", { cores = { "core.acme", "core.beta" } } } }
                expect(app.says("Added core.beta. The cell is stopped.")):eq(true)
            end)
        end)

        it("puts a cell which stands by on the air, once its bands are confirmed or chosen", function()
            local function standing_by()
                local cell = fake_cell({
                    state = "standby", id = 11, area = 0, cores = { "core.acme" }, enabled = true, confirmed = false,
                    network = "ACME", fingerprint = "aaaa",
                    links = { { core = "core.acme", state = "standby", network = "ACME", carriers = { "b20/1", "b3/1" } } },
                })
                -- As net.cell does: its bands said, or confirmed, it goes on the air.
                local configure = net.cell.configureCell
                stub(net.cell, "configureCell", function(changes)
                    local ok, restarted = configure(changes)
                    if ok and (changes.band ~= nil or changes.confirmed) then
                        cell.info.confirmed, cell.info.state, cell.info.links[1].state = true, "serving", "serving"
                    end
                    return ok, restarted
                end)
                return cell
            end

            local cell = standing_by()
            run({ "celld" }, {}, function(app)
                expect(app.line(1)):str_match("^Cell #11 +not on the air yet$")
                expect(app.says("Not on the air: confirm its bands under Go on the air.")):eq(true)
                app.choose("Status")
                expect(app.says("core.acme: ACME, standing by")):eq(true)
                expect(app.says("offers b20/1, b3/1")):eq(true)
                app.type("q")
                app.choose("Go on the air")
                expect(app.says("ACME: b20/1, b3/1")):eq(true)
                app.choose("Use any band")
                expect(cell.calls):same { { "configure", { confirmed = true } } }
                expect(app.line(1)):str_match("^Cell #11 +serving ACME$")
                expect(app.says("Bands confirmed: on the air.")):eq(true)
                expect(app.find("Go on the air...")):eq(nil)
            end)

            -- Or its bands are chosen there: nobody is asked whether to start it again, as it wasn't on the air.
            cell = standing_by()
            run({ "celld" }, {}, function(app)
                app.choose("Go on the air")
                app.choose("Choose its bands")
                expect(app.line(1)):str_match("^Bands +any$")
                -- Left as they were, it stands by still.
                app.type("q")
                expect(app.line(1)):eq("Go on the air")
                expect(#cell.calls):eq(0)
                app.choose("Choose its bands")
                app.choose("b20 ")
                app.choose("Any carrier")
                app.type("q")
                app.choose("b3 ")
                app.choose("b3/1")
                app.type("q")
                app.type("q")
                expect(cell.calls):same { { "configure", { band = { "b20", "b3/1" } } } }
                expect(app.line(1)):str_match("^Cell #11 +serving ACME$")
                expect(app.says("On the air.")):eq(true)
            end)

            -- With bands set already, those are what's confirmed.
            cell = standing_by()
            cell.info.band = "b3"
            run({ "celld" }, {}, function(app)
                app.choose("Go on the air")
                app.choose("Use b3 (1800MHz)")
                expect(cell.calls):same { { "configure", { confirmed = true } } }
            end)
        end)

        it("still says how the cell is doing when asked for its status", function()
            fake_cell()
            expect(capture("celld", "status").output):str_match("^Cell #11, area 3%.\n")
        end)
    end)

    describe("cellcore", function()
        local K11, K12, K13 = ("11"):rep(32), ("12"):rep(32), ("13"):rep(32)

        --[[ A core behind net.cell.manage: ACME's, with a cell, a computer which waits to be a cell, one which was
        refused, and two subscribers. What's asked of it (but how it's doing, and its log) is kept in `asked`, and done
        to it, unless `fail` says why not. `down` says why it can't be reached, if it can't. ]]
        local function fake_core()
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            local core = {
                asked = {}, connects = 0, started = 0,
                status = {
                    network = "ACME", prefix = "10.64.0.0/16", messages = 0, codes = 0, interval = 2,
                    spectrum = { "b20/1" },
                    cells = { {
                        id = 11, key = K11, address = "10.0.0.11", area = 1, since = 0, path = {}, carrier = "b20/1", ul = 8320,
                        carriers = { { id = 11, carrier = "b20/1", ul = 8320 }, { id = 2 ^ 40, carrier = "b3/1", ul = 17100, outside = true } },
                    }, },
                    allowed = {
                        { key = K11, fingerprint = "1111 1111 1111 1111 1111", label = "cell #11", role = "cell", id = 11 },
                        { key = K13, fingerprint = "1313 1313 1313 1313 1313", label = "old tower", role = "denied", id = 13 },
                    },
                    waiting = { { key = K12, fingerprint = "1212 1212 1212 1212 1212", id = 12, role = "cell", waited = 5 } },
                    subscribers = {
                        { id = "ACME-1", number = "100", address = "10.64.0.2", cell = 11, may_roam = true },
                        { id = "ACME-2", number = "101", may_roam = true },
                    },
                    networks = {},
                },
                log = { { n = 1, time = 0, text = "Cell #11 connected, from 10.0.0.11, on b20/1" } },
            }
            local status = core.status

            local function find(list, field, value)
                for i, entry in ipairs(list) do
                    if entry[field] == value then return entry, i end
                end
            end
            local answers = {}
            function answers.status() return status end
            function answers.log(message)
                local lines = {}
                for _, line in ipairs(core.log) do
                    if line.n > (message.after or 0) then lines[#lines + 1] = line end
                end
                return { lines = lines, last = #core.log }
            end
            function answers.allow(message)
                local entry, i = find(status.waiting, "key", message.key)
                if entry then
                    table.remove(status.waiting, i)
                    entry = { key = entry.key, fingerprint = entry.fingerprint, id = entry.id, role = entry.role }
                    status.allowed[#status.allowed + 1] = entry
                else
                    entry = find(status.allowed, "key", message.key)
                    if not entry then return nil, "No computer with that key is waiting" end
                    entry.role = "cell"
                end
                entry.label = message.label or entry.label or "cell #" .. entry.id
                return { role = entry.role, id = entry.id, label = entry.label, fingerprint = entry.fingerprint }
            end
            function answers.deny(message)
                local entry, i = find(status.waiting, "key", message.key)
                if entry then
                    table.remove(status.waiting, i)
                else
                    entry = find(status.allowed, "key", message.key)
                    if not entry then return nil, "No such computer" end
                    entry.role = "denied"
                end
                local _, cell = find(status.cells, "key", message.key)
                if cell then table.remove(status.cells, cell) end
                return { id = entry.id }
            end
            function answers.add(message)
                if find(status.subscribers, "number", message.number) then return nil, "Someone has that number already" end
                status.codes = status.codes + 1
                return { code = "7Q2M-K4XD-9PRB-T6WN-HJ3C" }
            end
            function answers.remove(message)
                local _, i = find(status.subscribers, "id", message.subscriber)
                if not i then return nil, "There's no subscriber called " .. tostring(message.subscriber) end
                table.remove(status.subscribers, i)
                return { removed = 1, codes = 0 }
            end
            function answers.set(message)
                local subscriber = find(status.subscribers, "id", message.subscriber)
                    or find(status.subscribers, "number", message.subscriber)
                if not subscriber then return nil, "There's no subscriber called " .. tostring(message.subscriber) end
                if message.barred ~= nil then subscriber.barred = message.barred or nil end
                if message.roaming ~= nil then subscriber.may_roam = message.roaming end
                for _, kind in ipairs { "range", "subnet" } do
                    if message[kind] then
                        if not message[kind]:match("^%d+%.%d+%.%d+%.%d+/%d+$") then return nil, "Expected a network, such as 10.64.5.0/28" end
                        subscriber.range, subscriber.subnet = nil, nil
                        subscriber[kind] = message[kind]
                    elseif message[kind] == false then
                        subscriber[kind] = nil
                    end
                end
                return {
                    id = subscriber.id, barred = subscriber.barred == true, roaming = subscriber.may_roam,
                    range = subscriber.range, subnet = subscriber.subnet,
                }
            end
            function answers.network(message)
                local network, i = find(status.networks, "network", message.network)
                if message.forget then
                    if not network then return nil, "There's no agreement with " .. message.network end
                    table.remove(status.networks, i)
                    return { network = message.network, forgotten = true }
                end
                if message.messages and not status.number_prefix then
                    return nil, "Set this network's number prefix first, with 'cellcore numbers'"
                end
                if not network then
                    network = { network = message.network, carry = false, roam = false, messages = false, visitors = 0, phones = 0, waiting = 0 }
                    status.networks[#status.networks + 1] = network
                end
                for _, field in ipairs { "carry", "roam", "messages" } do
                    if message[field] ~= nil then network[field] = message[field] end
                end
                if message.core ~= nil then network.core = message.core or nil end
                return { network = network.network, our_id = 50, our_fingerprint = "5050 5050 5050 5050 5050" }
            end
            function answers.numbers(message)
                if not tostring(message.prefix):match("^%d%d?%d?%d?%d?%d?%d?%d?$") then return nil, "Number prefixes are 1 to 8 digits" end
                status.number_prefix = message.prefix
                return { prefix = message.prefix }
            end
            function answers.spectrum(message)
                for _, carrier in ipairs(message.carriers or {}) do
                    if not carrier:match("^b%d+/%d$") then return nil, "There's no carrier called " .. carrier end
                end
                if message.carriers then status.spectrum = message.carriers end
                return { carriers = status.spectrum }
            end
            function answers.rename(message)
                if not message.network:match("^[%w%-]+$") then return nil, "Network names are letters, digits and dashes, up to 32 of them" end
                if message.network == "BETA" then return nil, "There's an agreement with a network called BETA" end
                local was = status.network
                status.network = message.network
                return { network = message.network, was = was, restarting = true }
            end
            function answers.beacon(message)
                if message.interval < 0.5 or message.interval > 10 then return nil, "Cells send system information every 0.5 to 10 seconds" end
                status.interval = message.interval
                return { interval = message.interval }
            end
            function answers.stop()
                core.down = "Connection refused"
                return { ok = true }
            end
            function answers.restart() return { ok = true } end

            stub(net.cell, "manage", function(target, waiting)
                core.connects, core.target = core.connects + 1, target
                if core.down then return nil, core.down end
                if core.fingerprint and waiting and waiting(core.fingerprint) == false then
                    return nil, "The core hasn't allowed this computer", core.fingerprint
                end
                return {
                    request = function(_, message)
                        if core.down then return nil, "Lost the core: closed" end
                        if message.op ~= "status" and message.op ~= "log" then
                            core.asked[#core.asked + 1] = message
                            if core.fail then return nil, core.fail end
                        end
                        return answers[message.op](message)
                    end,
                    close = function() end,
                }
            end)
            stub(net.cell, "startCore", function()
                core.started = core.started + 1
                if core.no_start then return nil, core.no_start end
                core.down = nil
                return true
            end)
            stub(net.cell, "stopCore", function() core.down = "Connection refused" end)
            return core
        end

        -- Run a test on a computer which is (or isn't) set up as a core, and leave it as it was.
        local function configured(yes, fn)
            fs.delete("/.cell")
            if yes then
                local file = fs.open(CONFIG, "w")
                file.write(textutils.serialise({ network = "ACME", prefix = "10.64.0.0/16" }))
                file.close()
            end
            local ok, err = pcall(fn)
            fs.delete("/.cell")
            if not ok then error(err, 0) end
        end

        it("shows the network and what can be done with it, and leaves with Q", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    expect(app.line(1)):str_match("^Core of ACME +10.64.0.0/16$")
                    expect(select(2, app.find("Computers"))):str_match("^Computers +1 waiting$")
                    expect(select(2, app.find("Cells"))):str_match("^Cells +1$")
                    expect(select(2, app.find("Subscribers"))):str_match("^Subscribers +1 of 2 attached$")
                    for _, text in ipairs { "Status", "Other networks", "Network settings", "Log", "Restart the core", "Stop the core" } do
                        expect(app.find(text) ~= nil):describe(text):eq(true)
                    end
                    expect(core.target):eq(nil)

                    app.choose("Status")
                    expect(app.says("Core of ACME, phones in 10.64.0.0/16")):eq(true)
                    expect(app.says("Cells: #11")):eq(true)
                    expect(app.says("Phones: 1 attached, of 2 subscribers")):eq(true)
                    expect(app.says("Waiting to be allowed: #12 cell, 1212 1212 1212 1212 1212")):eq(true)
                    app.type("q")
                    app.type("q")
                    expect(app.finished()):eq(true)
                    expect(core.asked):same {}
                end)
            end)
        end)

        it("lets computers in once their fingerprint was seen, and refuses them", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Computers")
                    expect(app.chosen()):str_match("^#12 cell +waiting$")
                    expect(select(2, app.find("#13"))):str_match("^#13 old tower +refused$")

                    app.choose("#12")
                    expect(app.says("#12 wants to be a cell.")):eq(true)
                    expect(app.says("Fingerprint: 1212 1212 1212 1212 1212")):eq(true)
                    app.choose("Allow it, with a label")
                    app.enter("north tower")
                    expect(core.asked):same { { op = "allow", key = K12, label = "north tower" } }
                    expect(app.says("Allowed #12 to be a cell, as north tower.")):eq(true)
                    expect(select(2, app.find("#12"))):str_match("^#12 north tower +cell$")

                    -- One which was let in is refused, but not without asking; and one refused is let in again.
                    app.choose("#12")
                    expect(app.says("Allowed to be a cell.")):eq(true)
                    app.choose("Refuse it")
                    app.type("n")
                    expect(#core.asked):eq(1)
                    app.choose("Refuse it")
                    app.type("y")
                    expect(core.asked[2]):same { op = "deny", key = K12 }
                    expect(app.says("Refused #12.")):eq(true)
                    app.choose("#13")
                    app.choose("Allow it again")
                    expect(core.asked[3]):same { op = "allow", key = K13 }
                    expect(select(2, app.find("#13"))):str_match("^#13 old tower +cell$")
                end)
            end)

            -- One which waits can be refused straight away, or simply let in.
            core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Computers")
                    app.choose("#12")
                    app.choose("Refuse it")
                    expect(core.asked):same { { op = "deny", key = K12 } }
                    expect(app.find("#12 cell")):eq(nil)
                end)
            end)
            core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Computers")
                    app.choose("#12")
                    app.choose("Allow it")
                    expect(core.asked):same { { op = "allow", key = K12 } }
                    expect(app.says("Allowed #12 to be a cell, as cell #12.")):eq(true)
                end)
            end)
        end)

        it("shows each cell, on each of its carriers", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Cells")
                    expect(app.chosen()):str_match("^#11 10.0.0.11 +b20/1 b3/1$")
                    app.choose("#11")
                    expect(app.line(1)):str_match("^Cell #11 +ACME$")
                    expect(app.says("#11 from 10.0.0.11, area 1, since")):eq(true)
                    expect(app.says("on b20/1, channel 8320")):eq(true)
                    expect(app.says("on b3/1, channel 17100, not this network's")):eq(true)
                    expect(app.says("phones attached: 1")):eq(true)
                    app.choose("Refuse this cell")
                    app.type("y")
                    expect(core.asked):same { { op = "deny", key = K11 } }
                    expect(app.says("No cells connected.")):eq(true)
                end)
            end)
        end)

        it("adds subscribers, changes what they may do, and removes them", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Subscribers")
                    expect(app.chosen()):str_match("^ACME%-1  100 +cell #11, 10.64.0.2$")
                    expect(select(2, app.find("ACME-2"))):str_match("^ACME%-2  101 +%-$")

                    app.choose("Add a subscriber")
                    app.enter("")
                    expect(app.says("Enter an ID for the subscriber.")):eq(true)
                    app.enter("ACME-3")
                    -- The core says why not.
                    app.enter("100")
                    expect(app.says("Someone has that number already")):eq(true)
                    app.enter("102")
                    expect(core.asked):same { { op = "add", id = "ACME-3", number = "100" }, { op = "add", id = "ACME-3", number = "102" } }
                    expect(app.line(1)):eq("Activation code")
                    expect(app.says("ACME-3, number 102. Good for a day: 7Q2M-K4XD-9PRB-T6WN-HJ3C")):eq(true)
                    expect(app.says("cell activate ACME <code>")):eq(true)
                    app.key(keys.enter)
                    expect(app.line(1)):str_match("^Subscribers")

                    app.choose("ACME-2")
                    expect(app.says("ACME-2, number 101")):eq(true)
                    app.choose("Barred")
                    expect(core.asked[3]):same { op = "set", subscriber = "ACME-2", barred = true }
                    expect(app.chosen()):str_match("^Barred +yes$")
                    expect(app.says("ACME-2 is barred.")):eq(true)
                    app.choose("Barred")
                    expect(core.asked[4]):same { op = "set", subscriber = "ACME-2", barred = false }
                    app.choose("May use other networks")
                    expect(core.asked[5]):same { op = "set", subscriber = "ACME-2", roaming = false }
                    expect(app.says("ACME-2 may only use this network's cells.")):eq(true)
                    app.choose("Remove")
                    app.type("n")
                    expect(#core.asked):eq(5)
                    app.choose("Remove")
                    app.type("y")
                    expect(core.asked[6]):same { op = "remove", subscriber = "ACME-2" }
                    expect(app.line(1)):str_match("^Subscribers")
                    expect(select(2, app.find("ACME-2"))):eq("Removed ACME-2.")
                end)
            end)
        end)

        it("makes a subscriber a router with a range, a site with a subnet, or a phone again", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Subscribers")
                    app.choose("ACME-2")
                    expect(select(2, app.find("Type"))):str_match("^Type +phone$")
                    app.choose("Type")
                    expect(app.line(1)):str_match("^Type of ACME%-2")
                    expect(app.chosen()):str_match("^Phone: one address +now$")

                    app.choose("Router: a range of our addresses")
                    expect(app.line(1)):eq("Range for ACME-2")
                    expect(app.says("Within 10.64.0.0/16, such as a /28: routed to the phone.")):eq(true)
                    app.enter("")
                    expect(app.says("Enter a network, such as 10.64.5.0/28.")):eq(true)
                    -- The core says what won't do.
                    app.enter("somewhere")
                    expect(app.says("Expected a network, such as 10.64.5.0/28")):eq(true)
                    app.enter("10.64.5.0/28")
                    expect(core.asked):same {
                        { op = "set", subscriber = "ACME-2", range = "somewhere" }, { op = "set", subscriber = "ACME-2", range = "10.64.5.0/28" },
                    }
                    expect(app.line(1)):str_match("^ACME%-2")
                    expect(app.chosen()):str_match("^Type +router, 10.64.5.0/28$")
                    expect(app.says("ACME-2 is a router, with the range 10.64.5.0/28 of this network's addresses behind it.")):eq(true)
                    app.type("q")
                    expect(select(2, app.find("ACME-2"))):str_match("^ACME%-2  101 +%-, routes 10.64.5.0/28$")

                    -- Its own network instead: what it had is there to change.
                    app.choose("ACME-2")
                    app.choose("Type")
                    expect(select(2, app.find("Router"))):str_match("now$")
                    app.choose("Site: a network of its own")
                    app.enter("192.168.5.0/24")
                    expect(core.asked[3]):same { op = "set", subscriber = "ACME-2", subnet = "192.168.5.0/24" }
                    expect(app.chosen()):str_match("^Type +site, 192.168.5.0/24$")
                    expect(app.says("ACME-2 is a site, with its own network 192.168.5.0/24 behind it.")):eq(true)
                    app.choose("Type")
                    app.choose("Site: a network of its own")
                    expect(app.line(3)):eq("Network: 192.168.5.0/24")
                    app.key(keys.tab)

                    -- And a phone again.
                    app.choose("Type")
                    app.choose("Phone: one address")
                    expect(core.asked[4]):same { op = "set", subscriber = "ACME-2", subnet = false }
                    expect(app.chosen()):str_match("^Type +phone$")
                    expect(app.says("ACME-2 is a phone: it has one address, and nothing behind it.")):eq(true)
                    -- Which, as it's one already, asks nothing of the core.
                    app.choose("Type")
                    app.choose("Phone: one address")
                    expect(#core.asked):eq(4)
                end)
            end)

            -- From the shell too.
            core = fake_core()
            configured(true, function()
                expect(capture("cellcore", "set", "ACME-2", "range", "10.64.5.0/28").output)
                    :str_match("^ACME%-2 is a router, with the range 10%.64%.5%.0/28 of this network's addresses behind it%.\n")
                expect(capture("cellcore", "set", "101", "subnet", "192.168.5.0/24").output)
                    :str_match("^ACME%-2 is a site, with its own network 192%.168%.5%.0/24 behind it%.\n")
                expect(capture("cellcore", "set", "ACME-2", "subnet", "none").output)
                    :eq("ACME-2 is a phone: it has one address, and nothing behind it.\n")
                expect(core.asked):same {
                    { op = "set", subscriber = "ACME-2", range = "10.64.5.0/28" }, { op = "set", subscriber = "101", subnet = "192.168.5.0/24" },
                    { op = "set", subscriber = "ACME-2", subnet = false },
                }
            end)
        end)

        it("makes and changes agreements with other networks", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Other networks")
                    app.choose("Add a network")
                    app.enter("ACME")
                    expect(app.says("That's this network.")):eq(true)
                    app.enter("not a name")
                    expect(app.says("Network names are letters, digits and dashes")):eq(true)
                    app.enter("BETA")
                    expect(app.line(1)):str_match("^BETA +ACME$")
                    expect(app.says("No agreement yet")):eq(true)

                    app.choose("Carry its phones")
                    expect(core.asked):same { { op = "network", network = "BETA", carry = true } }
                    expect(app.chosen()):str_match("^Carry its phones +on$")
                    expect(app.says("Changed. On its core, allow computer #50: 5050 5050 5050 5050 5050")):eq(true)
                    expect(app.says("Carries its phones")):eq(true)

                    -- As home only once its phones may use the other's cells at all.
                    expect(app.find("as if they were home")):eq(nil)
                    app.choose("Our phones use its cells")
                    expect(core.asked[2]):same { op = "network", network = "BETA", roam = "partner" }
                    app.choose("as if they were home")
                    expect(core.asked[3]):same { op = "network", network = "BETA", roam = "home" }
                    app.choose("as if they were home")
                    expect(core.asked[4]):same { op = "network", network = "BETA", roam = "partner" }
                    app.choose("Our phones use its cells")
                    expect(core.asked[5]):same { op = "network", network = "BETA", roam = false }

                    -- What the core won't do is said.
                    app.choose("Exchange messages")
                    expect(core.asked[6]):same { op = "network", network = "BETA", messages = true }
                    expect(app.says("Set this network's number prefix first")):eq(true)
                    expect(app.chosen()):str_match("^Exchange messages +off$")

                    app.choose("Its core")
                    app.enter("core.beta")
                    expect(core.asked[7]):same { op = "network", network = "BETA", core = "core.beta" }
                    expect(app.chosen()):str_match("^Its core +core.beta$")
                    app.choose("Its core")
                    expect(app.line(3)):eq("Core: core.beta")
                    app.enter("")
                    expect(core.asked[8]):same { op = "network", network = "BETA", core = false }

                    app.type("q")
                    expect(select(2, app.find("BETA"))):str_match("^BETA +not met yet$")
                    app.choose("BETA")
                    app.choose("Forget this agreement")
                    app.type("y")
                    expect(core.asked[9]):same { op = "network", network = "BETA", forget = true }
                    expect(app.says("Forgot the agreement with BETA.")):eq(true)
                    expect(app.line(1)):str_match("^Other networks")
                end)
            end)
        end)

        it("has the network's carriers ticked, band by band", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Network settings")
                    expect(select(2, app.find("Carriers"))):str_match("^Carriers +b20/1$")
                    app.choose("Carriers")
                    expect(app.line(1)):str_match("^Carriers +1 of 8$")
                    -- Every cellular band is there, with what's chosen of it.
                    local rows = {
                        "^b31  450 MHz +%-$", "^b28  700 MHz +%-$", "^b20  800 MHz +/1$", "^b8   900 MHz +%-$",
                        "^b3   1800 MHz +%-$", "^b1   2100 MHz +%-$", "^b7   2600 MHz +%-$",
                    }
                    for i, pattern in ipairs(rows) do expect(app.line(i + 2)):str_match(pattern) end

                    -- A band's carriers, each with its frequencies: ticked, they're the network's at once.
                    app.choose("b3 ")
                    expect(app.line(1)):str_match("^b3, 1800 MHz$")
                    -- (A cell which another network shares is on this one, though it isn't this network's.)
                    expect(app.chosen()):str_match("^%[ %] b3/1 +1805%-1810 MHz +1 cell$")
                    expect(app.find("Any carrier")):eq(nil)
                    expect(app.find("b3/15")):ne(nil)
                    app.choose("b3/2")
                    expect(core.asked):same { { op = "spectrum", carriers = { "b20/1", "b3/2" } } }
                    expect(app.chosen()):str_match("^%[x%] b3/2 +1810%-1815 MHz$")
                    expect(app.line(1)):str_match("^b3, 1800 MHz +/2$")
                    -- Space does as Enter does.
                    app.type(" ")
                    expect(core.asked[2]):same { op = "spectrum", carriers = { "b20/1" } }
                    expect(app.chosen()):str_match("^%[ %] b3/2")
                    app.type(" ")
                    -- What the core won't do is said, and changes nothing.
                    core.fail = "Lost the core"
                    app.choose("b3/4")
                    expect(app.says("Lost the core")):eq(true)
                    expect(app.chosen()):str_match("^%[ %] b3/4")
                    core.fail = nil
                    app.type("q")
                    expect(app.line(1)):str_match("^Carriers +2 of 8$")
                    expect(app.chosen()):str_match("^b3   1800 MHz +/2$")

                    -- How many cells are on each carrier is said: here, the one which is to go.
                    app.choose("b20 ")
                    expect(app.chosen()):str_match("^%[x%] b20/1 +791%-796 MHz +1 cell$")
                    app.key(keys.enter)
                    expect(core.asked[5]):same { op = "spectrum", carriers = { "b3/2" } }
                    app.type("q")
                    app.type("q")
                    expect(app.chosen()):str_match("^Carriers +b3/2$")
                end)
            end)

            -- A network with none says what that means, wherever its carriers are shown.
            core = fake_core()
            core.status.spectrum = {}
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    expect(select(2, app.find("Network settings"))):str_match("^Network settings +no carriers$")
                    app.choose("Network settings")
                    expect(select(2, app.find("Carriers"))):str_match("^Carriers +none$")
                    app.choose("Carriers")
                    expect(app.line(1)):str_match("^Carriers +0 of 8$")
                    expect(app.says("No carriers: cells stay off the air.")):eq(true)
                    -- And no more than eight.
                    app.choose("b7 ")
                    for i = 1, 8 do app.choose("b7/" .. i) end
                    expect(#core.asked):eq(8)
                    expect(core.status.spectrum):same { "b7/1", "b7/2", "b7/3", "b7/4", "b7/5", "b7/6", "b7/7", "b7/8" }
                    app.choose("b7/9")
                    expect(app.says("At most 8 may be chosen.")):eq(true)
                    expect(#core.asked):eq(8)
                end)
            end)
        end)

        it("renames the network, once that's confirmed", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Network settings")
                    expect(app.chosen()):str_match("^Name +ACME$")
                    app.choose("Name")
                    expect(app.line(1)):eq("Rename the network")
                    expect(app.line(3)):eq("Name: ACME")
                    -- Left as it is, nothing is asked.
                    app.key(keys.enter)
                    expect(app.line(1)):str_match("^Network settings")
                    expect(core.asked):same {}

                    app.choose("Name")
                    app.enter("not a name")
                    expect(app.says("Network names are letters, digits and dashes")):eq(true)
                    -- It says what renaming does, and may be thought better of.
                    app.enter("ZETA")
                    expect(app.line(1)):eq("Rename to ZETA")
                    expect(app.says("The core starts afresh: cells and phones connect again, under the new name.")):eq(true)
                    app.type("n")
                    expect(app.line(1)):str_match("^Network settings")
                    expect(core.asked):same {}
                    -- What the core won't have is said.
                    app.choose("Name")
                    app.enter("BETA")
                    app.type("y")
                    expect(app.says("There's an agreement with a network called BETA")):eq(true)
                    expect(app.line(1)):eq("Rename the network")

                    app.enter("ZETA")
                    app.type("y")
                    expect(core.asked[2]):same { op = "rename", network = "ZETA" }
                    expect(app.line(1)):str_match("^Network settings +ZETA$")
                    expect(app.chosen()):str_match("^Name +ZETA$")
                    expect(app.says("ACME is called ZETA now.")):eq(true)
                end)
            end)

            -- From the shell too, on the core or from another computer.
            core = fake_core()
            configured(true, function()
                expect(capture("cellcore", "rename", "ZETA").output):str_match("^ACME is called ZETA now%. The core starts afresh")
                expect(capture("cellcore", "rename", "BETA")):matches { ok = false, error = "There's an agreement with a network called BETA\n" }
                expect(capture("cellcore", "rename").output):str_match("cellcore rename <network>")
                expect(core.asked):same { { op = "rename", network = "ZETA" }, { op = "rename", network = "BETA" } }
                -- Set up again under another name, the name it had is kept the same way.
                expect(capture("cellcore", "setup", "OMEGA", "10.64.0.0/16").ok):eq(true)
                local config = textutils.unserialise(fs.open(CONFIG, "r").readAll())
                expect({ config.network, config.former }):same { "OMEGA", { "ACME" } }
            end)
        end)

        it("changes how often the network's cells are heard, and its number prefix", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Network settings")
                    expect(select(2, app.find("System information"))):str_match("^System information +every 2 seconds$")
                    expect(select(2, app.find("Number prefix"))):str_match("^Number prefix +none$")

                    app.choose("System information")
                    app.enter("often")
                    expect(app.says("Expected a number of seconds.")):eq(true)
                    app.enter("30")
                    expect(app.says("Cells send system information every 0.5 to 10 seconds")):eq(true)
                    app.enter("4")
                    expect(core.asked[2]):same { op = "beacon", interval = 4 }
                    expect(app.chosen()):str_match("^System information +every 4 seconds$")

                    app.choose("Number prefix")
                    app.enter("five")
                    expect(app.says("Number prefixes are 1 to 8 digits")):eq(true)
                    app.enter("555")
                    expect(core.asked[4]):same { op = "numbers", prefix = "555" }
                    expect(app.chosen()):str_match("^Number prefix +555$")
                    expect(app.says("Number prefix: 555.")):eq(true)
                end)
            end)
        end)

        it("shows the cells which are off the air, and why", function()
            local core = fake_core()
            core.status.standby = {
                { id = 14, key = K12, address = "10.0.0.14", since = 0 },
                { id = 15, key = K13, address = "10.0.0.15", since = 0, unplaced = { "b7" }, reason = "ACME has no carrier in band b7" },
            }
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Cells")
                    expect(select(2, app.find("#14"))):str_match("^#14 10.0.0.14 +choosing its bands$")
                    expect(select(2, app.find("#15"))):str_match("^#15 10.0.0.15 +no carrier$")
                    app.choose("#15")
                    expect(app.says("#15 is off the air: ACME has no carrier in band b7.")):eq(true)
                    expect(core.asked):same {}
                end)
            end)
        end)

        it("shows the log, and new lines as they come", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, { height = 8 }, function(app)
                    app.choose("Log")
                    expect(app.says("Cell #11 connected, from 10.0.0.11, on b20/1")):eq(true)
                    for i = 2, 12 do core.log[i] = { n = i, time = i * 60000, text = "Line " .. i } end
                    app.tick()
                    -- It stays at the end.
                    expect(app.chosen()):str_match("Line 12$")
                    expect(app.find("Line 2 ")):eq(nil)
                    -- Unless the user went up to read: then it stays there.
                    app.key(keys.up, keys.up, keys.up)
                    core.log[13] = { n = 13, time = 0, text = "Line 13" }
                    app.tick()
                    expect(app.chosen()):str_match("Line 9$")
                end)
            end)
        end)

        it("stops the core and starts it, and finds it again when it was started afresh", function()
            local core = fake_core()
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Restart the core")
                    expect(app.says("Cells and phones connect again, with new addresses.")):eq(true)
                    app.type("y")
                    expect(core.asked):same { { op = "restart" } }
                    expect(app.says("Starting the core afresh.")):eq(true)

                    -- It's away for a moment, and connected to again once it's back.
                    local connects = core.connects
                    core.down = "Connection refused"
                    app.tick()
                    expect(app.chosen()):eq("Connect again")
                    -- Why it's away is said, in place of what was done before.
                    expect(app.says("Starting the core afresh.")):eq(false)
                    expect(app.says("Connection refused")):eq(true)
                    -- It isn't connected to every time the screen looks again, which would hold the menu up: only
                    -- now and again.
                    local tried = core.connects
                    expect(tried):eq(connects + 1)
                    for _ = 1, 3 do app.tick() end
                    expect(core.connects):eq(tried)
                    app.tick()
                    expect(core.connects):eq(tried + 1)
                    expect(app.chosen()):eq("Connect again")
                    core.down = nil
                    for _ = 1, 4 do app.tick() end
                    expect(core.connects):eq(tried + 1)
                    app.tick()
                    expect(core.connects):eq(tried + 2)
                    expect(app.line(1)):str_match("^Core of ACME")
                    expect(app.find("Stop the core")):ne(nil)

                    -- "Connect again" doesn't wait for that.
                    core.down = "Connection refused"
                    app.tick()
                    expect(app.chosen()):eq("Connect again")
                    core.down = nil
                    connects = core.connects
                    app.key(keys.enter)
                    expect(core.connects):eq(connects + 1)
                    expect(app.line(1)):str_match("^Core of ACME")
                    expect(app.find("Stop the core")):ne(nil)
                    -- And when the core still isn't there, it says what else may be done.
                    core.down = "Connection refused"
                    app.tick()
                    connects = core.connects
                    app.key(keys.enter)
                    expect(core.connects):eq(connects + 1)
                    expect(app.says("The core isn't running.")):eq(true)
                    expect(app.chosen()):eq("Start the core")
                    core.down = nil
                    app.choose("Try again")
                    expect(app.line(1)):str_match("^Core of ACME")

                    app.choose("Stop the core")
                    app.type("n")
                    expect(#core.asked):eq(1)
                    app.choose("Stop the core")
                    app.type("y")
                    expect(core.asked[2]):same { op = "stop" }
                    expect(app.says("Stopped the core.")):eq(true)
                    expect(app.chosen()):eq("Start the core")
                    -- It may not start.
                    core.no_start = "The network stack is turned off"
                    app.key(keys.enter)
                    expect(app.says("The network stack is turned off")):eq(true)
                    core.no_start = nil
                    app.key(keys.enter)
                    expect(core.started):eq(2)
                    expect(app.line(1)):str_match("^Core of ACME")
                    expect(app.says("The core is running, and starts with this computer.")):eq(true)
                end)
            end)

            -- A core which isn't running when the menu opens.
            core = fake_core()
            core.down = "Connection refused"
            configured(true, function()
                run({ "cellcore" }, {}, function(app)
                    expect(app.says("The core isn't running.")):eq(true)
                    app.type("q")
                    expect(app.finished()):eq(true)
                end)
            end)
        end)

        it("sets up a network on a computer which isn't a core yet", function()
            local core = fake_core()
            core.down = "Connection refused"
            configured(false, function()
                run({ "cellcore" }, {}, function(app)
                    expect(app.says("This computer isn't a network's core.")):eq(true)
                    expect(core.connects):eq(0)
                    app.choose("Set up a network")
                    app.enter("not a name")
                    expect(app.says("Network names are letters, digits and dashes")):eq(true)
                    app.enter("ACME")
                    expect(app.line(1)):eq("Set up ACME")
                    expect(app.line(3)):eq("Addresses: 10.64.0.0/16")
                    app.enter("somewhere")
                    expect(app.says("Expected the network for phones' addresses, such as 10.64.0.0/16.")):eq(true)
                    expect(fs.exists(CONFIG)):eq(false)
                    app.enter("10.70.0.0/16")
                    expect(textutils.unserialise(fs.open(CONFIG, "r").readAll())):same { network = "ACME", prefix = "10.70.0.0/16" }
                    expect(core.started):eq(1)
                    -- A new network has no carriers: they're what's shown first.
                    expect(app.line(1)):str_match("^Carriers +1 of 8$")
                    app.type("q")
                    expect(app.line(1)):str_match("^Core of ACME")
                    expect(app.says("ACME is running, with phones in 10.70.0.0/16.")):eq(true)
                end)
            end)

            -- Or it manages another computer's core from here.
            core = fake_core()
            configured(false, function()
                run({ "cellcore" }, {}, function(app)
                    app.choose("Manage another computer's core")
                    app.enter("10.0.0.1")
                    expect(core.target):eq("10.0.0.1")
                    expect(app.line(1)):str_match("^Core of ACME +10.0.0.1$")
                end)
            end)
        end)

        it("manages another computer's core, waiting to be allowed if it must", function()
            local core = fake_core()
            core.fingerprint = "9999 8888 7777 6666 5555"
            local seen
            local manage = net.cell.manage
            stub(net.cell, "manage", function(target, waiting)
                return manage(target, function(fingerprint)
                    local answer = waiting(fingerprint)
                    seen = seen or { term.current().getLine(1), answer }
                    return answer
                end)
            end)
            configured(false, function()
                run({ "cellcore", "remote", "core.acme" }, {}, function(app)
                    expect(seen[1]):str_match("^Waiting to be allowed")
                    expect(seen[2]):eq(nil)
                    expect(core.target):eq("core.acme")
                    expect(app.line(1)):str_match("^Core of ACME +core.acme$")
                    -- It can't be started from afar.
                    app.choose("Stop the core")
                    app.type("y")
                    expect(app.find("Start the core")):eq(nil)
                    expect(app.chosen()):eq("Try again")
                    expect(app.says("Stopped the core.")):eq(true)
                end)
            end)

            core = fake_core()
            core.down = "No route to host"
            configured(false, function()
                run({ "cellcore", "remote", "core.acme" }, {}, function(app)
                    expect(app.line(1)):eq("Core core.acme")
                    expect(app.says("Cannot manage the core: No route to host")):eq(true)
                    core.down = nil
                    app.choose("Try again")
                    expect(app.line(1)):str_match("^Core of ACME +core.acme$")
                end)
            end)
        end)

        it("carries on, whatever is pressed", function()
            for seed, size in ipairs { { 51, 19 }, { 26, 20 }, { 12, 5 } } do
                local core = fake_core()
                core.status.networks[1] = {
                    network = "BETA", carry = true, roam = "home", messages = false, visitors = 2, phones = 1, waiting = 0,
                    core = "core.beta", id = 51, key = K13, fingerprint = "5151 5151", state = "lost", error = "No route to host",
                }
                configured(true, function()
                    storm({ "cellcore" }, size[1], size[2], seed, 500, function(random)
                        -- The core comes and goes, refuses things, and writes to its log.
                        core.down = random(1, 8) == 1 and "Connection refused" or nil
                        core.fail = random(1, 4) == 1 and "The core won't do that" or nil
                        core.log[#core.log + 1] = { n = #core.log + 1, time = 0, text = ("Something happened "):rep(random(1, 6)) }
                    end)
                end)
            end
        end)

        it("still says how the network is doing when asked for its status", function()
            local core = fake_core()
            configured(true, function()
                expect(capture("cellcore", "status").output)
                    :str_match("^Core of ACME, phones in 10.64.0.0/16\nCarriers: b20/1\nCells: #11\n")
                -- And its carriers, as it's asked for them or told them: none, too.
                expect(capture("cellcore", "spectrum").output):eq("Carriers: b20/1\n")
                expect(capture("cellcore", "spectrum", "b20/2", "b3/1").output):eq("Carriers: b20/2, b3/1\nCells hear of it at once.\n")
                expect(capture("cellcore", "spectrum", "none").output)
                    :eq("No carriers: cells stay off the air until some are chosen.\nCells hear of it at once.\n")
                expect(core.asked):same {
                    { op = "spectrum" }, { op = "spectrum", carriers = { "b20/2", "b3/1" } }, { op = "spectrum", carriers = {} },
                }
                core.status.standby = { { id = 15, key = K13, address = "10.0.0.15", since = 0, unplaced = { "b7" }, reason = "ACME has no carriers yet" } }
                expect(capture("cellcore", "status").output)
                    :str_match("^Core of ACME, phones in 10.64.0.0/16\nNo carriers: cells stay off the air%.\nCells: #11\nCells with no carrier: #15\n")
            end)
        end)
    end)

    describe("whatever is pressed", function()
        it("celld's menu carries on", function()
            if not crypto then stub(_G, "crypto", {}) end
            if not enclave then stub(_G, "enclave", {}) end
            for seed, size in ipairs { { 51, 19 }, { 26, 20 }, { 12, 5 }, { 80, 30 } } do
                local info = {
                    state = "serving", id = 11, area = 3, cores = { "core.acme" }, enabled = true, fingerprint = "aaaa bbbb",
                    links = { { core = "core.acme", state = "serving", network = "ACME" } }, carrier = "b20/1", ul = 8320,
                }
                stub(net.cell, "cellInfo", function() return info end)
                stub(net.cell, "configureCell", function(changes)
                    if changes.cores then
                        info.cores, info.links = changes.cores[1] and changes.cores or nil, {}
                        for i, core in ipairs(changes.cores) do info.links[i] = { core = core, state = "connecting" } end
                    end
                    if changes.power then return nil, "This computer's modem sends with -30 to 50 dBm" end
                    for key, value in pairs(changes) do
                        if key ~= "cores" then info[key] = value or nil end
                    end
                    return true, changes.area ~= nil
                end)
                stub(net.cell, "startCell", function()
                    info.state = "connecting"
                    return true
                end)
                stub(net.cell, "stopCell", function() info.state, info.links = "stopped", nil end)
                local states = { "serving", "waiting", "connecting", "lost", "refused", "odd" }
                storm({ "celld" }, size[1], size[2], seed, 400, function(random)
                    for _, link in ipairs(info.links or {}) do
                        link.state = states[random(1, #states)]
                        link.error, link.retry, link.network = "Something long went wrong with the core", random(1, 60), "ACME"
                        link.unplaced = random(1, 3) == 1 and { "b7" } or nil
                    end
                end)
            end
        end)
    end)
end)
