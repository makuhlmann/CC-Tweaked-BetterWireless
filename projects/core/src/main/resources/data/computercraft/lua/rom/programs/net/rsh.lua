-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local remote_term = require "cc.internal.net.remote_term"

local PORT = remote_term.PORT

local args = { ... }
if #args < 1 then
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name .. " <host>")
    print(name .. " <host> <command>")
    return
end

local host = table.remove(args, 1)
local command = #args > 0 and table.concat(args, " ") or nil

local connection, err = net.secure.connect(host, PORT)
if not connection then
    printError(("Cannot connect to %s: %s"):format(host, err))
    return
end

-- As SSH does, say when we've learnt a computer's key: this is the one moment someone could pretend to be it.
if connection:getTrust() == "new" then
    print(("First connection to %s. Its key's fingerprint is %s, which is remembered: you'll be told if it changes.")
        :format(host, net.fingerprint(connection:getPeerKey())))
end

local width, height = term.getSize()
local x, y = term.getCursorPos()
connection:send({
    width = width, height = height, colour = term.isColour(), x = x, y = y, command = command, name = os.getComputerLabel(),
})

-- Log in, giving the password if the other computer asks for it.
while true do
    local reply, reply_err = connection:receive(30)
    if type(reply) ~= "table" then
        printError("No answer from " .. host .. (reply_err and (": " .. reply_err) or ""))
        connection:abort()
        return
    end
    if reply.auth == "ok" then break end
    if reply.auth == "denied" then
        printError(tostring(reply.reason or "Not allowed to log in."))
        connection:close()
        return
    end
    if reply.auth == "password" then
        write(("Password for %s: "):format(host))
        connection:send({ password = read("*") })
    end
end

-- Forward this computer's input, and draw what the other computer sends.
local FORWARD = {
    key = true, key_up = true, char = true, paste = true, terminate = true,
    mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true,
}
local finished, succeeded, reason = false, nil, nil
-- Ctrl+T is for the other computer, so nothing here may treat it as a reason to stop.
local pull_event = os.pullEvent
os.pullEvent = os.pullEventRaw
local ok, session_err = pcall(parallel.waitForAny,
    function()
        while true do
            local message, message_err = connection:receive()
            if type(message) ~= "table" then
                reason = message_err
                return
            end
            if message.term then remote_term.apply(term.current(), message.term) end
            if message.exit then
                finished, succeeded = true, message.ok
                return
            end
        end
    end,
    function()
        while true do
            local event = table.pack(os.pullEventRaw())
            if FORWARD[event[1]] then
                connection:send({ event = { table.unpack(event, 1, event.n) } })
            elseif event[1] == "term_resize" then
                connection:send({ resize = { term.getSize() } })
            end
        end
    end
)
os.pullEvent = pull_event
connection:close()
if not ok then error(session_err, 0) end

term.setCursorBlink(false)
if not finished then
    printError(("Connection to %s lost%s"):format(host, reason and (": " .. reason) or ""))
elseif not command then
    print(("Connection to %s closed."):format(host))
elseif succeeded == false then
    printError("The command failed.")
end
