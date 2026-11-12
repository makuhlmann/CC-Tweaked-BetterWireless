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
                function() shell.run("/rom/programs/net/rshd.lua") end,
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
end)
