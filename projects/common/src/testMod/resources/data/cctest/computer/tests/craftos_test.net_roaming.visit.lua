-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is the core and a cell of another network, VISIT, which carries the phones of HOME.
net.setAddress(peripheral.getName(peripheral.find("modem", function(_, modem) return not modem.isWireless() end)), "10.0.0.3/24")
if not shell.run("cellcore", "setup", "VISIT", "10.65.0.0/16") then error("Couldn't set the core up", 0) end
if not shell.run("celld", "127.0.0.1") then error("Couldn't start the cell", 0) end
if not shell.run("cellcore", "carry", "HOME", "10.0.0.2") then error("Couldn't set roaming up", 0) end
shell.run("cellcore", "roaming")
