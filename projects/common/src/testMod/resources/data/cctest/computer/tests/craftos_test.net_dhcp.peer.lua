-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- A DHCP and DNS server for the zone "test".
local modem = peripheral.getName(peripheral.find("modem"))
net.setAddress(modem, "10.0.0.1/24")
settings.set("dhcpd.dns", "10.0.0.1")
settings.set("dhcpd.domain", "test")

parallel.waitForAny(
    function() shell.run("dhcpd", modem) end,
    function() shell.run("dnsd", "test", "/zones/test.txt") end
)
