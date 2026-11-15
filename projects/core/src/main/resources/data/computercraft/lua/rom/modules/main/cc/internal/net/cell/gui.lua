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
local menu = require "cc.internal.net.cell.menu"

-- What every menu is made of: the phone's, a cell's and a core's.
local fit, wrapped, c, put, clear = menu.fit, menu.wrapped, menu.c, menu.put, menu.clear
local draw_title, is_enter = menu.draw_title, menu.is_enter
local list_screen, confirm_screen = menu.list_screen, menu.confirm_screen
local new_field, field_insert, field_key, draw_field = menu.new_field, menu.field_insert, menu.field_key, menu.draw_field

-- How often the list of networks is read again while it's shown, in seconds.
local NETWORKS_REFRESH = 2

-- The longest message and the longest number which can be typed, in characters.
local MAX_TEXT = 1000
local MAX_NUMBER = 20

local function short_time(time)
    if type(time) ~= "number" then return "" end
    local seconds = math.floor(time / 1000)
    if os.date("%Y%m%d", seconds) == os.date("%Y%m%d") then return os.date("%H:%M", seconds) end
    return os.date("%d %b", seconds)
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

    -- Every line of the conversation, oldest first: its text, column, colour, and which message it's part of. It's only
    -- worked out again once the messages or the screen's width change, not for each key.
    local laid_out = {}
    local function lay_out(w)
        if laid_out.width == w and laid_out.messages == messages then return laid_out.lines end
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
        laid_out = { width = w, messages = messages, lines = lines }
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
                items[1] = { id = "messages", text = unread > 0 and (" Messages (%d new)"):format(unread) or " Messages" }
                items[2] = { id = "compose", text = " New message" }
                items[3] = { id = "networks", text = " Networks" }
            end
            -- Without a SIM, cell service on means listening for cells.
            local on = info.enabled ~= false and info.state ~= "off" and info.state ~= "none"
            items[#items + 1] = { id = "service", text = " Cell service: " .. (on and "On" or "Off") }
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
                local on = info.enabled ~= false and info.state ~= "off" and info.state ~= "none"
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
