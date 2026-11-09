-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is on a cable with the router. The far computer is over an encrypted radio link on its other side.
net.setAddress(peripheral.getName(peripheral.find("modem")), "10.1.0.2/24")
settings.set("net.gateway", "10.1.0.1")
net.reload()

-- Tell the far computer our key, so it lets us log in.
local connection, err
for _ = 1, 20 do
    connection, err = net.tcp.connect("10.2.0.2", 9010, 1)
    if connection then break end
    sleep(0.5)
end
if not connection then error("Couldn't connect: " .. tostring(err), 0) end
connection:send(net.getIdentity())
local allowed = connection:receive(10)
connection:close()
if allowed ~= true then error("The far computer didn't allow us: " .. tostring(allowed), 0) end

-- Run a command there with rsh.
shell.run("rsh", "10.2.0.2", "mkdir", "rsh-proof")

local check = assert(net.tcp.connect("10.2.0.2", 9011, 5))
local made = check:receive(10)
check:close()
if made ~= true then error("rsh didn't make the directory", 0) end

-- What a remote command prints appears on this computer's terminal.
local width, height = term.getSize()
local screen = window.create(term.current(), 1, 1, width, height, false)
local previous = term.redirect(screen)
shell.run("rsh", "10.2.0.2", "hello")
term.redirect(previous)
local seen = false
for y = 1, height do
    if screen.getLine(y):find("Hello from far", 1, true) then seen = true end
end
if not seen then error("The remote command's output didn't appear", 0) end

-- We know the far computer's key now, and a secure connection to it is still trusted.
local secure = assert(net.secure.connect("10.2.0.2", 22))
if secure:getTrust() ~= "known" then error("Expected to know the key, but trust is " .. tostring(secure:getTrust()), 0) end
secure:abort()
