-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is the network's core, and a cell, both running in the background. The phone reaches it over the air;
-- the cable is only for passing it its activation code.
net.setAddress(peripheral.getName(peripheral.find("modem", function(_, modem) return not modem.isWireless() end)), "10.0.0.2/24")
if not shell.run("cellcore", "setup", "TEST", "10.64.0.0/16") then error("Couldn't set the core up", 0) end
if not shell.run("cellcore", "add", "TEST-1", "100", "code.txt") then error("Couldn't make a code", 0) end
if not shell.run("celld", "127.0.0.1") then error("Couldn't start the cell", 0) end
local info = net.cell.cellInfo()
if info.state ~= "serving" then error("The cell isn't serving: " .. tostring(info.state) .. " " .. tostring(info.error), 0) end

-- Hand the phone its code.
local listener = assert(net.tcp.listen(9030))
local connection = listener:accept()
local file = fs.open("code.txt", "r")
connection:send(file.readAll())
file.close()
connection:close()

-- Then the phone asks to manage the core. Allow it, by the key the core shows.
local admin = assert(net.secure.connect("127.0.0.1", 2123))
admin:send({ role = "admin", id = os.getComputerID() })
local reply = admin:receive(5)
if type(reply) ~= "table" or not reply.ok then error("Couldn't manage the core: " .. textutils.serialise(reply), 0) end
local key
while not key do
    admin:send({ op = "status" })
    local status = admin:receive(5)
    for _, waiting in ipairs(status.waiting) do
        if waiting.role == "admin" then key = waiting.key end
    end
    if not key then sleep(0.5) end
end
admin:close()
if not shell.run("cellcore", "allow", key, "phone") then error("Couldn't allow the phone", 0) end
