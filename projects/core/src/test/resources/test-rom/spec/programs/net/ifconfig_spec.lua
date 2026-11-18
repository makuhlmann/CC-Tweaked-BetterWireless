-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The ifconfig program", function()
    local capture = require "test_helpers".capture_program
    local SETTING = "net.net_spec_none.address"

    local function run(...)
        local ok, result = pcall(capture, "/rom/programs/net/ifconfig.lua", ...)
        settings.unset(SETTING)
        settings.save()
        if not ok then error(result, 0) end
        return result
    end

    it("keeps an address for an interface which isn't there yet", function()
        local function kept(...)
            local result = run(...)
            return result, settings.get(SETTING)
        end
        local result
        result = run("net_spec_none", "10.0.0.5/24")
        expect(result):matches { ok = true, error = "", output = "No interface named net_spec_none yet. The setting will be used once it's added.\n" }

        -- Only if it's an address which can be used.
        for _, bad in ipairs {
            { "10.0.0.0/24", "10.0.0.0/24 is the address of the network itself, or its broadcast address\n" },
            { "127.0.0.1", "127.0.0.1 can't be a computer's address\n" },
            { "10.0.0.5/0", "The prefix length must be from 1 to 32\n" },
            { "10.0.0", "Invalid address '10.0.0'\n" },
        } do
            settings.unset(SETTING)
            local refused, setting = kept("net_spec_none", bad[1])
            expect(refused):matches { ok = true, output = "", error = bad[2] }
            expect(setting):eq(nil)
        end
    end)

    it("puts a radio on a channel of its own, from when the computer restarts", function()
        local CHANNEL = "net.net_spec_radio.channel"
        stub(net, "interfaces", function()
            return {
                { name = "net_spec_radio", modem = "net_spec_radio", kind = "wireless", band = "high" },
                { name = "net_spec_radio:low", modem = "net_spec_radio", kind = "wireless", band = "low" },
                { name = "net_spec_wire", modem = "net_spec_wire", kind = "wired", band = "high" },
            }
        end)
        local function channel(...)
            local result = capture("/rom/programs/net/ifconfig.lua", ...)
            return result, settings.get(CHANNEL)
        end

        local ok, err = pcall(function()
            local result, setting = channel("net_spec_radio", "channel", "1450")
            expect(result):matches {
                ok = true, error = "",
                output = "net_spec_radio will share channel 1450 (145MHz) when the computer restarts. Every computer on the link needs the same one.\n",
            }
            expect(setting):eq(1450)

            -- Refusals leave it as it was.
            for _, bad in ipairs {
                { { "net_spec_radio", "channel", "7935" }, "Channel 7935 (793.5MHz) is in cellular band b20 (800MHz), which phones and cells need\n" },
                { { "net_spec_radio", "channel", "65535" }, "A channel is a whole number from 300 to 65532 (30MHz to 6553.2MHz)\n" },
                { { "net_spec_radio", "channel", "fm" }, "A channel is a whole number from 300 to 65532 (30MHz to 6553.2MHz)\n" },
                { { "net_spec_radio:low", "channel", "1500" }, "Only a modem's own interface can: net_spec_radio here.\n" },
                { { "net_spec_wire", "channel", "1500" }, "Only wireless and ender modems can have a channel of their own.\n" },
                { { "net_spec_none", "channel", "1500" }, "Only wireless and ender modems can have a channel of their own.\n" },
            } do
                result, setting = channel(table.unpack(bad[1]))
                expect(result):matches { ok = true, output = "", error = bad[2] }
                expect(setting):eq(1450)
            end

            -- The band can still be set, though the channel is used instead.
            result = channel("net_spec_radio", "band", "low")
            expect(result.output):eq(
                "net_spec_radio will use the low band when the computer restarts.\n" ..
                "It's set to a channel of its own, though, which it uses instead: \"/rom/programs/net/ifconfig.lua net_spec_radio channel none\" to stop.\n"
            )

            result, setting = channel("net_spec_radio", "channel", "none")
            expect(result):matches { ok = true, error = "", output = "net_spec_radio will use its band when the computer restarts.\n" }
            expect(setting):eq(nil)
        end)
        settings.unset(CHANNEL)
        settings.unset("net.net_spec_radio.band")
        settings.save()
        if not ok then error(err, 0) end
    end)
end)
