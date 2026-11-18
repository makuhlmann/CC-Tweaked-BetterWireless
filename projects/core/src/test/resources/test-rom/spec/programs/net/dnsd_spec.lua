-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The dnsd program", function()
    local capture = require "test_helpers".capture_program

    local function write(path, text)
        local file = fs.open(path, "w")
        file.write(text)
        file.close()
    end

    it("answers from its zone file and DHCP's leases, passing by what it can't read", function()
        write("/zones/home.txt", "bank 10.0.0.5\nnonsense\n")
        write("/.dhcpd/top", textutils.serialise({
            { hostname = "laptop", address = 0x0A000064, expires = os.epoch("utc") / 1000 + 600 },
            -- Changed by hand: no expiry, and no name.
            { hostname = "broken", address = 0x0A000065 },
            { address = 0x0A000066, expires = os.epoch("utc") / 1000 + 600 },
        }))
        -- A folder where a file of leases would be.
        fs.makeDir("/.dhcpd/folder")

        local answers, result = {}, nil
        local ok, err = pcall(parallel.waitForAny,
            function() result = capture("/rom/programs/net/dnsd.lua", "run", "home") end,
            function()
                local socket = assert(net.udp.open())
                for i, name in ipairs { "bank.home", "laptop.home", "broken.home", "bank.home", "bank.home" } do
                    for _ = 1, 20 do
                        socket:send("127.0.0.1", 53, { id = i, name = name, type = "A" })
                        local answer = socket:receive(0.2)
                        if answer then
                            answers[i] = answer.code == "ok" and answer.records[1].value or answer.code
                            break
                        end
                    end
                end
                socket:close()
                -- Stop dnsd, as Ctrl+T would, and let it finish.
                os.queueEvent("terminate")
                while true do os.pullEventRaw() end
            end
        )
        fs.delete("/zones")
        fs.delete("/.dhcpd")
        if not ok then error(err, 0) end

        expect(answers):same { 0x0A000005, 0x0A000064, "not_found", 0x0A000005, 0x0A000005 }
        -- What's wrong with the zone file is said once, not for every question.
        expect(result.error):eq("zones/home.txt: Line 2: expected a name and an address\n")
    end)

    -- Run dnsd with some arguments, ask it some questions, and stop it. Gives each answer's address or code, and what
    -- dnsd printed.
    local function ask(arguments, names)
        local answers, result = {}, nil
        local forward = settings.get("dnsd.forward")
        settings.set("dnsd.forward", "none")
        local ok, err = pcall(parallel.waitForAny,
            function() result = capture("/rom/programs/net/dnsd.lua", table.unpack(arguments)) end,
            function()
                local socket = assert(net.udp.open())
                for i, name in ipairs(names) do
                    for _ = 1, 20 do
                        socket:send("127.0.0.1", 53, { id = i, name = name, type = "A" })
                        local answer = socket:receive(0.2)
                        if answer then
                            answers[i] = answer.code == "ok" and answer.records[1].value or answer.code
                            break
                        end
                    end
                end
                socket:close()
                os.queueEvent("terminate")
                while true do os.pullEventRaw() end
            end
        )
        if forward == nil then settings.unset("dnsd.forward") else settings.set("dnsd.forward", forward) end
        fs.delete("/zones")
        fs.delete("/records.txt")
        if not ok then error(err, 0) end
        return answers, result
    end

    it("answers for several zones, each from its own file, and refuses others", function()
        write("/zones/home.txt", "bank 10.0.0.5\n")
        write("/zones/shop.txt", "till 10.0.0.7\n")
        local answers, result = ask({ "run", "home", "shop" }, { "bank.home", "till.shop", "bank.shop", "bank.away" })
        expect(answers):same { 0x0A000005, 0x0A000007, "not_found", "refused" }
        expect(result.output):eq("Answering for home and shop.\nPress Ctrl+T to stop.\n")
    end)

    it("takes a zone's file after it", function()
        write("/records.txt", "bank 10.0.0.6\n")
        write("/zones/shop.txt", "till 10.0.0.7\n")
        local answers = ask({ "run", "home", "records.txt", "shop" }, { "bank.home", "till.shop" })
        expect(answers):same { 0x0A000006, 0x0A000007 }
    end)

    it("refuses what doesn't make sense, changing nothing", function()
        expect(capture("/rom/programs/net/dnsd.lua", "start", "home", "home").error):eq("home is there twice.\n")
        expect(capture("/rom/programs/net/dnsd.lua", "start", "records.txt").output:sub(1, 7)):eq("Usages:")
        expect(capture("/rom/programs/net/dnsd.lua", "start", "home", "a.txt", "b.txt").output:sub(1, 7)):eq("Usages:")
        expect(service.status("dnsd")):eq(nil)
    end)
end)
