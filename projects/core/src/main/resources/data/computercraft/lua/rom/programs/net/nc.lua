-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name .. " <host> <port>")
    print(name .. " -l <port>")
    print(name .. " -u <host> <port>")
    print(name .. " -u -l <port>")
end

local datagrams, listening = false, false
while args[1] == "-u" or args[1] == "-l" do
    if table.remove(args, 1) == "-u" then datagrams = true else listening = true end
end

local host, port
if listening and #args == 1 then
    port = tonumber(args[1])
elseif not listening and #args == 2 then
    host, port = args[1], tonumber(args[2])
end
if not port then
    usage()
    return
end

-- Show a message: text as it is, anything else serialised.
local function show(value, from)
    local text = type(value) == "string" and value or textutils.serialise(value, { compact = true })
    if from then text = from .. ": " .. text end
    print(text)
end

-- Send each line typed, until the program is stopped.
local function typing(send)
    while true do
        local line = read()
        local ok, err = send(line)
        if not ok then
            printError(err)
            return
        end
    end
end

if datagrams then
    local socket, err = net.udp.open(listening and port or nil)
    if not socket then
        printError(err)
        return
    end

    local reply_to, reply_port = host, port
    if listening then print(("Listening for datagrams on port %d. Press Ctrl+T to stop."):format(port)) end
    parallel.waitForAny(
        function()
            typing(function(line)
                if not reply_to then return true, print("Nobody to reply to yet.") end
                return socket:send(reply_to, reply_port, line)
            end)
        end,
        function()
            while true do
                local value, from, from_port = socket:receive()
                if listening then reply_to, reply_port = from, from_port end
                show(value, ("%s:%d"):format(from, from_port))
            end
        end
    )
    socket:close()
    return
end

local connection, err
if listening then
    local listener
    listener, err = net.tcp.listen(port)
    if not listener then
        printError(err)
        return
    end
    print(("Waiting for a connection on port %d. Press Ctrl+T to stop."):format(port))
    local ok, result = pcall(listener.accept, listener)
    listener:close()
    if not ok then error(result, 0) end
    connection = result
    print(("Connected to %s:%d"):format(connection:getPeer()))
else
    connection, err = net.tcp.connect(host, port)
    if not connection then
        printError(err)
        return
    end
    print(("Connected to %s:%d. Press Ctrl+T to stop."):format(connection:getPeer()))
end

local ok, result = pcall(parallel.waitForAny,
    function() typing(function(line) return connection:send(line) end) end,
    function()
        while true do
            local value, reason = connection:receive()
            if value == nil then
                if reason then printError(reason) else print("The other side closed the connection.") end
                return
            end
            show(value)
        end
    end
)
connection:close()
if not ok and result ~= "Terminated" then error(result, 0) end
