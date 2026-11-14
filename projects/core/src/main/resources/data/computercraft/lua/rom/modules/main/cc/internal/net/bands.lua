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
    stack_channels = stack_channels,
}
