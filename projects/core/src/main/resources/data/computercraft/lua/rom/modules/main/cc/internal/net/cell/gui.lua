-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The phone's menus, which run beneath its status bar: to read, send and answer messages, to choose a network, to
turn cell service off and on, and to open the monitor.

Everything here is drawn for a pocket computer's screen, and works on wider ones. Basic computers get greys where
advanced ones get colours, and everything can be done with the keyboard alone.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cell` program instead.

@local
]]

local expect = require "cc.expect".expect
local bar = require "cc.internal.net.cell.bar"

-- How often the list of networks is read again while it's shown, in seconds.
local NETWORKS_REFRESH = 2

-- How long to wait for the network to take a message, in seconds.
local SENT_TIMEOUT = 20

-- The longest message and the longest number which can be typed, in characters.
local MAX_TEXT = 1000
local MAX_NUMBER = 20

local function fit(text, width)
    text = tostring(text)
    if width <= 0 then return "" end
    if #text > width then return text:sub(1, width) end
    return text .. (" "):rep(width - #text)
end

-- Break text into lines no wider than a width, at spaces where it can. Each line is given as where it starts and ends
-- in the text, so a cursor can be put in it. The space or line break a line was broken at is in no line.
local function wrap(text, width)
    width = math.max(1, width)
    local lines, from, len = {}, 1, #text
    while from <= len do
        local to, after
        local newline = text:find("\n", from, true)
        if newline and newline - from <= width then
            to, after = newline - 1, newline + 1
        elseif len - from < width then
            to, after = len, len + 1
        else
            to, after = from + width - 1, from + width
            for i = from + width, from + 1, -1 do
                if text:byte(i) == 32 then
                    to, after = i - 1, i + 1
                    break
                end
            end
        end
        lines[#lines + 1] = { from, to }
        from = after
    end
    -- An empty text has one empty line, and so does the end of a text which was broken there.
    if #lines == 0 or lines[#lines][2] < len then lines[#lines + 1] = { len + 1, len } end
    return lines
end

local function wrapped(text, width)
    local lines = {}
    for i, line in ipairs(wrap(text, width)) do lines[i] = text:sub(line[1], line[2]) end
    return lines
end

-- Put short pieces of text next to each other, on as many lines as that takes.
local function flow(parts, width)
    local lines, current = {}, nil
    for _, part in ipairs(parts) do
        if not current then
            current = part
        elseif #current + 2 + #part <= width then
            current = current .. "  " .. part
        else
            lines[#lines + 1], current = current, part
        end
    end
    lines[#lines + 1] = current
    return lines
end

local function short_time(time)
    if type(time) ~= "number" then return "" end
    local seconds = math.floor(time / 1000)
    if os.date("%Y%m%d", seconds) == os.date("%Y%m%d") then return os.date("%H:%M", seconds) end
    return os.date("%d %b", seconds)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- Basic computers show greys, but no other colours.
local function c(wanted, grey)
    if term.isColour() then return wanted end
    return grey or colours.white
end

-- Write some text, leaving out what doesn't fit on the screen.
local function put(x, y, text, fg, bg)
    local w, h = term.getSize()
    if x < 1 or x > w or y < 1 or y > h then return end
    if x + #text - 1 > w then text = text:sub(1, w - x + 1) end
    term.setCursorPos(x, y)
    term.setTextColour(fg or colours.white)
    term.setBackgroundColour(bg or colours.black)
    term.write(text)
end

local function clear()
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    term.setCursorBlink(false)
end

-- A screen's first line: what it is, and something short about it on the right.
local function draw_title(left, right)
    local w = term.getSize()
    put(1, 1, fit(left, w), c(colours.yellow))
    if right and #left + 1 + #right <= w then put(w - #right + 1, 1, right, colours.lightGrey) end
end

-- Draw a row of buttons, and get the columns each one covers.
local function draw_buttons(y, labels, selected)
    local x, places = 1, {}
    for i, label in ipairs(labels) do
        local text = " " .. label .. " "
        if i == selected then
            put(x, y, text, colours.black, colours.white)
        else
            put(x, y, text, colours.white, colours.grey)
        end
        places[i] = { x, x + #text - 1 }
        x = x + #text + 1
    end
    return places
end

local function button_at(places, x)
    for i, place in ipairs(places) do
        if x >= place[1] and x <= place[2] then return i end
    end
    return nil
end

local function is_enter(key) return key == keys.enter or key == keys.numPadEnter end

--[[ Show a list to choose from, until something is chosen which ends it, or the user goes back.

The screen has a title, the list, a note and some hints. Up and Down (or the mouse wheel) move along the list, Enter
or a click chooses, and Backspace or Left goes back. Keys which are held down don't choose or go back, so holding one
a moment too long doesn't go through several screens.

`options` has:
 - `title`: a function which returns the title, and what to put to its right;
 - `items`: a function which returns the list. Each item has `text`; maybe `fg`, its colour; `tail`, pieces of text for
   the right of its line, each a text and a colour; and `id`, which the choice is kept by when the list changes;
 - `choose`: what to call with a chosen item. The list ends when it returns something;
 - `note`: a function which returns a note to show beneath the list, and its colour;
 - `empty`: what to say when the list is empty;
 - `hint`: short reminders for the bottom of the screen;
 - `keys`: what to call for other characters, by character;
 - `refresh`: how often to get the list again, in seconds;
 - `back`: false if there's nowhere to go back to.
]]
local function list_screen(options)
    local items, selected, scroll, first, visible = {}, 1, 0, 2, 0

    local function load()
        local id = items[selected] and items[selected].id
        items = options.items()
        if id ~= nil then
            for i, item in ipairs(items) do
                if item.id == id then
                    selected = i
                    break
                end
            end
        end
        selected = math.max(1, math.min(selected, #items))
    end

    local function draw()
        local w, h = term.getSize()
        clear()

        -- The title, a gap if there's room for one, the list, and at the bottom the note and the hints. On a
        -- screen with too few lines, the hints go first, then the note.
        first = h >= 10 and 3 or 2
        local room = h - first + 1
        local notes, note_fg = {}, nil
        if options.note then
            local text, fg = options.note()
            if text then notes, note_fg = wrapped(text, w), fg end
        end
        local hints = flow(options.hint or {}, w)
        local note_count = math.max(0, math.min(#notes, room - 1))
        local hint_count = math.max(0, math.min(#hints, room - note_count - 3))
        visible = math.max(1, room - note_count - hint_count)

        if selected <= scroll then scroll = selected - 1 end
        if selected > scroll + visible then scroll = selected - visible end
        scroll = math.max(0, math.min(scroll, #items - visible))

        local left, right = options.title()
        if not right and #items > visible then right = ("%d/%d"):format(selected, #items) end
        draw_title(left, right)

        if #items == 0 and options.empty then put(1, first, fit(options.empty, w), colours.lightGrey) end
        for row = 1, visible do
            local item = items[scroll + row]
            if not item then break end
            local y = first + row - 1
            local chosen = scroll + row == selected
            local fg, bg = item.fg or colours.white, colours.black
            if chosen then fg, bg = colours.black, colours.white end
            put(1, y, fit(item.text, w), fg, bg)

            local tail_width = 0
            for _, part in ipairs(item.tail or {}) do tail_width = tail_width + #part[1] end
            if tail_width > 0 and tail_width < w then
                local x = w - tail_width
                put(x, y, " ", fg, bg)
                for _, part in ipairs(item.tail) do
                    put(x + 1, y, part[1], chosen and fg or part[2], bg)
                    x = x + #part[1]
                end
            end
        end

        for i = 1, note_count do
            put(1, h - hint_count - note_count + i, notes[i], note_fg or colours.lightGrey)
        end
        for i = 1, hint_count do
            put(1, h - hint_count + i, hints[i], colours.grey)
        end
    end

    load()
    local timer = options.refresh and os.startTimer(options.refresh)

    -- Do what was chosen, which may show other screens for a while, and then catch up.
    local function act(handler, ...)
        local result = handler(...)
        if timer then
            os.cancelTimer(timer)
            timer = os.startTimer(options.refresh)
        end
        load()
        return result
    end

    local dirty = true
    while true do
        if dirty then draw() end
        dirty = true

        local result
        local event, a, b, y = os.pullEvent()
        if event == "key" then
            if a == keys.up and #items > 0 then
                selected = (selected - 2) % #items + 1
            elseif a == keys.down and #items > 0 then
                selected = selected % #items + 1
            elseif a == keys.home then
                selected = 1
            elseif a == keys["end"] then
                selected = math.max(1, #items)
            elseif is_enter(a) and not b and items[selected] then
                result = act(options.choose, items[selected])
            elseif (a == keys.backspace or a == keys.left) and not b and options.back ~= false then
                return nil
            else
                dirty = false
            end
        elseif event == "char" then
            local handler = options.keys and options.keys[a:lower()]
            if handler then result = act(handler) else dirty = false end
        elseif event == "mouse_click" then
            local index = scroll + y - first + 1
            if a == 1 and y >= first and y < first + visible and items[index] then
                selected = index
                result = act(options.choose, items[index])
            else
                dirty = false
            end
        elseif event == "mouse_scroll" then
            selected = math.max(1, math.min(#items, selected + a))
        elseif event == "timer" and a == timer then
            timer = os.startTimer(options.refresh)
            load()
        elseif event == "cell_state" or event == "cell_message" or event == "cell_sent" or event == "cell_messages"
            or event == "term_resize" then
            load()
        else
            dirty = false
        end
        if result ~= nil then return result end
    end
end

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

-- Say how a message which was just sent is getting on, until the network has answered or it has taken too long, and
-- then until a key is pressed. This returns true if the network took the message, false and why if it didn't, and
-- nothing if it hasn't answered.
local function sending_screen(number, id)
    local sent, reason
    local outcome, outcome_fg = "Sending...", colours.white
    local done = false

    local function draw()
        local w, h = term.getSize()
        clear()
        draw_title("To " .. number)
        for i, line in ipairs(wrapped(outcome, w)) do put(1, i + 2, line, outcome_fg) end
        if done then put(1, h, "Press any key", colours.grey) end
    end

    local timer = os.startTimer(SENT_TIMEOUT)
    draw()
    while true do
        local event, a, b, why = os.pullEvent()
        if done then
            if (event == "key" and not b) or event == "mouse_click" then break end
        elseif event == "cell_sent" and a == id then
            done, sent = true, b == true
            if sent then
                outcome, outcome_fg = "Sent.", c(colours.lime)
            else
                reason = why and tostring(why) or nil
                outcome, outcome_fg = reason and "Not sent: " .. reason or "Not sent.", c(colours.red)
            end
        elseif event == "timer" and a == timer then
            done = true
            outcome = "Still sending. The network hasn't answered yet."
        end
        draw()
    end
    os.cancelTimer(timer)
    return sent, reason
end

-- Write a message and send it. Up, Down and Tab move between the number, the text and the buttons. Enter goes from
-- the number to the text, and sends from there. Backspace in an empty number gives up.
local function compose_screen(number)
    local fields = {
        { value = number or "", pos = #(number or ""), max = MAX_NUMBER },
        { value = "", pos = 0, max = MAX_TEXT },
    }
    -- What is being typed in or would be pressed: the number, the text, Send or Cancel.
    local NUMBER, TEXT, SEND, CANCEL = 1, 2, 3, 4
    local focus = number and TEXT or NUMBER
    local problem
    local text_top, text_bottom, text_scroll, places = 4, 4, 0, {}

    local function draw()
        local w, h = term.getSize()
        clear()
        draw_title(number and "Reply" or "New message")

        local problems = problem and wrapped(problem, w) or {}
        local problem_count = math.max(0, math.min(#problems, h - 6))
        text_bottom = math.max(text_top, h - 2 - problem_count)

        -- The number, on one line. It moves along if the cursor would be off the screen.
        local to = fields[NUMBER]
        local along = math.max(0, to.pos - (w - 5))
        put(1, 2, "To:", focus == NUMBER and colours.white or colours.lightGrey)
        put(5, 2, to.value:sub(along + 1))

        -- The text, on as many lines as there are. A line is one narrower than the screen, to leave room for the
        -- cursor after its last character.
        local text = fields[TEXT]
        local count = ("%d/%d"):format(#text.value, text.max)
        put(1, 3, "Message:", focus == TEXT and colours.white or colours.lightGrey)
        put(w - #count + 1, 3, count, colours.lightGrey)
        local lines = wrap(text.value, w - 1)
        local cursor_line = 1
        for i, line in ipairs(lines) do
            if line[1] <= text.pos + 1 then cursor_line = i end
        end
        local rows = text_bottom - text_top + 1
        if cursor_line <= text_scroll then text_scroll = cursor_line - 1 end
        if cursor_line > text_scroll + rows then text_scroll = cursor_line - rows end
        text_scroll = math.max(0, math.min(text_scroll, #lines - rows))
        for row = 1, rows do
            local line = lines[text_scroll + row]
            if line then put(1, text_top + row - 1, text.value:sub(line[1], line[2])) end
        end

        for i = 1, problem_count do put(1, text_bottom + i, problems[i], c(colours.red)) end
        places = draw_buttons(h, { "Send", "Cancel" }, focus - SEND + 1)

        if focus == NUMBER then
            term.setCursorPos(5 + to.pos - along, 2)
        elseif focus == TEXT then
            term.setCursorPos(text.pos + 2 - lines[cursor_line][1], text_top + cursor_line - 1 - text_scroll)
        end
        term.setTextColour(colours.white)
        term.setCursorBlink(focus <= TEXT)
    end

    local function insert(typed)
        local field = fields[focus]
        if not field then return end
        typed = typed:gsub("[\r\n]+", " "):sub(1, math.max(0, field.max - #field.value))
        field.value = field.value:sub(1, field.pos) .. typed .. field.value:sub(field.pos + 1)
        field.pos = field.pos + #typed
    end

    -- Send the message. This returns whether there's nothing more to do here.
    local function submit()
        local to, text = fields[NUMBER].value:gsub("^%s+", ""):gsub("%s+$", ""), fields[TEXT].value
        if to == "" then
            problem, focus = "Enter a number first.", NUMBER
            return false
        elseif not text:find("%S") then
            problem, focus = "Write a message first.", TEXT
            return false
        end

        local ok, id = net.cell.send(to, text)
        bar.touch()
        if not ok then
            problem = tostring(id or "The message couldn't be sent")
            return false
        end
        local sent, reason = sending_screen(to, id)
        if sent == false then
            problem = reason and "Not sent: " .. reason or "Not sent."
            return false
        end
        return true
    end

    while true do
        draw()
        local event, a, b, y = os.pullEvent()
        local field = fields[focus]
        if event == "char" or event == "paste" then
            insert(a)
        elseif event == "key" then
            if is_enter(a) and not b then
                if focus == NUMBER then
                    focus = TEXT
                elseif focus == CANCEL or submit() then
                    break
                end
            elseif a == keys.tab then
                focus = focus % CANCEL + 1
            elseif a == keys.up then
                focus = focus >= SEND and TEXT or NUMBER
            elseif a == keys.down then
                if focus < SEND then focus = focus + 1 end
            elseif a == keys.left then
                if field then field.pos = math.max(0, field.pos - 1) else focus = SEND end
            elseif a == keys.right then
                if field then field.pos = math.min(#field.value, field.pos + 1) else focus = CANCEL end
            elseif a == keys.home and field then
                field.pos = 0
            elseif a == keys["end"] and field then
                field.pos = #field.value
            elseif a == keys.delete and field then
                field.value = field.value:sub(1, field.pos) .. field.value:sub(field.pos + 2)
            elseif a == keys.backspace then
                if field and field.pos > 0 then
                    field.value = field.value:sub(1, field.pos - 1) .. field.value:sub(field.pos + 1)
                    field.pos = field.pos - 1
                elseif not b and focus == NUMBER and field.value == "" then
                    break
                elseif not b and focus ~= NUMBER and (not field or field.value == "") then
                    focus = focus == TEXT and NUMBER or TEXT
                end
            end
        elseif event == "mouse_click" and a == 1 then
            local _, h = term.getSize()
            if y == h then
                local button = button_at(places, b)
                if button == 2 or (button == 1 and submit()) then break end
            elseif y == 2 then
                focus = NUMBER
            elseif y >= 3 and y <= text_bottom then
                focus = TEXT
            end
        end
    end
    term.setCursorBlink(false)
end

-- Show one message, all of it. Left and Right choose between the buttons, and Up and Down move a long message.
-- Opening a message marks it as read.
local function message_screen(n)
    local function find()
        for _, message in ipairs(net.cell.messages()) do
            if message.n == n then return message end
        end
        return nil
    end

    local message = find()
    if not message then return end
    if message.from and message.read == false then
        net.cell.markRead(n)
        bar.touch()
    end

    local selected, scroll, max_scroll, rows, confirming = 1, 0, 0, 1, false
    local labels, places = {}, {}

    local function draw()
        local w, h = term.getSize()
        clear()
        draw_title((message.from and "From " or "To ") .. tostring(message.from or message.to))
        local y = 2
        if type(message.time) == "number" then
            put(1, y, os.date("%Y-%m-%d %H:%M", math.floor(message.time / 1000)), colours.lightGrey)
            y = y + 1
        end
        if message.to then
            local status, fg = "Sent", c(colours.lime)
            if message.status == "sending" then
                status, fg = "Sending...", c(colours.yellow)
            elseif message.status ~= "sent" then
                status, fg = "Not sent" .. (message.error and ": " .. tostring(message.error) or ""), c(colours.red)
            end
            for _, line in ipairs(wrapped(status, w)) do
                put(1, y, line, fg)
                y = y + 1
            end
        end

        -- The text has the lines from here to the one above the buttons, but for a gap on either side.
        local top = y + 1
        local lines = wrapped(tostring(message.text):gsub("%s+$", ""), w)
        rows = math.max(1, h - 2 - top + 1)
        max_scroll = math.max(0, #lines - rows)
        scroll = math.max(0, math.min(scroll, max_scroll))
        for row = 1, rows do
            if lines[scroll + row] then put(1, top + row - 1, lines[scroll + row]) end
        end

        if confirming then
            put(1, h - 1, "Delete this message?")
            labels = { "Delete", "Keep" }
        else
            if max_scroll > 0 then
                put(1, h - 1, ("Up/Down: more (%d/%d)"):format(scroll + 1, max_scroll + 1), colours.grey)
            end
            labels = message.from and { "Reply", "Delete", "Back" } or { "Delete", "Back" }
        end
        selected = math.max(1, math.min(selected, #labels))
        places = draw_buttons(h, labels, selected)
    end

    -- Press a button. This returns whether the screen is done with.
    local function press(label)
        if label == "Reply" then
            compose_screen(tostring(message.from))
            message = find()
            return message == nil
        elseif label == "Delete" and confirming then
            net.cell.deleteMessage(n)
            bar.touch()
            return true
        elseif label == "Delete" then
            confirming, selected = true, 1
        elseif label == "Keep" then
            confirming, selected = false, message.from and 2 or 1
        elseif label == "Back" then
            return true
        end
        return false
    end

    while true do
        draw()
        local event, a, b, y = os.pullEvent()
        local label
        if event == "key" then
            if a == keys.left then
                selected = math.max(1, selected - 1)
            elseif a == keys.right or a == keys.tab then
                selected = math.min(#labels, selected + 1)
            elseif a == keys.up then
                scroll = scroll - 1
            elseif a == keys.down then
                scroll = scroll + 1
            elseif a == keys.pageUp then
                scroll = scroll - rows
            elseif a == keys.pageDown then
                scroll = scroll + rows
            elseif is_enter(a) and not b then
                label = labels[selected]
            elseif a == keys.backspace and not b then
                label = confirming and "Keep" or "Back"
            end
        elseif event == "char" and not confirming then
            if a:lower() == "r" and message.from then label = "Reply" end
            if a:lower() == "d" then label = "Delete" end
        elseif event == "mouse_click" and a == 1 then
            local _, h = term.getSize()
            if y == h then label = labels[button_at(places, b)] end
        elseif event == "mouse_scroll" then
            scroll = scroll + a
        elseif event == "cell_sent" or event == "cell_state" then
            -- A message which was being sent may have got there.
            message = find()
            if not message then return end
        end
        if label and press(label) then return end
    end
end

-- List the messages, newest first, and open the one which is chosen.
local function messages_screen()
    local unread = 0
    return list_screen {
        hint = { "* new", "> sent", "! failed", "Backspace: back" },
        empty = "No messages.",
        title = function() return "Messages", unread > 0 and unread .. " new" or nil end,
        items = function()
            local messages = net.cell.messages()
            local w = term.getSize()
            -- The columns are as wide as what's in them, but a long number doesn't take the text's room.
            local who_width, time_width, times = 1, 1, {}
            for i, message in ipairs(messages) do
                times[i] = short_time(message.time)
                who_width = math.max(who_width, #tostring(message.from or message.to))
                time_width = math.max(time_width, #times[i])
            end
            who_width = math.min(who_width, w >= 40 and 16 or 8)

            unread = 0
            local items = {}
            for i = #messages, 1, -1 do
                local message = messages[i]
                local mark, fg = " ", colours.lightGrey
                if message.from then
                    if message.read == false then mark, fg, unread = "*", colours.white, unread + 1 end
                elseif message.status == "failed" then
                    mark = "!"
                else
                    mark = ">"
                end
                items[#items + 1] = {
                    id = message.n, fg = fg,
                    text = ("%s%s %s %s"):format(mark, fit(message.from or message.to, who_width),
                        fit(times[i], time_width), (tostring(message.text):gsub("%s+", " "))),
                }
            end
            return items
        end,
        choose = function(item) message_screen(item.id) end,
    }
end

--------------------------------------------------------------------------------
-- Networks
--------------------------------------------------------------------------------

-- List the networks, to choose the one to use, or to leave the choice to the phone.
local function networks_screen()
    local result, result_fg
    return list_screen {
        refresh = NETWORKS_REFRESH,
        hint = { "> in use", "* chosen", "Backspace: back" },
        title = function() return "Networks" end,
        note = function() return result, result_fg end,
        items = function()
            local info, networks = net.cell.info(), net.cell.networks()
            local w = term.getSize()

            local kinds, kind_width, name_width = {}, 0, 4
            for i, network in ipairs(networks) do
                name_width = math.max(name_width, #tostring(network.name))
                if not network.allowed then
                    kinds[i] = "not allowed"
                elseif network.kind == "home" or network.kind == "partner" then
                    kinds[i] = network.kind
                else
                    kinds[i] = "allowed"
                end
                kind_width = math.max(kind_width, #kinds[i])
            end
            -- Two marks, the name, the kind and four bars, with a space between each. A long name is cut short.
            name_width = math.max(4, math.min(name_width, w - kind_width - 8))

            local items = { { id = 0, text = (info.selection == "auto" and " *" or "  ") .. "Automatic" } }
            for i, network in ipairs(networks) do
                local tail
                if network.signal then
                    local count = bar.signal_bars(network.signal)
                    tail = { { ("|"):rep(count), c(colours.lime) }, { ("."):rep(4 - count), colours.grey } }
                else
                    tail = { { "   -", colours.lightGrey } }
                end
                items[#items + 1] = {
                    id = network.name, name = network.name, tail = tail,
                    fg = network.allowed and colours.white or colours.lightGrey,
                    text = ("%s%s%s %s"):format(network.serving and ">" or " ", network.selected and "*" or " ",
                        fit(network.name, name_width), kinds[i]),
                }
            end
            return items
        end,
        choose = function(item)
            local ok, err = net.cell.setNetwork(item.name or "auto")
            bar.touch()
            if ok then
                result_fg = nil
                result = item.name and ("Using %s only."):format(item.name) or "The phone chooses the network."
            else
                result, result_fg = tostring(err or "That network can't be chosen"), c(colours.red)
            end
        end,
    }
end

--------------------------------------------------------------------------------
-- The home menu
--------------------------------------------------------------------------------

local function home_screen(monitor)
    local info, problem
    return list_screen {
        back = false,
        hint = { "Enter: choose", "Q: quit" },
        keys = { q = function() return "quit" end },
        title = function()
            local number = info.subscriber and info.subscriber.number
            return "Phone", number and "No. " .. tostring(number) or nil
        end,
        items = function()
            info = net.cell.info()
            local items = {}
            if info.network then
                local unread = tonumber(info.unread) or 0
                local on = info.state ~= "off" and info.state ~= "none"
                items[1] = { id = "messages", text = unread > 0 and (" Messages (%d new)"):format(unread) or " Messages" }
                items[2] = { id = "compose", text = " New message" }
                items[3] = { id = "networks", text = " Networks" }
                items[4] = { id = "service", text = " Cell service: " .. (on and "On" or "Off") }
            end
            items[#items + 1] = { id = "monitor", text = " Monitor" }
            items[#items + 1] = { id = "quit", text = " Quit" }
            return items
        end,
        note = function()
            if problem then return problem, c(colours.red) end
            if not info.network then
                if info.state == "activating" then return "Activating..." end
                return "No SIM. Activate one with: cell activate <network> <code>"
            elseif info.state == "off" then
                return "Cell service is off. Choose Cell service to turn it on."
            elseif info.state == "none" then
                return "Cell service isn't running. Choose Cell service to start it."
            elseif info.state == "rejected" then
                return "Rejected" .. (info.rejected and ": " .. tostring(info.rejected) or ""), c(colours.red)
            end
            return nil
        end,
        choose = function(item)
            problem = nil
            if item.id == "messages" then
                messages_screen()
            elseif item.id == "compose" then
                compose_screen()
            elseif item.id == "networks" then
                networks_screen()
            elseif item.id == "service" then
                local on = info.state ~= "off" and info.state ~= "none"
                local ok, err = net.cell.setEnabled(not on)
                if not ok then problem = tostring(err or "Cell service couldn't be turned on") end
                bar.touch()
            elseif item.id == "monitor" then
                -- The monitor only prints why it can't listen, which the menu would cover at once.
                local ok, err = net.cell.listen()
                if not ok then
                    problem = tostring(err or "The monitor can't listen")
                elseif monitor() == false then
                    -- It was terminated, and so are the menus.
                    return "quit"
                end
                bar.touch()
            elseif item.id == "quit" then
                return "quit"
            end
            return nil
        end,
    }
end

--[[- Run the phone's menus beneath the status bar, until the user quits.

@tparam function():boolean|nil monitor Shows the cell monitor on the current terminal, and returns when the user
leaves it, or `false` when it was terminated.
]]
local function run(monitor)
    expect(1, monitor, "function")
    bar.run(function()
        local ok, err = pcall(home_screen, monitor)
        clear()
        term.setCursorPos(1, 1)
        if not ok and err ~= "Terminated" then error(err, 0) end
    end)
end

return { run = run }
