-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The phone's status bar: the screen's top line, which says which network the phone is on, how strong its signal
is, and whether there are new messages. Any program can run beneath it.

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

--[[- Get how many of four bars a signal gets, as the monitor draws them.

@tparam number|nil signal The signal's strength, in dBm.
@treturn number From 0 to 4.
]]
local function signal_bars(signal)
    if type(signal) ~= "number" then return 0 end
    if signal >= -70 then return 4 elseif signal >= -80 then return 3 elseif signal >= -90 then return 2
    elseif signal >= -100 then return 1 else return 0 end
end

-- What the bar says in place of a network's name, when the phone isn't attached to one.
local BAR_STATES = {
    searching = "Searching...", attaching = "Connecting...", rejected = "Rejected", inactive = "Not activated",
    activating = "Activating...",
}

-- Whether there's something for the bar to show: cell service is on, and the phone has a SIM.
local function wanted(info)
    return info.state ~= "off" and info.state ~= "none" and info.network ~= nil
end

--[[- Make the status bar's line: the network's name on the left; four bars for the signal in brackets on the right
(`[||..]`), with an `R` before them when roaming (`R [||..]`); and how many messages are new, in the middle. On a
network the phone treats as its own (it isn't roaming there), the name is the SIM's own network's. On a narrow screen,
the name is cut short to leave room for the rest. The bar is dark grey.

@tparam table info The phone's state, as `net.cell.info` gives it.
@tparam number width The screen's width.
@tparam boolean colour Whether the screen shows colours.
@tparam[opt] boolean quiet Whether the phone has been searching for a while, and so has no service.
@treturn string The line's text.
@treturn string The colour of each character, as `term.blit` takes them.
@treturn string The background colour of each character.
]]
local function line(info, width, colour, quiet)
    expect(1, info, "table")
    expect(2, width, "number")
    expect(3, colour, "boolean")
    expect(4, quiet, "boolean", "nil")

    local attached = info.state == "attached"
    local name
    if attached then
        -- A network the phone treats as its own goes by its own network's name.
        name = info.roaming and info.serving_network or info.network or info.serving_network or "?"
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

    -- An R and a space when roaming, four bars in brackets, then a space. Only a very narrow screen has no room for
    -- them.
    local count = attached and signal_bars(info.signal) or 0
    local roaming = attached and info.roaming == true
    local right_width = roaming and 9 or 7
    local right = width - right_width + 1
    local room = width - 1
    if width >= right_width + 3 then
        room = width - right_width - 2
        if roaming then put(right, "R", "0") end
        put(width - 6, "[", "0")
        put(width - 5, ("|"):rep(count), "0")
        put(width - 5 + count, ("."):rep(4 - count), "8")
        put(width - 1, "]", "0")

        local unread = tonumber(info.unread) or 0
        if unread > 0 then
            local notice = unread == 1 and "1 new msg" or ("%d new msgs"):format(unread)
            -- The notice goes in the middle of the screen, or as near to it as the name and the bars let it.
            local left = room - #notice - 1
            if left >= math.min(#name, 3) then
                name = name:sub(1, left)
                local x = math.floor((width - #notice) / 2) + 1
                x = math.min(math.max(x, #name + 3), right - 1 - #notice)
                put(x, notice, colour and "4" or "0")
            end
        end
    end
    put(2, name:sub(1, room), "0")

    return text, fg, ("7"):rep(width)
end

local MOUSE_EVENTS = { mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true }

--[[- Run a function beneath the status bar. The bar has the screen's top line, and the function has the rest, as a
terminal of its own. While cell service is turned off, or the phone has no SIM, there's no bar, and the function has
the whole screen.

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
        parent.setCursorPos(1, 1)
        parent.blit(line(info, width, colour, os.clock() - searching_since >= SEARCH_PATIENCE))
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

return {
    signal_bars = signal_bars,
    line = line,
    touch = touch,
    run = run,
}
