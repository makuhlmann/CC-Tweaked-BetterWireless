-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The service program", function()
    local capture = require "test_helpers".capture_program
    local PROGRAM = "/service_spec_program.lua"

    local function write(path, text)
        local file = fs.open(path, "w")
        file.write(text)
        file.close()
    end

    -- Run a test, and stop and forget the services it started, whatever happens.
    local function with_cleanup(fn)
        local ok, err = pcall(fn)
        for _, name in ipairs { "spec", "dnsd", "dhcpd" } do
            if service.status(name) then service.remove(name) end
        end
        fs.delete(PROGRAM)
        fs.delete("/zones")
        fs.delete("/etc")
        _G.service_spec_current = nil
        if not ok then error(err, 0) end
    end

    it("adds a program as a service, which runs while the shell is free, and stops it", function()
        with_cleanup(function()
            write(PROGRAM, [[
                local socket = assert(net.udp.open(7300))
                print("Listening")
                pcall(function()
                    while true do
                        local message, from, port = socket:receive()
                        socket:send(from, port, "echo " .. tostring(message))
                    end
                end)
                socket:close()
            ]])
            local result = capture("service", "add", "spec", PROGRAM)
            expect(result.error):eq("")
            expect(result.output):eq(
                "Listening\nspec runs in the background, and starts with the computer. \"service stop spec\" stops it.\n"
            )

            -- The shell is free, and the service answers.
            local socket = assert(net.udp.open())
            socket:send("127.0.0.1", 7300, "hello")
            local reply = socket:receive(2)
            socket:close()
            expect(reply):eq("echo hello")

            local info = service.status("spec")
            expect(info.state):eq("running")
            expect(info.enabled):eq(true)
            expect(info.command):eq(PROGRAM)
            expect(capture("service", "list").output):str_match("spec +running +yes +" .. PROGRAM)

            -- Stopping it lets it close its socket, so the port is free again.
            result = capture("service", "stop", "spec")
            expect(result.output):eq("Stopped spec. It doesn't start with the computer now.\n")
            local again = assert(net.udp.open(7300))
            again:close()
            info = service.status("spec")
            expect(info.state):eq("stopped")
            expect(info.enabled):eq(false)

            result = capture("service", "remove", "spec")
            expect(result.output):eq("Stopped and removed spec.\n")
            expect(service.status("spec")):eq(nil)
            -- The service manager itself has had no trouble.
            expect(service.getErrors()):same {}
        end)
    end)

    it("says why a service couldn't start", function()
        with_cleanup(function()
            write(PROGRAM, [[error("No room at the inn", 0)]])
            local result = capture("service", "add", "spec", PROGRAM)
            expect(result.error):eq("No room at the inn\nspec stopped as soon as it started.\n")
            expect(service.status("spec").state):eq("exited")
        end)
    end)

    it("refuses what doesn't make sense, changing nothing", function()
        with_cleanup(function()
            expect(capture("service", "add", "spec", "no_such_program").error):eq("There's no program called no_such_program.\n")
            expect(capture("service", "start", "spec").error):eq("There's no service called spec.\n")
            expect(capture("service", "stop", "spec").error):eq("There's no service called spec.\n")
            expect(service.status("spec")):eq(nil)
        end)
    end)

    it("stops a service which ignores being told to, three seconds later", function()
        with_cleanup(function()
            write(PROGRAM, [[while true do os.pullEventRaw() end]])
            expect(service.add("spec", PROGRAM)):eq(true)
            local started = os.clock()
            expect(service.stop("spec")):eq(true)
            local took = os.clock() - started
            expect(took >= 2.5 and took < 6):describe("Took " .. took .. "s"):eq(true)
            local info = service.status("spec")
            expect(info.state):eq("stopped")
            expect(info.log[#info.log]):eq("Stopped, as it didn't finish when told to stop.")
            expect(service.getErrors()):same {}
        end)
    end)

    it("knows which service is running", function()
        with_cleanup(function()
            write(PROGRAM, [[
                _G.service_spec_current = service.current()
                while true do os.pullEvent() end
            ]])
            expect(service.add("spec", PROGRAM)):eq(true)
            expect(_G.service_spec_current):eq("spec")
            expect(service.current()):eq(nil)
        end)
    end)

    it("checks its arguments, without waiting on the background", function()
        expect.error(service.add, "x"):eq("bad argument #2 (string expected, got nil)")
        expect.error(service.add, "x", "/p", 3):eq("bad argument #3 (string expected, got number)")
        expect.error(service.start, 1):eq("bad argument #1 (string expected, got number)")
        expect.error(service.status, nil):eq("bad argument #1 (string expected, got nil)")
        expect.error(service.boot, "shell"):eq("bad argument #1 (table expected, got string)")
        expect({ service.remove("phone") }):same { nil, "phone can't be removed, only stopped" }
        expect({ service.add("bad name", "/rom/programs/id.lua") })
            :same { nil, "A service's name is up to 32 letters, digits, _, - and ." }
    end)

    it("changes nothing when a server's command is mistyped", function()
        with_cleanup(function()
            -- They take their settings from /etc now, not arguments.
            local result = capture("dhcpd", "start", "nowhere")
            expect(result.output:sub(1, 7)):eq("Usages:")
            expect(service.status("dhcpd")):eq(nil)

            result = capture("dnsd", "stop", "home")
            expect(result.output:sub(1, 7)):eq("Usages:")
            expect(service.status("dnsd")):eq(nil)
            expect(fs.exists("/etc")):eq(false)

            expect(capture("dnsd", "stop").error):eq("dnsd isn't running here.\n")
            expect(capture("dnsd", "status").error):eq("dnsd isn't set up here: start it with \"dnsd start\".\n")
            expect(capture("dhcpd", "status").error):eq("dhcpd isn't set up here: start it with \"dhcpd start\".\n")
            expect(capture("rshd", "status").error):eq("rshd isn't set up here: start it with \"rshd start\".\n")
        end)
    end)

    it("lists services on a pocket computer's screen, a line each", function()
        with_cleanup(function()
            write(PROGRAM, [[while true do os.pullEvent() end]])
            expect(service.add("spec", PROGRAM, "with", "a", "long", "list", "of", "arguments")):eq(true)
            local lines = require "test_helpers".with_window_lines(26, 6, function() shell.run("service") end)
            expect(lines[1]:gsub(" +$", "")):eq("Name State    Boot Runs")
            expect(lines[2]):eq("spec running  yes  /ser...")
            expect(lines[3]:gsub(" +$", "")):eq("")
        end)
    end)

    it("runs dnsd in the background, and stops it", function()
        with_cleanup(function()
            write("/etc/dnsd.conf", "zone home\n")
            write("/etc/dnsd.zones", "[home]\nbank 10.0.0.5\n")
            local result = capture("dnsd", "start")
            expect(result.error):eq("")
            expect(result.output):eq(
                "Answering for home.\ndnsd runs in the background, and starts with the computer. \"dnsd stop\" stops it.\n"
            )
            expect(service.status("dnsd").command):eq("/rom/programs/net/dnsd.lua run")

            local socket, answer = assert(net.udp.open()), nil
            for _ = 1, 20 do
                socket:send("127.0.0.1", 53, { id = 1, name = "bank.home", type = "A" })
                answer = socket:receive(0.2)
                if answer then break end
            end
            socket:close()
            expect(answer and answer.records[1].value):eq(0x0A000005)

            -- Asking for the same again changes nothing, and restarting reads the settings again.
            expect(capture("dnsd", "start").output):eq("dnsd is running already.\n")
            write("/etc/dnsd.conf", "zone home\nzone shop\n")
            expect(capture("dnsd", "restart").output):eq(
                "Answering for home and shop.\ndnsd runs in the background, and starts with the computer. \"dnsd stop\" stops it.\n"
            )

            result = capture("dnsd", "stop")
            expect(result.output):eq("Stopped dnsd. It doesn't start with the computer now.\n")
            local again = assert(net.udp.open(53))
            again:close()
            expect(capture("dnsd", "stop").output):eq("dnsd wasn't running. It doesn't start with the computer now.\n")
        end)
    end)

    it("sets dnsd up the first time it starts, and moves a service started before", function()
        with_cleanup(function()
            local result = capture("dnsd", "start")
            expect(result.output):eq(
                "Wrote /etc/dnsd.conf: dnsd answers for the zone home. Change it there.\nAnswering for home.\n"
                .. "dnsd runs in the background, and starts with the computer. \"dnsd stop\" stops it.\n"
            )
            expect(fs.exists("/etc/dnsd.zones")):eq(true)
            service.remove("dnsd")
            for _ = 1, 50 do
                if not service.status("dnsd") then break end
                sleep(0.1)
            end
            fs.delete("/etc")

            -- As an older version started it: its files are written from that, and it's started without them.
            write("/zones/shop.txt", "till 10.0.0.7\n")
            assert(service.add("dnsd", "/rom/programs/net/dnsd.lua", "run", "shop", "/zones/shop.txt"))
            for _ = 1, 20 do
                if fs.exists("/etc/dnsd.conf") then break end
                sleep(0.1)
            end
            local file = fs.open("/etc/dnsd.conf", "r")
            expect(file.readAll()):str_match("\nzone shop /zones/shop%.txt\n")
            file.close()
            result = capture("dnsd", "start")
            expect(service.status("dnsd").command):eq("/rom/programs/net/dnsd.lua run")
            expect(result.output):str_match("Answering for shop%.\n")
        end)
    end)
end)
