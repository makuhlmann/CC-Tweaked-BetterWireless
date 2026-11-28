-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The phone's status bar: the screen's top line, which says which network the phone is on, how strong its signal
is, and whether there are new messages: or, when there are none, the time of day in the world. Any program can run
beneath it. Without a SIM, once it listens for cells
(`cell on`), it says so, with the strongest cell's signal.

Basic computers get greys where advanced ones get colours.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cell` program instead.

@local
]]

local expect = require "cc.expect".expect

-- How often the status bar looks at the phone again, in seconds. Changes of state redraw it at once.
local BAR_REFRESH = 2

-- How long the bar says the phone is searching before it says there's no service, in seconds.
local SEARCH_PATIENCE = 10

-- Whether the phone may have changed without an event to say so, and the bar should look at it again.
local stale = false

--- Say that the phone may have changed without an event to say so: a message was read, say. The bar looks at the phone
-- again as soon as the program beneath it waits for an event, rather than when it next would.
local function touch() stale = true end

-- The weakest signal a placed computer's modem hears, in dBm, for which the bars go from -100 (one) to -70 (four).
local PLACED_SENSITIVITY = -100

--[[- Get how many of four bars a signal gets, as the monitor draws them.

The bars are a step of 10 dB each, the last going as the modem stops hearing: for a placed computer's, four from -70 dBm
and one from -100 dBm. A pocket computer's or a turtle's modem hears less, so its bars are moved up to match.

@tparam number|nil signal The signal's strength, in dBm.
@tparam[opt] number sensitivity The weakest signal the modem hears, in dBm (see the modem's `getSensitivity`), if known.
@treturn number From 0 to 4.
]]
local function signal_bars(signal, sensitivity)
    if type(signal) ~= "number" then return 0 end
    if type(sensitivity) == "number" then signal = signal - (sensitivity - PLACED_SENSITIVITY) end
    if signal >= -70 then return 4 elseif signal >= -80 then return 3 elseif signal >= -90 then return 2
    elseif signal >= -100 then return 1 else return 0 end
end

-- Whether something happened since the bar last looked at the phone, given how long ago it was (in seconds).
local function lately(age)
    return type(age) == "number" and age < BAR_REFRESH
end

-- What the bar says in place of a network's name, when the phone isn't attached to one.
local BAR_STATES = {
    searching = "Searching...", attaching = "Connecting...", rejected = "Rejected", inactive = "No SIM",
    activating = "Activating...",
}

-- Whether there's something for the bar to show: cell service is on, and the phone has a SIM (or, without one, was told
-- to listen for cells); and whether it should be shown, as it is unless it was turned off ("cell bar off").
local function wanted(info)
    return info.state ~= "off" and info.state ~= "none" and (info.network ~= nil or info.enabled == true)
        and settings.get("cell.bar") ~= false
end

--[[- Make the status bar's line: the network's name on the left; four bars for the signal in brackets on the right
(`[||..]`), with indicators before them: `SMS` on a cell which only carries messages, and `R` when roaming, each with a
space after it (`SMS R [||..]`); then, where the phone has an address on a cell which carries packets, a down and an up
arrow and a space, each white when the phone has received (or sent) a packet since the bar last looked, and grey
otherwise (characters 25 and 24 of the font); and how many messages are new, in the middle, or the time when none are. On a
network the phone treats as its own (it isn't roaming there), the name is the SIM's own network's. Without a SIM, it
says `No SIM`, and the bars are the strongest cell's, of any network (`strongest`). On a narrow screen, the name is cut
short to leave room for the rest. The bar is dark grey.

@tparam table info The phone's state, as `net.cell.info` gives it.
@tparam number width The screen's width.
@tparam boolean colour Whether the screen shows colours.
@tparam[opt] boolean quiet Whether the phone has been searching for a while, and so has no service.
@tparam[opt] string clock The time, as it's shown when there are no new messages (and there's room).
@treturn string The line's text.
@treturn string The colour of each character, as `term.blit` takes them.
@treturn string The background colour of each character.
]]
local function line(info, width, colour, quiet, clock)
    expect(1, info, "table")
    expect(2, width, "number")
    expect(3, colour, "boolean")
    expect(4, quiet, "boolean", "nil")
    expect(5, clock, "string", "nil")

    local attached = info.state == "attached"
    local name
    if attached then
        -- A network the phone treats as its own goes by its own network's name.
        name = info.roaming and info.serving_network or info.network or info.serving_network or "?"
    elseif info.state == "searching" and info.newer then
        -- The cells around speak a newer version than this phone, which may be why it finds none.
        name = "Phone too old"
    elseif info.state == "searching" and quiet then
        name = "No service"
    else
        name = BAR_STATES[info.state] or info.state
    end
    name = tostring(name)

    local text, fg = (" "):rep(width), ("0"):rep(width)
    local function put(x, part, part_colour)
        if #part == 0 or x < 1 or x + #part - 1 > width then return end
        text = text:sub(1, x - 1) .. part .. text:sub(x + #part)
        fg = fg:sub(1, x - 1) .. part_colour:rep(#part) .. fg:sub(x + #part)
    end

    -- The indicators and a space: SMS on a cell which only carries messages (a satellite's, say), then R when roaming.
    -- Then four bars in brackets, and a space. Only a very narrow screen has no room for them. Without a SIM, the bars
    -- are the strongest cell's.
    -- A cell which has gone quiet for now gets no bars: the network's name stays, as the phone isn't searching yet.
    local signal = attached and not info.fading and info.signal or nil
    if not info.network and type(info.strongest) == "table" then signal = info.strongest.signal end
    local count = signal_bars(signal, info.sensitivity)
    local marks = {}
    if attached and info.messages_only == true then marks[#marks + 1] = "SMS" end
    if attached and info.roaming == true then marks[#marks + 1] = "R" end
    local mark = table.concat(marks, " ")

    -- New messages, or the time when there are none, in grey: it's there to glance at.
    local unread = tonumber(info.unread) or 0
    local notice, notice_colour = clock, "8"
    if unread > 0 then
        notice, notice_colour = unread == 1 and "1 new msg" or ("%d new msgs"):format(unread), colour and "4" or "0"
    end

    -- How wide everything right of the name and the notice is: the indicators and a space, the arrows (if any) and a
    -- space, and the bars and a space.
    local function right_width_of(with_arrows)
        return 7 + (with_arrows and 3 or 0) + (#mark > 0 and #mark + 1 or 0)
    end
    -- Whether the notice fits, with that (see below).
    local function notice_fits(with_arrows)
        return width - right_width_of(with_arrows) - 3 - #notice >= math.min(#name, 3)
    end
    -- Arrows for packets, down then up, as most phones have, where the phone has an address on a cell which carries
    -- packets. Each lights up when the phone has received (or sent) one since the bar last looked. On a narrow screen,
    -- they make way for new messages.
    local arrows = attached and info.address ~= nil and info.messages_only ~= true
    if arrows and unread > 0 and not notice_fits(true) and notice_fits(false) then arrows = false end

    local right_width = right_width_of(arrows)
    local right = width - right_width + 1
    local room = width - 1
    if width >= right_width + 3 then
        room = width - right_width - 2
        put(right, mark, "0")
        if arrows then
            put(width - 9, "\25", lately(info.received_age) and "0" or "8")
            put(width - 8, "\24", lately(info.sent_age) and "0" or "8")
        end
        put(width - 6, "[", "0")
        put(width - 5, ("|"):rep(count), "0")
        put(width - 5 + count, ("."):rep(4 - count), "8")
        put(width - 1, "]", "0")

        if notice then
            -- The notice goes in the middle of the screen, or as near to it as the name and the bars let it. The
            -- name makes way for new messages, but not for the time.
            local left = room - #notice - 1
            if left >= math.min(#name, 3) and (unread > 0 or left >= #name) then
                name = name:sub(1, left)
                local x = math.floor((width - #notice) / 2) + 1
                x = math.min(math.max(x, #name + 3), right - 1 - #notice)
                put(x, notice, notice_colour)
            end
        end
    end
    put(2, name:sub(1, room), "0")

    return text, fg, ("7"):rep(width)
end

local MOUSE_EVENTS = { mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true }

--[[- Run a function beneath the status bar. The bar has the screen's top line, and the function has the rest, as a
terminal of its own. While cell service is turned off, or the phone has no SIM and doesn't listen for cells, there's no
bar, and the function has the whole screen.

When the function ends, it gets the top line back, and what it left on the screen stays. A program which is already
running beneath a bar doesn't get a second one.

@tparam function fn The function to run.
@param ... Arguments for the function.
@return What the function returned.
@throws If the function did.
]]
local function run(fn, ...)
    expect(1, fn, "function")

    local parent = term.current()
    if parent.cell_bar then return fn(...) end

    local arguments = table.pack(...)
    local colour = parent.isColour()
    local old_fg, old_bg, old_blink = parent.getTextColour(), parent.getBackgroundColour(), parent.getCursorBlink()

    local info = net.cell.info()
    local searching_since = os.clock()
    local width, height = parent.getSize()
    local shown = wanted(info) and height > 1
    local child = window.create(parent, 1, shown and 2 or 1, width, shown and height - 1 or height, true)
    child.cell_bar = true

    local function draw_bar()
        if not shown then return end
        -- The time of day in the world, as a clock shows it.
        local time = os.time()
        local clock = type(time) == "number" and textutils.formatTime(time, true) or nil
        parent.setCursorPos(1, 1)
        parent.blit(line(info, width, colour, os.clock() - searching_since >= SEARCH_PATIENCE, clock))
        child.restoreCursor()
    end

    -- Give the bar its line or take it away, as the phone and the screen's size have it.
    local function layout()
        width, height = parent.getSize()
        shown = wanted(info) and height > 1
        child.reposition(1, shown and 2 or 1, width, shown and height - 1 or height)
        draw_bar()
    end

    -- Look at the phone again. This returns whether the bar came or went, and so the function's terminal changed size.
    local function refresh()
        info = net.cell.info()
        if info.state ~= "searching" then searching_since = os.clock() end
        if (wanted(info) and height > 1) ~= shown then
            layout()
            return true
        end
        draw_bar()
        return false
    end

    local co = coroutine.create(fn)
    local child_term, filter, result = child, nil, nil

    -- Let the function run until it next waits for an event, on its own terminal.
    local function step(...)
        term.redirect(child_term)
        result = table.pack(coroutine.resume(co, ...))
        child_term = term.redirect(parent)
        if not result[1] then error(result[2], 0) end
        filter = result[2]
    end

    -- Give the function an event, if it's waiting for it.
    local function send(event, ...)
        if coroutine.status(co) == "dead" then return end
        if filter == nil or filter == event or event == "terminate" then step(event, ...) end
    end

    -- Look at the phone again, and tell the function if its terminal changed size.
    local function update()
        stale = false
        if refresh() then send("term_resize") end
    end

    local ok, err = pcall(function()
        draw_bar()
        stale = false
        step(table.unpack(arguments, 1, arguments.n))
        if stale then update() end

        local timer = os.startTimer(BAR_REFRESH)
        while coroutine.status(co) ~= "dead" do
            local event = table.pack(os.pullEventRaw())
            local name, pass, look = event[1], true, false
            if name == "timer" and event[2] == timer then
                timer, pass, look = os.startTimer(BAR_REFRESH), false, true
            elseif name == "cell_state" or name == "cell_message" or name == "cell_sent" or name == "cell_messages" then
                look = true
            elseif name == "term_resize" then
                layout()
            elseif shown and MOUSE_EVENTS[name] and type(event[4]) == "number" then
                -- The function's terminal starts a line down. Clicks on the bar aren't for it.
                event[4] = event[4] - 1
                pass = event[4] >= 1
            end

            if look then update() end
            if pass then send(table.unpack(event, 1, event.n)) end
            if stale then update() end
        end
        os.cancelTimer(timer)
    end)

    -- Give the whole screen back, with what the function left on it.
    term.redirect(parent)
    width, height = parent.getSize()
    child.reposition(1, 1, width, height)
    child.cell_bar = nil
    parent.setTextColour(old_fg)
    parent.setBackgroundColour(old_bg)
    parent.setCursorBlink(old_blink)

    if not ok then error(err, 0) end
    return table.unpack(result, 2, result.n)
end

--[[- Whether the computer should start beneath the status bar: it has a SIM (or, without one, listens for cells), the
bar hasn't been turned off, and nothing has given it one already.

@treturn boolean Whether it should.
]]
local function at_startup()
    if settings.get("cell.bar") == false or term.current().cell_bar or not (net and net.cell) then return false end
    local ok, info = pcall(net.cell.info)
    return ok and type(info) == "table" and (info.network ~= nil or info.enabled == true)
end

return {
    signal_bars = signal_bars,
    line = line,
    touch = touch,
    run = run,
    at_startup = at_startup,
}
