-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Encrypted links: every frame on an interface sealed with a key derived from a passphrase, like WPA.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `net.<interface>.psk` setting instead.

A sealed frame is `{ net = 1, src, dst, type = "sealed", body = { counter, data } }`. `data` is the frame's real type,
body and whether it was forwarded, encoded with [`cc.net.codec`] and encrypted with ChaCha20-Poly1305. The nonce is the
sender's ID and the counter, and the sender, receiver and counter are authenticated with it, so a frame can't be changed
or sent to anyone else.

Counters come from real time: `os.epoch("utc")` in milliseconds, times 1024, so they keep growing even when a computer
restarts. Every computer on a server shares that clock, so frames more than a minute from now are refused, and a
receiver only needs to remember which recent frames it has seen to refuse replays.

There's no forward secrecy: anyone who learns the passphrase can read everything sent with it, past and future. Use
secure connections for anything sensitive.

@local
]]

local codec = require "cc.net.codec"

local SALT = "cc-net link key 1"
local ITERATIONS = 4096

-- Counters per millisecond, and how far from now (in milliseconds) a frame's counter may be.
local PER_MS = 1024
local MAX_AGE = 60 * 1000
-- How far behind the newest frame from a computer (in milliseconds) a frame may arrive, out of order.
local REORDER = 2 * 1000
local MAX_PEERS = 512

--[[- Turn a passphrase into a link key.

@tparam table crypto The `crypto` API.
@tparam string passphrase The passphrase.
@treturn string The key.
]]
local function derive(crypto, passphrase)
    return crypto.pbkdf2(passphrase, SALT, ITERATIONS, 32)
end

--[[- Set up a link.

@tparam table|nil crypto The `crypto` API, or `nil` if there isn't one, in which case nothing can be sent or received.
@tparam string|nil key The key from [`derive`].
@tparam function():number epoch The time, in milliseconds, as `os.epoch("utc")` gives.
@treturn table The link.
]]
local function new(crypto, key, epoch)
    return { crypto = crypto, key = key, epoch = epoch, counter = 0, peers = {}, peer_count = 0 }
end

local function nonce(id, counter)
    return string.pack(">I4>I8", id % 0x100000000, counter)
end

local function aad(src, dst, counter)
    return codec.encode({ src, dst, counter })
end

--[[- Seal a frame's contents.

@tparam table link The link.
@tparam number src Our ID.
@tparam number dst The receiver's ID, or `-1` for everyone.
@tparam string kind The frame's type.
@param body The frame's body.
@tparam boolean|nil forwarded Whether it's a forwarded packet.
@treturn table|nil The sealed body, or `nil` if it can't be sealed.
]]
local function seal(link, src, dst, kind, body, forwarded)
    if not link.crypto or not link.key then return nil end
    local ok, plaintext = pcall(codec.encode, { type = kind, body = body, fwd = forwarded or nil })
    if not ok then return nil end

    local counter = math.max(link.counter + 1, math.floor(link.epoch() * PER_MS))
    link.counter = counter
    return { counter = counter, data = link.crypto.seal(link.key, nonce(src, counter), plaintext, aad(src, dst, counter)) }
end

-- Make room for a new computer, forgetting ones not heard from in longer than a frame stays valid.
local function make_room(link, now)
    for id, peer in pairs(link.peers) do
        if peer.top < now - MAX_AGE * PER_MS then
            link.peers[id] = nil
            link.peer_count = link.peer_count - 1
        end
    end
end

--[[- Open a sealed frame.

@tparam table link The link.
@tparam number src The sender's ID.
@tparam number dst The ID it was sent to.
@param sealed The sealed body.
@treturn[1] string The frame's type.
@return[1] The frame's body.
@treturn[1] boolean Whether it's a forwarded packet.
@treturn[2] nil If it's not from someone with the key, was changed, is too old, or was seen before.
]]
local function open(link, src, dst, sealed)
    if not link.crypto or not link.key or type(sealed) ~= "table" or type(sealed.data) ~= "string" then return nil end
    local counter = sealed.counter
    if type(counter) ~= "number" or counter % 1 ~= 0 or counter < 0 or counter > 2 ^ 53 then return nil end

    local now = link.epoch() * PER_MS
    if math.abs(counter - now) > MAX_AGE * PER_MS then return nil end
    local peer = link.peers[src]
    if peer and (counter <= peer.top - REORDER * PER_MS or peer.seen[counter]) then return nil end

    local plaintext = link.crypto.open(link.key, nonce(src, counter), sealed.data, aad(src, dst, counter))
    local inner = plaintext and codec.decode(plaintext)
    if type(inner) ~= "table" or type(inner.type) ~= "string" then return nil end

    if not peer then
        if link.peer_count >= MAX_PEERS then make_room(link, now) end
        -- Still full: refuse, rather than forget a computer whose frames could then be replayed.
        if link.peer_count >= MAX_PEERS then return nil end
        peer = { top = counter, seen = {}, count = 0 }
        link.peers[src] = peer
        link.peer_count = link.peer_count + 1
    end
    peer.seen[counter], peer.count = true, peer.count + 1
    if counter > peer.top then peer.top = counter end
    -- Now and then, forget frames too old to be accepted anyway.
    if peer.count > 256 then
        local floor, count = peer.top - REORDER * PER_MS, 0
        for seen in pairs(peer.seen) do
            if seen <= floor then peer.seen[seen] = nil else count = count + 1 end
        end
        peer.count = count
    end
    return inner.type, inner.body, inner.fwd == true
end

return {
    derive = derive,
    new = new,
    seal = seal,
    open = open,
}
