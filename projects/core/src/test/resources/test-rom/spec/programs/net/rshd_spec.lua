-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The rshd program", function()
    local remote_term = require "cc.internal.net.remote_term"
    local PROGRAM = "/rshd_spec_program.lua"

    -- The enclave is part of the mod, not the computer, so pretend to have one (as net_spec does).
    local function with_enclave(fn)
        local keys, base = {}, "\9" .. ("\0"):rep(31)
        _G.enclave = {
            publicKey = function(name) return keys[name] and keys[name].public end,
            generate = function(name)
                local private = crypto.generateKeyPair("x25519")
                keys[name] = { private = private, public = crypto.exchange(private, base) }
                return keys[name].public
            end,
            exchange = function(name, public) return crypto.exchange(keys[name].private, public) end,
        }
        local ok, err = pcall(fn)
        _G.enclave = nil
        fs.delete("/.net")
        fs.delete(PROGRAM)
        if not ok then error(err, 0) end
    end

    it("sends all a program draws, and lets it wait, while the client is slow to read", function()
        with_enclave(function()
            -- The client is this computer, so it's allowed by its own key.
            local file = fs.open("/.net/authorized_keys", "w")
            file.write(textutils.serialise({ [net.getIdentity()] = "itself" }))
            file.close()
            -- Thousands of lines without yielding, then a wait, which needs a timer event, then the last line.
            file = fs.open(PROGRAM, "w")
            file.write('for i = 1, 3000 do print("Line " .. i) end sleep(0.2) print("done")')
            file.close()

            local messages, connected = {}, false
            parallel.waitForAny(
                function() shell.run("/rom/programs/net/rshd.lua", "run") end,
                function()
                    local connection
                    for _ = 1, 20 do
                        connection = net.secure.connect("127.0.0.1", 22)
                        if connection then break end
                        sleep(0.1)
                    end
                    assert(connection, "Couldn't connect")
                    connected = true
                    connection:send({ width = 30, height = 10, colour = true, command = PROGRAM })
                    -- Read nothing for a while, so the server has to wait for room.
                    sleep(1)
                    while true do
                        local message = connection:receive(10)
                        if message == nil then break end
                        messages[#messages + 1] = message
                        if message.exit then break end
                    end
                    connection:close()
                end
            )

            expect(connected):eq(true)
            expect(messages[1]):same { auth = "ok" }
            expect(messages[#messages]):same { exit = true, ok = true }

            -- Every batch arrived, so the client's screen is the program's.
            local client = window.create(term.current(), 1, 1, 30, 10, false)
            local batches = 0
            for _, message in ipairs(messages) do
                if message.term then
                    remote_term.apply(client, message.term)
                    batches = batches + 1
                end
            end
            expect(batches > 2):eq(true)
            expect(client.getLine(8):gsub(" +$", "")):eq("Line 3000")
            expect(client.getLine(9):gsub(" +$", "")):eq("done")
        end)
    end)

    it("ends a session when it's stopped as a service, and tells the client", function()
        with_enclave(function()
            local ok, err = pcall(function()
                local file = fs.open("/.net/authorized_keys", "w")
                file.write(textutils.serialise({ [net.getIdentity()] = "itself" }))
                file.close()
                file = fs.open(PROGRAM, "w")
                file.write('print("Started") while true do sleep(1) end')
                file.close()

                -- (Not captured: that would take what the session prints, too.)
                expect(shell.run("/rom/programs/net/rshd.lua", "start")):eq(true)
                expect(service.status("rshd").state):eq("running")

                local connection
                for _ = 1, 20 do
                    connection = net.secure.connect("127.0.0.1", 22)
                    if connection then break end
                    sleep(0.1)
                end
                assert(connection, "Couldn't connect")
                connection:send({ width = 30, height = 10, colour = true, command = PROGRAM })
                expect(connection:receive(5)):same { auth = "ok" }
                -- Once the program has drawn, it's running.
                local message = connection:receive(5)
                expect(type(message) == "table" and message.term ~= nil):eq(true)

                expect(shell.run("/rom/programs/net/rshd.lua", "stop")):eq(true)
                expect(service.status("rshd").state):eq("stopped")
                local last
                while true do
                    message = connection:receive(5)
                    if message == nil then break end
                    last = message
                    if message.exit then break end
                end
                connection:close()
                expect(last):same { exit = true, stopped = true }
            end)
            if service.status("rshd") then service.remove("rshd") end
            if not ok then error(err, 0) end
        end)
    end)
end)
