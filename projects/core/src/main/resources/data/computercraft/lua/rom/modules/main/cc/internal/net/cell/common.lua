-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What phones, cells and the core share: system information, cell certificates, keys, and sealed messages.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cell` programs instead.

@local
]]

local address = require "cc.net.address"
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

--- How many cells one computer (a cell site) runs at most, each on a carrier of its own: what its antennas serve.
local MAX_CARRIERS = 8

--[[- How many carriers a network may have: every one there is. A network holds more of the spectrum than any one site
serves, and each site serves those it asks for. A cell names them all in its system information, so phones can listen
for that network's cells on them.
]]
local MAX_SPECTRUM = #bands.beacon_channels()

-- System information older (or newer) than this, in milliseconds, isn't believed: it may be a recording.
local SIB_MAX_AGE = 30 * 1000

--[[- How long a cell may send the same signed system information, in milliseconds, while nothing in it but the time
would change. Signing costs the cell, and checking the signature costs every phone which hears it, every time: a phone
needn't check what it checked before (see [`check_sib`]), so a cell signs again only once something changes, or once
what it signed is this old. Even then, with the longest interval between sending it, it's never near `SIB_MAX_AGE`.
]]
local SIB_RESIGN = 10 * 1000

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
the computer and its core say which of its cells each control message is about. Version 6 lets a cell site say its
name in system information, signed with the rest of the cell's part. Version 7 lets a network's name have spaces and
punctuation (see [`is_network`]): older phones don't take such a network for one. Whoever is newer knows
whether it can still talk to the other, so a computer which hears a newer version only notes it: a phone says the
network is newer than it is while it can't find a cell it can use, and a core logs it.
]]
local VERSION = 7

--- Whether another computer says it speaks a newer version than we do.
--
-- @param version What it said its version was, which may be anything.
-- @treturn boolean Whether it's newer.
local function is_newer(version)
    return type(version) == "number" and version % 1 == 0 and version > VERSION and version < 2 ^ 31
end

local SIB_PREFIX = "cc-net cell sib 1\0"
local CELL_KEY_PREFIX = "cc-net cell key 1\0"

-- Sealed messages' counters come from real time: this many per millisecond.
local PER_MS = 1024
-- How far from now (in milliseconds) a sealed message's counter may be.
local MAX_AGE = 60 * 1000
-- How far behind the newest sealed message (in milliseconds) one may arrive, out of order. A radio link can hold a
-- message back for about two seconds while terrain is looked up, so this leaves some room.
local REORDER = 5 * 1000

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

@param cell The cell's ID. Whatever isn't one (as another computer might give) is shown as it is.
@treturn string The ID, such as `"12"` or `"12 b3/1"`.
]]
local function cell_label(cell)
    if not is_id(cell) then return tostring(cell) end
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

--- The longest a network's name may be.
local MAX_NETWORK = 32

--- What a network's name may be, as it's said to whoever gave one which can't be.
local NETWORK_RULE = 'Network names are up to 32 letters, digits, spaces and punctuation (but not "), and don\'t start or end with a space'

--[[- Whether a value could be a network's name: 1 to [`MAX_NETWORK`] printable ASCII characters (letters, digits,
spaces and punctuation), which don't start or end with a space. There are no double quotes, which the shell keeps a name
with spaces together with (`cell network "Old Mill"`).

@param value The value.
@treturn boolean Whether it's a name.
]]
local function is_network(value)
    return type(value) == "string" and #value >= 1 and #value <= MAX_NETWORK and not value:find('[^ -~]')
        and not value:find('"', 1, true) and value:byte(1) ~= 32 and value:byte(-1) ~= 32
end

--[[- Read a network's name, as a phone hears or is given it: the spaces (and other whitespace) at its ends don't count,
so a cell can't name a network which looks like another, and a name typed with a space too many is still found.

@param value The name, which may be anything.
@treturn string|nil The name, without spaces at its ends, or `nil` if that isn't a network's name.
]]
local function network_name(value)
    if type(value) ~= "string" then return nil end
    local first = value:find("%S")
    if not first then return nil end
    local last = #value
    while value:find("^%s", last) do last = last - 1 end
    if last - first >= MAX_NETWORK then return nil end
    local name = value:sub(first, last)
    return is_network(name) and name or nil
end

--- How many DNS servers a network may give its phones.
local MAX_DNS = 4

--[[- Read the DNS servers a network gives its phones: from its administrator, its core's file, or its core.

@param value The servers: a list of up to 4 addresses, as text, such as `{ "10.64.0.1" }`.
@treturn { string... }|nil The servers, each written the usual way and once only, or nil if they don't make sense (an
address with a prefix, or one no computer has, such as 0.0.0.0, the broadcast address or this computer's own).
]]
local function read_dns(value)
    if type(value) ~= "table" or value[1] == nil or #value > MAX_DNS then return nil end
    local result, seen = {}, {}
    for i = 1, #value do
        local text = value[i]
        if type(text) ~= "string" or #text > 15 then return nil end
        local addr, prefix = address.parse(text)
        if not addr or prefix or addr == 0 or addr == 0xFFFFFFFF or address.is_loopback(addr) then return nil end
        local formatted = address.format(addr)
        if not seen[formatted] then
            seen[formatted] = true
            result[#result + 1] = formatted
        end
    end
    return result
end

--- Whether a value could be a network's DNS domain, which its phones look names without dots up in: names of lower
-- case letters, digits and dashes, separated by dots, up to 64 characters in all.
--
-- @param value The value.
-- @treturn boolean Whether it could be.
local function is_domain(value)
    if type(value) ~= "string" or #value < 1 or #value > 64 then return false end
    for label in (value .. "."):gmatch("([^%.]*)%.") do
        if not label:find("^[%l%d%-]+$") then return false end
    end
    return true
end

--- How many names a network had before the one it has now are remembered, by its core and by other networks' cores.
local MAX_FORMER = 4

--[[- The names a network had before it was renamed, from a list which may be anything: the newest of them, each once.

@param list The list.
@tparam[opt] string now The name it has now, which isn't one it had before.
@treturn { string... } The names, oldest first: at most [`MAX_FORMER`].
]]
local function former_names(list, now)
    local names, seen = {}, {}
    if type(list) ~= "table" then return names end
    for i = #list, 1, -1 do
        local name = list[i]
        if #names < MAX_FORMER and is_network(name) and name ~= now and not seen[name] then
            seen[name] = true
            table.insert(names, 1, name)
        end
    end
    return names
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
    if type(list) ~= "table" or #list > MAX_SPECTRUM then return false end
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

--- The most characters a cell site's name may have.
local MAX_SITE_NAME = 8

--- Whether a value could be a cell site's name, which its cells say in their system information for people to read:
-- 1 to [`MAX_SITE_NAME`] printable ASCII characters, which don't start or end with a space.
--
-- @param value The value, which may be anything.
-- @treturn boolean Whether it could be.
local function is_site_name(value)
    return type(value) == "string" and #value >= 1 and #value <= MAX_SITE_NAME and not value:find("[^ -~]")
        and not value:find("^ ") and not value:find(" $")
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
        ul = sib.ul, interval = sib.interval, pos = sib.pos, service = sib.service, name = sib.name,
        carriers = entry.carriers,
    }
end

--[[- Make the signed system information a cell broadcasts. It names each network the cell serves (one, or several
when operators share it), each with the certificate that network's operator gave the cell, and signed with the cell's
key.

@tparam {
    cell = number, area = number, load = number, time = number, sign = function(data:string):string,
    ul = number, interval = number, pos? = { number, number, number }, service? = string, name? = string,
    networks? = { { network = string, certificate = string, path? = { number... }, carriers? = { number... } }... },
    network? = string, certificate? = string, path? = { number... }, carriers? = { number... },
} options The cell's ID, tracking area and how busy it is (from 0 to 1); the time, as `os.epoch("utc")` gives; a way
to sign with the cell's key; the channel phones reach the cell on, and how often it sends system information, in
seconds; where the cell is, if it says; what it offers phones, if not everything (`"sms"`: only messages); its site's
name, if it has one (see [`is_site_name`]); and the networks it serves, each with its name, the cell's certificate from its operator, the relays the cell's backhaul to its
core goes through, nearest first, if it's a relay, and the carriers that network's cells use, by their beacon channels.
A cell of one network may give that network's `network`, `certificate`, `path` and `carriers` instead.
@tparam[opt] table last What this gave last time, as its second result: if the system information would say the same
again, apart from the time, and what was signed then isn't [`SIB_RESIGN`] old, that's given again, as it was, without
signing anything.
@treturn table The system information.
@treturn table What to give this next time, as `last`.
]]
local function make_sib(options, last)
    local networks = options.networks or {
        { network = options.network, certificate = options.certificate, path = options.path, carriers = options.carriers },
    }
    local sib = {
        op = "sib", v = VERSION, cell = options.cell, area = options.area, load = options.load, time = options.time,
        ul = options.ul, interval = options.interval, pos = options.pos, service = options.service, name = options.name,
        networks = {},
    }
    for i, entry in ipairs(networks) do
        local path = entry.path and #entry.path > 0 and entry.path or nil
        local carriers = entry.carriers and #entry.carriers > 0 and entry.carriers or nil
        sib.networks[i] = { network = entry.network, path = path, carriers = carriers, cert = entry.certificate }
    end

    -- Everything that's signed but the time, which is the same while nothing else changes.
    local time = sib.time
    sib.time = nil
    local same = codec.encode(sib)
    sib.time = time
    if last and last.same == same and type(time) == "number" and type(last.sib.time) == "number"
        and time >= last.sib.time and time - last.sib.time < SIB_RESIGN then
        return last.sib, last
    end

    for _, part in ipairs(sib.networks) do
        part.sig = options.sign(SIB_PREFIX .. codec.encode(signed_fields(sib, part)))
    end
    return sib, { sib = sib, same = same }
end

--[[- Read which networks a cell's system information names, without checking any of them: those whose names, paths
and carriers could be real, up to as many as a cell may serve (a name is read as [`network_name`] reads it, without
spaces at its ends). The cell's own part (its uplink channel and interval,
and its position, service and site's name if it gives them) must be fit to use too.

@param sib The system information, which may be anything.
@tparam number sender The ID of the computer which sent it.
@treturn { { network = string, path? = table, carriers? = table, cert = any, sig = any }... }|nil The networks, or
`nil` if it isn't system information from that computer.
]]
local function sib_networks(sib, sender)
    if type(sib) ~= "table" or sib.cell ~= sender or type(sib.area) ~= "number" or type(sib.load) ~= "number"
        or type(sib.time) ~= "number" or type(sib.networks) ~= "table" or not is_uplink(sib.ul)
        or not is_interval(sib.interval) or (sib.pos ~= nil and not is_position(sib.pos))
        or (sib.service ~= nil and sib.service ~= "sms") or (sib.name ~= nil and not is_site_name(sib.name)) then
        return nil
    end
    local result, seen = {}, {}
    for i = 1, MAX_SIB_NETWORKS do
        local entry = sib.networks[i]
        if entry == nil then break end
        local name = type(entry) == "table" and network_name(entry.network)
        if name and not seen[name]
            and (entry.path == nil or is_path(entry.path)) and (entry.carriers == nil or is_carriers(entry.carriers)) then
            -- A name with spaces at its ends is taken without them, as its core named it: no core names one so.
            if name ~= entry.network then
                entry = { network = name, path = entry.path, carriers = entry.carriers, cert = entry.cert, sig = entry.sig }
            end
            seen[name] = true
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
second, and checking it is one of the two signatures to check), each with the system information last signed under it
which checked out: a cell sends that again, as it was, until something in it changes (see [`make_sib`]), and exactly
the same bytes, signed the same, needn't be checked again. Anything else, even only a later time, is checked.
@treturn[1] true If it's good.
@treturn[1] number When the cell's certificate expires: one issued later expires later.
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
    local expires
    if known and known.expires > options.now then
        signer, expires = known.key, known.expires
    else
        known = nil
        local cert = certificate.decode(entry.cert)
        if not cert then return nil, "no certificate" end
        local name = cell_name(options.network, options.sender)
        local ok, reason = certificate.verify(crypto, cert, {
            name = name, key = cert.key, now = options.now, trusted = { [options.signing] = true },
        })
        if not ok then return nil, "certificate " .. reason end
        signer, expires = cert.key, cert.expires
        if cache_key then
            -- Only so many: a phone hears a few dozen cells at most, so this many is someone making them up.
            if certificates.count >= MAX_CERTIFICATES then certificates.checked, certificates.count = {}, 0 end
            if not certificates.checked[cache_key] then certificates.count = certificates.count + 1 end
            known = { key = cert.key, expires = cert.expires }
            certificates.checked[cache_key] = known
        end
    end

    local signed = SIB_PREFIX .. codec.encode(signed_fields(sib, entry))
    if known and known.sig == entry.sig and known.signed == signed then return true, expires end
    if not crypto.verify(signer, signed, entry.sig) then return nil, "bad signature" end
    if known then known.sig, known.signed = entry.sig, signed end
    return true, expires
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

--[[- Seals and opens messages with a shared key, counting them, and refusing replays. Each direction uses its own
numbers in the nonce, so the same key can be used both ways.

The same key may be used again later: a phone which moves from one cell to another and back shares the same key with
the first cell both times. So counters come from real time, as `cc.internal.net.link`'s do, rather than starting again
from one, which would seal different messages with the same nonce. Every computer on a server shares that clock, so a
sealer also refuses messages sealed well before it was made, which can't be from the other end as it is now.
]]
local Sealer = {}
Sealer.__index = Sealer

--[[- Make a sealer.

@tparam table crypto The `crypto` API.
@tparam string key The key.
@tparam number out_direction The number for messages we send (such as 1 for uplink).
@tparam number in_direction The number for messages we receive.
@tparam function():number epoch The time, in milliseconds, as `os.epoch("utc")` gives.
@treturn table The sealer.
]]
local function new_sealer(crypto, key, out_direction, in_direction, epoch)
    return setmetatable({
        crypto = crypto, key = key, out_direction = out_direction, in_direction = in_direction, epoch = epoch,
        counter = 0, top = -1, seen = {}, count = 0,
        -- The other end may have sealed a message a moment before we were made, and it may have been held back on the
        -- way. Anything older is from before, and could only be a replay.
        floor = math.floor(epoch() * PER_MS) - REORDER * PER_MS,
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
    local counter = math.max(self.counter + 1, math.floor(self.epoch() * PER_MS))
    self.counter = counter
    return { ctr = counter, ct = self.crypto.seal(self.key, nonce(self.out_direction, counter), plaintext) }
end

--- Open a sealed message, unless it was changed, isn't for us, or was seen before.
--
-- @param sealed The sealed message, which may be anything.
-- @return The value, or `nil` if it can't be opened.
-- @treturn number When it was sealed, as its counter: counters only grow with time, so this says which of two messages
-- was sealed first.
function Sealer:open(sealed)
    if type(sealed) ~= "table" or type(sealed.ct) ~= "string" then return nil end
    local counter = sealed.ctr
    if type(counter) ~= "number" or counter % 1 ~= 0 or counter < 1 or counter > 2 ^ 53 then return nil end
    if math.abs(counter - self.epoch() * PER_MS) > MAX_AGE * PER_MS or counter < self.floor then return nil end
    if counter <= self.top - REORDER * PER_MS or self.seen[counter] then return nil end

    local plaintext = self.crypto.open(self.key, nonce(self.in_direction, counter), sealed.ct)
    if not plaintext then return nil end
    local value = codec.decode(plaintext)
    if value == nil then return nil end

    self.seen[counter], self.count = true, self.count + 1
    if counter > self.top then self.top = counter end
    -- Now and then, forget messages too old to be accepted anyway. A busy sender may have many which are still recent:
    -- then wait for twice as many before looking again, rather than looking at them all for every message.
    if self.count > (self.limit or 256) then
        local floor, count = self.top - REORDER * PER_MS, 0
        for seen in pairs(self.seen) do
            if seen <= floor then self.seen[seen] = nil else count = count + 1 end
        end
        self.count, self.limit = count, math.max(256, count * 2)
    end
    return value, counter
end

--- The counter a message sealed now would have, or one sealed before it. This is compared with what a sealer's `open`
-- returns, to tell whether a message was sealed before something happened.
--
-- @tparam function():number epoch The time, in milliseconds, as `os.epoch("utc")` gives.
-- @treturn number The counter.
local function counter_now(epoch)
    return math.floor(epoch() * PER_MS)
end

--- When a message was sealed, from its counter.
--
-- @tparam number counter The counter.
-- @treturn number The time it was sealed, in milliseconds, as `os.epoch("utc")` gives.
local function counter_time(counter)
    return math.floor(counter / PER_MS)
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
    MAX_SPECTRUM = MAX_SPECTRUM,
    UPLINK = UPLINK,
    DOWNLINK = DOWNLINK,
    MAX_PATH = MAX_PATH,
    MAX_SIB_NETWORKS = MAX_SIB_NETWORKS,
    MAX_FORMER = MAX_FORMER,
    former_names = former_names,
    TUNNEL_LIMITS = TUNNEL_LIMITS,
    cell_name = cell_name,
    carrier_cell = carrier_cell,
    site_of = site_of,
    cell_label = cell_label,
    is_id = is_id,
    MAX_NETWORK = MAX_NETWORK,
    NETWORK_RULE = NETWORK_RULE,
    is_network = is_network,
    network_name = network_name,
    is_number_prefix = is_number_prefix,
    MAX_DNS = MAX_DNS,
    read_dns = read_dns,
    is_domain = is_domain,
    is_path = is_path,
    is_interval = is_interval,
    is_uplink = is_uplink,
    is_carriers = is_carriers,
    is_wants = is_wants,
    want_carrier = want_carrier,
    match_wants = match_wants,
    is_position = is_position,
    MAX_SITE_NAME = MAX_SITE_NAME,
    is_site_name = is_site_name,
    make_code = make_code,
    parse_code = parse_code,
    activation_key = activation_key,
    SIB_RESIGN = SIB_RESIGN,
    make_sib = make_sib,
    sib_networks = sib_networks,
    check_sib = check_sib,
    new_certificates = new_certificates,
    cell_key = cell_key,
    counter_now = counter_now,
    counter_time = counter_time,
    new_sealer = new_sealer,
}
