-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The ping program", function()
    local capture = require "test_helpers".capture_program

    -- A pinger which gives what the script says each time it's waited on: a reply; "wait", for nothing until the time
    -- given has passed (on a pretend clock); or "terminate", as Ctrl+T does.
    --
    -- The pretend clock starts at the real one and only goes forward: everything else on this computer sees it too
    -- (the network stack's loop, for one), and would wait far too long for a time which had gone back.
    local function fake_pinger(script, failures)
        local start = os.clock()
        local clock = start
        stub(os, "clock", function() return clock end)
        -- Times since the start, in whole thousandths, as adding to the real clock's time isn't exact.
        local function round(time) return math.floor(time * 1000 + 0.5) / 1000 end
        local pinger = { sends = {}, waits = {}, closed = false }
        stub(net, "pinger", function(target)
            if target == "nowhere" then return nil, "Name not found" end
            pinger.target = target
            return {
                getAddress = function() return "10.0.0.2" end,
                send = function()
                    pinger.sends[#pinger.sends + 1] = round(clock - start)
                    local seq = #pinger.sends
                    return seq, failures and failures[seq] or nil
                end,
                receive = function(_, timeout)
                    pinger.waits[#pinger.waits + 1] = round(timeout)
                    local step = table.remove(script, 1)
                    if step == "wait" then
                        clock = clock + timeout
                        return nil
                    elseif step == "terminate" then
                        error("Terminated", 0)
                    elseif step == nil then
                        error("The script ran out", 0)
                    end
                    return step
                end,
                close = function() pinger.closed = true end,
            }
        end)
        return pinger
    end

    local function reply(seq, time, duplicate)
        return { seq = seq, from = "10.0.0.2", time = time, ttl = 31, duplicate = duplicate or false }
    end

    it("checks its arguments", function()
        expect(capture("/rom/programs/net/ping.lua").output):str_match("^Usage: %S*ping%S* <address> %[count%]\n$")
        for _, count in ipairs { "0", "-1", "1.5", "lots" } do
            expect(capture("/rom/programs/net/ping.lua", "10.0.0.2", count))
                :matches { ok = true, output = "", error = "Count must be a whole number, from 1.\n" }
        end
        fake_pinger({})
        expect(capture("/rom/programs/net/ping.lua", "nowhere"))
            :matches { ok = true, output = "", error = "nowhere: Name not found\n" }
    end)

    it("pings every second until it's terminated, shows every reply, and then sums up", function()
        local pinger = fake_pinger {
            "wait",
            -- The second request's reply comes first, then the first's, twice.
            reply(2, 0.2), reply(1, 1.3), reply(1, 1.3, true),
            "wait",
            { seq = 3, from = "10.0.0.1", error = "Host unreachable" },
            "terminate",
        }
        expect(capture("/rom/programs/net/ping.lua", "example")):matches {
            ok = true, error = "",
            output = "PING example (10.0.0.2)\n" ..
                "Reply from 10.0.0.2: seq=2 ttl=31 time=200 ms\n" ..
                "Reply from 10.0.0.2: seq=1 ttl=31 time=1300 ms\n" ..
                "Reply from 10.0.0.2: seq=1 ttl=31 time=1300 ms (DUP!)\n" ..
                "From 10.0.0.1: seq=3 Host unreachable\n" ..
                "--- example ping statistics ---\n" ..
                "3 sent, 2 received, +1 duplicate, +1 error, 33% loss\n" ..
                "time min/avg/max = 200/750/1300 ms\n",
        }
        expect(pinger.sends):same { 0, 1, 2 }
        expect(pinger.closed):eq(true)
    end)

    it("stops after a count, waiting a little for the last replies", function()
        local pinger = fake_pinger { reply(1, 0.1), "wait", "wait" }
        expect(capture("/rom/programs/net/ping.lua", "10.0.0.2", "2")):matches {
            ok = true, error = "",
            output = "PING 10.0.0.2\n" ..
                "Reply from 10.0.0.2: seq=1 ttl=31 time=100 ms\n" ..
                "--- 10.0.0.2 ping statistics ---\n" ..
                "2 sent, 1 received, 50% loss\n" ..
                "time min/avg/max = 100/100/100 ms\n",
        }
        -- A second for the first request, then a second (twice the longest round trip, but at least one) for the last.
        expect(pinger.sends):same { 0, 1 }
        expect(pinger.waits):same { 1, 1, 1 }
    end)

    it("waits longer for the last replies when none came, and counts requests which couldn't be sent", function()
        local pinger = fake_pinger({ "wait", "wait", "wait", "wait" }, { [2] = "Network unreachable" })
        expect(capture("/rom/programs/net/ping.lua", "10.0.0.2", "3")):matches {
            ok = true, error = "seq=2: Network unreachable\n",
            output = "PING 10.0.0.2\n" ..
                "--- 10.0.0.2 ping statistics ---\n" ..
                "3 sent, 0 received, +1 error, 100% loss\n",
        }
        -- A second after each request, then ten seconds after the last one.
        expect(pinger.sends):same { 0, 1, 2 }
        expect(pinger.waits):same { 1, 1, 1, 9 }
    end)

    it("pings this computer", function()
        expect(capture("/rom/programs/net/ping.lua", "127.0.0.1", "2")):matches {
            ok = true, error = "",
            output = "PING 127.0.0.1\n" ..
                "Reply from 127.0.0.1: seq=1 ttl=32 time=0 ms\n" ..
                "Reply from 127.0.0.1: seq=2 ttl=32 time=0 ms\n" ..
                "--- 127.0.0.1 ping statistics ---\n" ..
                "2 sent, 2 received, 0% loss\n" ..
                "time min/avg/max = 0/0/0 ms\n",
        }
    end)
end)
