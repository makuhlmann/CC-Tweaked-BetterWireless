-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Secure connections: a Noise handshake over a connection, then every message encrypted and authenticated.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use `net.secure` instead.

The handshake's messages are the connection's first messages. The first is a table naming the handshake pattern:
`{ secure = 1, pattern = "XX" or "NK", message = <bytes> }`. The rest are strings. Each side's handshake payload is a
table encoded with [`cc.net.codec`]: the responder's carries its certificate, if it has one.

After the handshake, each message is `{ d = value }`, encoded and encrypted with a counter as the nonce. Connections
deliver messages once and in order, so the counters stay in step without being sent. Anything which doesn't decrypt was
tampered with (or replayed, or reordered), and ends the connection: there's no way to carry on safely. Closing sends an
encrypted `{ close = true }` first, so a connection which ends without one was cut short by someone.

Both work over any transport with `send(value)`, `receive([timeout])`, `close()` and `abort()` methods, which wait as
the net API's connections do.

@local
]]

local codec = require "cc.net.codec"
local noise = require "cc.internal.net.noise"

local PROLOGUE = "cc-net secure 1"
local VERSION = 1

--- The largest encoded message: connections carry messages of up to 60 KiB, as modems estimate sizes (a string costs
-- its length and 2 bytes), and encryption adds a 16 byte tag.
local MAX_ENCODED = 60 * 1024 - 2 - 16

local Session = {}
Session.__index = Session

-- Something went wrong which the connection can't recover from: end it, and keep saying why.
local function fail(self, reason)
    if not self.error then
        self.error = reason
        self.transport:abort()
    end
    return nil, self.error
end

--[[- Send a message.

@param value The message: anything [`cc.net.codec`] can encode, except `nil`.
@treturn[1] true If it was sent.
@treturn[2] nil If it couldn't be.
@treturn[2] string Why not.
]]
function Session:send(value)
    if self.error then return nil, self.error end
    if self.closing then return nil, "Connection closed" end
    if value == nil then return nil, "Can't send nil" end

    local ok, encoded = pcall(codec.encode, { d = value })
    if not ok then return nil, encoded end
    if #encoded > MAX_ENCODED then return nil, "Message too large" end

    local sent, err = self.transport:send(self.send_cipher:encrypt(encoded))
    -- The counters are now out of step with the other side, so nothing more can be sent.
    if not sent then return fail(self, err) end
    return true
end

--[[- Wait for the next message.

@tparam[opt] number timeout How long to wait, in seconds.
@return[1] The message.
@treturn[2] nil If the other side closed, and every message has been received.
@treturn[3] nil If nothing arrived in time, or the connection failed.
@treturn[3] string Why: `"Timed out"`, `"Message was tampered with"`, `"Connection closed unexpectedly"`, or what
went wrong with the connection.
]]
function Session:receive(timeout)
    while true do
        if self.error then return nil, self.error end

        local message, err = self.transport:receive(timeout)
        if message == nil then
            -- Once the other side has said it's closing, we have everything it sent, whatever happens to the
            -- connection now.
            if self.peer_closed then return nil end
            if err == "Timed out" then return nil, err end
            if err then return fail(self, err) end
            -- The connection ended without the other side saying it was closing: someone cut it short.
            return fail(self, "Connection closed unexpectedly")
        end

        if self.peer_closed then return fail(self, "Message was tampered with") end
        local plaintext = type(message) == "string" and self.receive_cipher:decrypt(message)
        local decoded = plaintext and codec.decode(plaintext)
        if type(decoded) ~= "table" then return fail(self, "Message was tampered with") end

        if decoded.close == true then
            self.peer_closed = true
        elseif decoded.d ~= nil then
            return decoded.d
        else
            return fail(self, "Message was tampered with")
        end
    end
end

--- Close our side: tell the other side we're done, then close the connection.
function Session:close()
    if self.closing or self.error then return end
    self.closing = true
    local sent = self.transport:send(self.send_cipher:encrypt(codec.encode({ close = true })))
    if sent then self.transport:close() end
end

--- Drop the connection at once.
function Session:abort()
    if not self.error then self.error = "Connection closed" end
    self.transport:abort()
end

local function decode_payload(payload)
    local decoded = payload and codec.decode(payload)
    if type(decoded) ~= "table" or decoded.v ~= VERSION then return nil end
    return decoded
end

local function new_session(transport, handshake, info)
    local send_cipher, receive_cipher = handshake:split()
    return setmetatable({
        transport = transport, send_cipher = send_cipher, receive_cipher = receive_cipher,
        peer_key = handshake.rs, peer_info = info, handshake_hash = handshake.h,
    }, Session)
end

local function client_handshake(transport, options)
    local pattern = options.pattern or "XX"
    local handshake = noise.new {
        crypto = options.crypto, pattern = pattern, initiator = true, prologue = PROLOGUE,
        static = options.static, remote_static = options.remote_static,
    }

    local message, err = handshake:write(codec.encode({ v = VERSION }))
    if not message then return nil, "The handshake failed: " .. err end
    local ok
    ok, err = transport:send({ secure = VERSION, pattern = pattern, message = message })
    if not ok then return nil, err end

    message, err = transport:receive(options.timeout)
    if message == nil then return nil, "The handshake failed: " .. (err or "the server closed the connection") end
    local info = decode_payload(handshake:read(message))
    if not info then return nil, "The handshake failed: the server isn't who we expected, or someone interfered" end

    -- Check the server is who we want before telling it who we are.
    if options.verify then
        local trusted, reason = options.verify(handshake.rs, info)
        if not trusted then return nil, reason or "The server isn't trusted" end
    end

    if not handshake:done() then
        message, err = handshake:write(codec.encode({ v = VERSION }))
        if not message then return nil, "The handshake failed: " .. err end
        ok, err = transport:send(message)
        if not ok then return nil, err end
    end
    return new_session(transport, handshake, info)
end

local function server_handshake(transport, options)
    local first, err = transport:receive(options.timeout)
    if first == nil then return nil, err or "The client closed the connection" end
    if type(first) ~= "table" or first.secure ~= VERSION or (first.pattern ~= "XX" and first.pattern ~= "NK")
        or type(first.message) ~= "string" then
        return nil, "Not a secure connection"
    end
    if first.pattern == "NK" and not options.anonymous then return nil, "The client didn't say who it is" end

    local handshake = noise.new {
        crypto = options.crypto, pattern = first.pattern, initiator = false, prologue = PROLOGUE, static = options.static,
    }
    if not decode_payload(handshake:read(first.message)) then return nil, "The handshake failed" end

    -- Answering uses the key the client just sent, which may be one no secret can be agreed with.
    local message, ok
    message, err = handshake:write(codec.encode({ v = VERSION, certificate = options.certificate }))
    if not message then return nil, "The handshake failed: " .. err end
    ok, err = transport:send(message)
    if not ok then return nil, err end

    if not handshake:done() then
        message, err = transport:receive(options.timeout)
        if message == nil then return nil, err or "The client closed the connection" end
        if not decode_payload(handshake:read(message)) then return nil, "The handshake failed" end
    end
    return new_session(transport, handshake, {})
end

--[[- Run the client's side of a handshake on a connection.

@tparam table transport The connection.
@tparam {
    crypto = table,
    static? = { public = string, exchange = function(public:string):string },
    remote_static? = string,
    pattern? = string,
    timeout? = number,
    verify? = function(key:string, info:table):boolean|nil, string|nil,
} options The `crypto` API; our static key (needed for `XX`, the default); the server's key, if we know it (needed for
`NK`, which leaves us anonymous); how long to wait for each answer; and a check of the server's key and handshake
payload, before we tell it who we are.
@treturn[1] table The session, with `send`, `receive`, `close` and `abort` methods, and the server's key in `peer_key`
and its handshake payload (such as `certificate`) in `peer_info`.
@treturn[2] nil If the handshake failed.
@treturn[2] string Why.
]]
local function client(transport, options)
    -- A failed handshake ends the connection, so the other side hears straight away.
    local session, err = client_handshake(transport, options)
    if not session then transport:abort() end
    return session, err
end

--[[- Run the server's side of a handshake on a connection.

@tparam table transport The connection.
@tparam {
    crypto = table,
    static = { public = string, exchange = function(public:string):string },
    certificate? = string,
    timeout? = number,
    anonymous? = boolean,
} options The `crypto` API; our static key; our certificate, if we have one; how long to wait for each message; and
whether to accept clients which don't say who they are.
@treturn[1] table The session. `peer_key` is the client's key, or `nil` if it stayed anonymous.
@treturn[2] nil If the handshake failed.
@treturn[2] string Why.
]]
local function server(transport, options)
    local session, err = server_handshake(transport, options)
    if not session then transport:abort() end
    return session, err
end

return {
    client = client,
    server = server,
    MAX_ENCODED = MAX_ENCODED,
}
