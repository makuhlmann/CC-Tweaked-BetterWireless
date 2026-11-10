-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- This computer is a phone. It gets its activation code over the cable, then does everything else over the air.
net.setAddress(peripheral.getName(peripheral.find("modem", function(_, modem) return not modem.isWireless() end)), "10.0.0.1/24")

local connection, err
for _ = 1, 20 do
    connection, err = net.tcp.connect("10.0.0.2", 9030, 1)
    if connection then break end
    sleep(0.5)
end
if not connection then error("Couldn't get a code: " .. tostring(err), 0) end
local code = connection:receive(10)
connection:close()

shell.run("cell", "activate", "TEST", code)
local info = net.cell.info()
if info.state ~= "attached" then error("Not attached: " .. tostring(info.state) .. " " .. tostring(info.activation_error), 0) end
if info.subscriber.number ~= "100" then error("Wrong number " .. tostring(info.subscriber.number), 0) end

-- The gateway answers, through the cell.
local time, ping_err = net.ping("10.64.0.1", 2)
if not time then error("No answer from the gateway: " .. tostring(ping_err), 0) end

-- A message to ourselves goes through the core and comes back.
assert(net.cell.send("100", "Hello from the test"))
local timer = os.startTimer(10)
while true do
    local event, from, text = os.pullEvent()
    if event == "cell_message" then
        if from ~= "100" or text ~= "Hello from the test" then error("Got " .. tostring(text) .. " from " .. tostring(from), 0) end
        break
    elseif event == "timer" and from == timer then
        error("The message didn't arrive", 0)
    end
end
