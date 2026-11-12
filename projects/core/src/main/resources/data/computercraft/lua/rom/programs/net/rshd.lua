-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local remote_term = require "cc.internal.net.remote_term"

local PORT = require "cc.internal.net.remote_term".PORT
local AUTHORIZED = "/.net/authorized_keys"
local PASSWORD = "/.net/rshd_password"
local MAX_TRIES = 3

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " password [none]")
    print(name .. " keys")
    print(name .. " allow <key> [label]")
    print(name .. " deny <key|label>")
end

local files = require "cc.internal.net.files"
local read_table, write_table, to_hex = files.read_table, files.write_table, files.hex.encode

local function hash_password(password, salt)
    return to_hex(crypto.pbkdf2(password, salt, 20000, 32))
end

-- Check a password against the saved one, taking the same time whether or not it's right.
local function check_password(password)
    local saved = read_table(PASSWORD)
    if type(saved.salt) ~= "string" or type(saved.hash) ~= "string" or type(password) ~= "string" then return false end
    return crypto.equals(hash_password(password, saved.salt), saved.hash)
end

-- Events which come from this computer's own keyboard, mouse or screen. A remote session only gets the remote ones.
local LOCAL_INPUT = {
    key = true, key_up = true, char = true, paste = true, term_resize = true,
    mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true, monitor_touch = false,
}
local REMOTE_EVENTS = {
    key = true, key_up = true, char = true, paste = true, terminate = true,
    mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true,
}
-- rshd's own events, which the session doesn't get.
local OWN_EVENTS = { rshd_input = true, rshd_output = true, rshd_sent = true }

-- How many batches of drawing may wait to be sent before the session waits for them (each is up to about 32 KiB), and
-- how many events the session may have waiting meanwhile, as a computer's own queue holds.
local MAX_OUTBOX, MAX_HELD_EVENTS = 4, 256

-- Run a shell, or a command, for a client, drawing on its terminal and taking its input.
--
-- What's drawn goes into an outbox, which a task of its own sends from: waiting for room on the connection pulls
-- events, and if the session's task did that, they'd be lost to the session (a `sleep` in it would never end). While
-- the outbox is full, the session's events wait for it, in order.
local function run_session(connection, hello)
    local outbox = {}
    local function send(message)
        outbox[#outbox + 1] = message
        os.queueEvent("rshd_output")
    end
    local remote = remote_term.new({
        width = hello.width, height = hello.height, colour = hello.colour == true, x = hello.x, y = hello.y,
    }, function(operations) send({ term = operations }) end)

    local result
    local session = coroutine.create(function()
        if hello.command then
            result = shell.run(hello.command)
        else
            shell.run("shell")
        end
    end)

    local filter
    local function resume(...)
        local previous = term.redirect(remote)
        local ok, value = coroutine.resume(session, ...)
        term.redirect(previous)
        remote.flush()
        if not ok then
            send({ term = { { "write", tostring(value) } } })
        else
            filter = value
        end
    end

    -- Events for the session, given to it once it wants them and there's room for what it draws.
    local held = {}
    local function offer(event)
        if #held < MAX_HELD_EVENTS then held[#held + 1] = event end
    end
    local function give()
        while held[1] and #outbox < MAX_OUTBOX and coroutine.status(session) ~= "dead" do
            local event = table.remove(held, 1)
            -- Only the client may terminate the session, not this computer's own Ctrl+T.
            if filter == nil or filter == event[1] or event[1] == "terminate" then resume(table.unpack(event, 1, event.n)) end
        end
    end

    local pending = {}
    local closed = false
    parallel.waitForAny(
        -- Messages from the client.
        function()
            while true do
                local message = connection:receive()
                if type(message) ~= "table" then
                    closed = true
                    os.queueEvent("rshd_input")
                    return
                end
                if type(message.event) == "table" and REMOTE_EVENTS[message.event[1]] then
                    pending[#pending + 1] = message.event
                    os.queueEvent("rshd_input")
                elseif type(message.resize) == "table" and type(message.resize[1]) == "number" and type(message.resize[2]) == "number" then
                    remote.resize(message.resize[1], message.resize[2])
                    pending[#pending + 1] = { "term_resize" }
                    os.queueEvent("rshd_input")
                end
            end
        end,
        -- The session, taking the client's input and this computer's other events.
        function()
            resume()
            while coroutine.status(session) ~= "dead" and not closed do
                local event = table.pack(os.pullEventRaw())
                if event[1] == "rshd_input" then
                    while pending[1] do
                        local remote_event = table.remove(pending, 1)
                        offer(table.pack(table.unpack(remote_event)))
                    end
                elseif not OWN_EVENTS[event[1]] and not LOCAL_INPUT[event[1]] and event[1] ~= "terminate" then
                    offer(event)
                end
                give()
            end
        end,
        -- What the session drew, to the client. A batch which can't be sent would leave the client's screen out of
        -- step with the session's for good, so that ends the session.
        function()
            while true do
                local message = table.remove(outbox, 1)
                if message then
                    if not connection:send(message) then
                        closed = true
                        return
                    end
                    os.queueEvent("rshd_sent")
                else
                    os.pullEvent("rshd_output")
                end
            end
        end
    )

    -- Send what's still to go, and then say the session is over.
    for _, message in ipairs(outbox) do
        if closed then break end
        if not connection:send(message) then closed = true end
    end
    if not closed then connection:send({ exit = true, ok = result }) end
    connection:close()
end

-- Find out whether a client may log in, asking for the password if need be.
local function authorise(connection, hello)
    local key = connection:getPeerKey()
    local authorized = read_table(AUTHORIZED)
    if authorized[key] then return true end

    if not fs.exists(PASSWORD) then
        connection:send({ auth = "denied", reason = "This computer doesn't know yours, and has no password set." })
        return false
    end

    for _ = 1, MAX_TRIES do
        connection:send({ auth = "password" })
        local reply = connection:receive(60)
        if type(reply) ~= "table" then return false end
        if check_password(reply.password) then
            -- Remember this computer, so it needn't give the password again.
            local label = type(hello.name) == "string" and hello.name:sub(1, 64) or connection:getPeer()
            authorized[key] = label
            write_table(AUTHORIZED, authorized)
            return true
        end
    end
    connection:send({ auth = "denied", reason = "Wrong password." })
    -- Make guessing slow.
    sleep(3)
    return false
end

local function serve()
    if not crypto or not enclave then
        printError("rshd needs the crypto and enclave APIs, which are turned off on this server")
        return
    end
    local listener, err = net.secure.listen(PORT)
    if not listener then
        printError("Cannot start the remote shell server: " .. err)
        return
    end
    print(("Waiting for remote shells on port %d. Press Ctrl+T to stop."):format(PORT))

    local ok, result = pcall(function()
        while true do
            local connection = listener:accept()
            local peer = connection:getPeer()
            local hello = connection:receive(10)
            if type(hello) == "table" and type(hello.width) == "number" and type(hello.height) == "number"
                and (hello.command == nil or type(hello.command) == "string") then
                if authorise(connection, hello) then
                    connection:send({ auth = "ok" })
                    print(("%s: %s"):format(peer, hello.command or "shell"))
                    local session_ok, session_err = pcall(run_session, connection, hello)
                    if not session_ok and session_err ~= "Terminated" then printError(session_err) end
                    if not session_ok and session_err == "Terminated" then error(session_err, 0) end
                else
                    print(peer .. ": refused")
                end
            end
            connection:close()
        end
    end)
    listener:close()
    if not ok and result ~= "Terminated" then error(result, 0) end
end

local command = args[1]
if command == nil then
    serve()
elseif command == "password" and #args <= 2 then
    if args[2] == "none" then
        fs.delete(PASSWORD)
        print("Password removed: only computers already allowed can log in.")
        return
    end
    write("New password: ")
    local password = read("*")
    write("Again: ")
    if read("*") ~= password then
        printError("The passwords are different.")
        return
    end
    if password == "" then
        printError("The password can't be empty.")
        return
    end
    local salt = to_hex(crypto.random(16))
    write_table(PASSWORD, { salt = salt, hash = hash_password(password, salt) })
    print("Password set. A computer which logs in with it is remembered.")
elseif command == "keys" and #args == 1 then
    local authorized = read_table(AUTHORIZED)
    local any = false
    for key, label in pairs(authorized) do
        print(("%s  %s"):format(net.fingerprint(key), tostring(label)))
        any = true
    end
    if not any then print("No computers are allowed yet.") end
elseif command == "allow" and (#args == 2 or #args == 3) then
    local key = args[2]:lower()
    if #key ~= 64 or key:find("[^%x]") then
        printError("Expected a key of 64 hexadecimal digits, as 'netkeys' shows.")
        return
    end
    local authorized = read_table(AUTHORIZED)
    authorized[key] = args[3] or "added by hand"
    write_table(AUTHORIZED, authorized)
    print("Allowed " .. net.fingerprint(key))
elseif command == "deny" and #args == 2 then
    local authorized, removed = read_table(AUTHORIZED), 0
    for key, label in pairs(authorized) do
        if key == args[2]:lower() or label == args[2] then
            authorized[key] = nil
            removed = removed + 1
        end
    end
    write_table(AUTHORIZED, authorized)
    print(removed > 0 and "Removed." or "No such computer.")
else
    usage()
end
