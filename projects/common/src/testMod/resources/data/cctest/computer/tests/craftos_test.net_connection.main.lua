-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is on a cable with the router. The far computer is on the router's other side, over the air.
net.setAddress(peripheral.getName(peripheral.find("modem")), "10.1.0.2/24")
settings.set("net.gateway", "10.1.0.1")
net.reload()

-- The other computers may not be set up yet, so keep trying.
local connection, err
for _ = 1, 20 do
    connection, err = net.tcp.connect("10.2.0.2", 9000, 1)
    if connection then break end
    sleep(0.5)
end
if not connection then error("Couldn't connect: " .. tostring(err), 0) end

-- A megabyte with every byte value in it, which the far computer checks.
local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
local data = table.concat(bytes):rep(4096)

local stream = net.stream(connection)
stream.write(data)
stream.close()
local reply = connection:receive(30)
if type(reply) ~= "table" or not reply.ok then error("Far computer got: " .. textutils.serialise(reply), 0) end

-- Copy a file with ncp, then ask for it back.
local file = fs.open("ncp-test.txt", "w")
file.write(("The quick brown fox.\n"):rep(2000))
file.close()
shell.run("ncp", "ncp-test.txt", "10.2.0.2")

local check = assert(net.tcp.connect("10.2.0.2", 9001, 5))
local copy = check:receive(10)
check:close()
fs.delete("ncp-test.txt")
if copy ~= ("The quick brown fox.\n"):rep(2000) then error("ncp's copy is different: " .. tostring(copy and #copy), 0) end
