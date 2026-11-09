-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

net.setAddress(peripheral.getName(peripheral.find("modem")), "10.2.0.2/24")
settings.set("net.gateway", "10.2.0.1")
net.reload()

local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
local expected = table.concat(bytes):rep(4096)

fs.delete("received")
fs.makeDir("received")

parallel.waitForAll(
    -- Check the megabyte.
    function()
        local listener = assert(net.tcp.listen(9000))
        local connection = listener:accept()
        local received = net.stream(connection).readAll()
        connection:send({ ok = received == expected, size = received and #received })
        connection:close()
    end,
    -- Receive files with ncp...
    function() shell.run("ncp", "receive", "received") end,
    -- ...and send back the one which arrives.
    function()
        local listener = assert(net.tcp.listen(9001))
        local connection = listener:accept()
        local file = fs.open("received/ncp-test.txt", "r")
        connection:send(file and file.readAll() or false)
        if file then file.close() end
        connection:close()
    end
)
