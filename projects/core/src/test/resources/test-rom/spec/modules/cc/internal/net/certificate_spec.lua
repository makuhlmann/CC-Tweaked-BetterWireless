-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.certificate", function()
    local certificate = require "cc.internal.net.certificate"
    local noise = require "cc.internal.net.noise"

    local authority_private, authority_public = crypto.generateKeyPair("ed25519")
    local server_key = noise.public_key(crypto, crypto.generateKeyPair("x25519"))

    local function issue(overrides)
        local options = {
            name = "bank.spawn", key = server_key, expires = 2000, issuer = authority_public,
            sign = function(data) return crypto.sign(authority_private, data) end,
        }
        for k, v in pairs(overrides or {}) do options[k] = v end
        return certificate.issue(options)
    end

    local function check(cert, overrides)
        local options = { name = "bank.spawn", key = server_key, now = 1000, trusted = { [authority_public] = true } }
        for k, v in pairs(overrides or {}) do options[k] = v end
        return certificate.verify(crypto, cert, options)
    end

    it("vouches for a name's key", function()
        local cert = certificate.decode(certificate.encode(issue()))
        expect(cert):ne(nil)
        expect(check(cert)):eq(true)
    end)

    it("fails for the wrong name, key or time, or an untrusted authority", function()
        local cert = issue()
        expect({ check(cert, { name = "evil.spawn" }) }):same { nil, "is for bank.spawn" }
        expect({ check(cert, { key = noise.public_key(crypto, crypto.generateKeyPair("x25519")) }) }):same { nil, "is for a different key" }
        expect({ check(cert, { now = 2000 }) }):same { nil, "has expired" }
        expect({ check(cert, { trusted = {} }) }):same { nil, "was issued by an authority this computer doesn't trust" }
    end)

    it("fails if anything was changed", function()
        for _, change in ipairs {
            { name = "evil.spawn" }, { expires = 10 ^ 15 }, { key = noise.public_key(crypto, crypto.generateKeyPair("x25519")) },
        } do
            local cert = issue()
            for k, v in pairs(change) do cert[k] = v end
            local ok, err = check(cert, { name = cert.name, key = cert.key })
            expect(ok):eq(nil)
            expect(err):eq("has a bad signature")
        end
    end)

    it("rejects things which aren't certificates", function()
        expect(certificate.decode("junk")):eq(nil)
        expect(certificate.decode(nil)):eq(nil)
        local cert = issue()
        cert.signature = "short"
        expect(certificate.decode(certificate.encode(cert))):eq(nil)
    end)
end)
