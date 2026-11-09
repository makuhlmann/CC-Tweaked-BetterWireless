-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Certificates: an authority's signed statement that a name has a key.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `netkeys` program instead.

A certificate is a table `{ v = 1, name, key, expires, issuer, signature }`: the name (such as `"bank.spawn"`), the
X25519 key the computer with that name uses for secure connections, when the certificate stops being valid (in
milliseconds, as `os.epoch("utc")` gives), the Ed25519 key of the authority which issued it, and the authority's
signature. The signature covers the other fields, encoded with [`cc.net.codec`] after a fixed prefix, so it can't be
mistaken for a signature over anything else.

@local
]]

local codec = require "cc.net.codec"

local VERSION = 1
local PREFIX = "cc-net certificate 1\0"

local function signed_bytes(certificate)
    return PREFIX .. codec.encode({
        v = VERSION, name = certificate.name, key = certificate.key, expires = certificate.expires, issuer = certificate.issuer,
    })
end

--[[- Issue a certificate.

@tparam {
    name = string, key = string, expires = number, issuer = string,
    sign = function(data:string):string,
} options The name; its X25519 public key; when it expires; the authority's Ed25519 public key; and a way to sign with
the authority's private key.
@treturn table The certificate.
]]
local function issue(options)
    local certificate = { v = VERSION, name = options.name, key = options.key, expires = options.expires, issuer = options.issuer }
    certificate.signature = options.sign(signed_bytes(certificate))
    return certificate
end

--- Write a certificate as bytes.
--
-- @tparam table certificate The certificate.
-- @treturn string The bytes.
local function encode(certificate)
    return codec.encode(certificate)
end

local function is_bytes(value, length) return type(value) == "string" and #value == length end

--[[- Read a certificate written by [`encode`].

@tparam string bytes The bytes.
@treturn table|nil The certificate, or `nil` if the bytes aren't one.
]]
local function decode(bytes)
    if type(bytes) ~= "string" then return nil end
    local certificate = codec.decode(bytes)
    if type(certificate) ~= "table" or certificate.v ~= VERSION or type(certificate.name) ~= "string"
        or #certificate.name > 255 or not is_bytes(certificate.key, 32) or type(certificate.expires) ~= "number"
        or not is_bytes(certificate.issuer, 32) or not is_bytes(certificate.signature, 64) then
        return nil
    end
    return certificate
end

--[[- Check a certificate vouches for a computer.

@tparam table crypto The `crypto` API.
@tparam table certificate The certificate.
@tparam {
    name = string, key = string, now = number, trusted = { [string] = any },
} options The name we wanted; the key the computer proved it has; the time; and the authorities we trust, by key.
@treturn[1] true If the certificate is good.
@treturn[2] nil If it isn't.
@treturn[2] string Why not, such as `"has expired"`.
]]
local function verify(crypto, certificate, options)
    if not options.trusted[certificate.issuer] then return nil, "was issued by an authority this computer doesn't trust" end
    if not crypto.verify(certificate.issuer, signed_bytes(certificate), certificate.signature) then
        return nil, "has a bad signature"
    end
    -- A good certificate for a different key would let anyone with a certificate pretend to be anyone.
    if not crypto.equals(certificate.key, options.key) then return nil, "is for a different key" end
    if certificate.name ~= options.name then return nil, "is for " .. certificate.name end
    if certificate.expires <= options.now then return nil, "has expired" end
    return true
end

return {
    issue = issue,
    encode = encode,
    decode = decode,
    verify = verify,
}
