-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local function hex(s)
    return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

describe("The crypto library", function()
    it("hashes binary strings", function()
        expect(hex(crypto.sha256("abc"))):eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        expect(#crypto.sha256("\0\255\128")):eq(32)
    end)

    it("generates random bytes", function()
        expect(#crypto.random(16)):eq(16)
        expect(crypto.random(0)):eq("")
        expect.error(crypto.random, -1):eq("Length must be between 0 and 1048576")
    end)

    it("seals and opens messages", function()
        local key, nonce = crypto.random(32), crypto.random(12)
        local sealed = crypto.seal(key, nonce, "Hello, world!", "header")
        expect(#sealed):eq(#"Hello, world!" + 16)
        expect(crypto.open(key, nonce, sealed, "header")):eq("Hello, world!")
        expect(crypto.open(key, nonce, sealed, "other header")):eq(nil)
        expect(crypto.open(key, nonce, sealed)):eq(nil)
    end)

    it("checks key and nonce lengths", function()
        expect.error(crypto.seal, "short", crypto.random(12), "x"):eq("The key must be 32 bytes")
        expect.error(crypto.seal, crypto.random(32), "short", "x"):eq("The nonce must be 12 bytes")
    end)

    it("agrees on shared secrets", function()
        local alicePrivate, alicePublic = crypto.generateKeyPair("x25519")
        local bobPrivate, bobPublic = crypto.generateKeyPair("x25519")
        expect(crypto.exchange(alicePrivate, bobPublic)):eq(crypto.exchange(bobPrivate, alicePublic))
    end)

    it("signs and verifies", function()
        local private, public = crypto.generateKeyPair("ed25519")
        local signature = crypto.sign(private, "message")
        expect(#signature):eq(64)
        expect(crypto.verify(public, "message", signature)):eq(true)
        expect(crypto.verify(public, "massage", signature)):eq(false)
    end)

    it("rejects unknown key kinds", function()
        expect.error(crypto.generateKeyPair, "rsa"):eq("Unknown key kind 'rsa' (expected x25519 or ed25519)")
    end)

    it("compares strings", function()
        expect(crypto.equals("abc", "abc")):eq(true)
        expect(crypto.equals("abc", "abd")):eq(false)
    end)
end)
