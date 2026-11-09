-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is on a cable with the router. The far computer is on the router's other side, over the air.
local modem = peripheral.getName(peripheral.find("modem"))
net.setAddress(modem, "10.1.0.2/24")
settings.set("net.gateway", "10.1.0.1")
net.reload()

-- The other computers may not be set up yet, so keep trying.
local time, ttl, from
for _ = 1, 15 do
    time, ttl, from = net.ping("10.2.0.2", 1)
    if time then break end
    sleep(0.5)
end
if not time then error("No reply: " .. tostring(ttl), 0) end
if from ~= "10.2.0.2" then error("Reply from " .. tostring(from), 0) end
if ttl ~= 31 then error("Expected the reply to pass one router, but its TTL is " .. tostring(ttl), 0) end

-- A request which may only reach the router is answered by the router, as traceroute relies on.
sleep(1)
local ok, err
ok, err, from = net.ping("10.2.0.2", 1, 1)
if ok or err ~= "TTL expired" or from ~= "10.1.0.1" then
    error(("Expected TTL expired from 10.1.0.1, got %s, %s, %s"):format(tostring(ok), tostring(err), tostring(from)), 0)
end
