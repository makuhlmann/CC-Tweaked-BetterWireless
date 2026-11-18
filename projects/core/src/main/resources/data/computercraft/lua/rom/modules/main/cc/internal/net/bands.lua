-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The radio bands the network stack and cellular networks use, as ranges of channels.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

A channel's number is its frequency in units of 100kHz, so a band is a range of channels: channel 21100 is 2110MHz.

There are two kinds of band:

 - **The network stack's own**, `low` (VHF, 136-174MHz) and `high` (2.4GHz). Computers send and listen on the same
   channels: each band's first channel is for broadcasts, and the rest are computers' unicast channels, by ID.
 - **Cellular bands**, which are paired, as LTE's FDD bands are: phones send on the uplink and cells on the downlink,
   a fixed distance apart, so phones never hear each other and cells never hear each other. These are LTE's bands 31
   (450MHz), 28 (700), 20 (800), 8 (900), 3 (1800), 1 (2100) and 7 (2600), with their real frequencies. In band 20,
   the uplink is above the downlink.

An interface can also have a channel of its own, outside the cellular bands, which every computer on it sends and
listens on (see [`check_link_channel`]).

Cells announce themselves on beacon channels which lie on a raster: the middle of each 5MHz block of a band's downlink,
counted from its start (as 5G's synchronisation raster is coarser than its channel raster). There are 61 across all
the cellular bands, so a phone can listen to every one at once, within a modem's limit of 128 open channels.

@local
]]

--- How many channels apart beacon channels are: 5MHz.
local RASTER = 50

--- Every band, lowest first. Ranges are inclusive.
local BANDS = {
    { name = "low", label = "VHF", channels = { 1360, 1739 } },
    { name = "b31", label = "450", uplink = { 4525, 4575 }, downlink = { 4625, 4675 } },
    -- Band 28 as Europe uses it, 2x30MHz: its full range would overlap band 20's downlink.
    { name = "b28", label = "700", uplink = { 7030, 7330 }, downlink = { 7580, 7880 } },
    { name = "b20", label = "800", uplink = { 8320, 8620 }, downlink = { 7910, 8210 } },
    { name = "b8", label = "900", uplink = { 8800, 9150 }, downlink = { 9250, 9600 } },
    { name = "b3", label = "1800", uplink = { 17100, 17850 }, downlink = { 18050, 18800 } },
    { name = "b1", label = "2100", uplink = { 19200, 19800 }, downlink = { 21100, 21700 } },
    { name = "high", label = "2.4GHz", channels = { 24000, 24834 } },
    { name = "b7", label = "2600", uplink = { 25000, 25700 }, downlink = { 26200, 26900 } },
}

local BY_NAME = {}
for _, band in ipairs(BANDS) do BY_NAME[band.name] = band end

--- Copy a band, so callers can't change ours.
local function copy(band)
    local result = {}
    for k, v in pairs(band) do result[k] = type(v) == "table" and { v[1], v[2] } or v end
    return result
end

--- Get a band by name.
--
-- @tparam string name The band's name, such as `"b20"` or `"low"`.
-- @treturn table|nil The band: its `name`, `label`, and either `channels` (the stack's bands) or `uplink` and
-- `downlink` (cellular bands), each the first and last channel. `nil` if there's no such band.
local function get(name)
    local band = BY_NAME[name]
    return band and copy(band)
end

--- Every band, lowest first.
--
-- @treturn { table... } The bands, as [`get`] gives them.
local function list()
    local result = {}
    for i, band in ipairs(BANDS) do result[i] = copy(band) end
    return result
end

--- Every cellular band, lowest first.
--
-- @treturn { table... } The bands, as [`get`] gives them.
local function cellular()
    local result = {}
    for _, band in ipairs(BANDS) do
        if band.downlink then result[#result + 1] = copy(band) end
    end
    return result
end

--- A channel's frequency.
--
-- @tparam number channel The channel.
-- @treturn number The frequency, in MHz.
local function frequency(channel)
    return channel / 10
end

local function within(channel, range)
    return range ~= nil and channel >= range[1] and channel <= range[2]
end

--- Which band a channel is in, and which part of it.
--
-- @tparam number channel The channel.
-- @treturn string|nil The band's name, or `nil` if it's in none.
-- @treturn string|nil `"uplink"`, `"downlink"`, or `"both"` for the stack's bands.
local function of(channel)
    if type(channel) ~= "number" then return nil end
    for _, band in ipairs(BANDS) do
        if within(channel, band.channels) then return band.name, "both" end
        if within(channel, band.downlink) then return band.name, "downlink" end
        if within(channel, band.uplink) then return band.name, "uplink" end
    end
    return nil
end

--- The uplink channel paired with a downlink channel in a cellular band: the same distance into the uplink.
--
-- @tparam string name The band's name.
-- @tparam number channel The downlink channel.
-- @treturn number|nil The uplink channel, or `nil` if the band isn't paired or the channel isn't in its downlink.
local function uplink_of(name, channel)
    local band = BY_NAME[name]
    if not band or not band.downlink or not within(channel, band.downlink) then return nil end
    return band.uplink[1] + (channel - band.downlink[1])
end

--- The beacon channels in a cellular band: the middle of each 5MHz block of its downlink.
--
-- @tparam string name The band's name.
-- @treturn { number... } The channels, lowest first. Empty if the band isn't a cellular one.
local function raster(name)
    local band, result = BY_NAME[name], {}
    if not band or not band.downlink then return result end
    local first, last = band.downlink[1], band.downlink[2]
    local channel = first + RASTER / 2
    while channel + RASTER / 2 <= last do
        result[#result + 1] = channel
        channel = channel + RASTER
    end
    return result
end

--- Every beacon channel in every cellular band, to look for cells.
--
-- @treturn { number... } The channels, lowest first.
local function beacon_channels()
    local result = {}
    for _, band in ipairs(BANDS) do
        for _, channel in ipairs(raster(band.name)) do result[#result + 1] = channel end
    end
    return result
end

--[[- The carrier a channel is in: the 5MHz block of a cellular band around one of its beacon channels, downlink and
the uplink paired with it. A carrier is known by its beacon channel.

@tparam number channel A downlink or uplink channel.
@treturn number|nil The carrier's beacon channel, or `nil` if the channel isn't in one.
@treturn string|nil The band's name.
]]
local function carrier_of(channel)
    local name, part = of(channel)
    local band = BY_NAME[name]
    if not band or not band.downlink then return nil end
    local downlink = channel
    if part == "uplink" then downlink = band.downlink[1] + (channel - band.uplink[1]) end
    local block = math.floor((downlink - band.downlink[1]) / RASTER)
    local beacon = band.downlink[1] + block * RASTER + RASTER / 2
    -- A band's last few channels may be less than a whole block, so no carrier's.
    if beacon + RASTER / 2 > band.downlink[2] then return nil end
    return beacon, name
end

--[[- A carrier's channels.

@tparam number beacon The carrier's beacon channel.
@treturn { downlink = { number, number }, uplink = { number, number }, band = string }|nil The first and last channel of
its downlink and uplink, and its band's name, or `nil` if it isn't a carrier's beacon channel.
]]
local function carrier(beacon)
    local found, name = carrier_of(beacon)
    if found ~= beacon then return nil end
    local band = BY_NAME[name]
    local first = beacon - RASTER / 2
    local up = band.uplink[1] + (first - band.downlink[1])
    return { downlink = { first, first + RASTER - 1 }, uplink = { up, up + RASTER - 1 }, band = name }
end

--- A carrier's name, for people to read: its band and which 5MHz of it, from 1.
--
-- @tparam number beacon The carrier's beacon channel.
-- @treturn string|nil The name, such as `"b20/2"`, or `nil` if it isn't a carrier's beacon channel.
local function carrier_name(beacon)
    local found, name = carrier_of(beacon)
    if found ~= beacon then return nil end
    return ("%s/%d"):format(name, (beacon - RASTER / 2 - BY_NAME[name].downlink[1]) / RASTER + 1)
end

--- Read a carrier's name, as [`carrier_name`] gives it. A band on its own means its first carrier.
--
-- @tparam string text The name, such as `"b20/2"` or `"b3"`.
-- @treturn number|nil The carrier's beacon channel, or `nil` if there's no such carrier.
local function parse_carrier(text)
    if type(text) ~= "string" then return nil end
    local name, index = text:lower():match("^(b%d+)/(%d+)$")
    if not name then name, index = text:lower():match("^(b%d+)$"), "1" end
    local channels = name and raster(name)
    return channels and channels[tonumber(index)]
end

-- The channels a link of its own may use (see `check_link_channel`): from 30MHz, the lowest frequency the radio
-- model works at (a lower channel would be sent at 30MHz anyway), up to the last one before rednet's and GPS's
-- (65533-65535), whose frequencies are fixed.
local FIRST_LINK_CHANNEL, LAST_LINK_CHANNEL = 300, 65532

--[[- Check that a channel can carry a link of its own: an interface which every computer on it sends and listens on.

Channels in the cellular bands can't: phones listen on every beacon channel, and cells on their uplinks, so a link
there would take channels a phone or cell on the same modem needs, and its broadcasts would reach every phone around.
The stack's own bands are fine: a computer whose unicast channel it is ignores frames for other computers, and only
hears the link's broadcasts, as it would from any other computer on its band.

@tparam number channel The channel.
@treturn boolean|nil `true` if it can be used.
@treturn string|nil Why not.
]]
local function check_link_channel(channel)
    if type(channel) ~= "number" or channel % 1 ~= 0 or channel < FIRST_LINK_CHANNEL or channel > LAST_LINK_CHANNEL then
        return nil, ("A channel is a whole number from %d to %d (%gMHz to %gMHz)"):format(
            FIRST_LINK_CHANNEL, LAST_LINK_CHANNEL, frequency(FIRST_LINK_CHANNEL), frequency(LAST_LINK_CHANNEL)
        )
    end
    local name, part = of(channel)
    if part == "uplink" or part == "downlink" then
        return nil, ("Channel %d (%gMHz) is in cellular band %s (%sMHz), which phones and cells need"):format(
            channel, frequency(channel), name, BY_NAME[name].label
        )
    end
    return true
end

--- A computer's channels on one of the network stack's own bands.
--
-- @tparam number id The computer's ID.
-- @tparam string name `"low"` or `"high"`.
-- @treturn number The computer's unicast channel.
-- @treturn number The band's broadcast channel.
local function stack_channels(id, name)
    local range = (BY_NAME[name] or BY_NAME.high).channels
    return range[1] + 1 + id % (range[2] - range[1]), range[1]
end

return {
    RASTER = RASTER,
    get = get,
    list = list,
    cellular = cellular,
    frequency = frequency,
    of = of,
    uplink_of = uplink_of,
    raster = raster,
    beacon_channels = beacon_channels,
    carrier_of = carrier_of,
    carrier = carrier,
    carrier_name = carrier_name,
    parse_carrier = parse_carrier,
    check_link_channel = check_link_channel,
    stack_channels = stack_channels,
}
