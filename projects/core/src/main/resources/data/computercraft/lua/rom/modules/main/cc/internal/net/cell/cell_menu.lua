-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell's menu, which `celld` opens: how the cell is doing, the cores it connects to, and its settings, each of
which can be changed where it's shown. And what the menu and `celld`'s commands share: how settings are written and
read, and what's said about the cell.

Everything the menu changes, it changes as `celld`'s commands do, with `net.cell.configureCell`: a value which won't
do is said, and changes nothing.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `celld` program instead.

@local
]]

local bands = require "cc.internal.net.bands"
local common = require "cc.internal.net.cell.common"
local menu = require "cc.internal.net.cell.menu"
local carrier_menu = require "cc.internal.net.cell.carrier_menu"

-- How often what's shown is read again, in seconds.
local REFRESH = 1

--- Each setting, with what it takes after its name (for "set"), in the order they're shown.
local SETTINGS = {
    { name = "area", takes = "<number>" },
    { name = "band", takes = "<band>...", most = common.MAX_CARRIERS },
    { name = "interval", takes = "<seconds>" },
    { name = "pos", takes = "<x> <y> <z>", count = 3 },
    { name = "power", takes = "<dBm>" },
    { name = "service", takes = "sms|full" },
    { name = "override", takes = "on|off" },
}

--- What overriding the carriers a cell's cores offer may do, for whoever turns it on to read first.
local OVERRIDE_WARNING = "The cell may then use carriers its cores don't offer. This may violate network assignment agreements."

-- A band, as a person might write it: "b3", "B3", "3", or its frequency, "1800" or "1800MHz". Or one of a band's
-- carriers: the band, and which 5MHz of it, as in "b3/2".
local function parse_band(text)
    local wanted, index = text:lower():match("^([^/]+)/(%d+)$")
    wanted = (wanted or text:lower()):gsub("mhz$", "")
    for _, band in ipairs(bands.cellular()) do
        if wanted == band.name or "b" .. wanted == band.name or wanted == band.label then
            if not index then return band.name end
            local carrier = bands.parse_carrier(band.name .. "/" .. index)
            return carrier and bands.carrier_name(carrier)
        end
    end
end

--- A band (or a carrier), or several, for people to read.
--
-- @tparam string|{ string... } band_name The band's name, or the names of several bands and carriers.
-- @treturn string What to show.
local function band_label(band_name)
    if type(band_name) == "table" then
        local labels = {}
        for i, each in ipairs(band_name) do labels[i] = band_label(each) end
        return table.concat(labels, ", ")
    end
    local band = bands.get(band_name)
    return band and band.label and ("%s (%sMHz)"):format(band_name, band.label) or band_name
end

--[[- Read a setting's value, from what was typed after its name.

@tparam string key The setting's name.
@tparam { string... } words What was typed.
@return The value, as `net.cell.configureCell` takes it. `false` means "full" for the service: not only messages.
@throws If it isn't a value the setting could have, with what's wrong with it.
]]
local function read_value(key, words)
    local text = words[1]
    if key == "band" then
        -- One band, or several bands and carriers: a cell on each.
        local list = {}
        for i, word in ipairs(words) do
            local band = parse_band(word)
            if not band and word:find("/", 1, true) then
                error(("There's no carrier called %s. A band's carriers are numbered from 1, as in b20/1."):format(word), 0)
            elseif not band then
                local names = {}
                for _, each in ipairs(bands.cellular()) do names[#names + 1] = band_label(each.name) end
                error(("There's no cellular band called %s. They're %s."):format(word, table.concat(names, ", ")), 0)
            end
            list[i] = band
        end
        if #list == 1 and not list[1]:find("/", 1, true) then return list[1] end
        return list
    elseif key == "service" then
        if text == "sms" then return "sms" end
        if text == "full" then return false end
        error("A cell's service is sms (it only carries messages) or full.", 0)
    elseif key == "override" then
        if text == "on" then return true end
        if text == "off" then return false end
        error("A cell's override is on (it may use carriers its cores don't offer) or off.", 0)
    elseif key == "pos" then
        local x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3])
        if not x or not y or not z then error("A cell's position is three whole numbers: its computer's x, y and z.", 0) end
        return { x, y, z }
    end
    local number = tonumber(text)
    if not number then error(("Expected a number, not %s."):format(text), 0) end
    return number
end

--- Each of a cell's settings, set or not, as it's shown.
--
-- @tparam table info The cell, as `net.cell.cellInfo` describes it.
-- @treturn { [string] = string } What to show for each setting, by its name.
local function setting_values(info)
    return {
        area = tostring(info.area or 0),
        band = info.band and band_label(info.band) or "any (its core picks)",
        override = info.override and "on" or "off",
        interval = info.interval and ("%g seconds"):format(info.interval)
            or info.current_interval and ("as its core says (%g seconds)"):format(info.current_interval)
            or "as its core says",
        pos = info.pos and ("%d %d %d"):format(info.pos[1], info.pos[2], info.pos[3]) or "not said",
        power = info.power and ("%g dBm"):format(info.power) or ("%g dBm (the default)"):format(info.default_power or 30),
        service = info.service == "sms" and "messages only" or "full",
    }
end

-- Why a core's network has the cell off the air: what it has no carrier for.
local function no_carrier(link)
    local network = tostring(link.network)
    if not (link.carriers or {})[1] then return network .. " has no carriers yet" end
    if link.unplaced and link.unplaced[1] then return ("%s has no carrier for %s"):format(network, table.concat(link.unplaced, ", ")) end
    return network .. " has no carrier for it"
end

--[[- What the cell is doing with one of its cores, in words.

@tparam table info The cell, as `net.cell.cellInfo` describes it.
@tparam table link The core's part of it: one of `info.links`.
@tparam string name What `celld` is called, to say which commands to use.
@tparam[opt] string added The core just added, which may have been mistyped.
@treturn { { text = string, bad? = boolean }... } Each line to say, and whether it says something is wrong.
]]
local function link_lines(info, link, name, added)
    local lines = {}
    local function say(text, bad) lines[#lines + 1] = { text = text, bad = bad } end
    if link.state == "connecting" then
        say(("%s: connecting..."):format(link.core))
    elseif link.state == "waiting" then
        say(("%s: waiting to be allowed. On that core, run 'cellcore allow %d', and check it shows this fingerprint:"):format(link.core, info.id))
        say("  " .. tostring(info.fingerprint))
    elseif link.state == "standby" then
        say(("%s: allowed by %s, whose carriers are %s."):format(
            link.core, tostring(link.network), table.concat(link.carriers or {}, ", ")
        ))
        say(("The cell isn't on the air yet. Say which bands it should use with '%s set band <band>...', or '%s confirm' for %s."):format(
            name, name, info.band and "those it's set to" or "any, as its core picks"
        ))
    elseif link.state == "unplaced" then
        say(("%s: %s. The cell is off the air until it has."):format(link.core, no_carrier(link)))
    elseif link.state == "serving" then
        say(("%s: serving %s."):format(link.core, link.network))
    elseif link.state == "refused" then
        say(("%s refused this cell: %s"):format(link.core, tostring(link.error)), true)
    elseif link.state == "lost" then
        say(("%s can't be reached: %s"):format(link.core, tostring(link.error)), true)
        if link.retry then say(("Trying again in %d seconds."):format(link.retry)) end
        if link.core == added then say(("If that's not the right core, '%s remove %s' stops trying."):format(name, link.core)) end
    end
    if link.state == "serving" and link.unplaced and link.unplaced[1] then
        say(("%s has no carrier for %s: the cell isn't on it."):format(link.network, table.concat(link.unplaced, ", ")))
    end
    if link.newer then
        say(("%s speaks a newer version of the network (%d). If they don't work together, update this cell's ROM."):format(
            link.core, link.newer
        ))
    end
    return lines
end

--- Where the cell is on the air: a line for each carrier its computer has a cell on.
--
-- @tparam table info The cell, as `net.cell.cellInfo` describes it.
-- @treturn { string... } The lines.
local function carrier_lines(info)
    local lines = {}
    -- A cell on each carrier the computer is on: one, unless it was set to be on several bands.
    for _, cell in ipairs(info.cells or { info }) do
        if cell.carrier then lines[#lines + 1] = ("On %s, reached on channel %d."):format(cell.carrier, cell.ul) end
    end
    return lines
end

--[[- What changing a setting did, in words.

@tparam table info The cell as it was before, as `net.cell.cellInfo` described it.
@tparam string key The setting's name.
@param value What it was set to, or `nil` if it was unset.
@tparam boolean restarted Whether the cell started again for it.
@tparam string name What `celld` is called, to say which commands to use.
@treturn { string... } Each line to say.
]]
local function changed_lines(info, key, value, restarted, name)
    local lines = {}
    local function say(text) lines[#lines + 1] = text end
    -- A cell which stands by isn't on any band yet: saying which it should use puts it on the air.
    local standby = info.state == "standby" or info.confirmed == false
    if standby and key == "band" then restarted = true end
    if key == "area" then
        say(("The cell is in area %d now."):format(value or 0))
    elseif key == "band" then
        if type(value) == "table" and info.state ~= "stopped" and not restarted then
            say(("The computer has its cells on %s already, and they stay there."):format(band_label(value)))
        elseif type(value) == "table" then
            say(("The computer runs a cell on each of %s: carriers of its core's."):format(band_label(value)))
        elseif value and info.state ~= "stopped" and not restarted then
            say(("The cell is on band %s already, and stays there."):format(band_label(value)))
        elseif value then
            say(("The cell goes on a carrier of its core's in band %s."):format(band_label(value)))
        else
            say("The cell may go on any of its core's carriers, when it next connects. It stays where it is until then.")
        end
    elseif key == "interval" then
        if value then
            say(("The cell sends its system information every %g seconds, whatever its core says."):format(value))
        else
            say("The cell sends its system information as often as its core says.")
        end
    elseif key == "pos" then
        if value then
            say(("The cell says it's at %d, %d, %d."):format(value[1], value[2], value[3]))
        else
            say("The cell no longer says where it is.")
        end
    elseif key == "power" then
        if value then
            say(("The cell sends with %g dBm."):format(value))
        else
            say(("The cell sends with %g dBm, the default: as far as phones can answer."):format(info.default_power or 30))
        end
    elseif key == "service" then
        if value then
            say("The cell only carries messages now. Its phones move to a cell which carries everything, if there's one.")
        else
            say("The cell carries everything.")
        end
    elseif key == "override" then
        if value then
            say("The cell may use carriers its cores don't offer. This may violate network assignment agreements.")
        else
            say("The cell only uses carriers its cores offer.")
        end
    end
    if standby and key == "band" and info.state ~= "stopped" then
        say("Its bands are confirmed: it goes on the air.")
    elseif restarted then
        say("It started again for that: its phones lose service for a moment, and attach again.")
    elseif info.state == "stopped" then
        if not info.cores then
            say(("It's kept for when the cell starts. Add a core with '%s add <core>'."):format(name))
        else
            say(("It's kept for when the cell starts again ('%s start')."):format(name))
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- The menu
--------------------------------------------------------------------------------

local c = menu.c

-- How the cell (or one of its cores) is doing, in a word or two, and the colour to say it in.
local function state_of(state, network)
    if state == "serving" then return network and "serving " .. network or "serving", c(colours.lime, colours.white) end
    if state == "waiting" then return "waiting to be allowed", c(colours.yellow, colours.lightGrey) end
    if state == "standby" then return "not on the air yet", c(colours.yellow, colours.lightGrey) end
    if state == "unplaced" then return "no carrier", c(colours.orange, colours.lightGrey) end
    if state == "connecting" then return "connecting", c(colours.yellow, colours.lightGrey) end
    if state == "lost" then return "can't reach its core", c(colours.red, colours.lightGrey) end
    if state == "refused" then return "refused", c(colours.red, colours.lightGrey) end
    if state == "stopped" then return "stopped", colours.lightGrey end
    return tostring(state), colours.lightGrey
end

-- Lines of text as a list's items, broken to fit the screen: there to be read, and choosing one does nothing.
local function text_items(items, lines)
    local w = term.getSize()
    for _, line in ipairs(lines) do
        local text, fg = line, nil
        if type(line) == "table" then text, fg = line.text, line.bad and c(colours.red, colours.lightGrey) or line.fg end
        for _, part in ipairs(menu.wrapped(text, w)) do items[#items + 1] = { text = part, fg = fg } end
    end
    return items
end

-- What the cell is doing with one of its cores, in as few words as say it: for the menu, whose reader knows the rest.
local function link_brief(info, link)
    local lines = {}
    local function say(text, bad, fg) lines[#lines + 1] = { text = text, bad = bad, fg = fg } end
    local core, state = tostring(link.core), link.state
    if state == "connecting" then
        say(core .. ": connecting")
    elseif state == "waiting" then
        say(core .. ": waiting to be allowed")
        say(("  #%d %s"):format(info.id, tostring(info.fingerprint)))
    elseif state == "standby" then
        say(("%s: %s, standing by"):format(core, tostring(link.network)))
    elseif state == "unplaced" then
        say(("%s: %s"):format(core, no_carrier(link)), false, c(colours.orange, colours.lightGrey))
    elseif state == "serving" then
        say(("%s: serving %s"):format(core, tostring(link.network)))
    elseif state == "refused" then
        say(("%s refused: %s"):format(core, tostring(link.error)), true)
    elseif state == "lost" then
        say(("%s: %s"):format(core, tostring(link.error)), true)
        if link.retry then say(("  again in %d s"):format(link.retry)) end
    end
    if link.carriers and (state == "standby" or state == "unplaced") and link.carriers[1] then
        say("  offers " .. table.concat(link.carriers, ", "))
    end
    if state == "serving" and link.unplaced and link.unplaced[1] then
        say(("  no carrier for %s"):format(table.concat(link.unplaced, ", ")), false, c(colours.orange, colours.lightGrey))
    end
    if link.newer then say(("  newer version (%d)"):format(link.newer)) end
    return lines
end

-- What each setting takes, for the screen it's typed on. Empty unsets it.
local NOTES = {
    area = "A whole number. Empty: 0.",
    interval = "0.5 to 10 seconds. Empty: as its core says.",
    pos = "x y z. Empty: not said.",
    power = "dBm. Empty: 30, as far as phones can answer.",
}

-- What's in a setting's line to begin with: its value as it would be typed.
local function typed_value(info, key)
    local value = info[key]
    if value == nil then return "" end
    if key == "pos" then return ("%d %d %d"):format(value[1], value[2], value[3]) end
    if key == "area" and value == 0 then return "" end
    return ("%g"):format(value)
end

-- The carriers a cell's cores offer, by name: each with the networks which have it.
local function offered_of(info)
    local offered = {}
    for _, link in ipairs(info.links or {}) do
        for _, name in ipairs(link.carriers or {}) do
            offered[name] = offered[name] or {}
            table.insert(offered[name], tostring(link.network))
        end
    end
    return offered
end

--[[- Show the cell's menu, until the user leaves it.

@tparam string name What `celld` is called, to say which commands to use.
]]
local function run(name)
    -- What the last thing done did (or why it couldn't be done), shown beneath the lists until something else is done.
    local said, said_bad = nil, false
    local function say(lines, bad)
        if type(lines) == "table" then lines = table.concat(lines, " ") end
        said, said_bad = lines, bad or false
    end
    local function note()
        if said then return said, said_bad and c(colours.red, colours.lightGrey) or colours.lightGrey end
    end

    -- Set a setting (or unset it, with `false`). A change which may start a running cell again is asked about first.
    -- Returns what's wrong, if it couldn't be done.
    local function apply(key, value)
        local info = net.cell.cellInfo()
        -- (A cell which is off the air has no phones to lose.)
        if info.state ~= "stopped" and info.state ~= "standby" and info.state ~= "unplaced" and (key == "area" or key == "band") then
            local sure = menu.confirm_screen("Change the " .. key,
                "The cell may start again: its phones lose service for a moment.", "Change")
            if not sure then
                say("Nothing was changed.")
                return nil
            end
        end
        local standby = info.state == "standby" or info.confirmed == false
        local ok, restarted = net.cell.configureCell({ [key] = value })
        if not ok then return tostring(restarted) end
        local text = ("%s: %s."):format(key, setting_values(net.cell.cellInfo())[key])
        if standby and key == "band" and info.state ~= "stopped" then
            text = text .. " On the air."
        elseif restarted then
            text = text .. " The cell started again."
        end
        say(text)
        return nil
    end

    -- Let the cell use carriers its cores don't offer, once whoever asks has read what that may do: or no longer.
    local function toggle_override()
        local info = net.cell.cellInfo()
        if not info.override and not menu.confirm_screen("Band override", OVERRIDE_WARNING, "Override", "Cancel") then
            return
        end
        local problem = apply("override", not info.override)
        if problem then say(problem, true) end
    end

    -- The cell's bands: those its cores offer (or all of them, with the override), and their carriers, to tick. What
    -- was ticked is the cell's once the screen is left.
    local function bands_screen()
        local info = net.cell.cellInfo()
        local draft = type(info.band) == "table" and { table.unpack(info.band) } or { info.band }
        local before = table.concat(carrier_menu.sorted(draft), " ")
        local on_air = {}
        carrier_menu.pick {
            title = "Bands",
            right = function() return draft[1] and #draft .. " chosen" or "any" end,
            look = function()
                on_air = {}
                for _, cell in ipairs(net.cell.cellInfo().cells or {}) do on_air[tostring(cell.carrier)] = true end
            end,
            chosen = function() return draft end,
            toggle = function(want, on)
                for i = #draft, 1, -1 do
                    if draft[i] == want then table.remove(draft, i) end
                end
                if on then draft[#draft + 1] = want end
            end,
            offered = function()
                local now = net.cell.cellInfo()
                if now.override then return nil end
                return offered_of(now)
            end,
            any = true,
            first = function()
                return { {
                    text = (draft[1] and "[ ] " or "[x] ") .. "Any band", id = "\0any",
                    tail = { { "its core picks", colours.lightGrey } },
                    open = function() draft = {} end,
                }, }
            end,
            last = function()
                local override = net.cell.cellInfo().override
                return { {
                    text = "Override", id = "\0override", open = toggle_override,
                    tail = { { override and "on" or "off", override and c(colours.orange, colours.white) or colours.lightGrey } },
                }, }
            end,
            -- The networks which have each carrier: in green while the computer has a cell on it.
            tail = function(carrier)
                local networks = offered_of(net.cell.cellInfo())[carrier]
                local text = networks and table.concat(networks, ", ") or "not offered"
                if on_air[carrier] then return text, c(colours.lime, colours.white) end
                return text, networks and colours.lightGrey or c(colours.orange, colours.lightGrey)
            end,
            note = function()
                -- (Why the override couldn't be changed, if it couldn't.)
                if said and said_bad then return note() end
                local now = net.cell.cellInfo()
                if now.override then return "Override: carriers its cores don't offer may be chosen.", c(colours.orange, colours.lightGrey) end
                if next(offered_of(now)) == nil then
                    return "Its cores offer no carriers yet.", c(colours.yellow, colours.lightGrey)
                end
            end,
            limit = common.MAX_CARRIERS,
            refresh = REFRESH,
        }
        local after = carrier_menu.sorted(draft)
        if table.concat(after, " ") == before then return end
        local value = after
        if not after[1] then
            value = false
        elseif not after[2] and not after[1]:find("/", 1, true) then
            value = after[1]
        end
        local problem = apply("band", value)
        if problem then say(problem, true) end
    end

    local function edit_setting(key)
        if key == "band" then return bands_screen() end
        if key == "override" then return toggle_override() end
        if key == "service" then
            menu.list_screen {
                title = function() return "Service" end,
                items = function()
                    local sms = net.cell.cellInfo().service == "sms"
                    return {
                        { text = "Full", tail = not sms and { { "now", colours.lightGrey } } or nil, value = false },
                        { text = "Messages only", tail = sms and { { "now", colours.lightGrey } } or nil, value = "sms" },
                    }
                end,
                choose = function(item)
                    local problem = apply("service", item.value)
                    if problem then say(problem, true) end
                    return "back"
                end,
                hint = { "Enter: choose", "Q: back" },
            }
            return
        end

        local setting
        for _, each in ipairs(SETTINGS) do
            if each.name == key then setting = each end
        end
        menu.input_screen {
            title = "Set the " .. key, label = key .. ":", value = typed_value(net.cell.cellInfo(), key), note = NOTES[key],
            check = function(text)
                if text == "" then return apply(key, false) end
                local words = {}
                for word in text:gmatch("%S+") do words[#words + 1] = word end
                if #words < (setting.count or 1) or #words > (setting.most or setting.count or 1) then
                    return ("Expected %s."):format(setting.takes)
                end
                local ok, value = pcall(read_value, key, words)
                if not ok then return tostring(value) end
                return apply(key, value)
            end,
        }
    end

    local function settings_screen()
        menu.list_screen {
            title = function() return "Settings" end,
            items = function()
                local info = net.cell.cellInfo()
                local shown, items = setting_values(info), {}
                for i, setting in ipairs(SETTINGS) do
                    local colour = setting.name == "override" and info.override and c(colours.orange, colours.white) or colours.lightGrey
                    items[i] = { text = setting.name, tail = { { shown[setting.name], colour } }, id = setting.name }
                end
                return items
            end,
            choose = function(item) edit_setting(item.id) end,
            note = note,
            hint = { "Enter: change", "Q: back" },
            refresh = REFRESH,
        }
    end

    -- The cores, as they'd be with one more, or one fewer.
    local function cores_with(info, add, remove)
        local cores = {}
        for _, core in ipairs(info.cores or {}) do
            if core ~= remove then cores[#cores + 1] = core end
        end
        cores[#cores + 1] = add
        return cores
    end

    local function add_core()
        menu.input_screen {
            title = "Add a core", label = "Core:", max = 255,
            note = "A core's name or address.",
            check = function(core)
                if core == "" then return "Enter the core's name or address." end
                local info = net.cell.cellInfo()
                for _, other in ipairs(info.cores or {}) do
                    if other:lower() == core:lower() then return ("This cell connects to %s already."):format(other) end
                end
                local ok, err = net.cell.configureCell({ cores = cores_with(info, core) })
                if not ok then return tostring(err) end
                if info.state == "stopped" then
                    if info.enabled == false and info.cores then
                        say(("Added %s. The cell is stopped."):format(core))
                        return nil
                    end
                    ok, err = net.cell.startCell()
                    if not ok then return tostring(err) end
                end
                say(("Added %s."):format(core))
                return nil
            end,
        }
    end

    local function link_of(info, core)
        for _, link in ipairs(info.links or {}) do
            if link.core == core then return link end
        end
    end

    local function core_screen(core)
        menu.list_screen {
            title = function() return core end,
            items = function()
                local info = net.cell.cellInfo()
                local link = link_of(info, core)
                local items = text_items({}, link and link_brief(info, link) or { "The cell isn't running." })
                items[#items + 1] = { text = "Remove this core", id = "remove" }
                return items
            end,
            choose = function(item)
                if item.id ~= "remove" then return nil end
                local info = net.cell.cellInfo()
                local last = #(info.cores or {}) <= 1
                local sure = menu.confirm_screen("Remove " .. core, last
                    and "The cell has no other cores: it stops."
                    or "Its network's phones here lose service.",
                    "Remove")
                if not sure then return nil end
                local ok, err = net.cell.configureCell({ cores = cores_with(info, nil, core) })
                if not ok then
                    say(tostring(err), true)
                else
                    say(last and ("Removed %s. The cell stopped."):format(core) or ("Removed %s."):format(core))
                end
                return "back"
            end,
            note = note,
            hint = { "Enter: choose", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function cores_screen()
        menu.list_screen {
            title = function() return "Cores" end,
            items = function()
                local info = net.cell.cellInfo()
                local items = {}
                for _, core in ipairs(info.cores or {}) do
                    local link = link_of(info, core)
                    local text, colour = state_of(link and link.state or "stopped", link and link.network)
                    items[#items + 1] = { text = core, tail = { { text, colour } }, id = core, core = core }
                end
                items[#items + 1] = { text = "Add a core...", id = "\0add" }
                return items
            end,
            choose = function(item)
                if item.core then core_screen(item.core) else add_core() end
            end,
            note = note,
            hint = { "Enter: open", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function status_screen()
        menu.list_screen {
            title = function()
                local info = net.cell.cellInfo()
                return "Status", (state_of(info.state, info.network))
            end,
            items = function()
                local info = net.cell.cellInfo()
                local lines = {}
                if not info.cores then
                    lines[1] = "No cell: add a core to start one."
                elseif info.state == "stopped" then
                    lines[1] = info.enabled == false and "The cell is stopped." or "The cell isn't running."
                    lines[2] = "Cores: " .. table.concat(info.cores, ", ")
                else
                    lines[1] = ("Cell #%d, area %d"):format(info.id, info.area or 0)
                    for _, cell in ipairs(info.cells or { info }) do
                        if cell.carrier then lines[#lines + 1] = ("%s, channel %d"):format(cell.carrier, cell.ul) end
                    end
                    for _, link in ipairs(info.links or {}) do
                        for _, line in ipairs(link_brief(info, link)) do lines[#lines + 1] = line end
                    end
                end
                return text_items({}, lines)
            end,
            choose = function() end,
            hint = { "Q: back" },
            refresh = REFRESH,
        }
    end

    -- A cell which stands by: what its networks have, and its bands to confirm (as they're set, or any), or to choose.
    local function confirm_screen()
        menu.list_screen {
            title = function() return "Go on the air" end,
            items = function()
                local info = net.cell.cellInfo()
                local lines = {}
                for _, link in ipairs(info.links or {}) do
                    if link.state == "standby" then
                        lines[#lines + 1] = ("%s: %s"):format(
                            tostring(link.network), (link.carriers or {})[1] and table.concat(link.carriers, ", ") or "no carriers yet"
                        )
                    end
                end
                if not lines[1] then lines[1] = "Its cores haven't answered yet." end
                local items = text_items({}, lines)
                items[#items + 1] = {
                    text = info.band and "Use " .. band_label(info.band) or "Use any band", id = "confirm",
                }
                items[#items + 1] = { text = "Choose its bands...", id = "choose" }
                return items
            end,
            choose = function(item)
                if item.id == "confirm" then
                    local ok, err = net.cell.configureCell({ confirmed = true })
                    if ok then say("Bands confirmed: on the air.") else say(tostring(err), true) end
                    return "back"
                elseif item.id == "choose" then
                    bands_screen()
                    if net.cell.cellInfo().confirmed ~= false then return "back" end
                end
                return nil
            end,
            note = note,
            hint = { "Enter: choose", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function start()
        local ok, err = net.cell.startCell()
        if ok then say("Started the cell.") else say(tostring(err), true) end
    end

    menu.list_screen {
        title = function()
            local info = net.cell.cellInfo()
            return ("Cell #%s"):format(tostring(info.id or "?")), (state_of(info.cores and info.state or "stopped", info.network))
        end,
        items = function()
            local info = net.cell.cellInfo()
            local running = info.cores and info.state ~= "stopped"
            local text, colour = state_of(info.cores and info.state or "stopped", info.network)
            local items = {
                { text = "Status", tail = { { text, colour } }, id = "status", open = status_screen },
                {
                    text = "Cores", tail = { { info.cores and tostring(#info.cores) or "none", colours.lightGrey } },
                    id = "cores", open = cores_screen,
                },
                { text = "Settings", id = "settings", open = settings_screen },
            }
            if running and (info.state == "standby" or info.confirmed == false) then
                items[#items + 1] = { text = "Go on the air...", id = "confirm", open = confirm_screen }
            end
            if running then
                items[#items + 1] = {
                    text = "Restart the cell", id = "restart",
                    open = function()
                        if not menu.confirm_screen("Restart the cell", "Its phones lose service for a moment.", "Restart") then
                            return
                        end
                        net.cell.stopCell()
                        start()
                    end,
                }
                items[#items + 1] = {
                    text = "Stop the cell", id = "stop",
                    open = function()
                        if not menu.confirm_screen("Stop the cell", "Its phones lose service.", "Stop") then return end
                        net.cell.stopCell()
                        say("Stopped the cell.")
                    end,
                }
            elseif info.cores then
                items[#items + 1] = { text = "Start the cell", id = "start", open = start }
            end
            return items
        end,
        choose = function(item) item.open() end,
        note = function()
            if said then return note() end
            local info = net.cell.cellInfo()
            if not info.cores then return "No cell: add a core to start one." end
            for _, link in ipairs(info.links or {}) do
                if link.state == "waiting" then
                    return ("Waiting to be allowed as #%d: %s"):format(info.id, tostring(info.fingerprint)),
                        c(colours.yellow, colours.lightGrey)
                end
            end
            if info.state == "standby" then
                return "Not on the air: confirm its bands under Go on the air.", c(colours.yellow, colours.lightGrey)
            end
            if info.state == "unplaced" then
                for _, link in ipairs(info.links or {}) do
                    if link.state == "unplaced" then return "Off the air: " .. no_carrier(link) .. ".", c(colours.orange, colours.lightGrey) end
                end
            end
        end,
        hint = { "Enter: open", "Q: quit" },
        refresh = REFRESH,
        back = "quit",
    }
    menu.clear()
    term.setCursorPos(1, 1)
end

return {
    SETTINGS = SETTINGS,
    OVERRIDE_WARNING = OVERRIDE_WARNING,
    band_label = band_label,
    read_value = read_value,
    setting_values = setting_values,
    link_lines = link_lines,
    carrier_lines = carrier_lines,
    changed_lines = changed_lines,
    run = run,
}
