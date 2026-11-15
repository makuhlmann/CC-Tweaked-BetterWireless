-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What the cellular programs' menus are made of: lists to choose from, questions, and lines to type in. The phone's
menus (`cc.internal.net.cell.gui`), a cell's (`cell_menu`) and a core's (`core_menu`) all use them, so they look and
work alike.

Everything here is drawn to fit the screen it's on, a pocket computer's or wider. Basic computers get greys where
advanced ones get colours, and everything can be done with the keyboard alone.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

-- What the user did while a menu waited for something else (see `wait_for`), for the menus to act on next, oldest
-- first. It's kept here, not put back on the computer's queue, so no other program sees any of it twice.
local pending = {}

-- Wait for the next event, as `os.pullEvent` does: what was kept while a menu waited comes first.
local function pull()
    local kept = table.remove(pending, 1)
    if kept then return table.unpack(kept, 1, kept.n) end
    return os.pullEvent()
end

--- Make some text just as wide as a width: cut short, or with spaces after it.
--
-- @param text The text.
-- @tparam number width The width.
-- @treturn string The text, that wide.
local function fit(text, width)
    text = tostring(text)
    if width <= 0 then return "" end
    if #text > width then return text:sub(1, width) end
    return text .. (" "):rep(width - #text)
end

--[[- Break text into lines no wider than a width, at spaces where it can. Each line is given as where it starts and
ends in the text, so a cursor can be put in it. The space or line break a line was broken at is in no line.

@tparam string text The text.
@tparam number width The width.
@treturn { { number, number }... } Where each line starts and ends in the text.
]]
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

--- Break text into lines no wider than a width, as [`wrap`] does.
--
-- @tparam string text The text.
-- @tparam number width The width.
-- @treturn { string... } The lines.
local function wrapped(text, width)
    local lines = {}
    for i, line in ipairs(wrap(text, width)) do lines[i] = text:sub(line[1], line[2]) end
    return lines
end

--- Put short pieces of text next to each other, on as many lines as that takes.
--
-- @tparam { string... } parts The pieces.
-- @tparam number width How wide a line may be.
-- @treturn { string... } The lines.
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

--- Choose a colour for the screen it's for: basic computers show greys, but no other colours.
--
-- @tparam number wanted The colour to use where there are colours.
-- @tparam[opt] number grey The grey to use where there aren't: white if not given.
-- @treturn number The colour to use.
local function c(wanted, grey)
    if term.isColour() then return wanted end
    return grey or colours.white
end

--- Write some text, leaving out what doesn't fit on the screen.
--
-- @tparam number x The column to start in.
-- @tparam number y The line.
-- @tparam string text The text.
-- @tparam[opt] number fg The text's colour: white if not given.
-- @tparam[opt] number bg The colour behind it: black if not given.
local function put(x, y, text, fg, bg)
    local w, h = term.getSize()
    if x < 1 or x > w or y < 1 or y > h then return end
    if x + #text - 1 > w then text = text:sub(1, w - x + 1) end
    term.setCursorPos(x, y)
    term.setTextColour(fg or colours.white)
    term.setBackgroundColour(bg or colours.black)
    term.write(text)
end

--- Clear the screen, for a menu to draw on.
local function clear()
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    term.setCursorBlink(false)
end

--- Draw a screen's first line: what it is, and something short about it on the right.
--
-- @tparam string left What the screen is.
-- @tparam[opt] string right Something short about it, shown if there's room.
local function draw_title(left, right)
    local w = term.getSize()
    put(1, 1, fit(left, w), c(colours.yellow))
    if right and #left + 1 + #right <= w then put(w - #right + 1, 1, right, colours.lightGrey) end
end

--- Draw a row of buttons.
--
-- @tparam number y The line to draw them on.
-- @tparam { string... } labels What each button says.
-- @tparam number selected Which of them is the chosen one.
-- @treturn { { number, number }... } The first and last column each button covers, for [`button_at`].
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

--- Find the button in a column.
--
-- @tparam { { number, number }... } places The columns each button covers, as [`draw_buttons`] gave them.
-- @tparam number x The column.
-- @treturn number|nil Which button is there, if one is.
local function button_at(places, x)
    for i, place in ipairs(places) do
        if x >= place[1] and x <= place[2] then return i end
    end
    return nil
end

--- Whether a key is one of the two Enter keys.
--
-- @tparam number key The key.
-- @treturn boolean Whether it is.
local function is_enter(key) return key == keys.enter or key == keys.numPadEnter end

--[[- Show a list to choose from, until something is chosen which ends it, or the user goes back.

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
 - `events`: other events to get the list again for, by name;
 - `follow`: whether to stay at the end of the list as it grows, while the last item is the chosen one (as for a log);
 - `back`: `"quit"` if there's nowhere to go back to, so Q and Backspace quit (and Left does nothing). The list then
   returns `"quit"`.

@tparam table options What to show, and what to do with it.
@return What ended the list: what `choose` (or one of `keys`) returned, or `back` when the user went back.
]]
local function list_screen(options)
    local items, selected, scroll, first, visible = {}, 1, 0, 2, 0

    local function load()
        local id = items[selected] and items[selected].id
        local at_end = options.follow and selected >= #items
        items = options.items()
        if at_end then
            selected = #items
        elseif id ~= nil then
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

    -- Get the list again, and count the time to the next time from now: getting it may take a while (a core on another
    -- computer is asked for it, say), and a timer which went off meanwhile is gone.
    local function reload()
        load()
        if timer then
            os.cancelTimer(timer)
            timer = os.startTimer(options.refresh)
        end
    end

    -- Do what was chosen, which may show other screens for a while, and then catch up.
    local function act(handler, item)
        local result = handler(item)
        reload()
        return result
    end

    -- Whether the last key was held down. The character it typed, which comes next, is then ignored too.
    local dirty, held = true, false
    while true do
        if dirty then draw() end
        dirty = true

        local result
        local event, a, b, y = pull()
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
            timer = nil
            load()
            timer = os.startTimer(options.refresh)
        elseif event == "cell_state" or event == "cell_message" or event == "cell_sent" or event == "cell_messages"
            or event == "term_resize" or (options.events and options.events[event]) then
            reload()
        else
            dirty = false
        end
        if result ~= nil then return result end
    end
end

--[[- Ask whether to do something. Left and Right (or Tab) choose between the buttons, and Enter or a click presses
one; Y says yes, and N, Q or Backspace no.

@tparam string title The screen's title.
@tparam string question What's asked, and what saying yes does.
@tparam string yes What the button which says yes says.
@tparam[opt="Keep"] string no What the button which says no says.
@treturn boolean Whether the answer was yes.
]]
local function confirm_screen(title, question, yes, no)
    local selected, places, held = 1, {}, false
    while true do
        local w, h = term.getSize()
        clear()
        draw_title(title)
        for i, line in ipairs(wrapped(question, w)) do
            if i + 2 < h then put(1, i + 2, line) end
        end
        places = draw_buttons(h, { yes, no or "Keep" }, selected)

        local event, a, b, y = pull()
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

--- Make a line of text to type in: what it says, and where the cursor is in it.
--
-- @tparam number max The longest the text may be.
-- @treturn table The field: its `value`, the cursor's `pos` in it, and `max`.
local function new_field(max)
    return { value = "", pos = 0, max = max }
end

--- Type into a field. Line breaks become spaces, and nothing goes past the longest it may be.
--
-- @tparam table field The field.
-- @tparam string typed What was typed (or pasted).
local function field_insert(field, typed)
    typed = typed:gsub("[\r\n]+", " "):sub(1, math.max(0, field.max - #field.value))
    field.value = field.value:sub(1, field.pos) .. typed .. field.value:sub(field.pos + 1)
    field.pos = field.pos + #typed
end

--- Edit a field with a key, as any line of text is.
--
-- @tparam table field The field.
-- @tparam number key The key.
-- @treturn boolean Whether the key did something to it.
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

--[[- Draw a field on one line, from a column to the end of the screen, moving along if the cursor would be off the
screen.

@tparam table field The field.
@tparam number x The column it starts in.
@tparam number y The line.
@tparam[opt] string placeholder What to show, in grey, while the field is empty.
@treturn number The column the cursor is in.
]]
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


--[[- Ask for a line of text, until it's given or the user goes back.

The screen has a title, what's asked for, the line to type in, and beneath it a note, or what's wrong with what was
typed. Enter gives the text, and Tab (or Backspace in an empty line) goes back. Keys which are held down don't give it
or go back.

`options` has:
 - `title`: the screen's title;
 - `label`: what the line is, before it;
 - `value`: what's in the line to begin with;
 - `max`: the longest the text may be, 200 characters if not said;
 - `note`: what to say beneath the line;
 - `check`: a function which is given the text, with the spaces at its ends taken off, and returns what's wrong with
   it, if anything is: the text is only given once nothing is. It may do what the text is for, and say why that failed.

@tparam table options What to ask for.
@treturn string|nil The text, or nothing if the user went back.
]]
local function input_screen(options)
    local field, problem = new_field(options.max or 200), nil
    field_insert(field, tostring(options.value or ""))
    local label = options.label and options.label .. " " or ""
    while true do
        local w, h = term.getSize()
        clear()
        draw_title(options.title)
        put(1, 3, label, colours.lightGrey)
        local x = draw_field(field, #label + 1, 3)
        local y = 5
        for _, line in ipairs(problem and wrapped(problem, w) or {}) do
            if y < h then put(1, y, line, c(colours.red)) end
            y = y + 1
        end
        if problem then y = y + 1 end
        for _, line in ipairs(options.note and wrapped(options.note, w) or {}) do
            if y < h then put(1, y, line, colours.lightGrey) end
            y = y + 1
        end
        if h >= 6 then put(1, h, fit("Enter: OK  Tab: back", w), colours.grey) end
        term.setCursorPos(x, 3)
        term.setTextColour(colours.white)
        term.setCursorBlink(true)

        local event, a, b = pull()
        if event == "char" or event == "paste" then
            field_insert(field, a)
            problem = nil
        elseif event == "key" then
            if is_enter(a) and not b then
                local text = field.value:gsub("^%s+", ""):gsub("%s+$", "")
                term.setCursorBlink(false)
                problem = options.check and options.check(text) or nil
                if not problem then return text end
            elseif (a == keys.tab or (a == keys.backspace and field.value == "")) and not b then
                term.setCursorBlink(false)
                return nil
            else
                field_key(field, a)
            end
        end
    end
end

--- Say something, until the user has read it: Enter, Q, Backspace or a click on the button goes on.
--
-- @tparam string title The screen's title.
-- @tparam string text What to say.
-- @tparam[opt] number colour The colour to say it in.
local function message_screen(title, text, colour)
    local held = false
    while true do
        local w, h = term.getSize()
        clear()
        draw_title(title)
        for i, line in ipairs(wrapped(text, w)) do
            if i + 2 < h then put(1, i + 2, line, colour) end
        end
        local places = draw_buttons(h, { "OK" }, 1)

        local event, a, b, y = pull()
        if event == "key" then
            held = b
            if (is_enter(a) or a == keys.backspace) and not b then return end
        elseif event == "char" and not held then
            if a:lower() == "q" then return end
        elseif event == "mouse_click" and a == 1 and y == h and button_at(places, b) then
            return
        end
    end
end

-- What the user does, which mustn't be lost while a menu waits for something else.
local INPUT = {
    key = true, key_up = true, char = true, paste = true, mouse_click = true, mouse_up = true, mouse_scroll = true,
    mouse_drag = true, term_resize = true,
}

--[[- Call a function which waits for something (an answer from another computer, say), keeping what the user does
meanwhile for the menus to act on afterwards. Whatever waits for one kind of event throws the others away: without
this, keys pressed while a menu asks a core something would be lost.

@tparam function fn The function.
@param ... What to call it with.
@return What the function returns. An error in it is thrown again.
]]
local function wait_for(fn, ...)
    local co = coroutine.create(fn)
    local kept = {}
    local result = table.pack(coroutine.resume(co, ...))
    while coroutine.status(co) ~= "dead" do
        local filter = result[2]
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then error("Terminated", 0) end
        if INPUT[event[1]] then kept[#kept + 1] = event end
        if filter == nil or event[1] == filter then
            result = table.pack(coroutine.resume(co, table.unpack(event, 1, event.n)))
        end
    end
    for _, event in ipairs(kept) do pending[#pending + 1] = event end
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

return {
    wait_for = wait_for,
    fit = fit,
    wrap = wrap,
    wrapped = wrapped,
    flow = flow,
    c = c,
    put = put,
    clear = clear,
    draw_title = draw_title,
    draw_buttons = draw_buttons,
    button_at = button_at,
    is_enter = is_enter,
    list_screen = list_screen,
    confirm_screen = confirm_screen,
    new_field = new_field,
    field_insert = field_insert,
    field_key = field_key,
    draw_field = draw_field,
    input_screen = input_screen,
    message_screen = message_screen,
}
