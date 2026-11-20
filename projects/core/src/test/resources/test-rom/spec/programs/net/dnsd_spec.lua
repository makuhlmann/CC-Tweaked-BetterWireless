-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The dnsd program", function()
    local capture = require "test_helpers".capture_program
    local dns = require "cc.internal.net.dns"

    local function write(path, text)
        local file = fs.open(path, "w")
        file.write(text)
        file.close()
    end

    local function read(path)
        local file = fs.open(path, "r")
        if not file then return nil end
        local text = file.readAll()
        file.close()
        return text
    end

    local function ip(text) return (require "cc.net.address".parse(text)) end

    --[[ Run dnsd with its files as given (or none), send it some messages from this computer (a question, given by
    its name, or an update), and stop it. Gives each answer (a question's address or code, an update's code), and what
    dnsd printed. The files are deleted afterwards. ]]
    local function run(files, messages, arguments)
        for path, text in pairs(files) do write(path, text) end
        local answers, result = {}, nil
        local ok, err = pcall(parallel.waitForAny,
            function() result = capture("/rom/programs/net/dnsd.lua", table.unpack(arguments or { "run" })) end,
            function()
                local socket = assert(net.udp.open())
                for i, message in ipairs(messages) do
                    if type(message) == "string" then message = { name = message, type = "A" } end
                    if type(message) == "function" then message = message() end
                    -- An update keeps its own ID, which it's signed with.
                    message.id = message.id or i
                    for _ = 1, 20 do
                        socket:send("127.0.0.1", 53, message)
                        -- Only the answer to this message: one sent again may have been answered twice.
                        local answer = socket:receive(0.2)
                        while answer and answer.id ~= message.id do answer = socket:receive(0.2) end
                        if answer then
                            -- The address, after any aliases.
                            local value
                            for _, record in ipairs(answer.code == "ok" and answer.records or {}) do
                                if record.type == "A" then value = record.value end
                            end
                            answers[i] = value or answer.code
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
        local leases = read("/etc/dnsd.leases")
        fs.delete("/etc")
        fs.delete("/zones")
        fs.delete("/records.txt")
        if not ok then error(err, 0) end
        return answers, result, leases
    end

    it("answers from its zones file and zones' own files, passing by what it can't read", function()
        local answers, result = run({
            ["/etc/dnsd.conf"] = "zone home\nzone shop /zones/shop.zone\n",
            ["/etc/dnsd.zones"] = "[home]\nbank 10.0.0.5\nnonsense\n[elsewhere]\nx 10.0.0.1\n",
            ["/zones/shop.zone"] = "till 10.0.0.7\n",
        }, { "bank.home", "till.shop", "bank.shop", "bank.away", "bank.home" })
        expect(answers):same { ip("10.0.0.5"), ip("10.0.0.7"), "not_found", "refused", ip("10.0.0.5") }
        expect(result.output):eq("Answering for home and shop.\nPress Ctrl+T to stop.\n")
        -- What's wrong with the zones file is said once, not for every question.
        expect(result.error):eq(
            "/etc/dnsd.zones: Line 3: expected a name, then its address or the name it's an alias for\n"
            .. "/etc/dnsd.zones: dnsd doesn't answer for elsewhere\n"
        )
    end)

    it("follows aliases, and says which never lead anywhere when it reads them", function()
        local answers, result = run({
            ["/etc/dnsd.conf"] = "zone home\nzone shop /zones/shop.zone\n",
            ["/etc/dnsd.zones"] = "[home]\nbank 10.0.0.5\nwww bank\ntill till.shop\nloop1 loop2\nloop2 loop1\n",
            ["/zones/shop.zone"] = "till 10.0.0.7\nbank bank.home.\n",
        }, { "www.home", "till.home", "bank.shop", "loop1.home" })
        expect(answers):same { ip("10.0.0.5"), ip("10.0.0.7"), ip("10.0.0.5"), "not_found" }
        expect(result.error):eq(
            "loop1.home isn't found: its aliases go round in a circle\nloop2.home isn't found: its aliases go round in a circle\n"
        )
    end)

    it("lets this computer set and delete names in its zones, and keeps them", function()
        local function update(fields)
            return function()
                fields.zone, fields.owner = "home", "computer 12"
                return dns.update_message(fields, nil, os.epoch("utc"))
            end
        end
        local answers, result, leases = run({
            ["/etc/dnsd.conf"] = "zone home\n",
            ["/etc/dnsd.zones"] = "[home]\nbank 10.0.0.5\n",
        }, {
            update { name = "laptop", address = ip("10.0.0.100"), lifetime = 60 }, "laptop.home",
            update { name = "bank", address = ip("10.0.0.100"), lifetime = 60 }, "bank.home",
            update { name = "pc", address = ip("10.0.0.101"), lifetime = 60 },
            update { name = "laptop" }, "laptop.home",
        })
        expect(answers):same {
            "ok", ip("10.0.0.100"), "taken", ip("10.0.0.5"), "ok", "ok", "not_found",
        }
        expect(result.output):str_match("Set laptop%.home to 10%.0%.0%.100 %(computer 12, from 127%.0%.0%.1%)\n")
        expect(result.output):str_match("Refused an update from 127%.0%.0%.1: bank%.home is in the zone's file\n")
        expect(result.output):str_match("Deleted laptop%.home %(computer 12, from 127%.0%.0%.1%)\n")
        -- What's left is kept for next time.
        local kept = textutils.unserialise(leases)
        expect({ kept["pc.home"].address, kept["laptop.home"] }):same { "10.0.0.101", nil }
    end)

    it("answers for names it was told before it started again", function()
        local answers = run({
            ["/etc/dnsd.conf"] = "zone home\n",
            ["/etc/dnsd.leases"] = textutils.serialise {
                ["pc.home"] = { zone = "home", name = "pc", address = "10.0.0.101", expires = os.epoch("utc") / 1000 + 60, owner = "computer 12" },
                ["old.home"] = { zone = "home", name = "old", address = "10.0.0.102", expires = os.epoch("utc") / 1000 - 1, owner = "computer 13" },
            },
        }, { "pc.home", "old.home" })
        expect(answers):same { ip("10.0.0.101"), "not_found" }
    end)

    it("takes only signed updates when it has a key", function()
        local function update(secret)
            return function()
                return dns.update_message(
                    { zone = "home", name = "pc", address = ip("10.0.0.100"), lifetime = 60, owner = "computer 12" },
                    secret, os.epoch("utc"))
            end
        end
        local answers, result = run({ ["/etc/dnsd.conf"] = "zone home\nkey s3cret\n" }, {
            update(nil), update("wrong"), "pc.home", update("s3cret"), "pc.home",
        })
        expect(answers):same { "refused", "refused", "not_found", "ok", ip("10.0.0.100") }
        expect(result.output):str_match("Updates must be signed with the key%.\n")
    end)

    it("won't start until its settings make sense", function()
        write("/etc/dnsd.conf", "zone home\nbogus 1\nforward home 10.0.0.9\n")
        local result = capture("/rom/programs/net/dnsd.lua", "run")
        fs.delete("/etc")
        expect(result.error):eq(
            "/etc/dnsd.conf: Line 2: there's no setting called bogus\n/etc/dnsd.conf: Line 3: home is there twice\n"
            .. "dnsd won't start until its settings make sense.\n"
        )
    end)

    it("writes its files the first time, from how it was started before", function()
        local forward = settings.get("dnsd.forward")
        settings.set("dnsd.forward", "10.0.0.2, 10.0.0.3")
        fs.delete("/etc")
        local conf_text, zones_text
        local answers, result = run({ ["/records.txt"] = "bank 10.0.0.6\n" }, {
            function()
                conf_text, zones_text = read("/etc/dnsd.conf"), read("/etc/dnsd.zones")
                return { name = "bank.home", type = "A" }
            end,
        }, { "run", "home", "/records.txt", "shop" })
        local after = settings.get("dnsd.forward")
        if forward == nil then settings.unset("dnsd.forward") else settings.set("dnsd.forward", forward) end

        expect(answers):same { ip("10.0.0.6") }
        expect(after):eq(nil)
        expect(conf_text):str_match("\nzone home /records%.txt\nzone shop\n")
        expect(conf_text):str_match("\nupstream 10%.0%.0%.2 10%.0%.0%.3\n")
        expect(zones_text):str_match("\n%[shop%]\n")
        expect(result.output):str_match("^Moved dnsd's settings to /etc/dnsd%.conf%.\n")
        expect(result.output):str_match("Answering for home and shop%.\nAsking 10%.0%.0%.2 and 10%.0%.0%.3 about other names%.\n")
    end)

    it("says how it's used", function()
        expect(capture("/rom/programs/net/dnsd.lua", "start", "home").output:sub(1, 7)):eq("Usages:")
        expect(capture("/rom/programs/net/dnsd.lua").output:sub(1, 7)):eq("Usages:")
        expect(service.status("dnsd")):eq(nil)
        expect(fs.exists("/etc/dnsd.conf")):eq(false)
    end)
end)
