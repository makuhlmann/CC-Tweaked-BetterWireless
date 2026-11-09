-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local modem = peripheral.getName(peripheral.find("modem"))

-- The server may start after us. If so, we retry 15 seconds after giving up, so allow a while.
local mine
for _ = 1, 60 do
    mine = net.getAddress(modem)
    if mine and mine:find("^10%.0%.0%.") then break end
    sleep(0.5)
end
if not mine or not mine:find("^10%.0%.0%.1%d%d/24$") then error("No address from DHCP: " .. tostring(mine), 0) end

-- DHCP told us about the DNS server and the "test" domain, so a bare name resolves through the zone file.
local addr, err = net.resolve("server")
if addr ~= "10.0.0.1" then error("Cannot resolve server: " .. tostring(addr or err), 0) end
