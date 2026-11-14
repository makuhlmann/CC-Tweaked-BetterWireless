-- SPDX-FileCopyrightText: 2017 Daniel Ratcliffe
--
-- SPDX-License-Identifier: LicenseRef-CCPL

-- How often a host sends its position, in seconds.
local INTERVAL = 2

local function printUsage()
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(programName .. " host [power <dBm>]")
    print(programName .. " host <x> <y> <z> [power <dBm>]")
    print(programName .. " locate")
end

local tArgs = { ... }
if #tArgs < 1 then
    printUsage()
    return
end

 local sCommand = tArgs[1]
if sCommand == "locate" then
    -- "gps locate"
    -- Just locate this computer (this will print the results)
    gps.locate(5, true)

elseif sCommand == "host" then
    -- "gps host"
    -- Act as a GPS host
    if pocket then
        print("GPS Hosts must be stationary")
        return
    end

    -- The position, if given, and then the power to send with, if given.
    local x, y, z, nPower
    local nNext = 2
    if #tArgs >= 4 and tArgs[2] ~= "power" then
        x, y, z = tonumber(tArgs[2]), tonumber(tArgs[3]), tonumber(tArgs[4])
        if x == nil or y == nil or z == nil then
            printUsage()
            return
        end
        nNext = 5
    end
    if tArgs[nNext] ~= nil then
        nPower = tArgs[nNext] == "power" and tonumber(tArgs[nNext + 1])
        if not nPower or tArgs[nNext + 2] ~= nil then
            printUsage()
            return
        end
    end

    -- Find a modem
    local sModemSide = nil
    for _, sSide in ipairs(rs.getSides()) do
        if peripheral.getType(sSide) == "modem" and peripheral.call(sSide, "isWireless") then
            sModemSide = sSide
            break
        end
    end

    if sModemSide == nil then
        print("No wireless modems found. 1 required.")
        return
    end

    -- Determine position
    if x then
        print("Position is " .. x .. "," .. y .. "," .. z)
    else
        -- Position is to be determined using locate
        x, y, z = gps.locate(5, true)
        if x == nil then
            print("Run \"gps host <x> <y> <z>\" to set position manually")
            return
        end
    end

    local modem = peripheral.wrap(sModemSide)
    if nPower then
        print(("Transmitting at %.1f dBm"):format(modem.setTransmitPower(nPower)))
    end

    -- Send our position on the GPS channel every two seconds, indefinitely, for anyone listening. Hosts start at a
    -- moment of their own, so they don't all send at once, and keep to their time.
    print("Sending position on modem " .. sModemSide)
    local nServed, nAt = 0, os.clock() + math.random() * INTERVAL
    local timer = os.startTimer(nAt - os.clock())
    while true do
        local _, id = os.pullEvent("timer")
        if id == timer then
            modem.transmit(gps.CHANNEL_GPS, gps.CHANNEL_GPS, { x, y, z })

            nAt = math.max(nAt + INTERVAL, os.clock())
            timer = os.startTimer(nAt - os.clock())

            -- Print the number of times we've sent it
            nServed = nServed + 1
            if nServed > 1 then
                local _, y = term.getCursorPos()
                term.setCursorPos(1, y - 1)
            end
            print("Position sent " .. nServed .. " times")
        end
    end
else
    -- "gps somethingelse"
    -- Error
    printUsage()
end
