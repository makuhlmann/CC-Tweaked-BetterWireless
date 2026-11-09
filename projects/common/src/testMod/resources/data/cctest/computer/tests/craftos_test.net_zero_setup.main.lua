-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local modem = peripheral.getName(peripheral.find("modem"))

-- Nothing is set up, so after DHCP gives up (about six seconds), we should have a link-local address.
local mine
for _ = 1, 40 do
    mine = net.getAddress(modem)
    if mine then break end
    sleep(0.5)
end
if not mine or not mine:find("^169%.254%.") then error("No link-local address: " .. tostring(mine), 0) end

-- And find the other computer by its name, which comes from its label.
local peer = "craftos-test-net-zero-setup-peer.local"
local addr, err
for _ = 1, 10 do
    addr, err = net.resolve(peer)
    if addr then break end
    sleep(1)
end
if not addr then error("Cannot resolve " .. peer .. ": " .. tostring(err), 0) end

local time
time, err = net.ping(peer)
if not time then error("No reply from " .. peer .. ": " .. tostring(err), 0) end
