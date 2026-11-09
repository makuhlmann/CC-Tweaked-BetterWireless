-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"

local args = { ... }
if #args > 1 then
    print("Usage: " .. (arg[0] or fs.getName(shell.getRunningProgram())) .. " [interface]")
    return
end
local only = args[1]

local function addr(value)
    return type(value) == "number" and address.format(value) or "?"
end

local function describe_body(frame)
    local body = frame.body
    if type(body) ~= "table" then return tostring(frame.type) end

    if frame.type == "nd" then
        return ("nd %s %s"):format(tostring(body.op), addr(body.addr))
    elseif frame.type == "ip" then
        local text = ("%s > %s %s"):format(addr(body.src), addr(body.dst), tostring(body.proto))
        local inner = body.body
        if body.proto == "icmp" and type(inner) == "table" then
            text = text .. " " .. tostring(inner.type)
            if inner.code then text = text .. " " .. tostring(inner.code) end
        end
        return text
    end
    return tostring(frame.type)
end

local function show(direction, interface, frame, signal)
    local dst = frame.dst == -1 and "all" or "#" .. tostring(frame.dst)
    local line = ("%-3s %s #%s>%s %s"):format(direction, interface, tostring(frame.src), dst, describe_body(frame))
    if signal then line = line .. (" (%d dBm)"):format(math.floor(signal + 0.5)) end

    if term.isColour() then term.setTextColour(direction == "in" and colours.lightBlue or colours.lime) end
    print(line)
    term.setTextColour(colours.white)
end

print("Capturing frames" .. (only and " on " .. only or "") .. ". Press Ctrl+T to stop.")

net.capture(true)
local renew = os.startTimer(10)
local ok, err = pcall(function()
    while true do
        local event, a, b, c, d = os.pullEvent()
        if event == "net_frame" and (only == nil or b == only) then
            show(a, b, c, d)
        elseif event == "timer" and a == renew then
            net.capture(true)
            renew = os.startTimer(10)
        end
    end
end)
net.capture(false)

if not ok and err ~= "Terminated" then error(err, 0) end
