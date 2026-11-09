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
                ephemeral = unhex(vector.init_ephemeral),
            }
            local responder = noise.new {
                crypto = crypto, pattern = vector.pattern, initiator = false, prologue = unhex(vector.prologue),
                static = static(vector.resp_static), ephemeral = unhex(vector.resp_ephemeral),
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
