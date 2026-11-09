-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local modem = peripheral.getName(peripheral.find("modem"))
net.setAddress(modem, "10.0.0.2/24")

-- The network stack answers pings in the background.
while true do os.pullEvent() end
