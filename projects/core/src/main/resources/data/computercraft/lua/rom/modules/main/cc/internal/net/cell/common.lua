-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What phones, cells and the core share: system information, cell certificates, keys, and sealed messages.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cell` programs instead.

@local
]]

local codec = require "cc.net.codec"
local certificate = require "cc.internal.net.certificate"

--- The frame type for everything between phones and cells.
local FRAME = "cell"

--- The port of the gateway's end of tunnels between cells and the gateway (like LTE's GTP-U).
local TUNNEL_PORT = 2152

--- The port of the cells' end of tunnels. It differs from the gateway's, so a computer can be a cell and the core.
local CELL_TUNNEL_PORT = 2153

--- The number in the nonce for messages from phones (and cells' tunnels to the gateway).
local UPLINK = 1

--- The number in the nonce for messages to phones (and the gateway's tunnels to cells).
local DOWNLINK = 2

--- The port cells reach the core on, for control messages.
local CONTROL_PORT = 2123

--- How often cells send system information, in seconds.
local SIB_INTERVAL = 1

-- System information older (or newer) than this, in milliseconds, isn't believed: it may be a recording.
local SIB_MAX_AGE = 30 * 1000

local SIB_PREFIX = "cc-net cell sib 1\0"
local CELL_KEY_PREFIX = "cc-net cell key 1\0"
local TUNNEL_KEY_PREFIX = "cc-net tunnel key 1\0"

-- How many sealed messages arriving out of order are accepted: the counters within this many of the newest.
local REPLAY_WINDOW = 64

--- The name a cell's certificate is for: its network and its ID.
--
-- @tparam string network The network's name.
-- @tparam number cell The cell's computer ID.
-- @treturn string The name.
local function cell_name(network, cell)
    return ("%s/cell/%d"):format(network, cell)
end

--- The most relays a cell's backhaul may go through.
local MAX_PATH = 16

--[[- Check a cell's path: the relays its backhaul goes through, as a list of their IDs.

@param path The path, which may be anything.
@treturn boolean Whether it's a path.
]]
local function is_path(path)
    if type(path) ~= "table" or #path > MAX_PATH then return false end
    for k, v in pairs(path) do
        if type(k) ~= "number" or k < 1 or k > #path or k % 1 ~= 0 or type(v) ~= "number" then return false end
    end
    return true
end

--[[- Make the signed system information a cell broadcasts.

@tparam {
    network = string, cell = number, area = number, load = number, time = number, path? = { number... },
    certificate = string, sign = function(data:string):string,
} options The network; the cell's ID, tracking area and how busy it is (from 0 to 1); the time, as `os.epoch("utc")`
gives; the relays the cell's backhaul goes through, nearest first, if it's a relay; the cell's certificate, from the
operator; and a way to sign with the cell's key.
@treturn table The system information.
]]
local function make_sib(options)
    local fields = {
        network = options.network, cell = options.cell, area = options.area, load = options.load, time = options.time,
        path = options.path and #options.path > 0 and options.path or nil,
    }
    local sib = { op = "sib", cert = options.certificate, sig = options.sign(SIB_PREFIX .. codec.encode(fields)) }
    for k, v in pairs(fields) do sib[k] = v end
    return sib
end

--[[- Check system information comes from a real cell of a network.

@tparam table crypto The `crypto` API.
@param sib The system information, which may be anything.
@tparam {
    network = string, signing = string, now = number, sender = number,
} options The network we want; its operator's Ed25519 key; the time; and the ID of the computer which sent it.
@treturn[1] true If it's good.
@treturn[2] nil If it isn't.
@treturn[2] string Why not.
]]
local function check_sib(crypto, sib, options)
    if type(sib) ~= "table" or sib.network ~= options.network or sib.cell ~= options.sender then return nil, "not ours" end
    if type(sib.area) ~= "number" or type(sib.load) ~= "number" or type(sib.time) ~= "number"
        or type(sib.sig) ~= "string" or #sib.sig ~= 64 or (sib.path ~= nil and not is_path(sib.path)) then
        return nil, "malformed"
    end
    if math.abs(sib.time - options.now) > SIB_MAX_AGE then return nil, "too old" end

    local cert = certificate.decode(sib.cert)
    if not cert then return nil, "no certificate" end
    local name = cell_name(options.network, options.sender)
    local ok, reason = certificate.verify(crypto, cert, {
        name = name, key = cert.key, now = options.now, trusted = { [options.signing] = true },
    })
    if not ok then return nil, "certificate " .. reason end

    local fields = { network = sib.network, cell = sib.cell, area = sib.area, load = sib.load, time = sib.time, path = sib.path }
    if not crypto.verify(cert.key, SIB_PREFIX .. codec.encode(fields), sib.sig) then return nil, "bad signature" end
    return true
end

--- The key a phone and a cell share, from the phone's attach: both the phone and the core can work it out, for any
-- cell, without the key for one cell telling anyone the key for another.
--
-- @tparam table crypto The `crypto` API.
-- @tparam string secret The secret from the attach's handshake.
-- @tparam number cell The cell's ID.
-- @treturn string The key.
local function cell_key(crypto, secret, cell)
    return crypto.hmac(secret, CELL_KEY_PREFIX .. tostring(cell))
end

local CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

--- Make an activation code: five groups of four letters and digits, in Crockford's base 32 (so there are no
-- ambiguous characters). The first group names the subscription; the other four, 80 random bits, are the secret.
--
-- @tparam table crypto The `crypto` API.
-- @treturn string The code, such as `"7Q2M-K4XD-9PRB-T6WN-HJ3C"`.
-- @treturn string The first group.
-- @treturn string The secret.
local function make_code(crypto)
    local bytes, chars = crypto.random(20), {}
    for i = 1, 20 do
        local n = bytes:byte(i) % 32 + 1
        chars[i] = CROCKFORD:sub(n, n)
    end
    local text = table.concat(chars)
    local code = text:gsub("(....)", "%1-"):sub(1, -2)
    return code, text:sub(1, 4), text:sub(5)
end

--- Read an activation code as typed: case, dashes and spaces don't matter, and O, I and L are taken as 0, 1 and 1.
--
-- @tparam string text The code.
-- @treturn string|nil The first group, or `nil` if it isn't a code.
-- @treturn string|nil The secret.
local function parse_code(text)
    if type(text) ~= "string" then return nil end
    text = text:upper():gsub("[%s%-]", ""):gsub("O", "0"):gsub("[IL]", "1")
    if #text ~= 20 or text:find("[^" .. CROCKFORD .. "]") then return nil end
    return text:sub(1, 4), text:sub(5)
end

--- The pre-shared key for activating with a code's secret.
--
-- @tparam table crypto The `crypto` API.
-- @tparam string secret The secret.
-- @treturn string The 32-byte key.
local function activation_key(crypto, secret)
    return crypto.sha256("cc-net cell activation 1\0" .. secret)
end

--- The key a cell's tunnels to the gateway are sealed with.
--
-- @tparam table crypto The `crypto` API.
-- @tparam string secret A secret the core keeps.
-- @tparam number cell The cell's ID.
-- @treturn string The key.
local function tunnel_key(crypto, secret, cell)
    return crypto.hmac(secret, TUNNEL_KEY_PREFIX .. tostring(cell))
end

--- Seals and opens messages with a shared key, counting them, and refusing replays. Each direction uses its own
-- numbers in the nonce, so the same key can be used both ways.
local Sealer = {}
Sealer.__index = Sealer

--[[- Make a sealer.

@tparam table crypto The `crypto` API.
@tparam string key The key.
@tparam number out_direction The number for messages we send (such as 1 for uplink).
@tparam number in_direction The number for messages we receive.
@treturn table The sealer.
]]
local function new_sealer(crypto, key, out_direction, in_direction)
    return setmetatable({
        crypto = crypto, key = key, out_direction = out_direction, in_direction = in_direction,
        counter = 0, top = -1, seen = {},
    }, Sealer)
end

local function nonce(direction, counter)
    return string.pack(">I4>I8", direction, counter)
end

--- Seal a value.
--
-- @param value The value.
-- @treturn table|nil The sealed message, `{ ctr, ct }`, or `nil` if the value can't be encoded.
function Sealer:seal(value)
    local ok, plaintext = pcall(codec.encode, value)
    if not ok then return nil end
    self.counter = self.counter + 1
    return { ctr = self.counter, ct = self.crypto.seal(self.key, nonce(self.out_direction, self.counter), plaintext) }
end

--- Open a sealed message, unless it was changed, isn't for us, or was seen before.
--
-- @param sealed The sealed message, which may be anything.
-- @return The value, or `nil` if it can't be opened.
function Sealer:open(sealed)
    if type(sealed) ~= "table" or type(sealed.ct) ~= "string" then return nil end
    local counter = sealed.ctr
    if type(counter) ~= "number" or counter % 1 ~= 0 or counter < 1 or counter > 2 ^ 53 then return nil end
    if counter <= self.top - REPLAY_WINDOW or self.seen[counter] then return nil end

    local plaintext = self.crypto.open(self.key, nonce(self.in_direction, counter), sealed.ct)
    if not plaintext then return nil end
    local value = codec.decode(plaintext)
    if value == nil then return nil end

    self.seen[counter] = true
    if counter > self.top then
        self.top = counter
        self.seen[counter - REPLAY_WINDOW] = nil
        -- Forget anything too old to matter, now and then.
        if counter % REPLAY_WINDOW == 0 then
            for seen in pairs(self.seen) do
                if seen <= counter - REPLAY_WINDOW then self.seen[seen] = nil end
            end
        end
    end
    return value
end

return {
    FRAME = FRAME,
    TUNNEL_PORT = TUNNEL_PORT,
    CELL_TUNNEL_PORT = CELL_TUNNEL_PORT,
    CONTROL_PORT = CONTROL_PORT,
    SIB_INTERVAL = SIB_INTERVAL,
    UPLINK = UPLINK,
    DOWNLINK = DOWNLINK,
    MAX_PATH = MAX_PATH,
    cell_name = cell_name,
    is_path = is_path,
    make_code = make_code,
    parse_code = parse_code,
    activation_key = activation_key,
    make_sib = make_sib,
    check_sib = check_sib,
    cell_key = cell_key,
    tunnel_key = tunnel_key,
    new_sealer = new_sealer,
}
