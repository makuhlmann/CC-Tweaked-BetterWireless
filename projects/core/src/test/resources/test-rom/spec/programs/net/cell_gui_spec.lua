-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local with_window = require "test_helpers".with_window

describe("The cell program's GUI", function()
    --[[ Put a made-up phone behind net.cell: one which is attached to ACME, with the number 0042. Tests change its
    `info`, `messages` and `networks`, and read what was asked of it from `sent`, `read`, `deleted`, `chosen` and
    `enabled`. Timers are made up too, so tests choose when they go off. ]]
    local function fake_phone(info)
        local phone = {
            info = info or {
                state = "attached", enabled = true, network = "ACME", serving_network = "ACME", signal = -75,
                roaming = false, selection = "auto", subscriber = { id = "ACME-0042", number = "0042" },
                address = "10.64.0.2", heard = {}, events = {},
            },
            messages = {}, networks = {}, sent = {}, read = {}, deleted = {}, chosen = {}, enabled = {}, timers = {},
        }

        if not crypto then stub(_G, "crypto", {}) end
        if not enclave then stub(_G, "enclave", {}) end
        stub(net.cell, "listen", function() return true end)
        stub(net.cell, "info", function()
            phone.info.unread = 0
            for _, message in ipairs(phone.messages) do
                if message.from and message.read == false then phone.info.unread = phone.info.unread + 1 end
            end
            return phone.info
        end)
        stub(net.cell, "messages", function()
            local list = {}
            for i, message in ipairs(phone.messages) do
                list[i] = {}
                for k, v in pairs(message) do list[i][k] = v end
            end
            return list
        end)
        stub(net.cell, "markRead", function(n)
            phone.read[#phone.read + 1] = n
            for _, message in ipairs(phone.messages) do
                if message.n == n then message.read = true end
            end
            return 1
        end)
        stub(net.cell, "deleteMessage", function(n)
            phone.deleted[#phone.deleted + 1] = n
            for i, message in ipairs(phone.messages) do
                if message.n == n then table.remove(phone.messages, i) break end
            end
            return true
        end)
        stub(net.cell, "send", function(number, text)
            phone.sent[#phone.sent + 1] = { number, text }
            if phone.refuse then return nil, phone.refuse end
            return true, 7
        end)
        stub(net.cell, "networks", function() return phone.networks end)
        stub(net.cell, "setNetwork", function(name)
            phone.chosen[#phone.chosen + 1] = name
            for _, network in ipairs(phone.networks) do
                if network.name == name and not network.allowed then return nil, "This SIM can't use " .. name end
            end
            for _, network in ipairs(phone.networks) do network.selected = network.name == name end
            phone.info.selection = name
            return true
        end)
        stub(net.cell, "setEnabled", function(enabled)
            phone.enabled[#phone.enabled + 1] = enabled
            if enabled and phone.no_modem then return nil, "This needs a wireless modem" end
            phone.info.enabled, phone.info.state = enabled, enabled and "attached" or "off"
            return true
        end)

        local next_timer = 1000000
        stub(os, "startTimer", function(seconds)
            next_timer = next_timer + 1
            phone.timers[next_timer] = seconds
            return next_timer
        end)
        stub(os, "cancelTimer", function(id) phone.timers[id] = nil end)

        return phone
    end

    --[[ Run the cell program on a screen of some size, and give a function the means to use it: to send it events,
    press keys and type, and to read the screen. `options` may have `width` and `height` (a pocket computer's if not
    given), `basic` for a screen without colours, and `args`, the program's arguments (`gui` if not given). ]]
    local function run(phone, options, body)
        with_window(options.width or 26, options.height or 20, function()
            local screen = term.current()
            if options.basic then
                local basic = setmetatable({}, { __index = screen })
                function basic.isColour() return false end
                basic.isColor = basic.isColour
                term.redirect(basic)
            end

            local result
            local co = coroutine.create(function(...) result = shell.run(...) end)
            local app = { screen = screen }

            function app.line(y)
                return (screen.getLine(y):gsub(" +$", ""))
            end
            function app.fg(y) return (select(2, screen.getLine(y))) end
            function app.bg(y) return (select(3, screen.getLine(y))) end
            function app.lines(from, to)
                local lines = {}
                for y = from, to do lines[#lines + 1] = app.line(y) end
                return lines
            end
            -- The first line with some text on it.
            function app.find(text)
                local _, height = screen.getSize()
                for y = 1, height do
                    if app.line(y):find(text, 1, true) then return y end
                end
                return nil
            end

            function app.event(...)
                assert(coroutine.resume(co, ...))
                if coroutine.status(co) == "dead" and result ~= true then
                    error("The program failed:\n" .. table.concat(app.lines(1, 6), "\n"), 0)
                end
            end
            function app.key(...)
                for _, key in ipairs({ ... }) do app.event("key", key, false) end
            end
            function app.type(text)
                for char in text:gmatch(".") do app.event("char", char) end
            end
            -- Let every timer which waits for some time go off.
            function app.timers(seconds)
                local due = {}
                for id, time in pairs(phone.timers) do
                    if time == seconds then due[#due + 1] = id end
                end
                table.sort(due)
                for _, id in ipairs(due) do
                    phone.timers[id] = nil
                    app.event("timer", id)
                end
            end
            function app.finished() return coroutine.status(co) == "dead" end

            app.event("/rom/programs/net/cell.lua", table.unpack(options.args or { "gui" }))
            body(app)
        end)
    end

    local function message_fixture()
        local now = os.epoch("utc")
        return {
            { n = 1, from = "0007", text = "Old news", time = now - 3 * 24 * 3600 * 1000, read = true },
            { n = 2, to = "0007", text = "On my way", time = now, status = "sent" },
            { n = 3, from = "0100", text = "Meet at the station at noon, by the big clock", time = now, read = false },
        }
    end

    local function network_fixture()
        return {
            { name = "ACME", kind = "home", allowed = true, signal = -65, serving = true, selected = false },
            { name = "BETA", kind = "partner", allowed = true, signal = -85, serving = false, selected = false },
            { name = "GAMMA", kind = "other", allowed = false, serving = false, selected = false },
        }
    end

    describe("whatever happens", function()
        -- Random numbers which are the same each time the tests run.
        local function random_numbers(seed)
            local state = seed
            return function(low, high)
                state = (state * 1103515245 + 12345) % 2147483648
                return low + math.floor(state / 2147483648 * (high - low + 1))
            end
        end

        local KEYS = {
            keys.up, keys.down, keys.left, keys.right, keys.enter, keys.numPadEnter, keys.backspace, keys.tab, keys.home,
            keys["end"], keys.delete, keys.pageUp, keys.pageDown, keys.a, keys.f1,
        }
        local STATES = { "none", "off", "inactive", "activating", "searching", "attaching", "attached", "rejected", "odd" }
        local TEXTS = {
            "", " ", "Hello", "\n\n\n", "one\ntwo\n\nthree\n", ("x"):rep(1000), ("word "):rep(200), "tab\there\0nul\255",
            ("\n"):rep(60) .. "end", "   leading and trailing   ",
        }
        local NAMES = { "ACME", "B", ("LONGNAME"):rep(4), "A-1" }
        local CHARS = "qQrRdDxy 0123456789"

        -- Use the menus at random on a screen of some size, with a phone which changes at random, and say what was
        -- done if anything fails.
        local function storm(width, height, seed, count)
            local random = random_numbers(seed)
            local function pick(list) return list[random(1, #list)] end

            local phone = fake_phone()
            phone.messages, phone.networks = message_fixture(), network_fixture()
            local done = {}
            local function note(...) done[#done + 1] = table.concat({ ... }, " ") end

            local function change_phone()
                local info = phone.info
                info.state = pick(STATES)
                info.enabled = info.state ~= "off"
                info.network = random(1, 5) > 1 and pick(NAMES) or nil
                info.serving_network = random(1, 4) > 1 and pick(NAMES) or nil
                info.signal = random(1, 5) > 1 and -random(40, 130) or nil
                info.roaming = random(1, 2) == 1
                info.selection = random(1, 3) == 1 and pick(NAMES) or "auto"
                info.subscriber = random(1, 4) > 1 and { id = "ACME-1", number = pick { "1", ("9"):rep(30) } } or nil
                info.rejected = random(1, 3) == 1 and "Not allowed here, for a reason which goes on and on" or nil
                phone.refuse = random(1, 4) == 1 and "No service" or nil
                phone.no_modem = random(1, 4) == 1

                phone.networks = {}
                for i = 1, random(0, 12) do
                    phone.networks[i] = {
                        name = pick(NAMES) .. i, kind = pick { "home", "partner", "other" }, allowed = random(1, 2) == 1,
                        signal = random(1, 3) > 1 and -random(40, 130) or nil, serving = random(1, 4) == 1,
                        selected = random(1, 4) == 1,
                    }
                end
                note("phone", info.state, tostring(info.network), #phone.networks)
            end

            local function add_message()
                local n = 0
                for _, message in ipairs(phone.messages) do n = math.max(n, message.n) end
                local message = { n = n + 1, text = pick(TEXTS), time = random(1, 4) > 1 and os.epoch("utc") or nil }
                if random(1, 2) == 1 then
                    message.from, message.read = pick { "0100", ("7"):rep(40) }, random(1, 3) == 1
                else
                    message.to, message.status = "0007", pick { "sending", "sent", "failed" }
                    message.error = random(1, 2) == 1 and "Nobody has that number" or nil
                end
                phone.messages[#phone.messages + 1] = message
                while #phone.messages > 30 do table.remove(phone.messages, 1) end
                note("message", message.n)
            end

            -- The menus are started again whenever they're quit, until enough has been done.
            local left = count
            local function session(app)
                note("start")
                while left > 0 do
                    if app.finished() then return end
                    left = left - 1
                    local w, h = app.screen.getSize()
                    local kind = random(1, 26)
                    if kind <= 7 then
                        local key, held = pick(KEYS), random(1, 6) == 1
                        note("key", keys.getName(key), tostring(held))
                        app.event("key", key, held)
                    elseif kind <= 10 then
                        local at = random(1, #CHARS)
                        note("char", CHARS:sub(at, at))
                        app.event("char", CHARS:sub(at, at))
                    elseif kind == 11 then
                        note("paste")
                        app.event("paste", pick(TEXTS))
                    elseif kind <= 14 then
                        local button, x, y = random(1, 3), random(0, w + 1), random(0, h + 1)
                        -- Half the clicks are ones a user might make: with the left button, where lists have their rows.
                        if random(1, 2) == 1 then button, x, y = 1, random(1, math.min(w, 10)), random(1, math.min(h, 9)) end
                        note("click", button, x, y)
                        app.event("mouse_click", button, x, y)
                        if not app.finished() then app.event("mouse_up", button, x, y) end
                    elseif kind == 15 then
                        note("drag")
                        app.event("mouse_drag", 1, random(0, w + 1), random(0, h + 1))
                    elseif kind == 16 then
                        local by = random(1, 2) * 2 - 3
                        note("scroll", by)
                        app.event("mouse_scroll", by, random(1, w), random(1, h))
                    elseif kind == 17 then
                        local new_w, new_h = math.max(1, w + random(-3, 3)), math.max(1, h + random(-3, 3))
                        note("resize", new_w, new_h)
                        app.screen.reposition(1, 1, new_w, new_h)
                        app.event("term_resize")
                    elseif kind == 18 then
                        change_phone()
                        app.event("cell_state", phone.info.state)
                    elseif kind == 19 then
                        add_message()
                        app.event("cell_message", "0100", "text")
                    elseif kind == 20 then
                        if #phone.messages > 0 then table.remove(phone.messages, random(1, #phone.messages)) end
                        note("messages")
                        app.event("cell_messages")
                    elseif kind == 21 then
                        local taken = random(1, 2) == 1
                        note("sent", tostring(taken))
                        app.event("cell_sent", pick { 7, 8 }, taken, not taken and random(1, 2) == 1 and "Nobody has that number" or nil)
                    elseif kind <= 23 then
                        local ids = {}
                        for id in pairs(phone.timers) do ids[#ids + 1] = id end
                        table.sort(ids)
                        if #ids > 0 then
                            local id = pick(ids)
                            note("timer", phone.timers[id])
                            phone.timers[id] = nil
                            app.event("timer", id)
                        end
                    elseif kind == 24 then
                        -- Deleting takes two steps, which seldom follow each other by chance.
                        note("delete")
                        app.event("char", "d")
                        if not app.finished() then app.event("key", keys.enter, false) end
                    elseif kind == 25 then
                        -- Wherever the menus have got to, terminating ends them, and they start from the top again.
                        break
                    else
                        note("other event")
                        app.event(pick { "redstone", "modem_message", "timer", "net_cell" }, random(1, 100))
                    end
                end
                if not app.finished() then
                    note("terminate")
                    app.event("terminate")
                end
                if not app.finished() then error("Still running after it was terminated", 0) end
            end
            local ok, err = pcall(function()
                while left > 0 do run(phone, { width = width, height = height }, session) end
            end)
            if not ok then
                local from = math.max(1, #done - 25)
                error(("%s\n%dx%d, seed %d, after %d things, the last being:\n%s"):format(
                    tostring(err), width, height, seed, #done, table.concat(done, "\n", from)), 0)
            end
            return phone
        end

        for _, size in ipairs { { 26, 20 }, { 51, 19 }, { 80, 30 }, { 12, 6 }, { 7, 4 }, { 3, 2 }, { 1, 1 } } do
            it(("the menus keep going, on a screen of %d by %d"):format(size[1], size[2]), function()
                local reached = { sent = 0, read = 0, deleted = 0, chosen = 0, enabled = 0 }
                -- Screens worth the name get more, as there's more to reach on them.
                local usable = size[1] >= 26
                for seed = 1, 6 do
                    local phone = storm(size[1], size[2], seed * 7919 + size[1], usable and 500 or 300)
                    for what, count in pairs(reached) do reached[what] = count + #phone[what] end
                end
                -- There, all this gets as far as each thing the menus can do. If it stops doing so, the menus have
                -- changed, and the storm needs to be steered to them again.
                if usable then
                    for what, count in pairs(reached) do
                        if count == 0 then fail(("The storm never got as far as %s"):format(what)) end
                    end
                end
            end)
        end
    end)

    describe("status bar", function()
        it("shows the network and its signal", function()
            run(fake_phone(), {}, function(app)
                expect(app.line(1)):eq(" ACME              [|||.]")
                expect(app.bg(1)):eq(("7"):rep(26))
                -- The bars which aren't lit are dimmer.
                expect(app.fg(1):sub(20, 25)):eq("000080")
                -- The menu starts on the next line.
                expect(app.line(2)):eq("Phone             No. 0042")
            end)
        end)

        it("fills a normal computer's screen", function()
            run(fake_phone(), { width = 51, height = 19 }, function(app)
                expect(app.line(1)):eq(" ACME" .. (" "):rep(39) .. "[|||.]")
                expect(app.bg(1)):eq(("7"):rep(51))
                expect(app.line(2)):eq("Phone" .. (" "):rep(38) .. "No. 0042")
            end)
        end)

        it("is dark grey, with or without colours", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, { basic = true }, function(app)
                expect(app.line(1)):eq(" ACME   1 new msg  [|||.]")
                expect(app.bg(1)):eq(("7"):rep(26))
                expect(app.fg(1)):eq(("0"):rep(23) .. "800")
                -- The menu has no colours either.
                expect(app.fg(2):sub(1, 5)):eq("00000")
            end)

            run(phone, { basic = true, width = 51, height = 19 }, function(app)
                expect(app.line(1)):eq(" ACME" .. (" "):rep(16) .. "1 new msg" .. (" "):rep(14) .. "[|||.]")
                expect(app.bg(1)):eq(("7"):rep(51))
            end)
        end)

        it("says when the phone is searching", function()
            local phone = fake_phone()
            phone.info.state, phone.info.signal, phone.info.serving_network = "searching", nil, nil
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" Searching...      [....]")
            end)
            run(phone, { width = 51, height = 19 }, function(app)
                expect(app.line(1)):eq(" Searching..." .. (" "):rep(31) .. "[....]")
            end)
        end)

        it("says when the phone has no service, or was rejected", function()
            local bar = require "cc.internal.net.cell.bar"
            local info = { state = "searching", network = "ACME", unread = 0 }
            expect((bar.line(info, 26, true, false))):eq(" Searching...      [....] ")
            expect((bar.line(info, 26, true, true))):eq(" No service        [....] ")
            info.state = "rejected"
            expect((bar.line(info, 26, false))):eq(" Rejected          [....] ")
            info.state = "attaching"
            expect((bar.line(info, 26, false))):eq(" Connecting...     [....] ")
        end)

        it("marks roaming", function()
            local phone = fake_phone()
            phone.info.roaming, phone.info.serving_network, phone.info.signal = true, "BETA", -95
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" BETA            R [|...]")
            end)
            run(phone, { width = 51, height = 19, basic = true }, function(app)
                expect(app.line(1)):eq(" BETA" .. (" "):rep(37) .. "R [|...]")
            end)
        end)

        it("counts new messages", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" ACME   1 new msg  [|||.]")
                -- The notice stands out.
                expect(app.fg(1):sub(9, 17)):eq(("4"):rep(9))

                phone.messages[1].read, phone.messages[4] = false, { n = 4, from = "0100", text = "Hi", time = 0, read = false }
                app.event("cell_message", "0100", "Hi")
                expect(app.line(1)):eq(" ACME   3 new msgs [|||.]")
            end)
            run(phone, { width = 51, height = 19 }, function(app)
                expect(app.line(1)):eq(" ACME" .. (" "):rep(15) .. "3 new msgs" .. (" "):rep(14) .. "[|||.]")
            end)
        end)

        it("cuts a long name short to fit the rest in", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            phone.messages[1].read, phone.messages[2] = false, { n = 2, from = "0100", text = "Hi", time = 0, read = false }
            phone.info.roaming, phone.info.serving_network = true, "LONGNETWORKNAME"
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" LONG 3 new msgs R [|||.]")
            end)
            run(phone, { width = 51, height = 19 }, function(app)
                expect(app.line(1)):eq(" LONGNETWORKNAME    3 new msgs" .. (" "):rep(12) .. "R [|||.]")
            end)

            -- Without a notice, the name has the room.
            phone.messages = {}
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" LONGNETWORKNAME R [|||.]")
            end)
        end)

        it("never draws wider than the screen", function()
            local bar = require "cc.internal.net.cell.bar"
            local info = { state = "attached", network = "ACME", serving_network = "ACME", signal = -60, roaming = true, unread = 12 }
            for width = 1, 60 do
                local text, fg, bg = bar.line(info, width, true)
                expect({ #text, #fg, #bg }):same { width, width, width }
            end
            expect((bar.line(info, 15, true))):eq(" ACME R [||||] ")
            expect((bar.line(info, 11, true))):eq(" ACME      ")
            expect((bar.line(info, 7, true))):eq(" ACME  ")
        end)

        it("follows the signal", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" ACME              [|||.]")
                phone.info.signal = -95
                app.timers(2)
                expect(app.line(1)):eq(" ACME              [|...]")

                phone.info.state, phone.info.signal, phone.info.serving_network = "searching", nil, nil
                app.event("cell_state", "searching")
                expect(app.line(1)):eq(" Searching...      [....]")
            end)
        end)

        it("isn't there while cell service is off", function()
            local phone = fake_phone()
            phone.info.state, phone.info.enabled = "off", false
            run(phone, {}, function(app)
                -- The menu has the top line.
                expect(app.line(1)):eq("Phone             No. 0042")
                expect(app.bg(1)):eq(("f"):rep(26))
                expect(app.line(3)):eq(" Messages")
                expect(app.line(20)):eq("Enter: choose  Q: quit")

                -- Nor does it come with the timer.
                app.timers(2)
                expect(app.line(1)):eq("Phone             No. 0042")

                -- It comes back with the service.
                phone.info.state, phone.info.enabled = "searching", true
                app.event("cell_state", "searching")
                expect(app.line(1)):eq(" Searching...      [....]")
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(app.line(4)):eq(" Messages")
                expect(app.line(20)):eq("Enter: choose  Q: quit")

                -- And goes with it.
                phone.info.state, phone.info.enabled = "off", false
                app.event("cell_state", "off")
                expect(app.line(1)):eq("Phone             No. 0042")
                expect(app.line(20)):eq("Enter: choose  Q: quit")
            end)
        end)

        it("isn't there without a SIM", function()
            local phone = fake_phone({ state = "none", enabled = true, selection = "auto", roaming = false })
            run(phone, {}, function(app)
                expect(app.lines(1, 4)):same { "Phone", "", " Monitor", " Quit" }
                expect(app.lines(17, 20)):same {
                    "No SIM. Activate one with:",
                    "cell activate <network>",
                    "<code>",
                    "Enter: choose  Q: quit",
                }

                -- A computer which only listens for cells, as the monitor makes it, has no SIM either.
                phone.info.state = "inactive"
                app.event("cell_state", "inactive")
                expect(app.lines(1, 4)):same { "Phone", "", " Monitor", " Quit" }

                -- Once it's activated, there's a bar, and everything else.
                phone.info.state, phone.info.network = "searching", "ACME"
                phone.info.subscriber = { id = "ACME-0042", number = "0042" }
                app.event("cell_state", "searching")
                expect(app.lines(1, 5)):same {
                    " Searching...      [....]", "Phone             No. 0042", "", " Messages", " New message",
                }
            end)
        end)

        it("follows the screen's size", function()
            run(fake_phone(), {}, function(app)
                app.screen.reposition(1, 1, 51, 19)
                app.event("term_resize")
                expect(app.line(1)):eq(" ACME" .. (" "):rep(39) .. "[|||.]")
                expect(app.bg(1)):eq(("7"):rep(51))
                expect(app.line(2)):eq("Phone" .. (" "):rep(38) .. "No. 0042")
                expect(app.line(19)):eq("Enter: choose  Q: quit")

                app.screen.reposition(1, 1, 26, 20)
                app.event("term_resize")
                expect(app.line(1)):eq(" ACME              [|||.]")
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(app.line(20)):eq("Enter: choose  Q: quit")
            end)
        end)
    end)

    describe("home menu", function()
        it("lists what can be done", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                expect(app.lines(2, 10)):same {
                    "Phone             No. 0042",
                    "",
                    " Messages (1 new)",
                    " New message",
                    " Networks",
                    " Cell service: On",
                    " Monitor",
                    " Quit",
                    "",
                }
                expect(app.line(20)):eq("Enter: choose  Q: quit")
                -- The first is chosen.
                expect({ app.bg(4), app.bg(5) }):same { ("0"):rep(26), ("f"):rep(26) }
            end)
        end)

        it("is moved through with the keys", function()
            run(fake_phone(), {}, function(app)
                app.key(keys.down, keys.down)
                expect({ app.bg(4), app.bg(6) }):same { ("f"):rep(26), ("0"):rep(26) }
                app.key(keys.up)
                expect(app.bg(5)):eq(("0"):rep(26))
                -- Up from the first goes to the last, and down from there to the first again.
                app.key(keys.up, keys.up)
                expect(app.bg(9)):eq(("0"):rep(26))
                app.key(keys.down)
                expect(app.bg(4)):eq(("0"):rep(26))

                -- There's nowhere to go back to.
                app.key(keys.backspace, keys.left)
                expect(app.line(2)):eq("Phone             No. 0042")

                -- Enter opens what is chosen, and Backspace or Left comes back.
                app.key(keys.down, keys.down, keys.enter)
                expect(app.line(2)):eq("Networks")
                app.key(keys.backspace)
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(app.bg(6)):eq(("0"):rep(26))
                app.key(keys.enter)
                expect(app.line(2)):eq("Networks")
                app.key(keys.left)
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(app.finished()):eq(false)
            end)
        end)

        it("doesn't go through screens while a key is held", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                app.key(keys.enter)
                app.event("key", keys.enter, true)
                expect(app.line(2)):eq("Messages             1 new")
                app.event("key", keys.backspace, true)
                expect(app.line(2)):eq("Messages             1 new")
            end)
        end)

        it("is used with the mouse", function()
            run(fake_phone(), {}, function(app)
                -- A click on the bar does nothing, nor does one on an empty line.
                app.event("mouse_click", 1, 3, 1)
                app.event("mouse_click", 1, 3, 12)
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(app.bg(4)):eq(("0"):rep(26))

                -- A click on a line opens it: the menu is one line down the screen.
                app.event("mouse_click", 1, 3, 6)
                expect(app.line(2)):eq("Networks")
                expect(app.line(4)):eq(" *Automatic")
                app.key(keys.backspace)

                app.event("mouse_scroll", 1, 3, 6)
                expect(app.bg(7)):eq(("0"):rep(26))

                app.event("mouse_click", 1, 3, 9)
                expect(app.finished()):eq(true)
            end)
        end)

        it("quits with Q, and leaves the screen clear", function()
            run(fake_phone(), {}, function(app)
                app.type("x")
                expect(app.finished()):eq(false)
                app.type("Q")
                expect(app.finished()):eq(true)
                expect(table.concat(app.lines(1, 20))):eq("")
                expect({ term.getCursorPos() }):same { 1, 1 }
                expect(term.current()):eq(app.screen)
            end)
        end)

        it("stops when it's terminated", function()
            run(fake_phone(), {}, function(app)
                app.key(keys.enter)
                app.event("terminate")
                expect(app.finished()):eq(true)
                expect(app.line(1)):eq("")
                expect(term.current()):eq(app.screen)
            end)
        end)

        it("says why the phone was rejected", function()
            local phone = fake_phone()
            phone.info.state, phone.info.rejected = "rejected", "Unknown subscriber"
            run(phone, {}, function(app)
                expect(app.line(1)):eq(" Rejected          [....]")
                expect(app.lines(18, 19)):same { "Rejected: Unknown", "subscriber" }
            end)
        end)
    end)

    describe("messages", function()
        it("are listed, newest first", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                app.key(keys.enter)
                expect(app.line(2)):eq("Messages             1 new")
                expect(app.line(4)):str_match("^%*0100 %d%d:%d%d  Meet at the s$")
                expect(app.line(5)):str_match("^>0007 %d%d:%d%d  On my way$")
                expect(app.line(6)):eq(" 0007 " .. os.date("%d %b", math.floor(phone.messages[1].time / 1000)) .. " Old news")
                expect(app.lines(19, 20)):same { "* new  > sent  ! failed", "Backspace: back" }
                -- Listing them doesn't read them.
                expect(phone.read):same {}
                expect(app.line(1)):eq(" ACME   1 new msg  [|||.]")
            end)

            run(phone, { width = 51, height = 19 }, function(app)
                app.key(keys.enter)
                expect(app.line(4)):str_match("^%*0100 %d%d:%d%d  Meet at the station at noon, by the bi$")
                expect(app.line(19)):eq("* new  > sent  ! failed  Backspace: back")
            end)
        end)

        it("may be none", function()
            run(fake_phone(), {}, function(app)
                app.key(keys.enter)
                expect(app.lines(2, 4)):same { "Messages", "", "No messages." }
                app.key(keys.enter, keys.down, keys.up)
                app.event("mouse_click", 1, 1, 4)
                expect(app.line(4)):eq("No messages.")
                app.key(keys.backspace)
                expect(app.line(2)):eq("Phone             No. 0042")
            end)
        end)

        it("show a message which arrives", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.enter)
                phone.messages = message_fixture()
                app.event("cell_message", "0100", "Meet at the station at noon, by the big clock")
                expect(app.line(4)):str_match("^%*0100 ")
                expect(app.line(1)):eq(" ACME   1 new msg  [|||.]")
            end)
        end)

        it("are opened, which reads them", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                app.key(keys.enter, keys.enter)
                expect(app.lines(2, 7)):same {
                    "From 0100",
                    os.date("%Y-%m-%d %H:%M", math.floor(phone.messages[3].time / 1000)),
                    "",
                    "Meet at the station at",
                    "noon, by the big clock",
                    "",
                }
                expect(app.line(20)):eq(" Reply   Delete   Back")
                expect(phone.read):same { 3 }
                -- The bar no longer counts it.
                expect(app.line(1)):eq(" ACME              [|||.]")

                -- Back in the list, it's no longer marked.
                app.key(keys.backspace)
                expect(app.line(2)):eq("Messages")
                expect(app.line(4)):str_match("^ 0100 ")

                -- A message which was read isn't marked again.
                app.key(keys.enter, keys.right, keys.right, keys.enter)
                expect(app.line(2)):eq("Messages")
                expect(phone.read):same { 3 }
            end)
        end)

        it("say how a sent message got on", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            phone.messages[4] = { n = 4, to = "0999", text = "Anyone?", time = os.epoch("utc"), status = "failed", error = "Nobody has that number" }
            phone.messages[5] = { n = 5, to = "0007", text = "Nearly there", time = os.epoch("utc"), status = "sending" }
            run(phone, {}, function(app)
                app.key(keys.enter)
                expect(app.line(4)):str_match("^>0007 %d%d:%d%d  Nearly there$")
                expect(app.line(5)):str_match("^!0999 %d%d:%d%d  Anyone%?$")
                expect(app.line(8)):str_match("^ 0007 %d%d %a%a%a Old news$")

                app.key(keys.enter)
                expect(app.line(2)):eq("To 0007")
                expect(app.lines(4, 6)):same { "Sending...", "", "Nearly there" }
                expect(app.line(20)):eq(" Delete   Back")
                -- It changes when the network has it.
                phone.messages[5].status = "sent"
                app.event("cell_sent", 9, true)
                expect(app.lines(4, 6)):same { "Sent", "", "Nearly there" }
                app.key(keys.right, keys.enter)

                app.key(keys.down, keys.enter)
                expect(app.line(2)):eq("To 0999")
                expect(app.lines(4, 7)):same { "Not sent: Nobody has that", "number", "", "Anyone?" }
                expect(phone.read):same {}
            end)
        end)

        it("are answered, with the number filled in", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                app.key(keys.enter, keys.enter, keys.enter)
                expect(app.lines(2, 4)):same { "Reply", "To: 0100", "Message:            0/1000" }
                expect(app.line(20)):eq(" Send   Cancel")
                -- The cursor waits in the text.
                expect({ term.getCursorPos() }):same { 1, 5 }

                app.type("See you there")
                expect(app.lines(4, 5)):same { "Message:           13/1000", "See you there" }
                app.key(keys.enter)
                expect(phone.sent):same { { "0100", "See you there" } }
                expect(app.lines(2, 4)):same { "To 0100", "", "Sending..." }
                app.event("cell_sent", 7, true)
                expect(app.line(4)):eq("Sent.")
                -- Then it's back to the message.
                app.key(keys.enter)
                expect(app.line(2)):eq("From 0100")

                -- R answers too.
                app.type("r")
                expect(app.lines(2, 3)):same { "Reply", "To: 0100" }
            end)
        end)

        it("are deleted, once that's confirmed", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                app.key(keys.enter, keys.enter, keys.right, keys.enter)
                expect(app.lines(19, 20)):same { "Delete this message?", " Delete   Keep" }
                expect(phone.deleted):same {}

                -- Keeping it changes nothing.
                app.key(keys.right, keys.enter)
                expect(app.lines(19, 20)):same { "", " Reply   Delete   Back" }
                expect(phone.deleted):same {}

                app.type("d")
                app.key(keys.enter)
                expect(phone.deleted):same { 3 }
                expect(app.line(2)):eq("Messages")
                expect(app.line(4)):str_match("^>0007 ")
                expect(#phone.messages):eq(2)
            end)
        end)

        it("are used with the mouse", function()
            local phone = fake_phone()
            phone.messages = message_fixture()
            run(phone, {}, function(app)
                app.event("mouse_click", 1, 5, 4)
                expect(app.line(2)):eq("Messages             1 new")
                app.event("mouse_click", 1, 5, 6)
                expect(app.lines(2, 5)):same { "From 0007", os.date("%Y-%m-%d %H:%M", math.floor(phone.messages[1].time / 1000)), "", "Old news" }
                -- Delete, then Keep, then Back.
                app.event("mouse_click", 1, 10, 20)
                expect(app.line(19)):eq("Delete this message?")
                app.event("mouse_click", 1, 12, 20)
                expect(app.line(19)):eq("")
                app.event("mouse_click", 1, 20, 20)
                expect(app.line(2)):eq("Messages             1 new")
            end)
        end)

        it("scroll when they're long", function()
            local phone = fake_phone()
            local words = {}
            for i = 1, 60 do words[i] = "word" .. i end
            phone.messages = { { n = 1, from = "0100", text = table.concat(words, " "), time = os.epoch("utc"), read = true } }
            run(phone, {}, function(app)
                app.key(keys.enter, keys.enter)
                expect(app.line(5)):eq("word1 word2 word3 word4")
                expect(app.line(18)):eq("word43 word44 word45")
                expect(app.line(19)):eq("Up/Down: more (1/6)")
                app.key(keys.down)
                expect(app.line(5)):eq("word5 word6 word7 word8")
                expect(app.line(19)):eq("Up/Down: more (2/6)")
                app.key(keys.pageDown, keys.down)
                expect(app.line(18)):eq("word58 word59 word60")
                expect(app.line(19)):eq("Up/Down: more (6/6)")
                app.event("mouse_scroll", -1, 1, 5)
                app.key(keys.up)
                expect(app.line(5)):eq("word13 word14 word15")
                app.key(keys.pageUp)
                expect(app.line(5)):eq("word1 word2 word3 word4")
            end)
        end)

        it("scroll when there are many", function()
            local phone = fake_phone()
            for i = 1, 30 do
                phone.messages[i] = { n = i, from = "0100", text = "Number " .. i, time = os.epoch("utc"), read = true }
            end
            run(phone, {}, function(app)
                app.key(keys.enter)
                expect(app.line(2)):eq("Messages              1/30")
                expect(app.line(4)):str_match("^ 0100 %d%d:%d%d Number 30$")
                expect(app.line(18)):str_match("Number 16$")
                for _ = 1, 15 do app.key(keys.down) end
                expect(app.line(2)):eq("Messages             16/30")
                expect(app.line(18)):str_match("Number 15$")
                expect(app.bg(18)):eq(("0"):rep(26))
                app.key(keys["end"])
                expect(app.line(18)):str_match("Number 1$")
            end)
        end)
    end)

    describe("new message", function()
        it("asks for a number and a text, and sends them", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.down, keys.enter)
                expect(app.lines(2, 4)):same { "New message", "To:", "Message:            0/1000" }
                expect({ term.getCursorPos() }):same { 5, 3 }

                app.type("0007")
                expect(app.line(3)):eq("To: 0007")
                app.key(keys.enter)
                app.type("Meet at the station, by the big clock")
                expect(app.lines(4, 6)):same { "Message:           37/1000", "Meet at the station, by", "the big clock" }
                expect({ term.getCursorPos() }):same { 14, 6 }
                expect(phone.sent):same {}

                app.key(keys.enter)
                expect(phone.sent):same { { "0007", "Meet at the station, by the big clock" } }
                expect(app.lines(2, 4)):same { "To 0007", "", "Sending..." }
                expect(app.line(20)):eq("")

                -- Other messages' news isn't this one's.
                app.event("cell_sent", 6, false, "Nobody has that number")
                expect(app.line(4)):eq("Sending...")
                app.event("cell_sent", 7, true)
                expect(app.line(4)):eq("Sent.")
                expect(app.line(20)):eq("Press any key")

                app.event("key", keys.enter, true)
                expect(app.line(4)):eq("Sent.")
                app.key(keys.space)
                expect(app.line(2)):eq("Phone             No. 0042")
            end)
        end)

        it("says why the network didn't take a message", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.down, keys.enter)
                app.type("0999")
                app.key(keys.enter)
                app.type("Anyone?")
                app.key(keys.enter)
                app.event("cell_sent", 7, false, "Nobody has that number")
                expect(app.lines(4, 5)):same { "Not sent: Nobody has that", "number" }

                -- Then the number can be put right.
                app.key(keys.enter)
                expect(app.lines(2, 5)):same { "New message", "To: 0999", "Message:            7/1000", "Anyone?" }
                expect(app.lines(17, 18)):same { "Not sent: Nobody has that", "number" }
                app.key(keys.up, keys.backspace, keys.backspace, keys.backspace)
                app.type("007")
                app.key(keys.down, keys.down, keys.enter)
                expect(phone.sent):same { { "0999", "Anyone?" }, { "0007", "Anyone?" } }
            end)
        end)

        it("stops waiting for the network after a while", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.down, keys.enter)
                app.type("0007")
                app.key(keys.enter)
                app.type("Hello")
                app.key(keys.enter)
                expect(app.line(4)):eq("Sending...")
                app.timers(20)
                expect(app.lines(4, 5)):same { "Still sending. The network", "hasn't answered yet." }
                app.event("mouse_click", 1, 1, 5)
                expect(app.line(2)):eq("Phone             No. 0042")
            end)
        end)

        it("says why a message can't be sent", function()
            local phone = fake_phone()
            phone.refuse = "No service"
            run(phone, {}, function(app)
                app.key(keys.down, keys.enter)

                -- Nothing is sent without a number and a text.
                app.key(keys.enter, keys.enter)
                expect(app.line(18)):eq("Enter a number first.")
                app.type(" 0007 ")
                app.key(keys.enter, keys.enter)
                expect(app.line(18)):eq("Write a message first.")
                expect(phone.sent):same {}

                app.type("Hello")
                app.key(keys.enter)
                expect(phone.sent):same { { "0007", "Hello" } }
                expect(app.line(2)):eq("New message")
                expect(app.line(18)):eq("No service")
                expect(app.line(5)):eq("Hello")

                -- Cancel gives up.
                app.key(keys.down, keys.right, keys.enter)
                expect(app.line(2)):eq("Phone             No. 0042")
            end)
        end)

        it("is edited like any text", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.down, keys.enter)
                app.type("12")
                app.key(keys.left)
                app.type("0")
                app.key(keys.home, keys.delete, keys["end"])
                app.type("3")
                expect(app.line(3)):eq("To: 023")
                -- A number is short.
                app.type(("9"):rep(30))
                expect(app.line(3)):eq("To: 023" .. ("9"):rep(17))

                app.key(keys.tab)
                app.event("paste", "One\nTwo")
                expect(app.lines(4, 5)):same { "Message:            7/1000", "One Two" }
                -- A message is no longer than the network takes, and the end of a long one stays in sight.
                app.event("paste", (" abcd"):rep(300))
                expect(app.line(4)):eq("Message:         1000/1000")
                expect(app.lines(17, 19)):same { "abcd abcd abcd abcd abcd", "ab", "" }
                expect({ term.getCursorPos() }):same { 3, 18 }
                app.type("x")
                expect(app.line(18)):eq("ab")
            end)
        end)

        it("is left with Backspace in an empty number, or with Cancel", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.down, keys.enter)
                app.type("1")
                app.key(keys.enter)
                -- From an empty text, Backspace goes back to the number.
                app.key(keys.backspace)
                app.key(keys.backspace)
                expect(app.line(3)):eq("To:")
                expect(app.line(2)):eq("New message")
                -- Holding it doesn't leave.
                app.event("key", keys.backspace, true)
                expect(app.line(2)):eq("New message")
                app.key(keys.backspace)
                expect(app.line(2)):eq("Phone             No. 0042")

                app.key(keys.enter)
                app.type("0007")
                app.event("mouse_click", 1, 10, 20)
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(phone.sent):same {}

                -- The mouse sends too.
                app.key(keys.enter)
                app.type("0007")
                app.event("mouse_click", 1, 3, 8)
                app.type("Hi")
                app.event("mouse_click", 1, 3, 20)
                expect(phone.sent):same { { "0007", "Hi" } }
            end)
        end)
    end)

    describe("networks", function()
        it("are listed, with the one in use", function()
            local phone = fake_phone()
            phone.networks = network_fixture()
            run(phone, {}, function(app)
                app.key(keys.down, keys.down, keys.enter)
                expect(app.lines(2, 8)):same {
                    "Networks",
                    "",
                    " *Automatic",
                    "> ACME  home          ||||",
                    "  BETA  partner       ||..",
                    "  GAMMA not allowed      -",
                    "",
                }
                expect(app.lines(19, 20)):same { "> in use  * chosen", "Backspace: back" }
            end)

            run(phone, { width = 51, height = 19 }, function(app)
                app.key(keys.down, keys.down, keys.enter)
                expect(app.line(5)):eq("> ACME  home" .. (" "):rep(35) .. "||||")
                expect(app.line(7)):eq("  GAMMA not allowed" .. (" "):rep(31) .. "-")
                expect(app.line(19)):eq("> in use  * chosen  Backspace: back")
            end)
        end)

        it("are kept up to date", function()
            local phone = fake_phone()
            phone.networks = network_fixture()
            run(phone, {}, function(app)
                app.key(keys.down, keys.down, keys.enter, keys.down, keys.down)
                expect(app.bg(6)):eq(("0"):rep(26))

                -- A new network comes into range, before the one which is chosen.
                phone.networks[2].signal = nil
                table.insert(phone.networks, 2, { name = "DELTA", kind = "partner", allowed = true, signal = -72, serving = false, selected = false })
                app.timers(2)
                expect(app.lines(5, 8)):same {
                    "> ACME  home          ||||",
                    "  DELTA partner       |||.",
                    "  BETA  partner          -",
                    "  GAMMA not allowed      -",
                }
                expect(app.bg(7)):eq(("0"):rep(26))

                -- And again, later.
                phone.networks[3].signal = -99
                app.timers(2)
                expect(app.line(7)):eq("  BETA  partner       |...")
            end)
        end)

        it("are chosen", function()
            local phone = fake_phone()
            phone.networks = network_fixture()
            run(phone, {}, function(app)
                app.key(keys.down, keys.down, keys.enter, keys.down, keys.down, keys.enter)
                expect(phone.chosen):same { "BETA" }
                expect(app.lines(4, 6)):same {
                    "  Automatic",
                    "> ACME  home          ||||",
                    " *BETA  partner       ||..",
                }
                expect(app.line(18)):eq("Using BETA only.")

                -- Automatic lets the phone choose again.
                app.event("mouse_click", 1, 4, 4)
                expect(phone.chosen):same { "BETA", "auto" }
                expect(app.lines(4, 6)):same {
                    " *Automatic",
                    "> ACME  home          ||||",
                    "  BETA  partner       ||..",
                }
                expect(app.lines(17, 18)):same { "The phone chooses the", "network." }
            end)
        end)

        it("cut a long name short", function()
            local phone = fake_phone()
            phone.networks = network_fixture()
            phone.networks[3].name = "GAMMA-TELECOM"
            run(phone, {}, function(app)
                app.key(keys.down, keys.down, keys.enter)
                expect(app.lines(5, 7)):same {
                    "> ACME    home        ||||",
                    "  BETA    partner     ||..",
                    "  GAMMA-T not allowed    -",
                }
            end)
        end)

        it("say why one can't be chosen", function()
            local phone = fake_phone()
            phone.networks = network_fixture()
            run(phone, {}, function(app)
                app.key(keys.down, keys.down, keys.enter, keys.up, keys.enter)
                expect(phone.chosen):same { "GAMMA" }
                expect(app.line(18)):eq("This SIM can't use GAMMA")
                expect(app.line(4)):eq(" *Automatic")
                expect(app.line(7)):eq("  GAMMA not allowed      -")
            end)
        end)
    end)

    describe("cell service", function()
        it("is turned off and on", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.down, keys.down, keys.down)
                expect(app.line(7)):eq(" Cell service: On")
                app.key(keys.enter)
                expect(phone.enabled):same { false }

                -- The bar goes, and the menu says how to get it back.
                expect(app.lines(1, 7)):same {
                    "Phone             No. 0042",
                    "",
                    " Messages",
                    " New message",
                    " Networks",
                    " Cell service: Off",
                    " Monitor",
                }
                expect(app.bg(6)):eq(("0"):rep(26))
                expect(app.lines(17, 20)):same {
                    "Cell service is off.",
                    "Choose Cell service to",
                    "turn it on.",
                    "Enter: choose  Q: quit",
                }

                app.key(keys.enter)
                expect(phone.enabled):same { false, true }
                expect(app.line(1)):eq(" ACME              [|||.]")
                expect(app.line(7)):eq(" Cell service: On")
                expect(app.bg(7)):eq(("0"):rep(26))
                expect(app.line(19)):eq("")
            end)
        end)

        it("says why it can't be turned on", function()
            local phone = fake_phone()
            phone.info.state, phone.info.enabled, phone.no_modem = "off", false, true
            run(phone, {}, function(app)
                app.event("mouse_click", 1, 2, 6)
                expect(phone.enabled):same { true }
                expect(app.line(6)):eq(" Cell service: Off")
                expect(app.lines(18, 19)):same { "This needs a wireless", "modem" }
                -- The next thing chosen clears it.
                app.key(keys.up, keys.enter, keys.backspace)
                expect(app.line(17)):eq("Cell service is off.")
            end)
        end)
    end)

    describe("monitor", function()
        it("is shown beneath the bar, until Q is pressed", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.up, keys.up)
                expect(app.bg(8)):eq(("0"):rep(26))
                app.key(keys.enter)
                app.event("cell_state", "attached")
                expect(app.line(1)):eq(" ACME              [|||.]")
                expect(app.line(2)):str_match("^ Cell monitor    %d%d:%d%d:%d%d$")
                expect(app.lines(3, 4)):same { "Attached", "Net  ACME" }
                expect(app.line(20)):eq("Press Q to quit")

                app.type("q")
                expect(app.finished()):eq(false)
                expect(app.line(2)):eq("Phone             No. 0042")
                expect(app.line(8)):eq(" Monitor")
                expect(app.bg(8)):eq(("0"):rep(26))
            end)
        end)

        it("stops the menus too when it's terminated", function()
            local phone = fake_phone()
            run(phone, {}, function(app)
                app.key(keys.up, keys.up, keys.enter)
                app.event("cell_state", "attached")
                expect(app.line(2)):str_match("^ Cell monitor")
                app.event("terminate")
                expect(app.finished()):eq(true)
            end)
        end)

        it("says why it can't listen", function()
            local phone = fake_phone({ state = "none", enabled = true, selection = "auto", roaming = false })
            stub(net.cell, "listen", function() return nil, "This needs a wireless modem" end)
            run(phone, {}, function(app)
                app.key(keys.enter)
                expect(app.lines(1, 4)):same { "Phone", "", " Monitor", " Quit" }
                expect(app.lines(18, 19)):same { "This needs a wireless", "modem" }
            end)
        end)
    end)

    describe("bar", function()
        local function program(text)
            local file = fs.open("/test-files/under_bar.lua", "w")
            file.write(text)
            file.close()
        end

        it("runs a program beneath the bar", function()
            program([[
                local w, h = term.getSize()
                print(("Size %dx%d"):format(w, h))
                local _, button, x, y = os.pullEvent("mouse_click")
                print(("Click %d at %d,%d"):format(button, x, y))
                os.pullEvent("term_resize")
                print(("Size %dx%d"):format(term.getSize()))
                os.pullEvent("key")
                print(table.concat({ ... }, " "))
            ]])
            local phone = fake_phone()
            run(phone, { args = { "bar", "/test-files/under_bar.lua", "one", "two" } }, function(app)
                expect(app.lines(1, 3)):same { " ACME              [|||.]", "Size 26x19", "" }

                -- It only gets what it waits for, and no clicks on the bar.
                app.event("key", keys.a, false)
                app.event("mouse_click", 1, 3, 1)
                expect(app.line(3)):eq("")
                app.event("mouse_click", 2, 3, 5)
                expect(app.line(3)):eq("Click 2 at 3,4")

                -- Without the bar, it has the whole screen.
                phone.info.state = "off"
                app.event("cell_state", "off")
                expect(app.lines(1, 4)):same { "Size 26x19", "Click 2 at 3,4", "Size 26x20", "" }
                phone.info.state = "attached"
                app.event("cell_state", "attached")
                expect(app.lines(1, 4)):same { " ACME              [|||.]", "Size 26x19", "Click 2 at 3,4", "Size 26x20" }
                -- The cursor is the program's, not the bar's.
                expect({ app.screen.getCursorPos() }):same { 1, 5 }

                -- When it ends, so does the bar, and what it wrote is still there.
                expect(app.finished()):eq(false)
                app.event("key", keys.a, false)
                expect(app.finished()):eq(true)
                expect(app.lines(1, 5)):same { "Size 26x19", "Click 2 at 3,4", "Size 26x20", "one two", "" }
                expect({ term.getCursorPos() }):same { 1, 5 }
                expect(term.current()):eq(app.screen)
            end)
        end)

        it("runs a shell if no program is given", function()
            run(fake_phone(), { args = { "bar" } }, function(app)
                expect(app.line(1)):eq(" ACME              [|||.]")
                expect(app.lines(2, 3)):same { os.version(), ">" }
                app.type("exit")
                app.key(keys.enter)
                expect(app.finished()):eq(true)
                expect(app.lines(1, 2)):same { os.version(), "> exit" }
            end)
        end)

        it("is completed, with the program to run", function()
            expect(shell.complete("cell g")):same { "ui" }
            expect(shell.complete("cell b")):same { "ar " }
            expect(shell.complete("cell bar cellc")):same { "ore " }
            expect(shell.complete("cell bar cell m")):same { "essages", "onitor" }
            expect(shell.complete("cell gui ")):eq(nil)
        end)

        it("has one bar, whatever runs beneath it", function()
            run(fake_phone(), { args = { "bar", "/rom/programs/net/cell.lua", "gui" } }, function(app)
                expect(app.lines(1, 4)):same { " ACME              [|||.]", "Phone             No. 0042", "", " Messages" }
                app.type("q")
                expect(app.finished()):eq(true)
            end)
        end)

        it("gives the screen back when the program fails", function()
            local bar = require "cc.internal.net.cell.bar"
            fake_phone()
            with_window(26, 20, function()
                local screen = term.current()
                term.setTextColour(colours.orange)
                term.setBackgroundColour(colours.green)

                expect.error(bar.run, function()
                    term.setTextColour(colours.red)
                    term.setCursorBlink(true)
                    print("Before")
                    error("Oh no", 0)
                end):eq("Oh no")

                expect(term.current()):eq(screen)
                expect({ term.getTextColour(), term.getBackgroundColour(), term.getCursorBlink() })
                    :same { colours.orange, colours.green, false }
                expect((screen.getLine(1):gsub(" +$", ""))):eq("Before")
            end)
        end)

        it("returns what the function does", function()
            local bar = require "cc.internal.net.cell.bar"
            fake_phone()
            with_window(26, 20, function()
                local function add(a, b)
                    local w, h = term.getSize()
                    return a + b, w, h
                end
                expect({ bar.run(add, 1, 2) }):same { 3, 26, 19 }
            end)
        end)

        it("leaves a program its own terminal", function()
            program([[
                local outer = term.current()
                local inner = window.create(outer, 1, 3, 12, 2)
                term.redirect(inner)
                write("Inner")
                os.pullEvent("key")
                write(" still")
                term.redirect(outer)
            ]])
            run(fake_phone(), { args = { "bar", "/test-files/under_bar.lua" } }, function(app)
                expect(app.lines(1, 5)):same { " ACME              [|||.]", "", "", "Inner", "" }
                app.event("cell_state", "attached")
                app.event("key", keys.a, false)
                expect(app.lines(1, 4)):same { "", "", "Inner still", "" }
            end)
        end)
    end)
end)
