-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local PORT = 115
local CHUNK = require "cc.internal.net.stream".CHUNK

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name .. " <file> <host> [name]")
    print(name .. " receive [directory]")
end

-- Show how far along a copy is, on one line.
local function progress(done, total, started)
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
    local elapsed = math.max(os.clock() - started, 0.05)
    term.write(("%d%%  %d KiB  %.1f KiB/s"):format(total > 0 and math.floor(done * 100 / total) or 100,
        math.floor(done / 1024), done / 1024 / elapsed))
end

local function receive_files(directory)
    directory = shell.resolve(directory or "")
    if not fs.isDir(directory) then
        printError(directory .. " isn't a directory")
        return
    end

    local listener, err = net.tcp.listen(PORT)
    if not listener then
        printError("Cannot receive files: " .. err)
        return
    end
    print(("Receiving files into /%s. Press Ctrl+T to stop."):format(directory))

    -- Receive one file, returning an error message if it didn't work out.
    local function receive_one(connection)
        local header = connection:receive(10)
        if type(header) ~= "table" or type(header.name) ~= "string" or type(header.size) ~= "number" then
            return "Not a file"
        end

        -- Only ever write into the directory, whatever name the sender gives.
        local name = fs.getName(header.name)
        if name == "" or name == "." or name == ".." or name ~= header.name:match("[^/\\]*$") then
            connection:send({ ok = false, error = "Invalid file name" })
            return "Invalid file name " .. header.name
        end
        local path = fs.combine(directory, name)
        if fs.exists(path) then
            connection:send({ ok = false, error = name .. " already exists" })
            return name .. " already exists"
        end
        if fs.isReadOnly(path) or fs.getFreeSpace(directory) < header.size then
            connection:send({ ok = false, error = "Not enough space for " .. name })
            return "Not enough space for " .. name
        end
        local file, open_err = fs.open(path, "wb")
        if not file then
            connection:send({ ok = false, error = open_err or ("Cannot write " .. name) })
            return open_err or ("Cannot write " .. name)
        end
        connection:send({ ok = true })

        local input, size = net.stream(connection), 0
        local ok, read_err = pcall(function()
            while true do
                local data = input.read(CHUNK)
                if not data then break end
                size = size + #data
                if size > header.size then error("Sent more than it said it would", 0) end
                file.write(data)
            end
        end)
        file.close()

        if ok and size ~= header.size then ok, read_err = false, ("Expected %d bytes, got %d"):format(header.size, size) end
        if not ok then
            fs.delete(path)
            connection:send({ ok = false, error = read_err })
            return read_err
        end
        connection:send({ ok = true, size = size })
        print(("Received %s (%d bytes) from %s"):format(name, size, (connection:getPeer())))
    end

    local ok, result = pcall(function()
        while true do
            local connection = listener:accept()
            local done, err = pcall(receive_one, connection)
            if not done then err = tostring(err) end
            if err then printError(("From %s: %s"):format(connection:getPeer(), err)) end
            connection:close()
        end
    end)
    listener:close()
    if not ok and result ~= "Terminated" then error(result, 0) end
end

local function send_file(path, host, name)
    path = shell.resolve(path)
    if not fs.exists(path) or fs.isDir(path) then
        printError("No such file: " .. path)
        return
    end
    name = name or fs.getName(path)
    local size = fs.getSize(path)

    local connection, err = net.tcp.connect(host, PORT)
    if not connection then
        printError(("Cannot connect to %s: %s"):format(host, err))
        return
    end

    local ok, result = pcall(function()
        connection:send({ name = name, size = size })
        local reply, reply_err = connection:receive(10)
        if type(reply) ~= "table" then return reply_err or "No answer" end
        if not reply.ok then return tostring(reply.error) end

        print(("Sending %s (%d bytes) to %s"):format(name, size, host))
        local started, sent = os.clock(), 0
        local file = fs.open(path, "rb")
        local output = net.stream(connection)
        local sent_ok, send_err = pcall(function()
            while true do
                local data = file.read(CHUNK)
                if not data then break end
                output.write(data)
                sent = sent + #data
                progress(sent, size, started)
            end
            output.flush()
        end)
        file.close()
        print()
        if not sent_ok then return send_err end
        connection:close()

        -- The receiver says whether everything arrived.
        reply, reply_err = connection:receive(30)
        if type(reply) ~= "table" then return reply_err or "No answer" end
        if not reply.ok then return tostring(reply.error) end
        print(("Done in %.1f seconds."):format(os.clock() - started))
    end)
    connection:close()
    if not ok then
        if result ~= "Terminated" then error(result, 0) end
    elseif result then
        printError(result)
    end
end

if args[1] == "receive" and #args <= 2 then
    receive_files(args[2])
elseif args[1] and args[2] and #args <= 3 and args[1] ~= "receive" then
    send_file(args[1], args[2], args[3])
else
    usage()
end
