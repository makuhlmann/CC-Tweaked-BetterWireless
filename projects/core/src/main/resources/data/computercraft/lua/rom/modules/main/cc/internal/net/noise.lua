-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The Noise Protocol Framework's handshakes (https://noiseprotocol.org/noise.html), with X25519, ChaCha20-Poly1305
and SHA-256, on top of the `crypto` API.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use `net.secure` instead.

Two handshake patterns are supported:

 - `XX`: both sides send their long-term (static) keys, encrypted, so both learn who the other is. Three messages.
 - `NK`: the initiator already knows the responder's static key, and stays anonymous. Two messages.

A side's static key is given as its public key and a function doing X25519 with its private key, so the private key can
stay in the enclave.

@local
]]

local HASH_LENGTH = 32
local KEY_LENGTH = 32
local TAG_LENGTH = 16

local BASE_POINT = "\9" .. ("\0"):rep(31)

local PATTERNS = {
    XX = { pre_responder = false, messages = { { "e" }, { "e", "ee", "s", "es" }, { "s", "se" } } },
    NK = { pre_responder = true, messages = { { "e", "es" }, { "e", "ee" } } },
}

local function nonce(n)
    return string.pack("<I4I8", 0, n)
end

--- A cipher with a key, counting the messages it handles (the nonce).
local Cipher = {}
Cipher.__index = Cipher

local function new_cipher(crypto, key)
    return setmetatable({ crypto = crypto, key = key, n = 0 }, Cipher)
end

--[[- Encrypt a message.

@tparam string plaintext The message.
@tparam[opt=""] string ad Data to authenticate along with it.
@treturn string The ciphertext, 16 bytes longer.
]]
function Cipher:encrypt(plaintext, ad)
    local ciphertext = self.crypto.seal(self.key, nonce(self.n), plaintext, ad or "")
    self.n = self.n + 1
    return ciphertext
end

--[[- Decrypt a message. Messages must be decrypted in the order they were encrypted.

@tparam string ciphertext The ciphertext.
@tparam[opt=""] string ad The data authenticated with it.
@treturn string|nil The message, or `nil` if it was tampered with (or is out of order).
]]
function Cipher:decrypt(ciphertext, ad)
    if #ciphertext < TAG_LENGTH then return nil end
    local plaintext = self.crypto.open(self.key, nonce(self.n), ciphertext, ad or "")
    if plaintext == nil then return nil end
    self.n = self.n + 1
    return plaintext
end

local Handshake = {}
Handshake.__index = Handshake

-- HKDF with the chaining key as the salt and an empty info string, giving two 32-byte outputs.
function Handshake:hkdf(ikm)
    local hmac = self.crypto.hmac
    local temp = hmac(self.ck, ikm)
    local first = hmac(temp, "\1")
    return first, hmac(temp, first .. "\2")
end

function Handshake:mix_hash(data)
    self.h = self.crypto.sha256(self.h .. data)
end

function Handshake:mix_key(ikm)
    local key
    self.ck, key = self:hkdf(ikm)
    self.cipher = new_cipher(self.crypto, key)
end

function Handshake:encrypt_and_hash(plaintext)
    local ciphertext = self.cipher and self.cipher:encrypt(plaintext, self.h) or plaintext
    self:mix_hash(ciphertext)
    return ciphertext
end

function Handshake:decrypt_and_hash(ciphertext)
    local plaintext = ciphertext
    if self.cipher then
        plaintext = self.cipher:decrypt(ciphertext, self.h)
        if not plaintext then error("decrypt", 0) end
    end
    self:mix_hash(ciphertext)
    return plaintext
end

-- X25519 between one of our key pairs and one of theirs.
function Handshake:dh(ours, theirs)
    if ours == "e" then return self.crypto.exchange(self.e.private, theirs) end
    return self.s.exchange(theirs)
end

-- The DH a token means, from our side.
function Handshake:token_dh(token)
    if token == "ee" then return self:dh("e", self.re) end
    local initiator = self.initiator
    if token == "es" then
        if initiator then return self:dh("e", self.rs) else return self:dh("s", self.re) end
    elseif token == "se" then
        if initiator then return self:dh("s", self.re) else return self:dh("e", self.rs) end
    end
end

--[[- Write the next handshake message.

@tparam[opt=""] string payload Data to send with it. It's encrypted unless it's the first message of an `XX` handshake.
@treturn string The message.
]]
function Handshake:write(payload)
    local pattern = self.pattern.messages[self.index]
    local parts = {}
    for _, token in ipairs(pattern) do
        if token == "e" then
            if not self.e then
                local private = self.fixed_ephemeral or self.crypto.generateKeyPair("x25519")
                self.e = { private = private, public = self.crypto.exchange(private, BASE_POINT) }
            end
            parts[#parts + 1] = self.e.public
            self:mix_hash(self.e.public)
        elseif token == "s" then
            parts[#parts + 1] = self:encrypt_and_hash(self.s.public)
        else
            self:mix_key(self:token_dh(token))
        end
    end
    parts[#parts + 1] = self:encrypt_and_hash(payload or "")
    self.index = self.index + 1
    return table.concat(parts)
end

--[[- Read the next handshake message.

@tparam string message The message.
@treturn[1] string The payload sent with it.
@treturn[2] nil If the message is malformed, or was tampered with.
]]
function Handshake:read(message)
    if type(message) ~= "string" then return nil end
    local pattern = self.pattern.messages[self.index]
    local ok, payload = pcall(function()
        local position = 1
        local function take(length)
            if position + length - 1 > #message then error("short", 0) end
            local part = message:sub(position, position + length - 1)
            position = position + length
            return part
        end

        for _, token in ipairs(pattern) do
            if token == "e" then
                self.re = take(KEY_LENGTH)
                self:mix_hash(self.re)
            elseif token == "s" then
                self.rs = self:decrypt_and_hash(take(KEY_LENGTH + (self.cipher and TAG_LENGTH or 0)))
            else
                self:mix_key(self:token_dh(token))
            end
        end
        return self:decrypt_and_hash(message:sub(position))
    end)
    if not ok then
        self.failed = true
        return nil
    end
    self.index = self.index + 1
    return payload
end

--- Whether it's our turn to write.
--
-- @treturn boolean Whether to call `write` next (rather than `read`).
function Handshake:writing()
    return (self.index % 2 == 1) == self.initiator
end

--- Whether the handshake is over.
--
-- @treturn boolean Whether every message has been written or read.
function Handshake:done()
    return self.index > #self.pattern.messages
end

--[[- Finish the handshake, getting the ciphers for the messages after it.

@treturn table The cipher for messages we send.
@treturn table The cipher for messages we receive.
]]
function Handshake:split()
    local first, second = self:hkdf("")
    local initiator_to_responder, responder_to_initiator = new_cipher(self.crypto, first), new_cipher(self.crypto, second)
    if self.initiator then return initiator_to_responder, responder_to_initiator end
    return responder_to_initiator, initiator_to_responder
end

--[[- Start a handshake.

@tparam {
    crypto = table,
    pattern = string,
    initiator = boolean,
    prologue? = string,
    static? = { public = string, exchange = function(public:string):string },
    remote_static? = string,
    ephemeral? = string,
} options The `crypto` API; the pattern (`"XX"` or `"NK"`); whether we start it; data both sides must agree on;
our static key; the other side's static key, if we know it already (the initiator of `NK` must); and, for tests only, a
fixed private ephemeral key.
@treturn table The handshake.
]]
local function new(options)
    local pattern = PATTERNS[options.pattern]
    if not pattern then error("Unknown handshake pattern " .. tostring(options.pattern), 2) end

    local crypto = options.crypto
    local name = "Noise_" .. options.pattern .. "_25519_ChaChaPoly_SHA256"
    local h = #name <= HASH_LENGTH and name .. ("\0"):rep(HASH_LENGTH - #name) or crypto.sha256(name)
    local self = setmetatable({
        crypto = crypto, pattern = pattern, initiator = options.initiator, index = 1,
        h = h, ck = h, s = options.static, rs = options.remote_static, fixed_ephemeral = options.ephemeral,
    }, Handshake)

    self:mix_hash(options.prologue or "")
    if pattern.pre_responder then
        local responder_static = self.initiator and self.rs or self.s.public
        if not responder_static then error("This handshake needs the responder's static key", 2) end
        self:mix_hash(responder_static)
    end
    return self
end

--- Work out the public key of an X25519 private key.
--
-- @tparam table crypto The `crypto` API.
-- @tparam string private The private key.
-- @treturn string The public key.
local function public_key(crypto, private)
    return crypto.exchange(private, BASE_POINT)
end

return {
    new = new,
    public_key = public_key,
}
