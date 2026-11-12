-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The phone's menus, which run beneath its status bar: to read and write messages, a conversation with each number,
to choose a network, to turn cell service off and on, and to open the monitor.

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
or a click chooses, and Q, Backspace or Left goes back. Keys which are held down don't choose or go back, so holding
one a moment too long doesn't go through several screens.

`options` has:
 - `title`: a function which returns the title, and what to put to its right;
 - `items`: a function which returns the list. Each item has `text`; maybe `fg`, its colour; `tail`, pieces of text for
   the right of its line, each a text and a colour; and `id`, which the choice is kept by when the list changes;
 - `choose`: what to call with a chosen item. The list ends when it returns something;
 - `note`: a function which returns a note to show beneath the list, and its colour;
 - `empty`: what to say when the list is empty;
 - `hint`: short reminders for the bottom of the screen;
 - `keys`: what to call for other characters, by character, with the chosen item. The list ends when it returns
   something;
 - `refresh`: how often to get the list again, in seconds;
 - `back`: `"quit"` if there's nowhere to go back to, so Q and Backspace quit (and Left does nothing). The list then
   returns `"quit"`.
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
    local function act(handler, item)
        local result = handler(item)
        if timer then
            os.cancelTimer(timer)
            timer = os.startTimer(options.refresh)
        end
        load()
        return result
    end

    -- Whether the last key was held down. The character it typed, which comes next, is then ignored too.
    local dirty, held = true, false
    while true do
        if dirty then draw() end
        dirty = true

        local result
        local event, a, b, y = os.pullEvent()
        if event == "key" then
            held = b
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
            elseif (a == keys.backspace or (a == keys.left and options.back ~= "quit")) and not b then
                return options.back
            else
                dirty = false
            end
        elseif event == "char" then
            local key = a:lower()
            local handler = options.keys and options.keys[key]
            if held then
                dirty = false
            elseif handler then
                result = act(handler, items[selected])
            elseif key == "q" then
                return options.back
            else
                dirty = false
            end
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

-- Who a message is with: the number it's from, or the one it's to.
local function contact(message) return tostring(message.from or message.to) end

-- How a sent message is getting on, in a few words, and the colour to show that in.
local function status_of(message)
    if message.status == "sent" then
        return "Sent", colours.lightGrey
    elseif message.status == "sending" then
        return "Sending...", c(colours.yellow, colours.lightGrey)
    elseif message.status == "waiting" then
        return "Waiting for service", c(colours.orange, colours.lightGrey)
    end
    return "Not sent" .. (message.error and ": " .. tostring(message.error) or ""), c(colours.red)
end

-- Ask whether to do something. Left and Right (or Tab) choose between the buttons, and Enter or a click presses one;
-- Y says yes, and N, Q or Backspace no. This returns whether the answer was yes.
local function confirm_screen(title, question, yes)
    local selected, places, held = 1, {}, false
    while true do
        local w, h = term.getSize()
        clear()
        draw_title(title)
        for i, line in ipairs(wrapped(question, w)) do
            if i + 2 < h then put(1, i + 2, line) end
        end
        places = draw_buttons(h, { yes, "Keep" }, selected)

        local event, a, b, y = os.pullEvent()
        if event == "key" then
            held = b
            if a == keys.left then
                selected = 1
            elseif a == keys.right or a == keys.tab then
                selected = 2
            elseif is_enter(a) and not b then
                return selected == 1
            elseif a == keys.backspace and not b then
                return false
            end
        elseif event == "char" and not held then
            local key = a:lower()
            if key == "y" then return true end
            if key == "n" or key == "q" then return false end
        elseif event == "mouse_click" and a == 1 and y == h then
            local button = button_at(places, b)
            if button then return button == 1 end
        end
    end
end

-- A line of text being typed: what it says, and where the cursor is in it.
local function new_field(max)
    return { value = "", pos = 0, max = max }
end

-- Type into a field. Line breaks become spaces, and nothing goes past the longest it may be.
local function field_insert(field, typed)
    typed = typed:gsub("[\r\n]+", " "):sub(1, math.max(0, field.max - #field.value))
    field.value = field.value:sub(1, field.pos) .. typed .. field.value:sub(field.pos + 1)
    field.pos = field.pos + #typed
end

-- Edit a field with a key, as any line of text is. Returns whether the key did something to it.
local function field_key(field, key)
    if key == keys.left then
        field.pos = math.max(0, field.pos - 1)
    elseif key == keys.right then
        field.pos = math.min(#field.value, field.pos + 1)
    elseif key == keys.home then
        field.pos = 0
    elseif key == keys["end"] then
        field.pos = #field.value
    elseif key == keys.delete then
        field.value = field.value:sub(1, field.pos) .. field.value:sub(field.pos + 2)
    elseif key == keys.backspace and field.pos > 0 then
        field.value = field.value:sub(1, field.pos - 1) .. field.value:sub(field.pos + 1)
        field.pos = field.pos - 1
    else
        return false
    end
    return true
end

-- Draw a field on one line, from a column to the end of the screen, moving along if the cursor would be off the
-- screen. Returns the column the cursor is in.
local function draw_field(field, x, y, placeholder)
    local w = term.getSize()
    local room = math.max(1, w - x)
    local along = math.max(0, field.pos - room)
    if field.value == "" and placeholder then
        put(x, y, placeholder, colours.grey)
    else
        put(x, y, field.value:sub(along + 1, along + room + 1))
    end
    return x + field.pos - along
end

-- Ask for the number to write to. Enter goes on to the conversation with it, and Backspace in an empty number goes
-- back. Returns the number, or nothing.
local function number_screen()
    local field, problem, held = new_field(MAX_NUMBER), nil, false
    while true do
        local w, h = term.getSize()
        clear()
        draw_title("New message")
        put(1, 3, "To:")
        local x = draw_field(field, 5, 3)
        for i, line in ipairs(problem and wrapped(problem, w) or {}) do
            if i + 4 < h then put(1, i + 4, line, c(colours.red)) end
        end
        if h >= 6 then put(1, h, fit("Enter: OK  Backspace: back", w), colours.grey) end
        term.setCursorPos(x, 3)
        term.setTextColour(colours.white)
        term.setCursorBlink(true)

        local event, a, b = os.pullEvent()
        if event == "char" or event == "paste" then
            field_insert(field, a)
            problem = nil
        elseif event == "key" then
            held = b
            if is_enter(a) and not b then
                local number = field.value:gsub("^%s+", ""):gsub("%s+$", "")
                if number ~= "" then
                    term.setCursorBlink(false)
                    return number
                end
                problem = "Enter a number first."
            elseif a == keys.backspace and field.value == "" then
                if not held then
                    term.setCursorBlink(false)
                    return nil
                end
            else
                field_key(field, a)
            end
        end
    end
end

--[[ A conversation with one number: the messages to and from it, oldest first, with the newest at the bottom, above a
line to write the next one in. Messages from the number are on the left, and those sent to it on the right, each with
when, and how a sent one is getting on.

Typing writes, Enter sends (even without service: the message waits until there is some), and Backspace in an empty
line goes back. Up and Down (and Page Up and Down, or the mouse wheel) scroll. Tab chooses a message instead, which Up
and Down move between: D deletes it, R sends one which wasn't sent again, and Tab, Q or Backspace go back to writing.
Opening the conversation reads its messages, and so does one which arrives while it's open.
]]
local function conversation_screen(number)
    local messages, field, problem = {}, new_field(MAX_TEXT), nil
    -- How many lines up from the newest the conversation is scrolled; the chosen message, while choosing; whether the
    -- last key was held down (the character it typed is then ignored too); and where things are on the screen.
    local scroll, choosing, held = 0, nil, false
    local body_top, body_bottom, input_y, back_x, shown = 2, 1, 1, nil, {}

    local function load()
        messages = {}
        local unread = {}
        for _, message in ipairs(net.cell.messages()) do
            if contact(message) == number then
                messages[#messages + 1] = message
                if message.from and message.read == false then unread[#unread + 1] = message.n end
            end
        end
        for _, n in ipairs(unread) do net.cell.markRead(n) end
        if #unread > 0 then bar.touch() end
        if choosing then choosing = #messages > 0 and math.max(1, math.min(choosing, #messages)) or nil end
    end

    -- Every line of the conversation, oldest first: its text, column, colour, and which message it's part of.
    local function lay_out(w)
        local lines = {}
        local width = w > 8 and w - 3 or w
        for i, message in ipairs(messages) do
            local sent = message.to ~= nil
            local fg = sent and c(colours.lightBlue, colours.white) or colours.white
            for _, line in ipairs(wrapped(tostring(message.text):gsub("%s+$", ""), width)) do
                lines[#lines + 1] = { text = line, x = sent and w - #line + 1 or 1, fg = fg, index = i }
            end
            local about, about_fg = short_time(message.time), colours.grey
            if sent then
                local status, status_fg = status_of(message)
                about = about ~= "" and about .. " " .. status or status
                if message.status ~= "sent" then about_fg = status_fg end
            end
            for _, line in ipairs(wrapped(about, w)) do
                lines[#lines + 1] = { text = line, x = sent and w - #line + 1 or 1, fg = about_fg, index = i }
            end
        end
        return lines
    end

    local function draw()
        local w, h = term.getSize()
        clear()
        local right = w >= #number + 6 and "Back" or nil
        draw_title(number, right)
        back_x = right and w - #right + 1 or nil

        input_y = math.max(1, h)
        local hint_y = h >= 6 and h - 1 or nil
        body_top, body_bottom = 2, (hint_y or input_y) - 1
        local rows = math.max(0, body_bottom - body_top + 1)

        local lines = lay_out(w)
        local max_scroll = math.max(0, #lines - rows)
        -- The chosen message is kept in sight.
        if choosing then
            local first, last
            for i, line in ipairs(lines) do
                if line.index == choosing then
                    first, last = first or i, i
                end
            end
            if first then
                local top = #lines - rows - scroll
                if first <= top then scroll = #lines - rows - first + 1 end
                if last > top + rows then scroll = #lines - last end
            end
        end
        scroll = math.max(0, math.min(scroll, max_scroll))
        local top = math.max(0, #lines - rows - scroll)

        if #messages == 0 and rows > 0 then put(1, body_top, fit("No messages yet.", w), colours.lightGrey) end
        shown = {}
        for row = 1, rows do
            local line = lines[top + row]
            if not line then break end
            local y = body_top + row - 1
            shown[y] = line.index
            if line.index == choosing then
                put(1, y, (" "):rep(w), colours.black, colours.white)
                put(line.x, y, line.text, colours.black, colours.white)
            else
                put(line.x, y, line.text, line.fg)
            end
        end

        if hint_y then
            if problem then
                put(1, hint_y, fit(problem, w), c(colours.red))
            elseif choosing then
                put(1, hint_y, fit("D: delete  R: resend", w), colours.grey)
            else
                put(1, hint_y, fit("Enter: send  Tab: choose", w), colours.grey)
            end
        end

        put(1, input_y, ">", choosing and colours.grey or colours.white)
        local x = draw_field(field, 3, input_y, "Write a message")
        if choosing then
            term.setCursorBlink(false)
        else
            term.setCursorPos(x, input_y)
            term.setTextColour(colours.white)
            term.setCursorBlink(true)
        end
        return rows
    end

    local function send(text)
        local ok, err = net.cell.send(number, text)
        bar.touch()
        if not ok then
            problem = tostring(err or "The message couldn't be sent")
            return false
        end
        problem, scroll = nil, 0
        return true
    end

    -- What can be done with the chosen message.
    local function delete_chosen()
        local message = messages[choosing]
        if message and confirm_screen(number, "Delete this message?", "Delete") then
            net.cell.deleteMessage(message.n)
            bar.touch()
        end
    end
    local function resend_chosen()
        local message = messages[choosing]
        if message and message.to and message.status == "failed" and send(tostring(message.text)) then
            net.cell.deleteMessage(message.n)
        end
    end

    load()
    local rows = 1
    while true do
        rows = draw()
        local event, a, b, y = os.pullEvent()
        if event == "key" then
            held = b
            if a == keys.up and choosing then
                choosing = math.max(1, choosing - 1)
            elseif a == keys.down and choosing then
                choosing = math.min(#messages, choosing + 1)
            elseif a == keys.up then
                scroll = scroll + 1
            elseif a == keys.down then
                scroll = scroll - 1
            elseif a == keys.pageUp then
                scroll = scroll + math.max(1, rows)
            elseif a == keys.pageDown then
                scroll = scroll - math.max(1, rows)
            elseif a == keys.tab then
                if choosing then
                    choosing = nil
                elseif #messages > 0 then
                    choosing = #messages
                end
            elseif choosing then
                if a == keys.backspace and not b then choosing = nil end
            elseif is_enter(a) and not b then
                if field.value:find("%S") and send(field.value) then field.value, field.pos = "", 0 end
                load()
            elseif a == keys.backspace and field.value == "" then
                if not b then
                    term.setCursorBlink(false)
                    return
                end
            else
                field_key(field, a)
                problem = nil
            end
        elseif (event == "char" or event == "paste") and choosing then
            local key = event == "char" and not held and a:lower()
            if key == "d" then
                delete_chosen()
                load()
            elseif key == "r" then
                resend_chosen()
                load()
            elseif key == "q" then
                choosing = nil
            end
        elseif event == "char" or event == "paste" then
            field_insert(field, a)
            problem = nil
        elseif event == "mouse_click" and a == 1 then
            if y == 1 and back_x and b >= back_x then
                term.setCursorBlink(false)
                return
            elseif y == input_y then
                choosing = nil
            elseif shown[y] then
                choosing = shown[y]
            end
        elseif event == "mouse_scroll" then
            scroll = scroll - a
        elseif event == "cell_message" or event == "cell_sent" or event == "cell_messages" or event == "cell_state"
            or event == "term_resize" then
            load()
        end
    end
end

-- List the conversations, with the newest first, and open the one which is chosen. N writes to another number, and D
-- deletes the chosen conversation, once that's confirmed.
local function conversations_screen()
    local unread = 0
    return list_screen {
        hint = { "* new", "! not sent", "N: new", "D: delete", "Q/Backspace: back" },
        empty = "No messages.",
        title = function() return "Messages", unread > 0 and unread .. " new" or nil end,
        items = function()
            -- Each number's messages, and the newest of them, by number.
            local by_number, order = {}, {}
            unread = 0
            for i, message in ipairs(net.cell.messages()) do
                local number = contact(message)
                local entry = by_number[number]
                if not entry then
                    entry = { number = number, messages = {}, unread = 0 }
                    by_number[number] = entry
                    order[#order + 1] = entry
                end
                entry.messages[#entry.messages + 1] = message
                entry.last, entry.at = message, i
                if message.from and message.read == false then
                    entry.unread, unread = entry.unread + 1, unread + 1
                end
            end
            table.sort(order, function(a, b) return a.at > b.at end)

            -- The columns are as wide as what's in them, but a long number doesn't take the text's room.
            local w = term.getSize()
            local who_width, time_width = 1, 1
            for _, entry in ipairs(order) do
                entry.time = short_time(entry.last.time)
                who_width = math.max(who_width, #entry.number)
                time_width = math.max(time_width, #entry.time)
            end
            who_width = math.min(who_width, w >= 40 and 16 or 8)

            local items = {}
            for _, entry in ipairs(order) do
                local last, mark, fg = entry.last, " ", colours.lightGrey
                if entry.unread > 0 then
                    mark, fg = "*", colours.white
                elseif last.to and last.status == "failed" then
                    mark = "!"
                elseif last.to then
                    mark = ">"
                end
                items[#items + 1] = {
                    id = entry.number, fg = fg, entry = entry,
                    text = ("%s%s %s %s"):format(mark, fit(entry.number, who_width), fit(entry.time, time_width),
                        (tostring(last.text):gsub("%s+", " "))),
                }
            end
            return items
        end,
        choose = function(item) conversation_screen(item.id) end,
        keys = {
            n = function()
                local number = number_screen()
                if number then conversation_screen(number) end
            end,
            d = function(item)
                if not item then return end
                local count = #item.entry.messages
                local question = count == 1 and ("Delete the message with %s?"):format(item.id)
                    or ("Delete the %d messages with %s?"):format(count, item.id)
                if confirm_screen("Messages", question, "Delete") then
                    for _, message in ipairs(item.entry.messages) do net.cell.deleteMessage(message.n) end
                    bar.touch()
                end
            end,
        },
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
        hint = { "> in use", "* chosen", "Q/Backspace: back" },
        title = function() return "Networks" end,
        note = function() return result, result_fg end,
        items = function()
            local info, networks = net.cell.info(), net.cell.networks()
            local w = term.getSize()

            local kinds, kind_width, name_width = {}, 0, 4
            for i, network in ipairs(networks) do
                name_width = math.max(name_width, #tostring(network.name))
                if not network.allowed then
                    kinds[i] = "unknown"
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
        back = "quit",
        hint = { "Enter: choose", "Q: quit" },
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
            elseif info.state == "searching" and info.newer then
                return "The cells around run a newer version of the network than this phone. Update the phone's software (the mod, or the server's ROM).", c(colours.orange)
            end
            return nil
        end,
        choose = function(item)
            problem = nil
            if item.id == "messages" then
                conversations_screen()
            elseif item.id == "compose" then
                local number = number_screen()
                if number then conversation_screen(number) end
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
