-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is the network's core, and a cell. The phone reaches it over the air; the cable is only for passing it
-- its activation code.
net.setAddress(peripheral.getName(peripheral.find("modem", function(_, modem) return not modem.isWireless() end)), "10.0.0.2/24")
shell.run("cellcore", "setup", "TEST", "10.64.0.0/16")
shell.run("cellcore", "add", "TEST-1", "100", "code.txt")

parallel.waitForAll(
    function() shell.run("cellcore") end,
    function()
        sleep(1)
        shell.run("celld", "127.0.0.1")
    end,
    function()
        local listener = assert(net.tcp.listen(9030))
        local connection = listener:accept()
        local file = fs.open("code.txt", "r")
        connection:send(file.readAll())
        file.close()
        connection:close()
    end
)
