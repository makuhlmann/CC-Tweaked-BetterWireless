-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What phones, cells and the core share: system information, cell certificates, keys, and sealed messages.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cell` programs instead.

@local
]]

local codec = require "cc.net.codec"
local bands = require "cc.internal.net.bands"
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

--- How often cells send system information by default, in seconds. A network's core may say otherwise, and a cell
-- too, within `MIN_INTERVAL` and `MAX_INTERVAL`. Phones wait longer for a cell which sends less often.
local DEFAULT_INTERVAL = 2

--- The least time a cell may leave between sending system information, in seconds.
local MIN_INTERVAL = 0.5

--- The most time a cell may leave between sending system information, in seconds. Phones take a cell to be gone after a
-- few intervals of silence, so a long one would keep them on a dead cell.
local MAX_INTERVAL = 10

--- How many of its network's carriers a cell names in its system information, so phones can listen for that network's
-- cells on them.
local MAX_CARRIERS = 8

-- System information older (or newer) than this, in milliseconds, isn't believed: it may be a recording.
local SIB_MAX_AGE = 30 * 1000

--- How many networks one cell may serve (and name in its system information): several operators may share a cell.
local MAX_SIB_NETWORKS = 8

-- How many cells' certificates a phone keeps once they've checked out.
local MAX_CERTIFICATES = 256

--[[- The version of the cellular network's protocols this computer speaks. System information, the hellos cells and
cores send each other, and what a core tells a phone when it attaches each carry it.

Version 2 is the first which says so (version 1 had system information for one network only). Version 3 has one
connection between two networks' cores, for all they do for each other. Version 4 puts cells on carriers (5MHz of a
cellular band): system information says which channel to reach the cell on, how often it's sent, and which carriers
the cell's network uses. Version 5 lets one computer run cells on several carriers (a site with several bands, say):
each is a cell of its own to phones, with an ID of its own (see [`carrier_cell`]), so nothing changes on the air, and
the computer and its core say which of its cells each control message is about. Whoever is newer knows
whether it can still talk to the other, so a computer which hears a newer version only notes it: a phone says the
network is newer than it is while it can't find a cell it can use, and a core logs it.
]]
local VERSION = 5

--- Whether another computer says it speaks a newer version than we do.
--
-- @param version What it said its version was, which may be anything.
-- @treturn boolean Whether it's newer.
local function is_newer(version)
    return type(version) == "number" and version % 1 == 0 and version > VERSION and version < 2 ^ 31
end

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

-- Computers' IDs are below this. The IDs of a computer's further cells are above it.
local SITE_IDS = 2 ^ 31

--[[- The ID of a cell a computer runs besides its first, on another carrier.

A computer's first cell has the computer's ID, as every cell did before one computer could run several. Each further
one's ID is made from the computer's ID and the cell's carrier, and is bigger than any computer's ID: so it's the same
whenever the cell is on that carrier, no two cells share one, and anyone can tell which computer (which cell site) a
cell is at. To phones it's a cell like any other: its ID is who its frames are from and to, what its certificate
names, and what its key with a phone is made from.

@tparam number site The computer's ID.
@tparam number carrier The carrier's beacon channel.
@treturn number The cell's ID.
]]
local function carrier_cell(site, carrier)
    return carrier * SITE_IDS + site
end

--[[- Which computer a cell is at: its cell site.

@tparam number cell The cell's ID.
@treturn number The computer's ID.
@treturn number|nil The cell's carrier (its beacon channel), if it isn't the computer's first cell, which doesn't say.
]]
local function site_of(cell)
    local site = cell % SITE_IDS
    if site == cell then return site, nil end
    return site, (cell - site) / SITE_IDS
end

--[[- A cell's ID, for people to read: its computer's ID, and its carrier if it isn't the computer's first cell.

@tparam number cell The cell's ID.
@treturn string The ID, such as `"12"` or `"12 b3/1"`.
]]
local function cell_label(cell)
    local site, carrier = site_of(cell)
    if not carrier then return ("%d"):format(site) end
    return ("%d %s"):format(site, bands.carrier_name(carrier) or ("?" .. carrier))
end

--- Whether a value could be a number prefix: up to 8 digits, which a network's numbers start with for other networks.
--
-- @param value The value.
-- @treturn boolean Whether it could be.
local function is_number_prefix(value)
    return type(value) == "string" and #value >= 1 and #value <= 8 and not value:find("%D")
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

--- Whether a value could be how often a cell sends system information.
--
-- @param value The value.
-- @treturn boolean Whether it could be.
local function is_interval(value)
    return type(value) == "number" and value >= MIN_INTERVAL and value <= MAX_INTERVAL
end

--- Whether a channel is a cell's uplink: the channel phones reach it on, in a carrier's uplink.
--
-- @param channel The channel, which may be anything.
-- @treturn boolean Whether it is.
local function is_uplink(channel)
    if not is_id(channel) or channel > 65532 then return false end
    local _, part = bands.of(channel)
    return part == "uplink" and bands.carrier_of(channel) ~= nil
end

--- Whether a value is a list of carriers, by their beacon channels, as a cell names its network's.
--
-- @param list The list, which may be anything.
-- @treturn boolean Whether it is.
local function is_carriers(list)
    if type(list) ~= "table" or #list > MAX_CARRIERS then return false end
    for k, v in pairs(list) do
        if type(k) ~= "number" or k < 1 or k > #list or k % 1 ~= 0 or not is_id(v) or bands.carrier(v) == nil then
            return false
        end
    end
    return true
end

--[[- The carrier something a cell site wants names, if it names one.

What a site wants is a list of bands and carriers, by name: a band (`"b20"`) for any of its network's carriers there,
or a carrier (`"b3/2"`) for that one. A band may come several times, for a cell on each of several of its carriers.

@tparam string want The band's or carrier's name.
@treturn number|nil The carrier's beacon channel, or `nil` if it's a band (or nothing at all).
]]
local function want_carrier(want)
    if type(want) ~= "string" or not want:find("/", 1, true) then return nil end
    return bands.parse_carrier(want)
end

--- Whether a value is what a cell site may want: a list of 1 to [`MAX_CARRIERS`] cellular bands and carriers, by name.
--
-- @param list The list, which may be anything.
-- @treturn boolean Whether it is.
local function is_wants(list)
    if type(list) ~= "table" or #list < 1 or #list > MAX_CARRIERS then return false end
    for k, v in pairs(list) do
        if type(k) ~= "number" or k < 1 or k > #list or k % 1 ~= 0 or type(v) ~= "string" then return false end
        local band = bands.get(v)
        if not (band and band.downlink) and not want_carrier(v) then return false end
    end
    return true
end

--[[- Match what a cell site wants with carriers, one for one: first each carrier it names, then a carrier in each band
it names.

@tparam { string... } wants What it wants, as [`is_wants`] takes it.
@tparam { number... } carriers The carriers there are, by their beacon channels, in order of preference.
@treturn { [number] = number } The carrier which answers each want, by the want's place in the list. Wants there's no
carrier for have none.
@treturn { [number] = boolean } Which carriers answer a want.
]]
local function match_wants(wants, carriers)
    local by_want, used = {}, {}
    for pass = 1, 2 do
        for i, want in ipairs(wants) do
            local named = want_carrier(want)
            if not by_want[i] and (pass == 1) == (named ~= nil) then
                for _, carrier in ipairs(carriers) do
                    local _, band = bands.carrier_of(carrier)
                    if not by_want[i] and not used[carrier] and (carrier == named or (not named and band == want)) then
                        by_want[i], used[carrier] = carrier, true
                    end
                end
            end
        end
    end
    return by_want, used
end

--- Whether a value could be a cell's position: three whole numbers, as `celld` takes it.
--
-- @param pos The value, which may be anything.
-- @treturn boolean Whether it could be.
local function is_position(pos)
    if type(pos) ~= "table" then return false end
    for i = 1, 3 do
        local v = pos[i]
        if type(v) ~= "number" or v % 1 ~= 0 or math.abs(v) > 2 ^ 31 then return false end
    end
    return pos[4] == nil and next(pos, 3) == nil
end

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

-- What each network's signature in system information covers: the cell's part, and that network's.
local function signed_fields(sib, entry)
    return {
        network = entry.network, cell = sib.cell, area = sib.area, load = sib.load, time = sib.time, path = entry.path,
        ul = sib.ul, interval = sib.interval, pos = sib.pos, service = sib.service, carriers = entry.carriers,
    }
end

--[[- Make the signed system information a cell broadcasts. It names each network the cell serves (one, or several
when operators share it), each with the certificate that network's operator gave the cell, and signed with the cell's
key.

@tparam {
    cell = number, area = number, load = number, time = number, sign = function(data:string):string,
    ul = number, interval = number, pos? = { number, number, number }, service? = string,
    networks? = { { network = string, certificate = string, path? = { number... }, carriers? = { number... } }... },
    network? = string, certificate? = string, path? = { number... }, carriers? = { number... },
} options The cell's ID, tracking area and how busy it is (from 0 to 1); the time, as `os.epoch("utc")` gives; a way
to sign with the cell's key; the channel phones reach the cell on, and how often it sends system information, in
seconds; where the cell is, if it says; what it offers phones, if not everything (`"sms"`: only messages); and the
networks it serves, each with its name, the cell's certificate from its operator, the relays the cell's backhaul to its
core goes through, nearest first, if it's a relay, and the carriers that network's cells use, by their beacon channels.
A cell of one network may give that network's `network`, `certificate`, `path` and `carriers` instead.
@treturn table The system information.
]]
local function make_sib(options)
    local networks = options.networks or {
        { network = options.network, certificate = options.certificate, path = options.path, carriers = options.carriers },
    }
    local sib = {
        op = "sib", v = VERSION, cell = options.cell, area = options.area, load = options.load, time = options.time,
        ul = options.ul, interval = options.interval, pos = options.pos, service = options.service, networks = {},
    }
    for i, entry in ipairs(networks) do
        local path = entry.path and #entry.path > 0 and entry.path or nil
        local carriers = entry.carriers and #entry.carriers > 0 and entry.carriers or nil
        local part = { network = entry.network, path = path, carriers = carriers, cert = entry.certificate }
        part.sig = options.sign(SIB_PREFIX .. codec.encode(signed_fields(sib, part)))
        sib.networks[i] = part
    end
    return sib
end

--[[- Read which networks a cell's system information names, without checking any of them: those whose names, paths
and carriers could be real, up to as many as a cell may serve. The cell's own part (its uplink channel and interval,
and its position and service if it gives them) must be fit to use too.

@param sib The system information, which may be anything.
@tparam number sender The ID of the computer which sent it.
@treturn { { network = string, path? = table, carriers? = table, cert = any, sig = any }... }|nil The networks, or
`nil` if it isn't system information from that computer.
]]
local function sib_networks(sib, sender)
    if type(sib) ~= "table" or sib.cell ~= sender or type(sib.area) ~= "number" or type(sib.load) ~= "number"
        or type(sib.time) ~= "number" or type(sib.networks) ~= "table" or not is_uplink(sib.ul)
        or not is_interval(sib.interval) or (sib.pos ~= nil and not is_position(sib.pos))
        or (sib.service ~= nil and sib.service ~= "sms") then
        return nil
    end
    local result, seen = {}, {}
    for i = 1, MAX_SIB_NETWORKS do
        local entry = sib.networks[i]
        if entry == nil then break end
        if type(entry) == "table" and is_network(entry.network) and not seen[entry.network]
            and (entry.path == nil or is_path(entry.path)) and (entry.carriers == nil or is_carriers(entry.carriers)) then
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
    network = string, signing = string, now = number, sender = number, certificates? = table,
} options The network we want; its operator's Ed25519 key; the time; the ID of the computer which sent it; and
certificates which checked out before, to check again only once they've expired (a cell sends the same one every
second, and checking it is one of the two signatures to check).
@treturn[1] true If it's good.
@treturn[2] nil If it isn't.
@treturn[2] string Why not.
]]
local function check_sib(crypto, sib, entry, options)
    if type(entry) ~= "table" or entry.network ~= options.network or sib.cell ~= options.sender then return nil, "not ours" end
    if type(sib.area) ~= "number" or type(sib.load) ~= "number" or type(sib.time) ~= "number"
        or type(entry.sig) ~= "string" or #entry.sig ~= 64 or (entry.path ~= nil and not is_path(entry.path))
        or not is_uplink(sib.ul) or not is_interval(sib.interval)
        or (entry.carriers ~= nil and not is_carriers(entry.carriers)) then
        return nil, "malformed"
    end
    if math.abs(sib.time - options.now) > SIB_MAX_AGE then return nil, "too old" end

    -- The same certificate, from the same cell, for the same network and operator, checked out before.
    local certificates, signer = options.certificates, nil
    local cache_key = certificates and type(entry.cert) == "string"
        and ("%s\0%d\0%s\0%s"):format(options.network, options.sender, options.signing, entry.cert)
    local known = cache_key and certificates.checked[cache_key]
    if known and known.expires > options.now then
        signer = known.key
    else
        local cert = certificate.decode(entry.cert)
        if not cert then return nil, "no certificate" end
        local name = cell_name(options.network, options.sender)
        local ok, reason = certificate.verify(crypto, cert, {
            name = name, key = cert.key, now = options.now, trusted = { [options.signing] = true },
        })
        if not ok then return nil, "certificate " .. reason end
        signer = cert.key
        if cache_key then
            -- Only so many: a phone hears a few dozen cells at most, so this many is someone making them up.
            if certificates.count >= MAX_CERTIFICATES then certificates.checked, certificates.count = {}, 0 end
            if not certificates.checked[cache_key] then certificates.count = certificates.count + 1 end
            certificates.checked[cache_key] = { key = cert.key, expires = cert.expires }
        end
    end

    if not crypto.verify(signer, SIB_PREFIX .. codec.encode(signed_fields(sib, entry)), entry.sig) then
        return nil, "bad signature"
    end
    return true
end

--- Make a store of certificates which checked out, for [`check_sib`].
--
-- @treturn table The store.
local function new_certificates()
    return { checked = {}, count = 0 }
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
    VERSION = VERSION,
    is_newer = is_newer,
    FRAME = FRAME,
    TUNNEL_PORT = TUNNEL_PORT,
    CELL_TUNNEL_PORT = CELL_TUNNEL_PORT,
    ROAM_TUNNEL_PORT = ROAM_TUNNEL_PORT,
    CONTROL_PORT = CONTROL_PORT,
    DEFAULT_INTERVAL = DEFAULT_INTERVAL,
    MIN_INTERVAL = MIN_INTERVAL,
    MAX_INTERVAL = MAX_INTERVAL,
    MAX_CARRIERS = MAX_CARRIERS,
    UPLINK = UPLINK,
    DOWNLINK = DOWNLINK,
    MAX_PATH = MAX_PATH,
    MAX_SIB_NETWORKS = MAX_SIB_NETWORKS,
    TUNNEL_LIMITS = TUNNEL_LIMITS,
    cell_name = cell_name,
    carrier_cell = carrier_cell,
    site_of = site_of,
    cell_label = cell_label,
    is_id = is_id,
    is_network = is_network,
    is_number_prefix = is_number_prefix,
    is_path = is_path,
    is_interval = is_interval,
    is_uplink = is_uplink,
    is_carriers = is_carriers,
    is_wants = is_wants,
    want_carrier = want_carrier,
    match_wants = match_wants,
    is_position = is_position,
    make_code = make_code,
    parse_code = parse_code,
    activation_key = activation_key,
    make_sib = make_sib,
    sib_networks = sib_networks,
    check_sib = check_sib,
    new_certificates = new_certificates,
    cell_key = cell_key,
    tunnel_key = tunnel_key,
    new_sealer = new_sealer,
}
