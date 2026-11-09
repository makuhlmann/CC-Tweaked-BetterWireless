-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local modem = peripheral.getName(peripheral.find("modem"))
net.setAddress(modem, "10.0.0.1/24")

-- The other computer may not have set its address yet, so keep trying.
local time, err
for _ = 1, 10 do
    time, err = net.ping("10.0.0.2", 1)
    if time then break end
end
if not time then error("No reply: " .. tostring(err), 0) end
