-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local modem = peripheral.getName(peripheral.find("modem"))
net.setPassphrase(modem, "test passphrase")
net.setAddress(modem, "10.2.0.2/24")
settings.set("net.gateway", "10.2.0.1")
net.reload()
fs.delete("rsh-proof")
local hello = fs.open("hello.lua", "w")
hello.write('print("Hello from far")')
hello.close()

parallel.waitForAll(
    -- The remote shell server.
    function() shell.run("rshd") end,
    -- Allow whichever computer sends its key.
    function()
        local listener = assert(net.tcp.listen(9010))
        local connection = listener:accept()
        local key = connection:receive(10)
        shell.run("rshd", "allow", key, "main")
        connection:send(true)
        connection:close()
    end,
    -- Say whether rsh made the directory.
    function()
        local listener = assert(net.tcp.listen(9011))
        local connection = listener:accept()
        connection:send(fs.isDir("rsh-proof"))
        connection:close()
    end
)
