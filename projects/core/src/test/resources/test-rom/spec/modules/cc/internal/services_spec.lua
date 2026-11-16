-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.services", function()
    local services = require "cc.internal.services"

    local FILE = "/.services_spec"
    local PROGRAM = "/services_spec_program.lua"

    local function write(path, text)
        local file = fs.open(path, "w")
        file.write(text)
        file.close()
    end

    -- A set of services, with a clock and timers of its own, so a test says when time passes.
    local function setup(builtins)
        local now, timers, queued = 0, {}, {}
        local m = services.new {
            file = FILE, builtins = builtins, width = 51,
            queue_event = function(...) queued[#queued + 1] = table.pack(...) end,
            clock = function() return now end,
            start_timer = function(delay)
                timers[#timers + 1] = now + delay
                return #timers
            end,
            cancel_timer = function(id) timers[id] = nil end,
        }
        return m, {
            advance = function(seconds) now = now + seconds end,
            timers = timers,
            queued = queued,
        }
    end

    local function cleanup()
        fs.delete(FILE)
        fs.delete(PROGRAM)
        _G.services_spec = nil
    end

    -- Run a test, and tidy up whatever happens.
    local function with_cleanup(fn)
        local ok, err = pcall(fn)
        cleanup()
        if not ok then error(err, 0) end
    end

    it("runs a program in the background, with what it prints in its log, not on the screen", function()
        with_cleanup(function()
            write(PROGRAM, [[
                print("Hello")
                while true do
                    local _, text = os.pullEvent("spec_event")
                    print("Got " .. text)
                end
            ]])
            local m = setup()
            expect(m:add("echo", { PROGRAM })):eq(true)
            local screen = term.current()
            m:resume("service")
            expect(term.current()):eq(screen)

            local info = m:status("echo")
            expect(info.state):eq("running")
            expect(info.enabled):eq(true)
            expect(info.log):same { "Hello" }

            m:resume("spec_event", "one")
            m:resume("other_event", "two")
            m:resume("spec_event", "three")
            expect(m:status("echo").log):same { "Hello", "Got one", "Got three" }
        end)
    end)

    it("doesn't give a service the keyboard, the mouse or Ctrl+T", function()
        with_cleanup(function()
            write(PROGRAM, [[
                local seen = {}
                _G.services_spec = seen
                while true do seen[#seen + 1] = (os.pullEventRaw()) end
            ]])
            local m = setup()
            m:add("listener", { PROGRAM })
            m:resume("service")
            for _, event in ipairs { "key", "char", "paste", "terminate", "mouse_click", "term_resize", "timer", "spec" } do
                m:resume(event)
            end
            expect(_G.services_spec):same { "timer", "spec" }
            expect(m:status("listener").state):eq("running")
        end)
    end)

    it("passes arguments as they are, spaces and all", function()
        with_cleanup(function()
            write(PROGRAM, [[print(table.concat({ ... }, "|"))]])
            local m = setup()
            m:add("args", { PROGRAM, "two words", "", "last" })
            m:resume("service")
            expect(m:status("args").log):same { "two words||last" }
            expect(m:status("args").command):eq(PROGRAM .. ' "two words" "" last')
        end)
    end)

    it("says a service which ends by itself has exited, with what it printed", function()
        with_cleanup(function()
            write(PROGRAM, [[print("Starting") error("Something broke", 0)]])
            local m, fake = setup()
            m:add("broken", { PROGRAM })
            m:resume("service")
            local info = m:status("broken")
            expect(info.state):eq("exited")
            expect(info.log):same { "Starting", "Something broke" }
            -- Anyone waiting hears of it.
            expect(fake.queued[#fake.queued]):same { n = 3, "service", "broken", "exited" }
        end)
    end)

    it("stops a service by telling it to, so it can tidy up", function()
        with_cleanup(function()
            write(PROGRAM, [[
                local ok, err = pcall(function() while true do os.pullEvent() end end)
                _G.services_spec = err
            ]])
            local m, fake = setup()
            m:add("tidy", { PROGRAM })
            m:resume("service")
            expect(m:stop("tidy")):eq(true)
            expect(m:settled("tidy")):eq(false)
            m:resume("service")

            expect(_G.services_spec):eq("Terminated")
            local info = m:status("tidy")
            expect(info.state):eq("stopped")
            expect(info.enabled):eq(false)
            expect(m:settled("tidy")):eq(true)
            -- Nothing's left waiting to make sure it stopped.
            expect(next(fake.timers)):eq(nil)
        end)
    end)

    it("stops a service which doesn't finish when told to, a while later", function()
        with_cleanup(function()
            write(PROGRAM, [[while true do os.pullEventRaw() end]])
            local m, fake = setup()
            m:add("stubborn", { PROGRAM })
            m:resume("service")
            m:stop("stubborn")
            m:resume("service")
            expect(m:status("stubborn").state):eq("stopping")

            fake.advance(1)
            m:resume("spec")
            expect(m:status("stubborn").state):eq("stopping")

            fake.advance(2)
            m:resume("timer", 1)
            local info = m:status("stubborn")
            expect(info.state):eq("stopped")
            expect(info.log[#info.log]):eq("Stopped, as it didn't finish when told to stop.")
        end)
    end)

    it("lets a service stop itself", function()
        with_cleanup(function()
            write(PROGRAM, [[
                os.pullEvent("go")
                _G.services_spec.manager:stop("itself")
                while true do os.pullEvent() end
            ]])
            local m = setup()
            _G.services_spec = { manager = m }
            m:add("itself", { PROGRAM })
            m:resume("service")
            m:resume("go")
            expect(m:status("itself").state):eq("stopped")
        end)
    end)

    it("starts a service again with its new command", function()
        with_cleanup(function()
            write(PROGRAM, [[print("Running " .. ...) while true do os.pullEvent() end]])
            local m = setup()
            m:add("changing", { PROGRAM, "first" })
            m:resume("service")
            -- The same command again changes nothing.
            m:add("changing", { PROGRAM, "first" })
            m:resume("service")
            expect(m:status("changing").log):same { "Running first" }

            m:add("changing", { PROGRAM, "second" })
            m:resume("service")
            local info = m:status("changing")
            expect(info.state):eq("running")
            expect(info.log):same { "Running second" }
        end)
    end)

    it("keeps services in a file, and starts those which start with the computer", function()
        with_cleanup(function()
            write(PROGRAM, [[print("Up") while true do os.pullEvent() end]])
            local m = setup()
            m:add("kept", { PROGRAM })
            m:add("stopped", { PROGRAM })
            m:resume("service")
            m:stop("stopped")
            m:resume("service")

            local again = setup()
            local names = {}
            for _, info in ipairs(again:list()) do names[#names + 1] = info.name .. ":" .. info.state end
            expect(names):same { "kept:stopped", "stopped:stopped" }

            again:boot(shell)
            again:boot(shell)
            again:resume("service")
            expect(again:status("kept").state):eq("running")
            expect(again:status("kept").log):same { "Up" }
            expect(again:status("stopped").state):eq("stopped")
        end)
    end)

    it("ignores what doesn't make sense in its file", function()
        with_cleanup(function()
            write(FILE, textutils.serialise {
                good = { command = { PROGRAM } },
                ["bad name"] = { command = { PROGRAM } },
                nocommand = {},
                notwords = { command = { PROGRAM, 3 } },
                [1] = "nonsense",
            })
            local m = setup()
            local names = {}
            for _, info in ipairs(m:list()) do names[#names + 1] = info.name end
            expect(names):same { "good" }
        end)
    end)

    it("removes a service, stopping it first", function()
        with_cleanup(function()
            write(PROGRAM, [[while true do os.pullEvent() end]])
            local m = setup()
            m:add("gone", { PROGRAM })
            m:resume("service")
            expect(m:remove("gone")):eq(true)
            m:resume("service")
            expect(m:status("gone")):eq(nil)
            expect(m:list()):same {}
            expect(setup():list()):same {}
            expect(m:remove("gone")):eq(nil)
        end)
    end)

    it("checks names and commands before changing anything", function()
        with_cleanup(function()
            write(PROGRAM, "")
            local m = setup { { name = "builtin", info = function() return nil end } }
            expect({ m:add("bad name", { PROGRAM }) }):same { nil, "A service's name is up to 32 letters, digits, _, - and ." }
            expect({ m:add(("x"):rep(33), { PROGRAM }) })
                :same { nil, "A service's name is up to 32 letters, digits, _, - and ." }
            expect({ m:add("builtin", { PROGRAM }) }):same { nil, "builtin is a service of its own, which can't be changed" }
            expect({ m:add("x", {}) }):same { nil, "A service's command is a program, and its arguments" }
            expect({ m:add("x", { "/no_such_program.lua" }) }):same { nil, "There's no program /no_such_program.lua" }
            expect({ m:add("x", { PROGRAM, 'say "hi"' }) }):same { nil, "A service's command can't have a \" in it" }
            expect({ m:start("x") }):same { nil, "There's no service called x" }
            expect({ m:remove("builtin") }):same { nil, "builtin can't be removed, only stopped" }
            expect(m:list()):same {}
            expect(fs.exists(FILE)):eq(false)
        end)
    end)

    describe("copes with services which misbehave", function()
        it("may ask to start again as it stops, and does", function()
            with_cleanup(function()
                write(PROGRAM, [[
                    pcall(function() while true do os.pullEvent() end end)
                    local spec = _G.services_spec
                    spec.runs = spec.runs + 1
                    if spec.runs == 1 then spec.manager:start("phoenix") end
                ]])
                local m = setup()
                _G.services_spec = { manager = m, runs = 0 }
                m:add("phoenix", { PROGRAM })
                m:resume("service")
                m:stop("phoenix")
                m:resume("service")
                local info = m:status("phoenix")
                expect(info.state):eq("running")
                expect(info.enabled):eq(true)
                expect(m:settled("phoenix")):eq(true)
                local file = fs.open(FILE, "r")
                local saved = textutils.unserialise(file.readAll())
                file.close()
                expect(saved.phoenix.enabled):eq(true)
            end)
        end)

        it("may ask to be removed as it stops, and is", function()
            with_cleanup(function()
                write(PROGRAM, [[
                    pcall(function() while true do os.pullEvent() end end)
                    _G.services_spec.manager:remove("leaving")
                ]])
                local m = setup()
                _G.services_spec = { manager = m }
                m:add("leaving", { PROGRAM })
                m:resume("service")
                m:stop("leaving")
                m:resume("service")
                expect(m:status("leaving")):eq(nil)
                expect(setup():list()):same {}
            end)
        end)

        it("is still stopped if it waits for something it'll never get", function()
            with_cleanup(function()
                write(PROGRAM, [[while true do coroutine.yield({}) end]])
                local m, fake = setup()
                m:add("waiting", { PROGRAM })
                m:resume("service")
                m:resume("spec")
                m:stop("waiting")
                m:resume("service")
                expect(m:status("waiting").state):eq("stopping")
                fake.advance(3)
                m:resume("timer", 1)
                expect(m:status("waiting").state):eq("stopped")
            end)
        end)

        it("leaves the user's terminal as it was, whatever it redirects to", function()
            with_cleanup(function()
                write(PROGRAM, [[
                    local own = window.create(term.current(), 1, 1, 20, 3, false)
                    _G.services_spec = own
                    term.redirect(own)
                    term.setPaletteColour(colours.red, 0x123456)
                    print("Hidden")
                    os.pullEvent("spec")
                    print("Again")
                    while true do os.pullEvent() end
                ]])
                local m = setup()
                local screen, red = term.current(), { term.getPaletteColour(colours.red) }
                m:add("redirects", { PROGRAM })
                m:resume("service")
                expect(term.current()):eq(screen)
                m:resume("spec")
                expect(term.current()):eq(screen)
                expect({ term.getPaletteColour(colours.red) }):same(red)

                local own = _G.services_spec
                expect(own.getLine(1):gsub(" +$", "")):eq("Hidden")
                expect(own.getLine(2):gsub(" +$", "")):eq("Again")
                expect(m:status("redirects").log):same {}
            end)
        end)

        it("keeps the last lines of a service which prints a lot", function()
            with_cleanup(function()
                write(PROGRAM, [[
                    for i = 1, 1000 do print("Line " .. i) end
                    print(("x"):rep(10000))
                    print("End")
                ]])
                local m = setup()
                m:add("chatty", { PROGRAM })
                m:resume("service")
                local log = m:status("chatty").log
                expect(#log <= 100):eq(true)
                expect(log[#log]):eq("End")
                expect(log[#log - 1]):eq(("x"):rep(10000 % 51))
            end)
        end)

        it("says so when its program has gone", function()
            with_cleanup(function()
                write(PROGRAM, [[while true do os.pullEvent() end]])
                setup():add("gone", { PROGRAM })
                fs.delete(PROGRAM)
                local m = setup()
                m:boot(shell)
                m:resume("service")
                local info = m:status("gone")
                expect(info.state):eq("exited")
                expect(info.log):same { "No such program" }
            end)
        end)

        it("exits at once, having asked for another to start", function()
            with_cleanup(function()
                write(PROGRAM, [[
                    if ... == "starter" then
                        _G.services_spec.manager:start("other")
                        return
                    end
                    while true do os.pullEvent() end
                ]])
                local m = setup()
                _G.services_spec = { manager = m }
                m:add("other", { PROGRAM, "other" })
                m:resume("service")
                m:stop("other")
                m:resume("service")
                m:add("starter", { PROGRAM, "starter" })
                m:resume("service")
                expect(m:status("starter").state):eq("exited")
                expect(m:status("other").state):eq("running")
            end)
        end)
    end)

    describe("does what was asked last, when asked twice before it runs", function()
        local function program()
            write(PROGRAM, [[
                local spec = _G.services_spec
                spec.starts = spec.starts + 1
                print("Running " .. ...)
                while true do os.pullEvent() end
            ]])
            _G.services_spec = { starts = 0 }
        end

        it("stops, then starts with a new command, once", function()
            with_cleanup(function()
                program()
                local m = setup()
                m:add("twice", { PROGRAM, "first" })
                m:resume("service")
                m:stop("twice")
                m:add("twice", { PROGRAM, "second" })
                m:resume("service")
                local info = m:status("twice")
                expect(info.state):eq("running")
                expect(info.log):same { "Running second" }
                expect(_G.services_spec.starts):eq(2)
            end)
        end)

        it("keeps a service which is started once it's been removed", function()
            with_cleanup(function()
                program()
                local m = setup()
                m:add("kept", { PROGRAM, "first" })
                m:resume("service")
                m:remove("kept")
                m:start("kept")
                m:resume("service")
                expect(m:status("kept").state):eq("running")
                expect(#setup():list()):eq(1)
            end)
        end)

        it("removes a service which is removed once it's been started, or stopped", function()
            with_cleanup(function()
                program()
                local m = setup()
                m:add("first", { PROGRAM, "first" })
                m:add("second", { PROGRAM, "second" })
                m:resume("service")
                m:start("first")
                m:remove("first")
                m:remove("second")
                m:stop("second")
                m:resume("service")
                expect(m:list()):same {}
                expect(setup():list()):same {}
            end)
        end)
    end)

    it("still wakes after a wake is lost to a full event queue", function()
        with_cleanup(function()
            write(PROGRAM, [[while true do os.pullEvent() end]])
            local dropped, queued = false, {}
            local m = services.new {
                file = FILE, width = 51,
                queue_event = function(event)
                    if event == "service_wake" and not dropped then
                        dropped = true
                        return
                    end
                    queued[#queued + 1] = event
                end,
            }
            m:add("woken", { PROGRAM })
            -- Any event does what was asked.
            m:resume("spec")
            expect(m:status("woken").state):eq("running")
            m:stop("woken")
            expect(queued[#queued]):eq("service_wake")
        end)
    end)

    it("lists services which run elsewhere, once they're set up here, and starts and stops them", function()
        with_cleanup(function()
            local set_up, running, calls = false, false, {}
            local elsewhere = {
                name = "elsewhere", description = "Somewhere else", hint = "elsewhere status",
                info = function()
                    if not set_up then return nil end
                    return { running = running, enabled = running, detail = running and "busy" or nil }
                end,
                start = function()
                    calls[#calls + 1] = "start"
                    running = true
                    return true
                end,
                stop = function()
                    calls[#calls + 1] = "stop"
                    running = false
                    return true
                end,
            }
            local m = setup { elsewhere }
            expect(m:list()):same {}
            expect({ m:start("elsewhere") }):same { nil, "There's no service called elsewhere" }

            set_up = true
            local listed = {
                name = "elsewhere", description = "Somewhere else", hint = "elsewhere status", builtin = true,
                state = "stopped", enabled = false,
            }
            expect(m:list()):same { listed }
            expect(m:start("elsewhere")):eq(true)
            expect(m:status("elsewhere").state):eq("running")
            expect(m:status("elsewhere").detail):eq("busy")
            expect(m:restart("elsewhere")):eq(true)
            expect(m:stop("elsewhere")):eq(true)
            expect(calls):same { "start", "stop", "start", "stop" }
            expect(m:settled("elsewhere")):eq(true)
        end)
    end)
end)
