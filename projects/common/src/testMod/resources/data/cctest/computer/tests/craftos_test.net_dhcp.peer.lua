-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DHCP and DNS server for the zone "test", whose names are in /zones/test.txt. DHCP's clients' names are registered
-- in it too.
local modem = peripheral.getName(peripheral.find("modem"))
net.setAddress(modem, "10.0.0.1/24")

local function write(path, text)
    local file = assert(fs.open(path, "w"))
    file.write(text)
    file.close()
end
write("/etc/dnsd.conf", "zone test /zones/test.txt\n")
write("/etc/dhcpd.conf", ("interface %s\ndns 10.0.0.1\ndomain test\nupdate-server 127.0.0.1\n"):format(modem))

parallel.waitForAny(
    function() shell.run("dhcpd", "run") end,
    function() shell.run("dnsd", "run") end
)
