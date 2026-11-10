-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " activate <network> <code>")
    print(name .. " send <number> <message>")
    print(name .. " messages")
    print(name .. " monitor")
end

if not crypto or not enclave then
    printError("Phones need the crypto and enclave APIs, which are turned off on this server")
    return
end

local STATES = {
    none = "No SIM: activate one with 'cell activate'",
    inactive = "Not activated",
    activating = "Activating",
    searching = "Searching for a cell",
    attaching = "Attaching",
    attached = "Attached",
    rejected = "Rejected",
}

-- How long a cell may be quiet before the monitor shows it as gone, in seconds (as the phone does).
local SILENCE = 4

-- Everything about the phone's service on one screen, which fits a pocket computer: its state, the cells it hears (of
-- any network), and what has happened lately. It's redrawn every second, and whenever the state changes.
local function monitor()
    local ok, err = net.cell.listen()
    if not ok then
        printError(err)
        return
    end

    local parent = term.current()
    local colour = parent.isColour()
    -- Basic computers show greys, but no other colours.
    local function c(wanted, grey)
        if colour then return wanted end
        return grey or colours.white
    end

    local SHORT_STATES = {
        none = "No SIM", inactive = "Not activated", activating = "Activating", searching = "Searching",
        attaching = "Attaching", attached = "Attached", rejected = "Rejected",
    }
    local STATE_COLOURS = {
        attached = c(colours.lime), searching = c(colours.yellow), attaching = c(colours.yellow),
        activating = c(colours.yellow), rejected = c(colours.red), inactive = colours.lightGrey, none = colours.lightGrey,
    }
    local HEADER_BG = c(colours.blue, colours.grey)

    local function fit(text, width)
        text = tostring(text)
        if #text > width then return text:sub(1, width) end
        return text .. (" "):rep(width - #text)
    end
    local function round(x) return math.floor(x + 0.5) end

    -- How many of four bars a signal gets.
    local function bars(signal)
        if signal >= -70 then return 4 elseif signal >= -80 then return 3 elseif signal >= -90 then return 2
        elseif signal >= -100 then return 1 else return 0 end
    end

    local function describe(event)
        local kind = event.kind
        if kind == "attached" then return ("Attached #%s"):format(event.cell), c(colours.lime)
        elseif kind == "handover" then return ("Moved #%s > #%s"):format(event.from, event.to), c(colours.lightBlue)
        elseif kind == "lost" then return ("Lost #%s"):format(event.cell), c(colours.orange)
        elseif kind == "rejected" then return "Rejected: " .. tostring(event.reason), c(colours.red)
        elseif kind == "activated" then return "Activated on " .. tostring(event.network), c(colours.lime)
        elseif kind == "activation_failed" then return "Not activated: " .. tostring(event.reason), c(colours.red)
        end
        return tostring(kind), colours.white
    end

    local win
    local function resize()
        local w, h = parent.getSize()
        win = window.create(parent, 1, 1, w, h, false)
    end
    resize()

    local function draw()
        local info = net.cell.info()
        local heard, events = info.heard or {}, info.events or {}
        local w, h = win.getSize()
        win.setVisible(false)
        win.setBackgroundColour(colours.black)
        win.clear()

        local y = 0
        local function line(text, fg, bg)
            y = y + 1
            if y > h then return end
            win.setCursorPos(1, y)
            win.setBackgroundColour(bg or colours.black)
            win.setTextColour(fg or colours.white)
            win.write(fit(text, w))
        end
        -- Write over part of the current line.
        local function at(x, text, fg, bg)
            if y > h or x < 1 then return end
            win.setCursorPos(x, y)
            win.setBackgroundColour(bg or colours.black)
            win.setTextColour(fg or colours.white)
            win.write(text)
        end
        local function right(text, fg, bg)
            if #text < w then at(w - #text + 1, text, fg, bg) end
        end

        local serving
        for _, cell in ipairs(heard) do
            if cell.serving then serving = cell end
        end

        line(" Cell monitor", colours.white, HEADER_BG)
        right(os.date("%H:%M:%S "), colours.white, HEADER_BG)

        line(SHORT_STATES[info.state] or tostring(info.state), STATE_COLOURS[info.state])
        if serving then
            -- Four bars, then a space.
            local count, x = bars(serving.signal), w - 4
            at(x, ("|"):rep(count), STATE_COLOURS.attached)
            at(x + count, ("."):rep(4 - count), colours.grey)
        end
        local function row(label, value) line(("%-5s%s"):format(label, value)) end
        row("Net", info.network or "-")
        row("No.", info.subscriber and ("%s (%s)"):format(info.subscriber.number, info.subscriber.id) or "-")
        row("IP", info.address or "-")
        row("Cell", serving and ("#%d, %d dBm"):format(serving.id, round(serving.signal)) or "-")

        -- Share what's left between the cells and the events, giving either the other's spare lines.
        local left = h - y - 2
        local cell_lines = math.max(1, math.min(#heard, math.max(math.ceil(left / 2), left - #events)))
        local event_lines = left - cell_lines

        line(" Cells", colours.white, HEADER_BG)
        right(("%d "):format(#heard), colours.white, HEADER_BG)
        if #heard == 0 then line("None heard", colours.lightGrey) end
        for i = 1, math.min(#heard, cell_lines) do
            local cell = heard[i]
            if i == cell_lines and #heard > cell_lines then
                line(("  and %d more"):format(#heard - cell_lines + 1), colours.lightGrey)
                break
            end
            -- Our cell, ours, fakes claiming to be ours, and other networks'.
            local own = info.network ~= nil and cell.network == info.network
            local mark, fg = " ", colours.lightGrey
            if cell.serving then
                mark, fg = ">", c(colours.lime)
            elseif own and cell.verified == false then
                mark, fg = "!", c(colours.red)
            elseif own then
                fg = colours.white
            end
            if cell.age > SILENCE then fg = colours.grey end
            local id, signal = fit("#" .. cell.id, 5), ("%4d"):format(round(cell.signal))
            line(mark .. id .. " " .. fit(cell.network, math.max(1, w - 8 - #signal)) .. " " .. signal, fg)
        end

        line(" Events", colours.white, HEADER_BG)
        if #events == 0 and event_lines > 0 then line("Nothing yet", colours.lightGrey) end
        for i = #events, math.max(1, #events - event_lines + 1), -1 do
            local text, fg = describe(events[i])
            line(os.date("%H:%M:%S ", math.floor(events[i].time / 1000)) .. text, fg)
        end

        if y < h then
            y = h - 1
            line("Press Q to quit", colours.grey)
        end
        win.setVisible(true)
    end

    term.setCursorBlink(false)
    local ran, failure = pcall(function()
        local timer = os.startTimer(0)
        while true do
            local event, value = os.pullEvent()
            if event == "timer" and value == timer then
                draw()
                timer = os.startTimer(1)
            elseif event == "cell_state" then
                draw()
            elseif event == "char" and (value == "q" or value == "Q") then
                return
            elseif event == "term_resize" then
                resize()
                draw()
            end
        end
    end)
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    term.setCursorPos(1, 1)
    if not ran and failure ~= "Terminated" then error(failure, 0) end
end

local command = args[1]
if command == "monitor" and #args == 1 then
    monitor()
elseif command == nil then
    local info = net.cell.info()
    print(STATES[info.state] or info.state)
    if info.network then print("Network:  " .. info.network) end
    if info.subscriber then print(("Number:   %s (%s)"):format(tostring(info.subscriber.number), tostring(info.subscriber.id))) end
    if info.address then print("Address:  " .. info.address) end
    if info.cell and info.state == "attached" then print("Cell:     #" .. info.cell) end
    if info.rejected then printError(info.rejected) end
    if info.activation_error then printError(info.activation_error) end
    for _, cell in ipairs(info.cells or {}) do
        print(("  Cell #%-5d %4d dBm%s"):format(cell.id, math.floor(cell.signal + 0.5), cell.id == info.cell and " (in use)" or ""))
    end
    if info.state == "inactive" and #(info.networks or {}) > 0 then
        print("Networks in range: " .. table.concat(info.networks, ", "))
    end
elseif command == "activate" and #args >= 3 then
    local network, code = args[2], table.concat(args, " ", 3)
    -- Give the phone a moment to hear which networks are around.
    local info = net.cell.info()
    local deadline = os.clock() + 5
    while info.state ~= "inactive" and info.state ~= "rejected" and info.state ~= "none" and os.clock() < deadline do
        sleep(0.5)
        info = net.cell.info()
    end
    local ok, err
    for _ = 1, 6 do
        ok, err = net.cell.activate(network, code)
        if ok or err ~= "No cell of " .. network .. " in range" then break end
        sleep(1)
    end
    if not ok then
        printError(err)
        return
    end

    print("Activating...")
    local timer = os.startTimer(30)
    while true do
        local event, state = os.pullEvent()
        if event == "cell_state" and (state == "searching" or state == "attaching" or state == "attached") then
            info = net.cell.info()
            print(("Activated on %s, as number %s."):format(network, tostring(info.subscriber and info.subscriber.number)))
            break
        elseif (event == "cell_state" and state == "inactive") or (event == "timer" and state == timer) then
            printError(net.cell.info().activation_error or "Activation didn't finish")
            return
        end
    end
    -- Wait a little for the phone to attach.
    timer = os.startTimer(15)
    while net.cell.info().state ~= "attached" do
        local event, value = os.pullEvent()
        if event == "timer" and value == timer then break end
    end
    info = net.cell.info()
    if info.state == "attached" then print("Attached, with the address " .. info.address .. ".") end
elseif command == "send" and #args >= 3 then
    local ok, err = net.cell.send(args[2], table.concat(args, " ", 3))
    if ok then print("Sent.") else printError(err) end
elseif command == "messages" and #args == 1 then
    local messages = net.cell.messages()
    if #messages == 0 then print("No messages.") end
    for _, message in ipairs(messages) do
        print(("%s  From %s: %s"):format(os.date("%Y-%m-%d %H:%M", message.time / 1000), message.from, message.text))
    end
else
    usage()
end
