-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The screens carriers are chosen on, in a core's menu and a cell's: the cellular bands, and in each its carriers,
to tick and untick, so nobody need type their names.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cellcore` and `celld` programs instead.

@local
]]

local bands = require "cc.internal.net.bands"
local common = require "cc.internal.net.cell.common"
local menu = require "cc.internal.net.cell.menu"

local c = menu.c

--- The frequencies of a carrier's downlink, for people to read.
--
-- @tparam number beacon The carrier's beacon channel.
-- @treturn string The frequencies, such as `"791-796 MHz"`.
local function range_of(beacon)
    local carrier = bands.carrier(beacon)
    return ("%g-%g MHz"):format(carrier.downlink[1] / 10, (carrier.downlink[2] + 1) / 10)
end

--[[- Put what was chosen in order: band by band, lowest first, a band as a whole before its carriers.

@tparam { string... } wants Bands and carriers, by name.
@treturn { string... } The same, in order.
]]
local function sorted(wants)
    local order = {}
    for i, band in ipairs(bands.cellular()) do order[band.name] = i end
    local keyed = {}
    for i, want in ipairs(wants) do
        local carrier = common.want_carrier(want)
        local band = carrier and select(2, bands.carrier_of(carrier)) or want
        keyed[i] = { want = want, band = order[band] or 0, carrier = carrier or 0, at = i }
    end
    table.sort(keyed, function(a, b)
        if a.band ~= b.band then return a.band < b.band end
        if a.carrier ~= b.carrier then return a.carrier < b.carrier end
        return a.at < b.at
    end)
    local result = {}
    for i, entry in ipairs(keyed) do result[i] = entry.want end
    return result
end

-- What of a band was chosen, in a few characters: "any" for the band as a whole, and its carriers by number.
local function chosen_in(band, wants)
    local parts = {}
    for _, want in ipairs(sorted(wants)) do
        if want == band then
            parts[#parts + 1] = "any"
        elseif want:match("^([^/]+)/") == band then
            parts[#parts + 1] = want:match("(/%d+)$")
        end
    end
    return table.concat(parts, " ")
end

--[[- Show the bands, and the carriers of whichever is opened, to tick and untick, until the user goes back.

`options` has:
 - `title`: the first screen's title, and `right`, a function which returns what to put to its right;
 - `chosen`: a function which returns what's chosen now, a list of carriers (`"b20/1"`) and bands (`"b20"`) by name;
 - `toggle`: what to call with a carrier or band and whether it's now chosen. It returns what's wrong, if it couldn't
   be done;
 - `offered`: a function which returns the carriers which may be chosen, as a table with each one's name in it, or
   `nil` when any may. Others are only shown while they're chosen, so they can be unticked;
 - `any`: whether a band may be chosen as a whole, for whichever of its carriers suits;
 - `first`: a function which returns items to put before the bands, and `last`, after them: each as a list's items
   are, with `open`, what choosing it does;
 - `tail`: a function which, given a carrier's name, returns what to say at the end of its line, and the colour;
 - `note`: a function which returns a note for beneath the bands, and its colour;
 - `limit`: how many may be chosen;
 - `look`: what to call before what's chosen is shown again: to ask whoever knows, say;
 - `refresh`: how often to look at what's chosen again, in seconds.

@tparam table options What to choose from, and what choosing does.
]]
local function pick(options)
    local problem
    local function note()
        if problem then return problem, c(colours.red, colours.lightGrey) end
        if options.note then return options.note() end
    end

    local function toggle(want, on)
        problem = nil
        if on and options.limit and #options.chosen() >= options.limit then
            problem = ("At most %d may be chosen."):format(options.limit)
            return
        end
        problem = options.toggle(want, on)
    end

    local function is_chosen(want)
        for _, each in ipairs(options.chosen()) do
            if each == want then return true end
        end
        return false
    end

    local function tick(on) return on and "[x] " or "[ ] " end

    -- A band's carriers.
    local function band_screen(band)
        menu.list_screen {
            title = function() return ("%s, %s MHz"):format(band.name, band.label), chosen_in(band.name, options.chosen()) end,
            items = function()
                if options.look then options.look() end
                local offered = options.offered and options.offered()
                local items = {}
                if options.any then
                    local on, any = is_chosen(band.name), false
                    for name in pairs(offered or {}) do any = any or name:match("^([^/]+)/") == band.name end
                    if on or not offered or any then
                        items[#items + 1] = {
                            text = tick(on) .. "Any carrier", id = band.name, want = band.name, on = on,
                            tail = { { "its core picks", colours.lightGrey } },
                        }
                    end
                end
                for i, beacon in ipairs(bands.raster(band.name)) do
                    local name = ("%s/%d"):format(band.name, i)
                    local on = is_chosen(name)
                    local may = not offered or offered[name] ~= nil
                    if on or may then
                        local text, colour
                        if not may then
                            text, colour = "not offered", c(colours.orange, colours.lightGrey)
                        elseif options.tail then
                            text, colour = options.tail(name)
                        end
                        items[#items + 1] = {
                            text = ("%s%-6s %s"):format(tick(on), name, range_of(beacon)), id = name, want = name, on = on,
                            tail = text and { { text, colour or colours.lightGrey } } or nil,
                        }
                    end
                end
                return items
            end,
            choose = function(item) toggle(item.want, not item.on) end,
            keys = { [" "] = function(item) if item then toggle(item.want, not item.on) end end },
            empty = "None of its carriers is offered.",
            note = note,
            hint = { "Enter: tick", "Q: back" },
            refresh = options.refresh,
        }
        problem = nil
    end

    menu.list_screen {
        title = function() return options.title, options.right and options.right() or nil end,
        items = function()
            if options.look then options.look() end
            local wants = options.chosen()
            local offered = options.offered and options.offered()
            local items = {}
            for _, item in ipairs(options.first and options.first() or {}) do items[#items + 1] = item end
            for _, band in ipairs(bands.cellular()) do
                local shown = not offered
                for name in pairs(offered or {}) do shown = shown or name:match("^([^/]+)/") == band.name end
                local chosen = chosen_in(band.name, wants)
                if shown or chosen ~= "" then
                    items[#items + 1] = {
                        text = ("%-4s %s MHz"):format(band.name, band.label), id = band.name,
                        tail = { { chosen ~= "" and chosen or "-", chosen ~= "" and c(colours.lime, colours.white) or colours.lightGrey } },
                        open = function() band_screen(band) end,
                    }
                end
            end
            for _, item in ipairs(options.last and options.last() or {}) do items[#items + 1] = item end
            return items
        end,
        choose = function(item)
            problem = nil
            return item.open()
        end,
        note = note,
        hint = { "Enter: open", "Q: back" },
        refresh = options.refresh,
    }
end

return {
    range_of = range_of,
    sorted = sorted,
    pick = pick,
}
