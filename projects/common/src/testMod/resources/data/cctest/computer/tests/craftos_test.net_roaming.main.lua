-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is a phone of the network HOME. It gets its activation code over the cable, then does everything else
-- over the air: first through its own network's cell, then through a cell of VISIT, which carries HOME's phones.
net.setAddress(peripheral.getName(peripheral.find("modem", function(_, modem) return not modem.isWireless() end)), "10.0.0.1/24")

local connection, err
for _ = 1, 20 do
    connection, err = net.tcp.connect("10.0.0.2", 9031, 1)
    if connection then break end
    sleep(0.5)
end
if not connection then error("Couldn't get a code: " .. tostring(err), 0) end
local code = connection:receive(10)
connection:close()

-- Wait for the phone to be in some state, for so long.
local function wait_for(what, test, seconds)
    local deadline = os.clock() + seconds
    while true do
        local info = net.cell.info()
        if test(info) then return info end
        if os.clock() > deadline then error(what .. " didn't happen: " .. textutils.serialise(net.cell.info()), 0) end
        sleep(0.25)
    end
end

shell.run("cell", "activate", "HOME", code)
local info = net.cell.info()
if info.state ~= "attached" then error("Not attached: " .. tostring(info.state) .. " " .. tostring(info.activation_error), 0) end
if info.roaming or info.serving_network ~= "HOME" then error("Not at home: " .. textutils.serialise(info), 0) end
local addr = info.address

-- A phone hears of the networks it may roam on when it attaches. The agreement may be made after that, so attach
-- again until it has.
local function partner()
    for _, network in ipairs(net.cell.networks()) do
        if network.name == "VISIT" then return network.kind == "partner" and network.allowed end
    end
end
for _ = 1, 20 do
    if partner() then break end
    net.cell.setEnabled(false)
    if net.cell.info().state ~= "off" then error("Cell service didn't turn off", 0) end
    sleep(1)
    assert(net.cell.setEnabled(true))
    wait_for("Attaching again", function(now) return now.state == "attached" end, 15)
end
if not partner() then error("Never heard of VISIT: " .. textutils.serialise(net.cell.networks()), 0) end
local refused, why = net.cell.setNetwork("NOT A NAME")
if refused or why ~= "Network names are letters, digits and dashes, up to 32 of them" then
    error("Could choose a network which can't be: " .. tostring(why), 0)
end

-- Told to use VISIT, the phone roams, with the address its own network gave it.
assert(net.cell.setNetwork("VISIT"))
info = wait_for("Roaming", function(now) return now.state == "attached" and now.roaming end, 20)
if info.serving_network ~= "VISIT" or info.address ~= addr or info.selection ~= "VISIT" then
    error("Wrong service while roaming: " .. textutils.serialise(info), 0)
end

-- Its own network's gateway answers, through VISIT's cell and core.
local time, ping_err = net.ping("10.64.0.1", 2)
if not time then error("No answer from the gateway while roaming: " .. tostring(ping_err), 0) end

-- So do messages: one to ourselves goes to our own network's core and back.
assert(net.cell.send("100", "Hello from abroad"))
local timer = os.startTimer(10)
while true do
    local event, from, text = os.pullEvent()
    if event == "cell_message" then
        if from ~= "100" or text ~= "Hello from abroad" then error("Got " .. tostring(text) .. " from " .. tostring(from), 0) end
        break
    elseif event == "timer" and from == timer then
        error("The message didn't arrive", 0)
    end
end
local messages = net.cell.messages()
local sent, received = messages[#messages - 1], messages[#messages]
if not sent or sent.to ~= "100" or sent.status ~= "sent" or not received or received.from ~= "100" or received.read ~= false then
    error("Wrong messages: " .. textutils.serialise(messages), 0)
end

-- The menus show all this beneath the status bar: the network in use, an R for roaming, and the new message. Reading
-- the message there takes the note away.
do
    local screen = window.create(term.current(), 1, 1, 26, 20, false)
    local old = term.redirect(screen)
    local co = coroutine.create(function() return shell.run("cell", "gui") end)
    local function line(y) return (screen.getLine(y):gsub("%s+$", "")) end
    local function fail(what)
        term.redirect(old)
        local lines = {}
        for y = 1, 20 do lines[y] = line(y) end
        error(what .. ":\n" .. table.concat(lines, "\n"), 0)
    end
    local function event(...)
        local ok, problem = coroutine.resume(co, ...)
        if not ok then fail("The menus failed: " .. tostring(problem)) end
    end
    local function count(text)
        local found = 0
        for y = 2, 20 do
            if line(y):find(text, 1, true) then found = found + 1 end
        end
        return found
    end
    local function shown(text) return count(text) > 0 end

    event()
    local bar = line(1)
    if not bar:find("^ VISIT ") or not bar:find("1 new msg", 1, true) or not bar:find(" R %[[|.][|.][|.][|.]%]$") then
        fail("Wrong status bar while roaming")
    end
    if not shown("Messages (1 new)") or not shown("No. 100") then fail("Wrong menu") end

    event("key", keys.enter, false)
    -- One conversation, with 100: the message sent to it, and the one from it.
    if not shown("*100 ") or not shown("Hello from") then fail("The messages aren't listed") end
    event("key", keys.enter, false)
    if count("Hello from abroad") ~= 2 or not shown(" Sent") then fail("The conversation isn't shown") end
    if line(1):find("new msg", 1, true) then fail("The message is still new") end

    event("key", keys.backspace, false)
    event("key", keys.backspace, false)
    if not shown("Networks") or shown("new)") then fail("Not back at the menu") end
    event("char", "q")
    term.redirect(old)
    if coroutine.status(co) ~= "dead" then error("The menus didn't quit", 0) end
    messages = net.cell.messages()
    if messages[#messages].read ~= true then error("The message wasn't read: " .. textutils.serialise(messages), 0) end
end
if not shell.run("cell", "networks") then error("Couldn't list the networks", 0) end

-- Told to use its own network, it goes home. (Left to choose, it would stay on VISIT here, whose cell is the stronger:
-- a roaming phone only goes home once its own network is stronger.)
if not shell.run("cell", "network", "HOME") then error("Couldn't send the phone home", 0) end
info = wait_for("Going home", function(now) return now.state == "attached" and not now.roaming end, 30)
if info.serving_network ~= "HOME" or info.address ~= addr then error("Wrong service at home: " .. textutils.serialise(info), 0) end
time, ping_err = net.ping("10.64.0.1", 2)
if not time then error("No answer from the gateway at home: " .. tostring(ping_err), 0) end

-- Left to choose again, it stays at home, though VISIT's cell is stronger: it only leaves its own network when it
-- loses it.
if not shell.run("cell", "network", "auto") then error("Couldn't let the phone choose", 0) end
sleep(6)
info = net.cell.info()
if info.state ~= "attached" or info.roaming or info.serving_network ~= "HOME" then
    error("Didn't stay at home: " .. textutils.serialise(info), 0)
end

local errors = net.getErrors()
if #errors > 0 then error("Network errors: " .. table.concat(errors, "; "), 0) end
