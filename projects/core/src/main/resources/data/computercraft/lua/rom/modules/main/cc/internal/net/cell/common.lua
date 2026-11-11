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
local message = require "cc.internal.net.message"

--- The frame type for everything between phones and cells.
local FRAME = "cell"

--- The port of the gateway's end of tunnels between cells and the gateway (like LTE's GTP-U).
local TUNNEL_PORT = 2152

--- The port of the cells' end of tunnels. It differs from the gateway's, so a computer can be a cell and the core.
local CELL_TUNNEL_PORT = 2153

--- The port a core takes tunnels on from the cores of networks whose phones it carries (roaming partners). It differs
-- from the cells', so a core can be a cell too.
local ROAM_TUNNEL_PORT = 2154

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

--- How many networks one cell may serve (and name in its system information): several operators may share a cell.
local MAX_SIB_NETWORKS = 8

local SIB_PREFIX = "cc-net cell sib 1\0"
local CELL_KEY_PREFIX = "cc-net cell key 1\0"
local TUNNEL_KEY_PREFIX = "cc-net tunnel key 1\0"

-- How many sealed messages arriving out of order are accepted: the counters within this many of the newest.
local REPLAY_WINDOW = 64

--- Whether a value is an ID: of a computer, a tunnel or a message. They're whole numbers, and are used as tables' keys,
-- which NaN can't be.
--
-- @param value The value.
-- @treturn boolean Whether it's an ID.
local function is_id(value)
    return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 2 ^ 53
end

--- Whether a value could be a network's name: letters, digits and dashes, up to 32 of them.
--
-- @param value The value.
-- @treturn boolean Whether it's a name.
local function is_network(value)
    return type(value) == "string" and #value >= 1 and #value <= 32 and value:find("^[%w%-]+$") ~= nil
end

--- The name a cell's certificate is for: its network and its ID.
--
-- @tparam string network The network's name.
-- @tparam number cell The cell's computer ID.
-- @treturn string The name.
local function cell_name(network, cell)
    return ("%s/cell/%d"):format(network, cell)
end

--- How big datagrams in tunnels between cells and the core may be: bigger than programs may send, as they carry
-- programs' packets whole.
local TUNNEL_LIMITS = message.TUNNEL

--- The most relays a cell's backhaul may go through. Each relay wraps phones' packets in another tunnel, about 250
-- bytes bigger, and the biggest message a program may send must still fit in the outermost one (see
-- [`cc.internal.net.message`]'s `TUNNEL`): it would through 13, and this leaves some room.
local MAX_PATH = 10

--[[- Check a cell's path: the relays its backhaul goes through, as a list of their IDs. The core may send a cell one
longer than [`MAX_PATH`], to say it's too far from the core to serve.

@param path The path, which may be anything.
@treturn boolean Whether it's a path.
]]
local function is_path(path)
    if type(path) ~= "table" or #path > MAX_PATH + 1 then return false end
    for k, v in pairs(path) do
        if type(k) ~= "number" or k < 1 or k > #path or k % 1 ~= 0 or not is_id(v) then return false end
    end
    return true
end

--[[- Make the signed system information a cell broadcasts. It names each network the cell serves (one, or several
when operators share it), each with the certificate that network's operator gave the cell, and signed with the cell's
key.

@tparam {
    cell = number, area = number, load = number, time = number, sign = function(data:string):string,
    networks? = { { network = string, certificate = string, path? = { number... } }... },
    network? = string, certificate? = string, path? = { number... },
} options The cell's ID, tracking area and how busy it is (from 0 to 1); the time, as `os.epoch("utc")` gives; a way
to sign with the cell's key; and the networks it serves, each with its name, the cell's certificate from its operator,
and the relays the cell's backhaul to its core goes through, nearest first, if it's a relay. A cell of one network may
give that network's `network`, `certificate` and `path` instead.
@treturn table The system information.
]]
local function make_sib(options)
    local networks = options.networks
        or { { network = options.network, certificate = options.certificate, path = options.path } }
    local sib = {
        op = "sib", cell = options.cell, area = options.area, load = options.load, time = options.time, networks = {},
    }
    for i, entry in ipairs(networks) do
        local path = entry.path and #entry.path > 0 and entry.path or nil
        local fields = {
            network = entry.network, cell = options.cell, area = options.area, load = options.load, time = options.time,
            path = path,
        }
        sib.networks[i] = {
            network = entry.network, path = path, cert = entry.certificate, sig = options.sign(SIB_PREFIX .. codec.encode(fields)),
        }
    end
    return sib
end

--[[- Read which networks a cell's system information names, without checking any of them: those whose names and
paths could be real, up to as many as a cell may serve.

@param sib The system information, which may be anything.
@tparam number sender The ID of the computer which sent it.
@treturn { { network = string, path? = table, cert = any, sig = any }... }|nil The networks, or `nil` if it isn't
system information from that computer.
]]
local function sib_networks(sib, sender)
    if type(sib) ~= "table" or sib.cell ~= sender or type(sib.area) ~= "number" or type(sib.load) ~= "number"
        or type(sib.time) ~= "number" or type(sib.networks) ~= "table" then
        return nil
    end
    local result, seen = {}, {}
    for i = 1, MAX_SIB_NETWORKS do
        local entry = sib.networks[i]
        if entry == nil then break end
        if type(entry) == "table" and is_network(entry.network) and not seen[entry.network]
            and (entry.path == nil or is_path(entry.path)) then
            seen[entry.network] = true
            result[#result + 1] = entry
        end
    end
    return result
end

--[[- Check that a cell's system information comes from a real cell of a network it names.

@tparam table crypto The `crypto` API.
@tparam table sib The system information, as [`sib_networks`] took it.
@tparam table entry The network's part of it, from what [`sib_networks`] gave.
@tparam {
    network = string, signing = string, now = number, sender = number,
} options The network we want; its operator's Ed25519 key; the time; and the ID of the computer which sent it.
@treturn[1] true If it's good.
@treturn[2] nil If it isn't.
@treturn[2] string Why not.
]]
local function check_sib(crypto, sib, entry, options)
    if type(entry) ~= "table" or entry.network ~= options.network or sib.cell ~= options.sender then return nil, "not ours" end
    if type(sib.area) ~= "number" or type(sib.load) ~= "number" or type(sib.time) ~= "number"
        or type(entry.sig) ~= "string" or #entry.sig ~= 64 or (entry.path ~= nil and not is_path(entry.path)) then
        return nil, "malformed"
    end
    if math.abs(sib.time - options.now) > SIB_MAX_AGE then return nil, "too old" end

    local cert = certificate.decode(entry.cert)
    if not cert then return nil, "no certificate" end
    local name = cell_name(options.network, options.sender)
    local ok, reason = certificate.verify(crypto, cert, {
        name = name, key = cert.key, now = options.now, trusted = { [options.signing] = true },
    })
    if not ok then return nil, "certificate " .. reason end

    local fields = {
        network = entry.network, cell = sib.cell, area = sib.area, load = sib.load, time = sib.time, path = entry.path,
    }
    if not crypto.verify(cert.key, SIB_PREFIX .. codec.encode(fields), entry.sig) then return nil, "bad signature" end
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
    ROAM_TUNNEL_PORT = ROAM_TUNNEL_PORT,
    CONTROL_PORT = CONTROL_PORT,
    SIB_INTERVAL = SIB_INTERVAL,
    UPLINK = UPLINK,
    DOWNLINK = DOWNLINK,
    MAX_PATH = MAX_PATH,
    MAX_SIB_NETWORKS = MAX_SIB_NETWORKS,
    TUNNEL_LIMITS = TUNNEL_LIMITS,
    cell_name = cell_name,
    is_id = is_id,
    is_network = is_network,
    is_path = is_path,
    make_code = make_code,
    parse_code = parse_code,
    activation_key = activation_key,
    make_sib = make_sib,
    sib_networks = sib_networks,
    check_sib = check_sib,
    cell_key = cell_key,
    tunnel_key = tunnel_key,
    new_sealer = new_sealer,
}
