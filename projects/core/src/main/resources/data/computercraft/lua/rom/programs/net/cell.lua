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

local command = args[1]
if command == nil then
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
