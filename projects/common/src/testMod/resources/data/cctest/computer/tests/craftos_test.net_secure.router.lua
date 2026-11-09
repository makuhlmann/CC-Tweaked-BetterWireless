-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local function find(wireless)
    return peripheral.getName(peripheral.find("modem", function(_, modem) return modem.isWireless() == wireless end))
end

net.setAddress(find(false), "10.1.0.1/24")
-- The radio link is encrypted: only computers with the passphrase can use it.
net.setPassphrase(find(true), "test passphrase")
net.setAddress(find(true), "10.2.0.1/24")
settings.set("net.forwarding", true)
net.reload()

-- The network stack forwards packets in the background.
while true do os.pullEvent() end
