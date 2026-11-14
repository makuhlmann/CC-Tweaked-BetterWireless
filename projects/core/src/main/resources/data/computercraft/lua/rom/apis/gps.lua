-- SPDX-FileCopyrightText: 2017 Daniel Ratcliffe
--
-- SPDX-License-Identifier: LicenseRef-CCPL

--[[- Use [modems][`modem`] to locate the position of the current turtle or
computers.

This works by listening to other computers (called GPS hosts) that already
know their position, and send it every two seconds. It finds the distance to
those computers (with [`modem_message`]), and uses that to derive its position
from theirs (with a process known as
[trilateration](https://en.wikipedia.org/wiki/Trilateration)). It sends
nothing itself, so it works as far away as the hosts can be heard.

A computer which stays put is found exactly. One which moves while it listens
hears each host from somewhere else, so it is found less well, and
[`gps.locate`] says how far off it may be. Hosts far apart from each other (and
at different heights) give the best positions.

@module gps
@since 1.31
@see gps_setup
]]

local expect = dofile("rom/modules/main/cc/expect.lua").expect
local solver = dofile("rom/modules/main/cc/internal/locate.lua")

--- The channel which GPS hosts send their positions on.
CHANNEL_GPS = 65534

--- Tries to retrieve the computer or turtles own location.
--
-- It listens for GPS hosts until it hears enough of them to know where it is
-- (or the time is up). Hosts send their positions every two seconds.
--
-- @tparam[opt=3] number timeout The maximum time in seconds taken to establish our
-- position.
-- @tparam[opt=false] boolean debug Print debugging messages
-- @treturn[1] number This computer's `x` position.
-- @treturn[1] number This computer's `y` position.
-- @treturn[1] number This computer's `z` position.
-- @treturn[1] number How far off that position may be, in blocks: 0 if it is
-- exact, as it is for a computer which doesn't move.
-- @treturn[2] nil If the position could not be established.
function locate(_nTimeout, _bDebug)
    expect(1, _nTimeout, "number", "nil")
    expect(2, _bDebug, "boolean", "nil")
    -- Let command computers use their magic fourth-wall-breaking special abilities
    if commands then
        local x, y, z = commands.getBlockPosition()
        return x, y, z, 0
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
        if _bDebug then
            print("No wireless modem attached")
        end
        return nil
    end

    if _bDebug then
        print("Finding position...")
    end

    -- Open GPS channel to listen for hosts
    local modem = peripheral.wrap(sModemSide)
    local bCloseChannel = false
    if not modem.isOpen(CHANNEL_GPS) then
        modem.open(CHANNEL_GPS)
        bCloseChannel = true
    end

    -- Listen to the hosts. Each fix is a host's position, how far away it was, and when. A host heard twice says how
    -- fast we are moving towards or away from it, at least.
    local tFixes, nSpeed = {}, 0
    local x, y, z, nError, tOne, tOther
    local timeout = os.startTimer(_nTimeout or 3)
    while true do
        local e, p1, p2, p3, p4, p5 = os.pullEvent()
        if e == "modem_message" then
            local sSide, sChannel, sReplyChannel, tMessage, nDistance = p1, p2, p3, p4, p5
            if sSide == sModemSide and sChannel == CHANNEL_GPS and sReplyChannel == CHANNEL_GPS and type(nDistance) == "number"
                and type(tMessage) == "table" and #tMessage == 3 and tonumber(tMessage[1]) and tonumber(tMessage[2]) and tonumber(tMessage[3]) then
                local tFix = {
                    x = tonumber(tMessage[1]), y = tonumber(tMessage[2]), z = tonumber(tMessage[3]),
                    distance = nDistance, time = os.clock(),
                }
                if _bDebug then
                    print(tFix.distance .. " metres from " .. tFix.x .. "," .. tFix.y .. "," .. tFix.z)
                end
                local sKey = tFix.x .. "," .. tFix.y .. "," .. tFix.z
                local tOlder = tFixes[sKey]
                if tOlder and tFix.time > tOlder.time then
                    nSpeed = math.max(nSpeed, math.abs(tFix.distance - tOlder.distance) / (tFix.time - tOlder.time))
                end
                tFixes[sKey] = tFix

                local tList, nNow = {}, os.clock()
                for _, tHeard in pairs(tFixes) do
                    tList[#tList + 1] = { x = tHeard.x, y = tHeard.y, z = tHeard.z, distance = tHeard.distance, age = nNow - tHeard.time }
                end
                x, y, z, nError = solver.locate(tList, nSpeed)
                if x then
                    break
                elseif y == "ambiguous" then
                    tOne, tOther = z, nError
                end
            end

        elseif e == "timer" then
            -- We received a timeout
            local timer = p1
            if timer == timeout then
                break
            end

        end
    end

    -- Close the channel, if we opened one
    if bCloseChannel then
        modem.close(CHANNEL_GPS)
    end

    os.cancelTimer(timeout)

    -- Return the response
    if x then
        if _bDebug then
            if nError == math.huge then
                print("Position is " .. x .. "," .. y .. "," .. z .. ", but it may be far off: the hosts say little about one direction")
            elseif nError > 0 then
                print("Position is " .. x .. "," .. y .. "," .. z .. ", within " .. nError .. " metres")
            else
                print("Position is " .. x .. "," .. y .. "," .. z)
            end
        end
        return x, y, z, nError
    elseif tOne and tOther then
        if _bDebug then
            print("Ambiguous position")
            print("Could be " .. tOne[1] .. "," .. tOne[2] .. "," .. tOne[3] .. " or " .. tOther[1] .. "," .. tOther[2] .. "," .. tOther[3])
        end
        return nil
    else
        if _bDebug then
            print("Could not determine position")
        end
        return nil
    end
end
