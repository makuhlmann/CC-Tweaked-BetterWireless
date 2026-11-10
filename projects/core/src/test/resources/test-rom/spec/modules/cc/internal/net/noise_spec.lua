-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.noise", function()
    local noise = require "cc.internal.net.noise"

    local function unhex(text) return (text:gsub("..", function(byte) return string.char(tonumber(byte, 16)) end)) end
    local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

    local function static(private)
        private = unhex(private)
        return { public = noise.public_key(crypto, private), exchange = function(public) return crypto.exchange(private, public) end }
    end

    -- Test vectors from cacophony (https://github.com/haskell-cryptography/cacophony/blob/master/vectors/cacophony.txt).
    local VECTORS = {
        {
            pattern = "XX", prologue = "4a6f686e2047616c74",
            init_static = "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
            init_ephemeral = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
            resp_static = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
            resp_ephemeral = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
            handshake_hash = "c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e",
            messages = {
                { "4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573" },
                { "4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad" },
                { "462e20412e20486179656b", "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030" },
                { "4361726c204d656e676572", "96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df" },
                { "4a65616e2d426170746973746520536179", "3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5" },
                { "457567656e2042f6686d20766f6e2042617765726b", "eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3a58502ae3f" },
            },
        },
        {
            pattern = "NK", prologue = "4a6f686e2047616c74",
            init_ephemeral = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
            init_remote_static = "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62",
            resp_static = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
            resp_ephemeral = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
            handshake_hash = "2efa38a9c7c93ac98f3a097af25c2f58b9e7673787717bc27e98827118c2c1a5",
            messages = {
                { "4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79448134d00711fdb390a0d178fa008f6d47d2891e5ea18ae136c3b4c23ac384efb0" },
                { "4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088438ea16e3701bc0d77744f117bee22451c9afa7f4cdbbcff00c04a8ee0913c88" },
                { "462e20412e20486179656b", "a62de29ce27cb80245d440d986ed816c156e9d757d7008df2198b0" },
                { "4361726c204d656e676572", "174a35f11c689f4530d7208618e0564ae12f2f50ba8eb4df5382ff" },
                { "4a65616e2d426170746973746520536179", "337e475ebb8eae60f91974c4e455a5af38d1d8628d1803b160d60442874b0a1777" },
                { "457567656e2042f6686d20766f6e2042617765726b", "047e80e060b7bb08b53c5a23dfe9920cae135b9d1dc6302fc475003062723700366346ac9d" },
            },
        },
        {
            pattern = "IK", prologue = "4a6f686e2047616c74",
            init_static = "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
            init_ephemeral = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
            init_remote_static = "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62",
            resp_static = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
            resp_ephemeral = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
            handshake_hash = "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7",
            messages = {
                { "4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7" },
                { "4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5" },
                { "462e20412e20486179656b", "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8" },
                { "4361726c204d656e676572", "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667" },
                { "4a65616e2d426170746973746520536179", "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4" },
            },
        },
        {
            pattern = "XXpsk3", prologue = "4a6f686e2047616c74",
            psk = "54686973206973206d7920417573747269616e20706572737065637469766521",
            init_static = "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
            init_ephemeral = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
            resp_static = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
            resp_ephemeral = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
            handshake_hash = "a477edf6a131bbdb54707f6ea30eab6cd935d9b560f0e5fd1f053a95a99669fb",
            messages = {
                { "4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944c9f5ff0e8079630cb7e270c20bbf480821b77a384a645c71a2fd9b3db1c16a5f" },
                { "4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843b123def17f71e6ae8e57e0e1dec5949c5f7415c6f33517398747d821a06dc23ad430aa1fd7381d46195c378a819fd574425462cbb2d4ca339e738a0b7001dc91423fbf55a99af0c6f1df21012ceb2f" },
                { "462e20412e20486179656b", "52187316111b118d4c060364f7b975dc0809b2590779aff2d63113c564f11744493384db7bf32d5ae6686df6ab06d508d2e07caaf1d6afc010b978735fc78900e71ae1d314130d042e729a" },
                { "4361726c204d656e676572", "eaedc672d4c21e0e2955758756fb98f194c4e90d5deb5b6cf30b27" },
                { "4a65616e2d426170746973746520536179", "522d543c5fe799d09a3d9da7ff54d0dc03c8af1dc7751d2ff708339d2290943e98" },
            },
        },
    }

    it("derives public keys", function()
        expect(hex(noise.public_key(crypto, unhex(VECTORS[2].resp_static)))):eq(VECTORS[2].init_remote_static)
    end)

    for _, vector in ipairs(VECTORS) do
        it("matches the test vectors for Noise_" .. vector.pattern .. "_25519_ChaChaPoly_SHA256", function()
            local initiator = noise.new {
                crypto = crypto, pattern = vector.pattern, initiator = true, prologue = unhex(vector.prologue),
                static = vector.init_static and static(vector.init_static),
                remote_static = vector.init_remote_static and unhex(vector.init_remote_static),
                ephemeral = unhex(vector.init_ephemeral), psk = vector.psk and unhex(vector.psk),
            }
            local responder = noise.new {
                crypto = crypto, pattern = vector.pattern, initiator = false, prologue = unhex(vector.prologue),
                static = static(vector.resp_static), ephemeral = unhex(vector.resp_ephemeral),
                psk = vector.psk and unhex(vector.psk),
            }

            local i_send, i_receive, r_send, r_receive
            for index, message in ipairs(vector.messages) do
                local payload, expected = unhex(message[1]), message[2]
                local from_initiator = index % 2 == 1
                local ciphertext, received
                if not initiator:done() then
                    local writer, reader = initiator, responder
                    if not from_initiator then writer, reader = responder, initiator end
                    expect(writer:writing()):eq(true)
                    ciphertext = writer:write(payload)
                    received = reader:read(ciphertext)
                    if initiator:done() then
                        expect(hex(initiator.h)):eq(vector.handshake_hash)
                        expect(hex(responder.h)):eq(vector.handshake_hash)
                        i_send, i_receive = initiator:split()
                        r_send, r_receive = responder:split()
                    end
                elseif from_initiator then
                    ciphertext = i_send:encrypt(payload)
                    received = r_receive:decrypt(ciphertext)
                else
                    ciphertext = r_send:encrypt(payload)
                    received = i_receive:decrypt(ciphertext)
                end
                expect(hex(ciphertext)):describe("Message " .. index):eq(expected)
                expect(received):describe("Message " .. index):eq(payload)
            end
        end)
    end

    describe("handshakes", function()
        local function pair(pattern)
            local i_private, r_private = crypto.generateKeyPair("x25519"), crypto.generateKeyPair("x25519")
            local i_static = { public = noise.public_key(crypto, i_private), exchange = function(p) return crypto.exchange(i_private, p) end }
            local r_static = { public = noise.public_key(crypto, r_private), exchange = function(p) return crypto.exchange(r_private, p) end }
            local initiator = noise.new {
                crypto = crypto, pattern = pattern, initiator = true, static = i_static,
                remote_static = pattern == "NK" and r_static.public or nil,
            }
            local responder = noise.new { crypto = crypto, pattern = pattern, initiator = false, static = r_static }
            return initiator, responder, i_static, r_static
        end

        -- Both sides of a handshake of any pattern.
        local function parties(pattern)
            local function key()
                local private = crypto.generateKeyPair("x25519")
                return { public = noise.public_key(crypto, private), exchange = function(p) return crypto.exchange(private, p) end }
            end
            local i_static, r_static = key(), key()
            local psk = pattern == "XXpsk3" and crypto.random(32) or nil
            return noise.new {
                crypto = crypto, pattern = pattern, initiator = true, static = i_static, psk = psk,
                remote_static = (pattern == "NK" or pattern == "IK") and r_static.public or nil,
            }, noise.new { crypto = crypto, pattern = pattern, initiator = false, static = r_static, psk = psk }
        end

        -- Run a handshake, changing one of its messages on the way. Returns whether both sides finished it, agreeing,
        -- and how long each message was.
        local function handshake(pattern, index, change)
            local initiator, responder = parties(pattern)
            local lengths = {}
            while not initiator:done() do
                local i = #lengths + 1
                local writer, reader = initiator, responder
                if i % 2 == 0 then writer, reader = responder, initiator end
                local message = writer:write("payload " .. i)
                if not message then return false, lengths end
                lengths[i] = #message
                if i == index then message = change(message) end
                if reader:read(message) == nil then return false, lengths end
            end
            return responder:done() and initiator.h == responder.h, lengths
        end

        local LOW_ORDER = {
            ("\0"):rep(32), "\1" .. ("\0"):rep(31), "\236" .. ("\255"):rep(30) .. "\127", "\237" .. ("\255"):rep(30) .. "\127",
        }

        for _, pattern in ipairs { "XX", "NK", "IK", "XXpsk3" } do
            it("of " .. pattern .. " fail, without errors, however a message is changed", function()
                math.randomseed(53)
                local worked, lengths = handshake(pattern)
                expect(worked):eq(true)
                for index, length in ipairs(lengths) do
                    for position = 1, length do
                        local flipped = handshake(pattern, index, function(message)
                            return message:sub(1, position - 1) .. string.char(bit32.bxor(message:byte(position), 2 ^ math.random(0, 7)))
                                .. message:sub(position + 1)
                        end)
                        expect(flipped):describe(("Message %d with byte %d changed"):format(index, position)):eq(false)
                        if position % 8 == 0 then
                            expect((handshake(pattern, index, function(message) return message:sub(1, position - 1) end)))
                                :describe(("Message %d cut to %d bytes"):format(index, position - 1)):eq(false)
                        end
                    end
                    expect((handshake(pattern, index, function(message) return message .. "x" end)))
                        :describe(("Message %d with a byte more"):format(index)):eq(false)
                    for i, point in ipairs(LOW_ORDER) do
                        expect((handshake(pattern, index, function(message) return point .. message:sub(33) end)))
                            :describe(("Message %d with bad key %d"):format(index, i)):eq(false)
                    end
                    for _, odd in ipairs { false, 5, {}, "" } do
                        expect((handshake(pattern, index, function() return odd end))):eq(false)
                    end
                end
            end)
        end

        it("can be copied, to read a message which may not be meant for them", function()
            local initiator, responder = parties("IK")
            expect(responder:read(initiator:write("hello"))):eq("hello")
            local reply = responder:write("welcome")

            -- Something which only looks like the answer spoils the copy, not the handshake.
            local attempt = initiator:clone()
            expect(attempt:read(("x"):rep(#reply))):eq(nil)
            attempt = initiator:clone()
            expect(attempt:read(reply:sub(1, -2) .. "x")):eq(nil)
            expect(initiator:done()):eq(false)

            attempt = initiator:clone()
            expect(attempt:read(reply)):eq("welcome")
            expect(attempt:done()):eq(true)
            expect(attempt.h):eq(responder.h)
        end)

        it("tell each side the other's key", function()
            local initiator, responder, i_static, r_static = pair("XX")
            responder:read(initiator:write())
            initiator:read(responder:write())
            responder:read(initiator:write())
            expect(initiator:done() and responder:done()):eq(true)
            expect(initiator.rs):eq(r_static.public)
            expect(responder.rs):eq(i_static.public)
        end)

        it("fail when a message is changed", function()
            for index = 1, 3 do
                local initiator, responder = pair("XX")
                local parties = { initiator, responder, initiator }
                local readers = { responder, initiator, responder }
                local failed = false
                for i = 1, 3 do
                    local message = parties[i]:write("payload")
                    if i == index then
                        -- Flip one bit in the last byte. Message 1 isn't encrypted, so change its key instead.
                        local at = index == 1 and 1 or #message
                        message = message:sub(1, at - 1) .. string.char(bit32.bxor(message:byte(at), 1)) .. message:sub(at + 1)
                    end
                    local payload = readers[i]:read(message)
                    if payload == nil then
                        failed = true
                        break
                    end
                end
                expect(failed):describe("Changed message " .. index):eq(true)
            end
        end)

        it("fail with the wrong responder key", function()
            local initiator = noise.new {
                crypto = crypto, pattern = "NK", initiator = true, remote_static = noise.public_key(crypto, crypto.generateKeyPair("x25519")),
            }
            local _, responder = pair("NK")
            expect(responder:read(initiator:write("hello"))):eq(nil)
        end)

        it("reject truncated and odd messages", function()
            local initiator, responder = pair("XX")
            responder:read(initiator:write())
            local message = responder:write()
            expect(initiator:read(message:sub(1, 40))):eq(nil)
            local _, other = pair("XX")
            expect(other:read({})):eq(nil)
            expect(other:read("")):eq(nil)
        end)
    end)
end)
