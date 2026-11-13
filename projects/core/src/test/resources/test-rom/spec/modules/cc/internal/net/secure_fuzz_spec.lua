-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Misbehaving computers, and the security layer: handshakes, encrypted messages, encoded values, certificates and
sealed frames, filled with things they don't expect. Nothing may escape as an error, nobody may end up trusting
something which was changed on the way, and everything must carry on working afterwards. ]]

describe("The security layer, given bad messages,", function()
    local helpers = require "support.net_helpers"
    local secure = require "cc.internal.net.secure"
    local noise = require "cc.internal.net.noise"
    local codec = require "cc.net.codec"
    local certificate = require "cc.internal.net.certificate"
    local link = require "cc.internal.net.link"
    local remote_term = require "cc.internal.net.remote_term"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local ip = helpers.ip

    local NIL = helpers.NIL
    local BAD = helpers.bad_values()

    local function unhex(text)
        return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
    end

    -- Public keys which give the same shared secret (all zeros) whoever they're combined with.
    local LOW_ORDER = {
        unhex("0000000000000000000000000000000000000000000000000000000000000000"),
        unhex("0100000000000000000000000000000000000000000000000000000000000000"),
        unhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
        unhex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
        unhex("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        unhex("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        unhex("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
    }

    local yield = require "support.yield"

    local function new_key()
        local private = crypto.generateKeyPair("x25519")
        return { public = noise.public_key(crypto, private), exchange = function(public) return crypto.exchange(private, public) end }
    end
    local client_key, server_key = new_key(), new_key()

    local function flip(text, position)
        return text:sub(1, position - 1) .. string.char(bit32.bxor(text:byte(position), 2 ^ math.random(0, 7))) .. text:sub(position + 1)
    end

    --[[ Run a handshake between a client and a server, joined directly rather than by a network.

    `options.tamper(side, index, message)` sees each message a side sends, and returns what arrives instead. Returning
    `nil` ends the connection there. Afterwards, `queues[side]` holds what's waiting for that side to receive, and
    receiving from an empty queue times out.
    ]]
    local function handshake(options)
        options = options or {}
        local progress, timed_out = 0, false
        local queues, dead, counts = { client = {}, server = {} }, {}, { client = 0, server = 0 }

        local function transport(name, other)
            return {
                send = function(_, value)
                    if dead[name] or dead[other] then return nil, "Connection reset" end
                    counts[name] = counts[name] + 1
                    if options.tamper then value = options.tamper(name, counts[name], value) end
                    table.insert(queues[other], { value })
                    progress = progress + 1
                    return true
                end,
                receive = function()
                    while true do
                        local item = table.remove(queues[name], 1)
                        if item then
                            progress = progress + 1
                            return item[1]
                        end
                        if dead[name] or dead[other] then return nil, "Connection reset" end
                        if timed_out then return nil, "Timed out" end
                        coroutine.yield()
                    end
                end,
                close = function() end,
                abort = function() dead[name] = true end,
            }
        end

        local pattern = options.pattern or "XX"
        local results = {}
        local threads = {
            client = coroutine.create(function()
                results.client = table.pack(secure.client(transport("client", "server"), {
                    crypto = crypto, static = pattern == "XX" and client_key or nil, pattern = pattern,
                    remote_static = pattern == "NK" and server_key.public or nil, timeout = 5,
                }))
            end),
            server = coroutine.create(function()
                results.server = table.pack(secure.server(transport("server", "client"), {
                    crypto = crypto, static = server_key, timeout = 5, anonymous = pattern == "NK",
                    certificate = options.certificate,
                }))
            end),
        }
        while true do
            local before, alive = progress, false
            for _, name in ipairs { "client", "server" } do
                local thread = threads[name]
                if coroutine.status(thread) ~= "dead" then
                    local ok, err = coroutine.resume(thread)
                    if not ok then error(("The %s threw %q"):format(name, tostring(err)), 0) end
                    if coroutine.status(thread) ~= "dead" then alive = true end
                end
            end
            if not alive then break end
            -- Nobody did anything: whoever is waiting has waited long enough.
            if progress == before then timed_out = true end
        end
        timed_out = true

        return {
            client = results.client[1], client_err = results.client[2],
            server = results.server[1], server_err = results.server[2], queues = queues,
        }
    end

    -- Run a handshake which someone interferes with. However it goes, nothing may be thrown, the two sides can't both
    -- think it worked, and a side which thinks it did finds out as soon as it uses the connection.
    local function check_spoiled(failures, name, options)
        local ok, result = pcall(handshake, options)
        if not ok then
            failures[#failures + 1] = name .. ": " .. tostring(result)
            return
        end
        if result.client and result.server then failures[#failures + 1] = name .. ": the handshake worked" end
        for _, side in ipairs { "client", "server" } do
            if result[side] then
                local received, err = result[side]:receive(1)
                if received ~= nil or type(err) ~= "string" then failures[#failures + 1] = name .. ": the " .. side .. " carried on" end
            elseif type(result[side .. "_err"]) ~= "string" then
                failures[#failures + 1] = name .. ": the " .. side .. " gave no reason"
            end
        end
    end

    -- Every message of a handshake, in order: who sends it, which of that side's messages it is, and its bytes.
    local function messages_of(pattern)
        local messages = {}
        local result = handshake {
            pattern = pattern,
            tamper = function(side, index, value)
                messages[#messages + 1] = { side = side, index = index, bytes = type(value) == "table" and value.message or value }
                return value
            end,
        }
        assert(result.client and result.server, "The handshake failed")
        return messages
    end

    -- Replace the bytes of one handshake message. The client's first message is a table holding them.
    local function replace_bytes(target, change)
        return function(side, index, value)
            if side ~= target.side or index ~= target.index then return value end
            if type(value) ~= "table" then return change(value) end
            return { secure = value.secure, pattern = value.pattern, message = change(value.message) }
        end
    end

    describe("handshakes", function()
        it("work when nobody interferes", function()
            for _, pattern in ipairs { "XX", "NK" } do
                local result = handshake { pattern = pattern }
                expect(result.client_err):eq(nil)
                expect(result.server_err):eq(nil)
                assert(result.client:send("hello"))
                expect(result.server:receive(1)):eq("hello")
                assert(result.server:send({ answer = 42 }))
                expect(result.client:receive(1)):same { answer = 42 }
            end
        end)

        it("fail cleanly when a message is something else entirely", function()
            local failures = {}
            for _, pattern in ipairs { "XX", "NK" } do
                for _, target in ipairs(messages_of(pattern)) do
                    for _, bad in ipairs(BAD) do
                        local value = bad[2]
                        if value == NIL then value = nil end
                        local where = ("%s message %d from the %s"):format(pattern, target.index, target.side)
                        check_spoiled(failures, ("%s = %s"):format(where, bad[1]), {
                            pattern = pattern,
                            tamper = function(side, index, original)
                                if side == target.side and index == target.index then return value end
                                return original
                            end,
                        })
                        check_spoiled(failures, ("%s with bytes = %s"):format(where, bad[1]), {
                            pattern = pattern, tamper = replace_bytes(target, function() return value end),
                        })
                    end
                    yield()
                end

                -- The fields of the client's opening message.
                for _, field in ipairs { "secure", "pattern" } do
                    for _, bad in ipairs(BAD) do
                        check_spoiled(failures, ("%s opening with %s = %s"):format(pattern, field, bad[1]), {
                            pattern = pattern,
                            tamper = function(side, index, original)
                                if side ~= "client" or index ~= 1 then return original end
                                local changed = { secure = original.secure, pattern = original.pattern, message = original.message }
                                if bad[2] == NIL then changed[field] = nil else changed[field] = bad[2] end
                                return changed
                            end,
                        })
                    end
                end
                yield()
            end
            expect(failures):same {}
        end)

        for _, pattern in ipairs { "XX", "NK" } do
            it("fail cleanly when a " .. pattern .. " message is cut short or has more added", function()
                local failures = {}
                for _, target in ipairs(messages_of(pattern)) do
                    local where = ("%s message %d from the %s"):format(pattern, target.index, target.side)
                    for length = 0, #target.bytes - 1 do
                        check_spoiled(failures, ("%s cut to %d bytes"):format(where, length), {
                            pattern = pattern, tamper = replace_bytes(target, function(bytes) return bytes:sub(1, length) end),
                        })
                        if length % 20 == 0 then yield() end
                    end
                    for _, extra in ipairs { "\0", "x", ("\0"):rep(16), ("x"):rep(1000) } do
                        check_spoiled(failures, ("%s with %d bytes more"):format(where, #extra), {
                            pattern = pattern, tamper = replace_bytes(target, function(bytes) return bytes .. extra end),
                        })
                    end
                end
                expect(failures):same {}
            end)

            it("fail cleanly when any byte of a " .. pattern .. " message is changed", function()
                math.randomseed(17)
                local failures = {}
                for _, target in ipairs(messages_of(pattern)) do
                    for position = 1, #target.bytes do
                        check_spoiled(failures, ("%s message %d from the %s with byte %d changed"):format(pattern, target.index, target.side, position), {
                            pattern = pattern, tamper = replace_bytes(target, function(bytes) return flip(bytes, position) end),
                        })
                        if position % 20 == 0 then yield() end
                    end
                end
                expect(failures):same {}
            end)
        end

        it("fail cleanly when a key is one which gives everyone the same secret", function()
            -- Each side's first message starts with a key made up for this handshake. A server reads a client's before
            -- it can check anything about it.
            local failures = {}
            for _, pattern in ipairs { "XX", "NK" } do
                for _, target in ipairs(messages_of(pattern)) do
                    if target.index == 1 then
                        for i, point in ipairs(LOW_ORDER) do
                            check_spoiled(failures, ("%s message from the %s with bad key %d"):format(pattern, target.side, i), {
                                pattern = pattern, tamper = replace_bytes(target, function(bytes) return point .. bytes:sub(33) end),
                            })
                        end
                    end
                end
            end
            expect(failures):same {}
        end)

        it("fail cleanly when the first message is noise", function()
            math.randomseed(29)
            local failures = {}
            for i = 1, 300 do
                local bytes = {}
                for j = 1, math.random(0, 150) do bytes[j] = string.char(math.random(0, 255)) end
                local noise_bytes = table.concat(bytes)
                check_spoiled(failures, "Noise " .. i, {
                    pattern = i % 2 == 0 and "XX" or "NK",
                    tamper = replace_bytes({ side = "client", index = 1 }, function() return noise_bytes end),
                })
                if i % 20 == 0 then yield() end
            end
            expect(failures):same {}
        end)

        it("refuse clients which don't say who they are, unless asked not to", function()
            local transport = {
                messages = { { secure = 1, pattern = "NK", message = ("x"):rep(68) } },
                receive = function(self) return table.remove(self.messages, 1) end,
                send = function() return true end,
                abort = function(self) self.aborted = true end,
            }
            expect({ secure.server(transport, { crypto = crypto, static = server_key, timeout = 1 }) })
                :same { nil, "The client didn't say who it is" }
            expect(transport.aborted):eq(true)
        end)
    end)

    describe("encrypted messages", function()
        it("end the connection when they're anything but what was sent", function()
            local failures = {}
            for _, bad in ipairs(BAD) do
                local ok, err = pcall(function()
                    local result = handshake()
                    local value = bad[2]
                    if value == NIL then value = nil end
                    table.insert(result.queues.server, { value })
                    local received, reason = result.server:receive(1)
                    if received ~= nil then error("Received " .. tostring(received), 0) end
                    local expected = value == nil and "Connection closed unexpectedly" or "Message was tampered with"
                    if reason ~= expected then error("Failed with " .. tostring(reason), 0) end

                    -- And it stays ended, even if good messages follow.
                    table.insert(result.queues.server, { result.client.send_cipher:encrypt(codec.encode({ d = "too late" })) })
                    local again, again_reason = result.server:receive(1)
                    if again ~= nil or again_reason ~= expected then error("Carried on afterwards", 0) end
                    if result.server:send("anything") ~= nil then error("Sent afterwards", 0) end
                end)
                if not ok then failures[#failures + 1] = bad[1] .. ": " .. tostring(err) end
            end
            expect(failures):same {}
        end)

        it("end the connection when they decrypt to something which isn't a message", function()
            -- Only the other side can make these, but it may be a different program, or a broken one.
            local cases = {
                { "a number", codec.encode(5) }, { "a string", codec.encode("d") }, { "nothing", "" },
                { "an empty table", codec.encode({}) }, { "an odd close", codec.encode({ close = "yes" }) },
                { "another field", codec.encode({ data = "x" }) }, { "bytes which aren't a value", "\255\255\255" },
                { "a value with more after it", codec.encode({ d = 1 }) .. "\0" },
            }
            local failures = {}
            for _, case in ipairs(cases) do
                local ok, err = pcall(function()
                    local result = handshake()
                    table.insert(result.queues.server, { result.client.send_cipher:encrypt(case[2]) })
                    local received, reason = result.server:receive(1)
                    if received ~= nil or reason ~= "Message was tampered with" then
                        error(("Got %s, %s"):format(tostring(received), tostring(reason)), 0)
                    end
                end)
                if not ok then failures[#failures + 1] = case[1] .. ": " .. tostring(err) end
            end
            expect(failures):same {}
        end)

        it("refuse anything after the other side said it was closing", function()
            local result = handshake()
            assert(result.client:send("last"))
            table.insert(result.queues.server, { result.client.send_cipher:encrypt(codec.encode({ close = true })) })
            table.insert(result.queues.server, { result.client.send_cipher:encrypt(codec.encode({ d = "sneaked in" })) })
            expect(result.server:receive(1)):eq("last")
            expect({ result.server:receive(1) }):same { nil, "Message was tampered with" }
        end)

        it("carry every kind of value, including false and odd numbers", function()
            local result = handshake()
            local values = {
                false, true, 0, -0.5, 2 ^ 53, math.huge, -math.huge, "", ("\0\255"):rep(100),
                { [1] = "a", [2.5] = "b", [true] = "c", [false] = "d", x = { y = { z = {} } } },
            }
            for _, value in ipairs(values) do
                assert(result.client:send(value))
                expect(result.server:receive(1)):same(value)
            end
            assert(result.client:send(0 / 0))
            local nan = result.server:receive(1)
            expect(nan ~= nan):eq(true)

            -- The biggest message which fits, and the smallest which doesn't.
            local overhead = #codec.encode({ d = "" })
            local biggest = ("x"):rep(secure.MAX_ENCODED - overhead)
            assert(result.client:send(biggest))
            expect(result.server:receive(1) == biggest):eq(true)
            expect({ result.client:send(biggest .. "x") }):same { nil, "Message too large" }
            assert(result.client:send("still fine"))
            expect(result.server:receive(1)):eq("still fine")
        end)
    end)

    describe("encoded values", function()
        -- Whether two values are the same, counting NaN as itself.
        local function same(a, b)
            if type(a) ~= type(b) then return false end
            if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
            for k, v in pairs(a) do
                if not same(v, b[k]) then return false end
            end
            for k in pairs(b) do
                if a[k] == nil then return false end
            end
            return true
        end

        -- Decode some bytes. If they're accepted, the value must be one which encodes, and reads back the same.
        local function check(bytes)
            local value = codec.decode(bytes)
            if value == nil then return end
            local again = codec.decode(codec.encode(value))
            if not same(value, again) then error("Read back differently", 0) end
        end

        local function run(cases)
            local failures = {}
            for i, case in ipairs(cases) do
                local ok, err = pcall(check, case)
                if not ok then
                    failures[#failures + 1] = ("%q: %s"):format(case:sub(1, 40), tostring(err))
                end
                if i % 500 == 0 then yield() end
            end
            expect(failures):same {}
        end

        it("are never read from noise as something which can't be written", function()
            math.randomseed(31)
            local cases = {}
            for i = 1, 6000 do
                -- Mostly the bytes which mean something, so the noise gets some way in.
                local bytes = {}
                for j = 1, math.random(0, 60) do
                    bytes[j] = string.char(math.random() < 0.7 and math.random(0, 8) or math.random(0, 255))
                end
                cases[i] = table.concat(bytes)
            end
            run(cases)
        end)

        it("are never read from changed bytes as something which can't be written", function()
            math.randomseed(37)
            local cases = {}
            local values = {
                { 1, 2, 3 }, { name = "bank", key = ("k"):rep(32), expires = 2000, nested = { a = true, b = false, [0.5] = "half" } },
                "text", 12.5, { {}, { {} }, { { {} } } }, { d = ("x"):rep(50) },
            }
            for _, value in ipairs(values) do
                local bytes = codec.encode(value)
                for position = 1, #bytes do
                    for bit = 0, 7 do
                        cases[#cases + 1] = bytes:sub(1, position - 1) .. string.char(bit32.bxor(bytes:byte(position), 2 ^ bit)) .. bytes:sub(position + 1)
                    end
                    cases[#cases + 1] = bytes:sub(1, position - 1)
                    cases[#cases + 1] = bytes:sub(1, position) .. bytes:sub(position)
                end
            end
            run(cases)
        end)

        it("are refused when they lie about their size, nest too deeply, or repeat keys", function()
            local function number(n) return "\3" .. string.pack("<d", n) end
            local function text(s) return "\5" .. string.pack("<s4", s) end
            local function count(n) return "\6" .. string.pack("<I4", n) end

            expect(codec.decode(count(1) .. number(1) .. number(2))):same { 2 }
            local refused = {
                count(2 ^ 32 - 1), count(2 ^ 31) .. number(1) .. number(2), count(2) .. number(1) .. number(2),
                "\5" .. string.pack("<I4", 2 ^ 32 - 1) .. "x", "\5" .. string.pack("<I4", 5) .. "abcd",
                count(2) .. number(1) .. number(2) .. number(1) .. number(3), -- A key twice.
                count(1) .. "\4" .. number(1), -- NaN as a key.
                count(1) .. count(0) .. number(1), -- A table as a key.
                count(1) .. "\0" .. number(1), -- nil as a key.
                number(1) .. number(2), number(1):sub(1, 8), text("abc") .. "\0", "\7", "",
            }
            for i, bytes in ipairs(refused) do
                expect({ codec.decode(bytes) }):describe("Case " .. i):same { nil, "Invalid data" }
            end

            -- 64 tables inside each other is as deep as values go, both ways.
            local function nested(depth)
                return (count(1) .. number(1)):rep(depth - 1) .. count(0)
            end
            expect(codec.decode(nested(64))):ne(nil)
            expect({ codec.decode(nested(65)) }):same { nil, "Invalid data" }
            expect({ codec.decode(nested(10000)) }):same { nil, "Invalid data" }
            local deep = {}
            for _ = 1, 63 do deep = { deep } end
            expect(codec.decode(codec.encode(deep))):same(deep)
            expect.error(codec.encode, { deep }):eq("Tables are nested too deeply")
        end)
    end)

    describe("certificates", function()
        local authority_private, authority_public = crypto.generateKeyPair("ed25519")

        local function issue()
            return certificate.issue {
                name = "bank.spawn", key = server_key.public, expires = 2000, issuer = authority_public,
                sign = function(data) return crypto.sign(authority_private, data) end,
            }
        end

        local function vouches(bytes)
            local decoded = certificate.decode(bytes)
            if not decoded then return false end
            return certificate.verify(crypto, decoded, {
                name = "bank.spawn", key = server_key.public, now = 1000, trusted = { [authority_public] = true },
            }) == true
        end

        it("vouch for nothing once any field is changed", function()
            expect(vouches(certificate.encode(issue()))):eq(true)

            local failures = {}
            for _, field in ipairs { "v", "name", "key", "expires", "issuer", "signature" } do
                for _, bad in ipairs(BAD) do
                    local changed = issue()
                    if bad[2] == NIL then changed[field] = nil else changed[field] = bad[2] end
                    -- Values which can't be written as bytes can't arrive in a certificate either.
                    local encoded, bytes = pcall(certificate.encode, changed)
                    if encoded then
                        local ok, result = pcall(vouches, bytes)
                        if not ok or result then failures[#failures + 1] = ("%s = %s: %s"):format(field, bad[1], tostring(result)) end
                    end
                end
            end
            expect(failures):same {}
        end)

        it("vouch for nothing once any byte is changed", function()
            math.randomseed(41)
            local bytes = certificate.encode(issue())
            local failures = {}
            for position = 1, #bytes do
                local ok, result = pcall(vouches, flip(bytes, position))
                if not ok or result then failures[#failures + 1] = ("Byte %d: %s"):format(position, tostring(result)) end
                ok, result = pcall(vouches, bytes:sub(1, position - 1))
                if not ok or result then failures[#failures + 1] = ("Cut to %d bytes: %s"):format(position - 1, tostring(result)) end
            end
            expect(failures):same {}
        end)

        it("aren't believed for authorities whose keys aren't keys", function()
            -- Someone may put anything in the list of authorities.
            for _, issuer in ipairs { ("\0"):rep(32), ("\255"):rep(32), LOW_ORDER[2] } do
                local forged = issue()
                forged.issuer = issuer
                local ok, result = pcall(certificate.verify, crypto, certificate.decode(certificate.encode(forged)), {
                    name = "bank.spawn", key = server_key.public, now = 1000, trusted = { [issuer] = true },
                })
                expect({ ok, result }):same { true, nil }
            end
        end)
    end)

    describe("encrypted links", function()
        local KEY = link.derive(crypto, "correct horse battery staple")

        -- A computer (1) and its neighbour (2) on an encrypted link.
        local function sealed_network()
            local net = network()
            local stacks = {}
            for i = 1, 2 do
                local stack = net.stack(i)
                net.connect(stack, "top")
                stack:set_link_key("top", KEY)
                stack:set_address("top", ip("10.0.0." .. i), 24)
                stacks[i] = stack
            end
            net.run()
            return net, stacks[1], stacks[2]
        end

        -- Something which seals frames with the link's key, as any computer which has the passphrase could.
        local function insider(net)
            return link.new(crypto, KEY, function() return 1.7e12 + net.time * 1000 end)
        end

        local function seal(inside, src, dst, kind, body)
            return { net = 1, src = src, dst = dst, type = "sealed", body = link.seal(inside, src, dst, kind, body) }
        end

        local function check_working(net, target, peer)
            if net.errors[1] then error("Logged " .. tostring(net.errors[1]), 0) end
            local result = net.ping(peer, target.interfaces.top.address, nil, 3)
            if not result or result.error then error("Ping failed: " .. tostring(result and result.error), 0) end
        end

        local with = helpers.with

        it("ignore sealed frames with anything unexpected in them", function()
            local net, target, peer = sealed_network()
            local inside = insider(net)
            local failures = {}
            local function try(name, frame, channel)
                local ok, err = pcall(function()
                    net.inject("top", channel or target.interfaces.top.unicast, frame)
                    net.advance(0.5)
                    check_working(net, target, peer)
                end)
                if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
                net.errors = {}
            end

            for _, bad in ipairs(BAD) do
                -- A frame from someone without the key, and one from someone with it, each with one field made bad.
                local outside = { net = 1, src = 9, dst = 1, type = "sealed", body = { counter = (1.7e12 + net.time * 1000) * 1024, data = ("x"):rep(40) } }
                local genuine = seal(inside, 9, 1, "ip", { v = 1 })
                for _, template in ipairs { outside, genuine } do
                    for _, field in ipairs { "net", "src", "dst", "type", "body", "fwd" } do
                        try(("Frame with %s = %s"):format(field, bad[1]), with(template, field, bad[2]))
                    end
                    for _, field in ipairs { "counter", "data" } do
                        try(("Sealed body with %s = %s"):format(field, bad[1]), with(template, "body", with(template.body, field, bad[2])))
                    end
                end
                -- And frames which open properly, with something unexpected inside.
                for _, kind in ipairs { "ip", "nd", "sealed", "other" } do
                    local body = bad[2]
                    if body == NIL then body = nil end
                    local sealed = link.seal(inside, 9, -1, kind, body)
                    if sealed then
                        try(("A %s frame holding %s"):format(kind, bad[1]), { net = 1, src = 9, dst = -1, type = "sealed", body = sealed },
                            target.interfaces.top.broadcast)
                    end
                end
                yield()
            end
            expect(failures):same {}
        end)

        it("refuse frames replayed to a computer which has restarted", function()
            local net, target, peer = sealed_network()
            local heard = 0
            target:udp_open(5000, function() heard = heard + 1 end)

            -- Something records a datagram from the neighbour.
            local socket = assert(peer:udp_open(5000))
            assert(peer:udp_send(socket, address.BROADCAST, 5000, "open the door", "top"))
            local captured = textutils.unserialise(textutils.serialise(net.queue[#net.queue].frame))
            expect(captured.type):eq("sealed")
            net.run()
            expect(heard):eq(1)

            -- A little later the computer restarts, and so has forgotten which frames it has seen.
            net.advance(10)
            net.remove(target)
            target = net.stack(1)
            net.connect(target, "top")
            target:set_link_key("top", KEY)
            target:set_address("top", ip("10.0.0.1"), 24)
            target:udp_open(5000, function() heard = heard + 1 end)
            net.run()

            net.inject("top", target.interfaces.top.broadcast, captured)
            net.run()
            expect(heard):eq(1)

            -- New frames still get through.
            assert(peer:udp_send(socket, address.BROADCAST, 5000, "open the door", "top"))
            net.run()
            expect(heard):eq(2)
            check_working(net, target, peer)
        end)

        it("remember a limited number of computers and frames", function()
            local net, target, peer = sealed_network()
            local inside = insider(net)
            local state = target.interfaces.top.link

            -- Frames from 2,000 computers which have the key (or one pretending to be that many).
            for id = 1000, 2999 do
                net.inject("top", target.interfaces.top.broadcast, seal(inside, id, -1, "nd", { op = "is", addr = ip("10.0.0.9") }))
                if id % 100 == 0 then net.run() end
            end
            net.run()
            local peers = 0
            for _ in pairs(state.peers) do peers = peers + 1 end
            expect(peers <= 512):eq(true)
            expect(state.peer_count):eq(peers)
            -- The neighbour it already knew is still heard.
            check_working(net, target, peer)

            -- Once those computers have been quiet for a while, there's room for new ones.
            net.advance(120)
            local late = net.stack(3)
            net.connect(late, "top")
            late:set_link_key("top", KEY)
            late:set_address("top", ip("10.0.0.3"), 24)
            net.run()
            check_working(net, target, late)

            -- A neighbour which talks a lot: only its recent frames are remembered.
            for _ = 1, 3000 do
                net.inject("top", target.interfaces.top.broadcast, seal(inside, 2, -1, "nd", { op = "who", addr = ip("10.0.0.99") }))
                net.advance(0.01)
            end
            local seen = 0
            for _ in pairs(state.peers[2].seen) do seen = seen + 1 end
            expect(seen <= 600):eq(true)
            check_working(net, target, peer)
        end)

        it("refuse frames from the future, and far from now", function()
            local net, target, peer = sealed_network()
            local frames = target.interfaces.top.stats.frames_in
            for _, offset in ipairs { 61, 3600, -61, -3600 } do
                local skewed = link.new(crypto, KEY, function() return 1.7e12 + (net.time + offset) * 1000 end)
                net.inject("top", target.interfaces.top.broadcast, seal(skewed, 9, -1, "nd", { op = "who", addr = ip("10.0.0.1") }))
            end
            net.run()
            expect(target.interfaces.top.stats.frames_in):eq(frames)
            check_working(net, target, peer)
        end)
    end)

    describe("remote terminals", function()
        it("ignore drawing calls with anything unexpected in them", function()
            local client = window.create(term.current(), 1, 1, 20, 5, false)
            local calls = {
                { "write", "x" }, { "blit", "a", "0", "f" }, { "clear" }, { "clearLine" }, { "scroll", 1 },
                { "setCursorPos", 1, 1 }, { "setCursorBlink", true }, { "setTextColour", 1 }, { "setBackgroundColour", 1 },
                { "setPaletteColour", 1, 0, 0, 0 },
            }
            local failures = {}
            for _, call in ipairs(calls) do
                for position = 1, #call + 1 do
                    for _, bad in ipairs(BAD) do
                        local changed = { table.unpack(call) }
                        if bad[2] == NIL then changed[position] = nil else changed[position] = bad[2] end
                        local ok, err = pcall(remote_term.apply, client, { changed })
                        if not ok then failures[#failures + 1] = ("%s with argument %d = %s: %s"):format(call[1], position - 1, bad[1], err) end
                    end
                end
            end
            for _, bad in ipairs(BAD) do
                local ok, err = pcall(remote_term.apply, client, bad[2] ~= NIL and bad[2] or nil)
                if not ok then failures[#failures + 1] = ("A batch of %s: %s"):format(bad[1], err) end
                ok, err = pcall(remote_term.apply, client, { bad[2] ~= NIL and bad[2] or nil })
                if not ok then failures[#failures + 1] = ("A call of %s: %s"):format(bad[1], err) end
            end
            expect(failures):same {}

            -- The terminal still works, and is still the size it was.
            remote_term.apply(client, { { "setCursorPos", 1, 1 }, { "write", "fine" } })
            expect(client.getLine(1):sub(1, 4)):eq("fine")
            expect({ client.getSize() }):same { 20, 5 }
        end)

        it("draw huge and far-off things without harm", function()
            local client = window.create(term.current(), 1, 1, 20, 5, false)
            remote_term.apply(client, {
                { "write", ("x"):rep(50000) }, { "setCursorPos", 2 ^ 40, -2 ^ 40 }, { "write", "lost" },
                { "scroll", 2 ^ 40 }, { "scroll", -2 ^ 40 }, { "blit", ("x"):rep(20000), ("0"):rep(20000), ("f"):rep(20000) },
                { "setCursorPos", 1, 1 }, { "write", "fine" },
            })
            expect(client.getLine(1):sub(1, 4)):eq("fine")
        end)
    end)
end)
