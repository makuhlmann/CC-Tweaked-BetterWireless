-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A core's menu, which `cellcore` opens: how the network is doing, the computers waiting to be let in and those
which were, its cells and subscribers, its agreements with other networks, its carriers, and its log, each of which
can be changed where it's shown. And what the menu and `cellcore`'s commands share: setting a core up, and what's said
about the network.

Everything the menu does, it asks the core for as `cellcore`'s commands do, over the control port: so it works on the
core's own computer and (with `cellcore remote`) on another, and what the core refuses is said, and changes nothing.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cellcore` program instead.

@local
]]

local files = require "cc.internal.net.files"
local common = require "cc.internal.net.cell.common"
local menu = require "cc.internal.net.cell.menu"

local CONFIG = "/.cell/config"

-- How often the core is asked how the network is doing while the menu is shown, in seconds.
local REFRESH = 2

-- While the core can't be reached, how many times the menu looks at it again between tries to connect: a try may
-- take a while, and the menu does nothing else meanwhile.
local RECONNECT_EVERY = 5

-- How many of the log's lines to keep to show.
local MAX_LOG = 200

local c = menu.c

-- What each kind of computer does, as "wants to ..." and "allowed to ...".
local WANTS = { cell = "be a cell", admin = "manage the network" }

--- What a kind of computer does, as "wants to ..." and "allowed to ...".
--
-- @param role The kind of computer: `"cell"` or `"admin"`.
-- @treturn string What it does: what a cell does, for any other kind.
local function wants(role)
    return WANTS[role] or WANTS.cell
end

--- What another network's core offers, in words.
--
-- @tparam[opt] table asks What it asked for: `carry` and `messages`.
-- @treturn string What it offers.
local function offers(asks)
    local parts = {}
    if asks and asks.carry then parts[#parts + 1] = "carry this network's phones" end
    if asks and asks.messages then parts[#parts + 1] = "exchange messages with this network's phones" end
    return #parts > 0 and table.concat(parts, " and ") or "make an agreement with this network"
end

--- Describe a computer which is waiting, or was let in: its ID, what it is, and its fingerprint.
--
-- @tparam table entry The computer, as the core's status has it.
-- @treturn string The description.
local function describe(entry)
    local role = ({ admin = "manager", network = "core of " .. tostring(entry.network or "?") })[entry.role] or entry.role
    return ("#%s %s, %s"):format(tostring(entry.id or "?"), role, entry.fingerprint)
end

--- When something happened, as a time of day.
--
-- @tparam number epoch The time, in milliseconds.
-- @treturn string The time, as hours and minutes.
local function since(epoch)
    return os.date("%H:%M", math.floor(epoch / 1000))
end

-- How the connection to another network's core is going, in words.
local STATES = {
    connecting = "connecting", waiting = "waiting to be allowed by its core", connected = "connected",
    lost = "can't reach its core", refused = "refused",
}

--- How the connection to another network's core is going, in words.
--
-- @tparam table network The agreement, as the core's status has it.
-- @treturn string How it's going.
local function how(network)
    if network.connected then return "connected" end
    if not network.state then return network.key and "waiting for its core to connect" or "not met yet" end
    local text = STATES[network.state] or tostring(network.state)
    if network.error then text = text .. ": " .. network.error end
    return text
end

--[[- An agreement with another network: who its core is, what the two networks do for each other, and how it's going.

@tparam table network The agreement, as the core's status has it.
@tparam table status The core's status.
@treturn { string... } Each line to say.
]]
local function network_lines(network, status)
    local lines = {}
    local function say(text) lines[#lines + 1] = text end
    local where = network.core and (" at " .. network.core) or ""
    say(("%s, core #%s%s: %s"):format(network.network, tostring(network.id or "?"), where, how(network)))
    if network.carry then
        say(("  Carries its phones%s"):format(network.carrying and (" (%d here)"):format(network.visitors) or ""))
    end
    if network.roam then
        say(("  This network's phones %s its cells%s"):format(
            network.roam == "home" and "treat as home" or "roam on", network.carried and (" (%d there)"):format(network.phones) or ""
        ))
    end
    if network.messages then
        local text = "  Messages between the networks' phones"
        if network.prefix then text = text .. (", its numbers starting %s"):format(network.prefix) end
        if (network.waiting or 0) > 0 then text = text .. (", %d waiting"):format(network.waiting) end
        say(text)
        if not status.number_prefix then say("  (This network needs a number prefix first: 'cellcore numbers')") end
    end
    if not network.carry and not network.roam and not network.messages then say("  Nothing agreed") end
    if network.fingerprint then say("  Its fingerprint: " .. network.fingerprint) end
    return lines
end

--- How the network is doing, in a few lines.
--
-- @tparam table status The core's status.
-- @treturn { string... } Each line to say, but for the computers waiting to be allowed.
local function status_lines(status)
    local lines = {}
    local function say(text) lines[#lines + 1] = text end
    say(("Core of %s, phones in %s%s"):format(
        status.network, status.prefix, status.number_prefix and ", numbers +" .. status.number_prefix or ""
    ))
    local cells = {}
    for _, cell in ipairs(status.cells) do cells[#cells + 1] = "#" .. cell.id end
    say(#cells > 0 and "Cells: " .. table.concat(cells, ", ") or "No cells connected.")
    local attached = 0
    for _, subscriber in ipairs(status.subscribers) do
        if subscriber.cell then attached = attached + 1 end
    end
    say(("Phones: %d attached, of %d subscribers"):format(attached, #status.subscribers))
    if status.messages > 0 then say(("Messages waiting: %d"):format(status.messages)) end
    if status.codes > 0 then say(("Activation codes not used yet: %d"):format(status.codes)) end
    local away, visiting = 0, 0
    for _, network in ipairs(status.networks or {}) do away, visiting = away + network.phones, visiting + network.visitors end
    if away > 0 then say(("Roaming on other networks: %d"):format(away)) end
    if visiting > 0 then say(("Other networks' phones here: %d"):format(visiting)) end
    return lines
end

--- Where a subscriber's phone is, in a few words.
--
-- @tparam table subscriber The subscriber, as the core's status has them.
-- @treturn string Where it is: `"-"` if it's nowhere.
local function where_is(subscriber)
    local where = "-"
    if subscriber.barred then
        where = "barred"
    elseif subscriber.cell then
        where = ("cell #%s%s, %s"):format(
            common.cell_label(subscriber.cell), subscriber.roaming and " of " .. subscriber.roaming or "", subscriber.address
        )
    end
    if subscriber.may_roam == false then where = where .. " (no roaming)" end
    -- A router, with a network behind it.
    if subscriber.range or subscriber.subnet then where = where .. ", routes " .. (subscriber.range or subscriber.subnet) end
    return where
end

--[[- What kind of subscriber someone is, and what that means, in words: a phone; a router with a range of the
network's addresses behind it; or a site with a subnet of its own.

@tparam table subscriber The subscriber, as the core's status has them (or as it answers when one is changed).
@treturn { string... } Each line to say.
]]
local function routed_lines(subscriber)
    local id = tostring(subscriber.id)
    if subscriber.range then
        return {
            ("%s is a router, with the range %s of this network's addresses behind it."):format(id, subscriber.range),
            "The core sends that range to its phone, which has an address of its own besides. On the router, give an "
                .. "interface an address in the range, and turn forwarding on: computers behind it use the rest.",
        }
    elseif subscriber.subnet then
        return {
            ("%s is a site, with its own network %s behind it."):format(id, subscriber.subnet),
            "The core sends that network to its phone, and tells routers which listen to it (RIP) where it is: others "
                .. "need a route to it through the core. On the site's router, turn forwarding on.",
        }
    end
    return { ("%s is a phone: it has one address, and nothing behind it."):format(id) }
end

--[[- Set this computer up as a network's core, and start it: afresh, if it was one already.

@tparam string network The network's name.
@tparam string prefix The network phones' addresses are in, such as `"10.64.0.0/16"`.
@tparam[opt] string numbers The network's number prefix, which other networks' phones reach its phones by.
@treturn[1] table The core's settings, as they're kept.
@treturn[2] nil If it couldn't be.
@treturn[2] string Why not.
]]
local function setup(network, prefix, numbers)
    if not network:match("^[%w%-]+$") or #network > 32 then
        return nil, "Network names are letters, digits and dashes, up to 32 of them."
    end
    local addr, length = require("cc.net.address").parse(prefix)
    if not addr or not length or length > 30 then
        return nil, "Expected the network for phones' addresses, such as 10.64.0.0/16."
    end
    if numbers and (#numbers > 8 or not numbers:match("^%d+$")) then
        return nil, "Number prefixes are 1 to 8 digits, such as 555."
    end
    local config = files.read_table(CONFIG)
    config.network, config.prefix, config.enabled = network, prefix, nil
    if numbers then config.number_prefix = numbers end
    -- Start again with the new settings.
    net.cell.stopCore()
    files.write_table(CONFIG, config)
    local ok, err = net.cell.startCore()
    if not ok then return nil, err end
    return config
end

--------------------------------------------------------------------------------
-- The menu
--------------------------------------------------------------------------------

-- Lines of text as a list's items, broken to fit the screen: there to be read, and choosing one does nothing.
local function text_items(items, lines, fg)
    local w = term.getSize()
    for _, line in ipairs(lines) do
        for _, part in ipairs(menu.wrapped(line, w)) do items[#items + 1] = { text = part, fg = fg } end
    end
    return items
end

local function on_off(value) return value and "on" or "off" end

--[[- Show a core's menu, until the user leaves it.

@tparam { target? = string, remote? = boolean, name = string } options The core to manage, if it isn't this
computer's (as `cellcore remote` takes it); and what `cellcore` is called, to say which commands to use.
]]
local function run(options)
    local target, remote = options.target, options.remote == true
    local manager, status, problem
    -- What the last thing done did (or why it couldn't be done), shown beneath the lists until something else is done.
    local said, said_bad = nil, false
    local function say(text, bad) said, said_bad = text, bad or false end
    local function note()
        if said then return said, said_bad and c(colours.red, colours.lightGrey) or colours.lightGrey end
    end

    local function hang_up()
        if manager then manager:close() end
        manager = nil
    end

    -- Connect to the core. While it hasn't allowed this computer, say how it's allowed, and wait if `wait`.
    local function connect(wait)
        hang_up()
        local err
        -- Connecting again behind the user's back may take a while: what they do meanwhile is kept. (Not while the
        -- screen says to wait to be allowed: keys pressed then aren't meant for what comes after.)
        local function manage(...)
            if wait then return net.cell.manage(...) end
            return menu.wait_for(net.cell.manage, ...)
        end
        manager, err = manage(target, function(fingerprint)
            if not wait then return false end
            menu.clear()
            menu.draw_title("Waiting to be allowed")
            local w, h = term.getSize()
            local text = ("The core hasn't allowed this computer to manage it yet. On the core, allow computer #%d "
                .. "(in its menu, or with 'cellcore allow %d'), and check it shows this fingerprint:\n\n%s\n\n"
                .. "Waiting... Hold Ctrl+T to give up."):format(os.getComputerID(), os.getComputerID(), fingerprint)
            for i, line in ipairs(menu.wrapped(text, w)) do
                if i + 2 <= h then menu.put(1, i + 2, line) end
            end
        end)
        problem = not manager and tostring(err) or nil
        return manager ~= nil
    end

    -- Ask the core something. What the user does while it answers is kept for afterwards.
    local function request(message)
        if not manager then return nil, problem or "Not connected to the core" end
        return menu.wait_for(manager.request, manager, message)
    end

    -- Ask the core how the network is doing, unless it was just asked (`now`, after something changed: the screen
    -- which is shown again then needn't ask once more). A core which doesn't answer (it was started afresh, say) is
    -- connected to again.
    local fresh, failures = false, 0
    local function refresh(now)
        if fresh and not now then
            fresh = false
            return status
        end
        fresh = now == true
        local reply, err = request({ op = "status" })
        if not reply then
            -- At once the first time (and when asked to), and then only now and again.
            failures = failures + 1
            if now or failures == 1 or failures % RECONNECT_EVERY == 0 then
                if connect(false) then reply, err = request({ op = "status" }) else err = problem or err end
            end
        end
        if reply then failures = 0 end
        -- What was said about the last thing done is old news once the core is lost: why it's lost is said instead.
        if not reply and status and not now then said = nil end
        status, problem = reply, not reply and tostring(err) or nil
        return status
    end

    -- Ask the core to do something, and say what it did (as `done` words it, given the core's answer), or why not.
    local function ask(message, done)
        local reply, err = request(message)
        if reply then
            say(type(done) == "function" and done(reply) or done)
        else
            say(tostring(err), true)
        end
        refresh(true)
        return reply
    end

    local function title_of(text)
        return function() return text, status and status.network or nil end
    end

    ----------------------------------------------------------------------------
    -- Computers: those waiting to be let in, and those which were (or were refused)
    ----------------------------------------------------------------------------

    local function allowed_text(reply)
        if reply.role == "network" then
            local text = ("Allowed the core of %s (#%s)."):format(tostring(reply.network), tostring(reply.id or "?"))
            if reply.roam then text = text .. " This network's phones are told they may use its cells when they next attach." end
            if reply.messages then text = text .. " Its phones and this network's can send each other messages." end
            return text
        end
        return ("Allowed #%s to %s, as %s."):format(tostring(reply.id or "?"), wants(reply.role), tostring(reply.label))
    end

    local function refused_text(reply)
        local text = ("Refused #%s."):format(tostring(reply.id or "?"))
        if reply.network then text = text .. (" The agreement with %s does nothing from now on."):format(reply.network) end
        return text
    end

    -- A computer which waits to be allowed: what it wants, and its fingerprint, to check before allowing it.
    local function waiting_screen(key)
        menu.list_screen {
            title = title_of("Allow a computer"),
            items = function()
                local entry
                for _, each in ipairs(refresh() and status.waiting or {}) do
                    if each.key == key then entry = each end
                end
                if not entry then return text_items({}, { "It's no longer waiting." }, colours.lightGrey) end
                local items = text_items({}, {
                    ("#%s%s wants to %s."):format(
                        tostring(entry.id or "?"), entry.network and ", the core of " .. entry.network .. "," or "",
                        entry.role == "network" and offers(entry.asks) or wants(entry.role)
                    ),
                    "Check that it shows this fingerprint:",
                    "  " .. tostring(entry.fingerprint),
                })
                items[#items + 1] = { text = "Allow it", id = "allow" }
                items[#items + 1] = { text = "Allow it, with a label...", id = "label" }
                items[#items + 1] = { text = "Refuse it", id = "deny" }
                return items
            end,
            choose = function(item)
                if item.id == "allow" then
                    ask({ op = "allow", key = key }, allowed_text)
                elseif item.id == "label" then
                    local label = menu.input_screen {
                        title = "Allow a computer", label = "Label:", max = 40,
                        note = "What to call the computer in the core's lists: where it is, say.",
                    }
                    if not label then return nil end
                    ask({ op = "allow", key = key, label = label ~= "" and label or nil }, allowed_text)
                elseif item.id == "deny" then
                    ask({ op = "deny", key = key }, refused_text)
                else
                    return nil
                end
                return "back"
            end,
            hint = { "Enter: choose", "Q: back" },
            refresh = REFRESH,
        }
    end

    -- A computer which was allowed, or refused.
    local function computer_screen(key)
        menu.list_screen {
            title = title_of("Computer"),
            items = function()
                local entry
                for _, each in ipairs(refresh() and status.allowed or {}) do
                    if each.key == key then entry = each end
                end
                if not entry then return text_items({}, { "It's no longer in the list." }, colours.lightGrey) end
                local items = text_items({}, {
                    ("#%s, %s"):format(tostring(entry.id or "?"), tostring(entry.label)),
                    entry.role == "denied" and "Refused." or ("Allowed to %s."):format(wants(entry.role)),
                    "Fingerprint:",
                    "  " .. tostring(entry.fingerprint),
                })
                if entry.role == "denied" then
                    items[#items + 1] = { text = "Allow it again", id = "allow" }
                else
                    items[#items + 1] = { text = "Refuse it", id = "deny" }
                end
                return items
            end,
            choose = function(item)
                if item.id == "allow" then
                    ask({ op = "allow", key = key }, allowed_text)
                elseif item.id == "deny" then
                    if not menu.confirm_screen("Refuse a computer",
                        "It's cut off now, and refused when it connects again, until it's allowed again.", "Refuse") then
                        return nil
                    end
                    ask({ op = "deny", key = key }, refused_text)
                else
                    return nil
                end
                return "back"
            end,
            hint = { "Enter: choose", "Q: back" },
            refresh = REFRESH,
        }
    end

    local ROLES = { cell = "cell", admin = "manager", denied = "refused", network = "core" }

    local function computers_screen()
        menu.list_screen {
            title = title_of("Computers"),
            items = function()
                local items = {}
                if not refresh() then return items end
                for _, entry in ipairs(status.waiting) do
                    items[#items + 1] = {
                        text = ("#%s %s"):format(tostring(entry.id or "?"), entry.network or ROLES[entry.role] or tostring(entry.role)),
                        tail = { { "waiting", c(colours.yellow, colours.white) } }, id = "w" .. entry.key, waiting = entry.key,
                    }
                end
                for _, entry in ipairs(status.allowed) do
                    items[#items + 1] = {
                        text = ("#%s %s"):format(tostring(entry.id or "?"), tostring(entry.label)),
                        tail = { { ROLES[entry.role] or tostring(entry.role), entry.role == "denied" and c(colours.red, colours.lightGrey) or colours.lightGrey } },
                        id = "a" .. entry.key, allowed = entry.key,
                    }
                end
                return items
            end,
            choose = function(item)
                if item.waiting then waiting_screen(item.waiting) else computer_screen(item.allowed) end
            end,
            empty = "No computer is waiting, and none was allowed.",
            note = function()
                if said then return note() end
                return "A cell waits here once 'celld add <this core>' runs on it; a computer to manage the core from, once "
                    .. "'cellcore remote <this core>' does."
            end,
            hint = { "Enter: open", "Q: back" },
            refresh = REFRESH,
        }
    end

    ----------------------------------------------------------------------------
    -- Cells
    ----------------------------------------------------------------------------

    local function cell_lines(cell)
        local lines = { ("#%d from %s, area %s, since %s"):format(cell.id, cell.address, tostring(cell.area or 0), since(cell.since)) }
        -- A cell on each carrier its computer is on.
        for _, each in ipairs(cell.carriers or { cell }) do
            if each.carrier then lines[#lines + 1] = ("  on %s, reached on channel %d"):format(each.carrier, each.ul) end
        end
        -- A relay: its backhaul goes through other cells.
        if cell.path and #cell.path > 0 then
            local through = {}
            for i, relay in ipairs(cell.path) do through[i] = "#" .. relay end
            lines[#lines + 1] = "  a relay, through cell " .. table.concat(through, ", ")
        end
        return lines
    end

    local function cell_screen(id)
        menu.list_screen {
            title = title_of("Cell #" .. id),
            items = function()
                local cell
                for _, each in ipairs(refresh() and status.cells or {}) do
                    if each.id == id then cell = each end
                end
                if not cell then return text_items({}, { "It's no longer connected." }, colours.lightGrey) end
                local items = text_items({}, cell_lines(cell))
                local phones = 0
                for _, subscriber in ipairs(status.subscribers) do
                    if subscriber.cell and not subscriber.roaming and common.site_of(subscriber.cell) == id then phones = phones + 1 end
                end
                text_items(items, { ("  phones attached: %d"):format(phones) })
                items[#items + 1] = { text = "Refuse this cell", id = "deny", key = cell.key }
                return items
            end,
            choose = function(item)
                if item.id ~= "deny" then return nil end
                if not menu.confirm_screen("Refuse cell #" .. id,
                    "It's cut off now, and its phones lose service. It's refused when it connects again, until it's allowed again.",
                    "Refuse") then
                    return nil
                end
                ask({ op = "deny", key = item.key }, refused_text)
                return "back"
            end,
            hint = { "Enter: choose", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function cells_screen()
        menu.list_screen {
            title = title_of("Cells"),
            items = function()
                local items = {}
                for _, cell in ipairs(refresh() and status.cells or {}) do
                    local carriers = {}
                    for i, each in ipairs(cell.carriers or { cell }) do carriers[i] = tostring(each.carrier) end
                    items[#items + 1] = {
                        text = ("#%d %s"):format(cell.id, tostring(cell.address)),
                        tail = { { table.concat(carriers, " "), colours.lightGrey } }, id = cell.id,
                    }
                end
                -- Those which were let in, but aren't on the air until whoever sets them up has chosen their bands.
                for _, cell in ipairs(status and status.standby or {}) do
                    items[#items + 1] = {
                        text = ("#%d %s"):format(cell.id, tostring(cell.address)), fg = colours.lightGrey,
                        tail = { { "choosing its bands", c(colours.yellow, colours.lightGrey) } }, id = "s" .. cell.id,
                    }
                end
                return items
            end,
            choose = function(item)
                if type(item.id) == "number" then cell_screen(item.id) end
            end,
            empty = "No cells connected.",
            note = function()
                if said then return note() end
                return "A cell joins with 'celld add <this core>' on its computer, and waits under Computers to be allowed."
            end,
            hint = { "Enter: open", "Q: back" },
            refresh = REFRESH,
        }
    end

    ----------------------------------------------------------------------------
    -- Subscribers
    ----------------------------------------------------------------------------

    local function add_subscriber()
        local id = menu.input_screen {
            title = "Add a subscriber", label = "ID:", max = 40,
            note = "What to call the subscriber, such as " .. (status and status.network or "ACME") .. "-0042.",
            check = function(text) return text == "" and "Enter an ID for the subscriber." or nil end,
        }
        if not id then return end
        local code
        local number = menu.input_screen {
            title = "Add a subscriber", label = "Number:", max = 20,
            note = "The phone number of " .. id .. ".",
            check = function(text)
                if text == "" then return "Enter a number." end
                local reply, err = request({ op = "add", id = id, number = text })
                if not reply then return tostring(err) end
                code = reply.code
                return nil
            end,
        }
        if not number then return end
        refresh(true)
        menu.message_screen("Activation code", ("For %s (number %s), for a day:\n\n%s\n\nOn the phone, run 'cell activate %s <code>'."):format(
            id, number, tostring(code), status and status.network or "<network>"
        ))
    end

    -- What kind of subscriber someone is: a phone, a router with a range of our addresses, or a site with its own.
    local function type_screen(id, subscriber)
        local function network_for(kind, title, note)
            menu.input_screen {
                title = title, label = "Network:", max = 18, value = subscriber[kind] or "", note = note,
                check = function(text)
                    if text == "" then return "Enter a network, such as 10.64.5.0/28." end
                    local reply, err = request({ op = "set", subscriber = id, [kind] = text })
                    if not reply then return tostring(err) end
                    say(table.concat(routed_lines(reply), " "))
                    return nil
                end,
            }
        end
        menu.list_screen {
            title = title_of("Type of " .. tostring(id)),
            items = function()
                local function now(is) return is and { { "now", colours.lightGrey } } or nil end
                return {
                    { text = "Phone: one address", id = "phone", tail = now(not subscriber.range and not subscriber.subnet) },
                    { text = "Router: a range of our addresses...", id = "range", tail = now(subscriber.range ~= nil) },
                    { text = "Site: a network of its own...", id = "subnet", tail = now(subscriber.subnet ~= nil) },
                }
            end,
            choose = function(item)
                if item.id == "phone" then
                    if subscriber.range or subscriber.subnet then
                        ask({ op = "set", subscriber = id, [subscriber.range and "range" or "subnet"] = false }, function(reply)
                            return table.concat(routed_lines(reply), " ")
                        end)
                    end
                elseif item.id == "range" then
                    network_for("range", "Range for " .. tostring(id),
                        ("Part of this network's addresses (%s), such as a /28 of them, which the core sends to the "
                            .. "subscriber's phone: for a small site, whose router hands them out behind it."):format(
                            status and status.prefix or "its prefix"
                        ))
                else
                    network_for("subnet", "Network of " .. tostring(id),
                        "A network which isn't this network's own, such as 192.168.5.0/24, which the core sends to the "
                            .. "subscriber's phone: for a site with addresses of its own, bridged to the rest through here.")
                end
                refresh(true)
                return "back"
            end,
            note = function()
                return "Changing this cuts the subscriber's phone off for a moment: it attaches again, and hears what it is."
            end,
            hint = { "Enter: choose", "Q: back" },
        }
    end

    local function subscriber_screen(id)
        local function find()
            for _, each in ipairs(refresh() and status.subscribers or {}) do
                if each.id == id then return each end
            end
        end
        menu.list_screen {
            title = title_of(tostring(id)),
            items = function()
                local subscriber = find()
                if not subscriber then return text_items({}, { "They're no longer a subscriber." }, colours.lightGrey) end
                local items = text_items({}, {
                    ("%s, number %s"):format(tostring(subscriber.id), tostring(subscriber.number)),
                    "Phone: " .. where_is(subscriber),
                })
                if subscriber.fingerprint then text_items(items, { "SIM: " .. subscriber.fingerprint }) end
                items[#items + 1] = {
                    text = "Type", id = "type",
                    tail = { {
                        subscriber.range and "router, " .. subscriber.range or subscriber.subnet and "site, " .. subscriber.subnet
                            or "phone", colours.lightGrey,
                    }, },
                }
                items[#items + 1] = {
                    text = "Barred", tail = { { subscriber.barred and "yes" or "no", colours.lightGrey } }, id = "barred",
                    value = not subscriber.barred,
                }
                items[#items + 1] = {
                    text = "May use other networks", tail = { { subscriber.may_roam and "yes" or "no", colours.lightGrey } },
                    id = "roaming", value = not subscriber.may_roam,
                }
                items[#items + 1] = { text = "Remove", id = "remove" }
                return items
            end,
            choose = function(item)
                if item.id == "type" then
                    type_screen(id, find() or {})
                elseif item.id == "barred" then
                    ask({ op = "set", subscriber = id, barred = item.value }, function(reply)
                        return reply.barred and ("%s is barred: their phone is cut off, and refused."):format(tostring(reply.id))
                            or ("%s is no longer barred."):format(tostring(reply.id))
                    end)
                elseif item.id == "roaming" then
                    ask({ op = "set", subscriber = id, roaming = item.value }, function(reply)
                        return reply.roaming and ("%s may use other networks' cells."):format(tostring(reply.id))
                            or ("%s may only use this network's cells."):format(tostring(reply.id))
                    end)
                elseif item.id == "remove" then
                    if not menu.confirm_screen("Remove " .. tostring(id), "Their phone can't attach any more.", "Remove") then
                        return nil
                    end
                    ask({ op = "remove", subscriber = id }, ("Removed %s."):format(tostring(id)))
                    return "back"
                end
                return nil
            end,
            note = note,
            hint = { "Enter: change", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function subscribers_screen()
        menu.list_screen {
            title = title_of("Subscribers"),
            items = function()
                local items = {}
                for _, subscriber in ipairs(refresh() and status.subscribers or {}) do
                    items[#items + 1] = {
                        text = ("%s  %s"):format(tostring(subscriber.id), tostring(subscriber.number)),
                        tail = { { where_is(subscriber), subscriber.cell and c(colours.lime, colours.white) or colours.lightGrey } },
                        id = "s" .. tostring(subscriber.id), subscriber = subscriber.id,
                    }
                end
                items[#items + 1] = { text = "Add a subscriber...", id = "\0add" }
                return items
            end,
            choose = function(item)
                if item.subscriber ~= nil then subscriber_screen(item.subscriber) else add_subscriber() end
            end,
            note = note,
            hint = { "Enter: open", "Q: back" },
            refresh = REFRESH,
        }
    end

    ----------------------------------------------------------------------------
    -- Other networks
    ----------------------------------------------------------------------------

    local function network_screen(name)
        local function find()
            for _, each in ipairs(refresh() and status.networks or {}) do
                if each.network == name then return each end
            end
        end
        -- Change the agreement, and say what its core must do, if it hasn't met ours yet.
        local function change(changes)
            changes.op, changes.network = "network", name
            ask(changes, function(reply)
                if reply.forgotten then return ("Forgot the agreement with %s."):format(name) end
                if reply.key then return "Changed the agreement." end
                return ("Changed. Its core must allow this one, unless it's this core which waits for it: there, allow "
                    .. "computer #%s, and check it shows the fingerprint %s"):format(
                    tostring(reply.our_id or "?"), tostring(reply.our_fingerprint)
                )
            end)
        end
        menu.list_screen {
            title = title_of(name),
            items = function()
                local network = find() or { network = name }
                local items = {}
                if network.id or network.core or network.carry or network.roam or network.messages then
                    text_items(items, network_lines(network, status or {}))
                else
                    text_items(items, { "No agreement yet: turn on what the two networks do for each other, and say where its core is, or have its core connect to this one." }, colours.lightGrey)
                end
                local function switch(text, id, value, change_to)
                    items[#items + 1] = { text = text, tail = { { on_off(value), colours.lightGrey } }, id = id, changes = change_to }
                end
                switch("Carry its phones", "carry", network.carry, { carry = not network.carry })
                switch("Our phones use its cells", "roam", network.roam, { roam = not network.roam and "partner" or false })
                if network.roam then
                    switch("...as if they were home", "home", network.roam == "home", { roam = network.roam == "home" and "partner" or "home" })
                end
                switch("Exchange messages", "messages", network.messages, { messages = not network.messages })
                items[#items + 1] = { text = "Its core", tail = { { network.core or "none", colours.lightGrey } }, id = "core" }
                items[#items + 1] = { text = "Forget this agreement", id = "forget" }
                return items
            end,
            choose = function(item)
                if item.changes then
                    change(item.changes)
                elseif item.id == "core" then
                    local network = find() or {}
                    menu.input_screen {
                        title = "Core of " .. name, label = "Core:", max = 255, value = network.core or "",
                        note = "The name or address this core connects to the other network's core at. Empty: this core "
                            .. "waits for the other to connect.",
                        check = function(text)
                            local reply, err = request({ op = "network", network = name, core = text ~= "" and text or false })
                            if not reply then return tostring(err) end
                            say("Changed the agreement.")
                            return nil
                        end,
                    }
                    refresh(true)
                elseif item.id == "forget" then
                    if not menu.confirm_screen("Forget " .. name,
                        "The two networks do nothing for each other any more: its phones here, and this network's there, lose service.",
                        "Forget") then
                        return nil
                    end
                    change({ forget = true })
                    return "back"
                end
                return nil
            end,
            note = note,
            hint = { "Enter: change", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function networks_screen()
        menu.list_screen {
            title = title_of("Other networks"),
            items = function()
                local items = {}
                for _, network in ipairs(refresh() and status.networks or {}) do
                    local going = how(network)
                    items[#items + 1] = {
                        text = tostring(network.network),
                        tail = { { going, network.connected and c(colours.lime, colours.white) or colours.lightGrey } },
                        id = "n" .. tostring(network.network), network = network.network,
                    }
                end
                items[#items + 1] = { text = "Add a network...", id = "\0add" }
                return items
            end,
            choose = function(item)
                if item.network then return network_screen(item.network) end
                local name = menu.input_screen {
                    title = "Add a network", label = "Network:", max = 32,
                    note = "The other network's name. An agreement says what the two networks do for each other: carry "
                        .. "each other's phones, and exchange messages.",
                    check = function(text)
                        if not common.is_network(text) then return "Network names are letters, digits and dashes, up to 32 of them." end
                        if status and text == status.network then return "That's this network." end
                        return nil
                    end,
                }
                if name then network_screen(name) end
            end,
            note = note,
            hint = { "Enter: open", "Q: back" },
            refresh = REFRESH,
        }
    end

    ----------------------------------------------------------------------------
    -- The network's own settings, and its log
    ----------------------------------------------------------------------------

    local function radio_screen()
        menu.list_screen {
            title = title_of("Network settings"),
            items = function()
                if not refresh() then return {} end
                local picked = status.spectrum_picked and " (picked)" or ""
                return {
                    { text = "Carriers", tail = { { table.concat(status.spectrum or {}, " ") .. picked, colours.lightGrey } }, id = "spectrum" },
                    {
                        text = "System information", id = "beacon",
                        tail = { { ("every %s seconds"):format(tostring(status.interval)), colours.lightGrey } },
                    },
                    { text = "Number prefix", tail = { { status.number_prefix or "none", colours.lightGrey } }, id = "numbers" },
                }
            end,
            choose = function(item)
                if not status then return nil end
                if item.id == "spectrum" then
                    menu.input_screen {
                        title = "Carriers", label = "Carriers:",
                        value = status.spectrum_picked and "" or table.concat(status.spectrum or {}, " "),
                        note = "The carriers this network's cells use: up to 8, such as b20/1 b3/2. Cells hear of them at "
                            .. "once, and move when they next connect. Empty: one of band 20's, picked from the network's name.",
                        check = function(text)
                            local carriers = {}
                            for word in text:gmatch("%S+") do carriers[#carriers + 1] = word end
                            local reply, err = request({ op = "spectrum", carriers = carriers })
                            if not reply then return tostring(err) end
                            say("Carriers: " .. table.concat(reply.carriers, ", ") .. ". Cells move to them when they next connect.")
                            return nil
                        end,
                    }
                elseif item.id == "beacon" then
                    menu.input_screen {
                        title = "System information", label = "Seconds:", value = tostring(status.interval or ""),
                        note = ("How often this network's cells send system information: every %g to %g seconds. Phones find "
                            .. "cells sooner with less, and the air is quieter with more."):format(common.MIN_INTERVAL, common.MAX_INTERVAL),
                        check = function(text)
                            local interval = tonumber(text)
                            if not interval then return "Expected a number of seconds." end
                            local reply, err = request({ op = "beacon", interval = interval })
                            if not reply then return tostring(err) end
                            say(("Cells send system information every %s seconds."):format(tostring(reply.interval)))
                            return nil
                        end,
                    }
                elseif item.id == "numbers" then
                    menu.input_screen {
                        title = "Number prefix", label = "Prefix:", value = status.number_prefix or "", max = 8,
                        note = "The digits other networks' phones put before this network's numbers to reach its phones, such as 555.",
                        check = function(text)
                            local reply, err = request({ op = "numbers", prefix = text })
                            if not reply then return tostring(err) end
                            say(("Other networks' phones reach this network's at %s<number>."):format(text))
                            return nil
                        end,
                    }
                end
                refresh(true)
                return nil
            end,
            note = note,
            hint = { "Enter: change", "Q: back" },
            refresh = REFRESH,
        }
    end

    local function log_screen()
        local lines, last = {}, 0
        menu.list_screen {
            title = title_of("Log"),
            items = function()
                local reply = request({ op = "log", after = last })
                if reply then
                    for _, line in ipairs(reply.lines) do
                        lines[#lines + 1] = ("%s %s"):format(since(line.time), tostring(line.text))
                    end
                    while #lines > MAX_LOG do table.remove(lines, 1) end
                    last = reply.last
                end
                return text_items({}, lines)
            end,
            choose = function() end,
            empty = "Nothing has happened yet.",
            hint = { "Q: back" },
            refresh = 1,
            follow = true,
        }
    end

    local function status_screen()
        menu.list_screen {
            title = title_of("Status"),
            items = function()
                if not refresh() then return text_items({}, { tostring(problem) }, c(colours.red, colours.lightGrey)) end
                local items = text_items({}, status_lines(status))
                if #status.waiting > 0 then
                    text_items(items, { "Waiting to be allowed:" })
                    for _, entry in ipairs(status.waiting) do text_items(items, { "  " .. describe(entry) }) end
                end
                return items
            end,
            choose = function() end,
            hint = { "Q: back" },
            refresh = REFRESH,
        }
    end

    ----------------------------------------------------------------------------
    -- Setting a core up, and the menu itself
    ----------------------------------------------------------------------------

    -- Ask for what a new network needs, and set this computer up as its core. Returns whether it was.
    local function setup_screens()
        local network = menu.input_screen {
            title = "Set up a network", label = "Name:", max = 32,
            note = "This computer isn't a network's core yet. What is the network called? Letters, digits and dashes.",
            check = function(text)
                if not text:match("^[%w%-]+$") then return "Network names are letters, digits and dashes, up to 32 of them." end
                return nil
            end,
        }
        if not network then return false end
        local done = false
        local prefix = menu.input_screen {
            title = "Set up " .. network, label = "Addresses:", value = "10.64.0.0/16", max = 18,
            note = "The network its phones' addresses are in. Every other computer needs a route to it, through this one.",
            check = function(text)
                local config, err = setup(network, text)
                if not config then return tostring(err) end
                done = true
                return nil
            end,
        }
        if not prefix or not done then return false end
        say(("%s is set up and running, giving phones addresses in %s. Cells join with 'celld add <this computer's address>', and wait here to be allowed."):format(network, prefix))
        return true
    end

    -- Without a core to manage: say why, and offer what may help.
    local function no_core_screen()
        local configured = remote or fs.exists(CONFIG)
        return menu.list_screen {
            title = function() return remote and "Core " .. tostring(target) or "Core" end,
            items = function()
                local items = {}
                if not configured then
                    items[#items + 1] = { text = "Set up a network...", id = "setup" }
                    items[#items + 1] = { text = "Manage another computer's core...", id = "remote" }
                else
                    if not remote then items[#items + 1] = { text = "Start the core", id = "start" } end
                    items[#items + 1] = { text = "Try again", id = "again" }
                end
                return items
            end,
            choose = function(item)
                if item.id == "setup" then
                    if not setup_screens() then return nil end
                elseif item.id == "remote" then
                    local core = menu.input_screen {
                        title = "Manage a core", label = "Core:", max = 255,
                        note = "The name or address of the core. It must allow this computer, the first time.",
                        check = function(text) return text == "" and "Enter the core's name or address." or nil end,
                    }
                    if not core then return nil end
                    target, remote, configured = core, true, true
                elseif item.id == "start" then
                    local ok, err = net.cell.startCore()
                    if not ok then
                        say(tostring(err), true)
                        return nil
                    end
                    say("The core is running, and starts with this computer.")
                end
                if connect(true) and refresh(true) then return "connected" end
                say(tostring(problem), true)
                return nil
            end,
            note = function()
                if said then return note() end
                if not configured then return "This computer isn't a network's core." end
                if not remote and problem == "Connection refused" then return "The core isn't running." end
                return "Cannot manage the core: " .. tostring(problem), c(colours.red, colours.lightGrey)
            end,
            hint = { "Enter: choose", "Q: quit" },
            back = "quit",
        }
    end

    local function home_screen()
        return menu.list_screen {
            title = function()
                if not status then return "Core", "not connected" end
                return "Core of " .. tostring(status.network), remote and tostring(target) or status.prefix
            end,
            items = function()
                if not refresh() then
                    -- Choosing it tries at once: and when that doesn't work either, what else may be done is shown.
                    local function again()
                        if connect(false) and refresh(true) then return nil end
                        return "lost"
                    end
                    return { { text = "Connect again", id = "again", open = again } }
                end
                local attached = 0
                for _, subscriber in ipairs(status.subscribers) do
                    if subscriber.cell then attached = attached + 1 end
                end
                local waiting = #status.waiting
                local function grey(text) return { { text, colours.lightGrey } } end
                return {
                    { text = "Status", id = "status", open = status_screen },
                    {
                        text = "Computers", id = "computers", open = computers_screen,
                        tail = waiting > 0 and { { waiting .. " waiting", c(colours.yellow, colours.white) } }
                            or grey(tostring(#status.allowed)),
                    },
                    { text = "Cells", tail = grey(tostring(#status.cells)), id = "cells", open = cells_screen },
                    {
                        text = "Subscribers", tail = grey(("%d of %d attached"):format(attached, #status.subscribers)),
                        id = "subscribers", open = subscribers_screen,
                    },
                    { text = "Other networks", tail = grey(tostring(#(status.networks or {}))), id = "networks", open = networks_screen },
                    { text = "Network settings", id = "radio", open = radio_screen },
                    { text = "Log", id = "log", open = log_screen },
                    {
                        text = "Restart the core", id = "restart",
                        open = function()
                            if not menu.confirm_screen("Restart the core",
                                "The core starts afresh. Cells join again by themselves, and phones attach again, with new addresses.",
                                "Restart") then
                                return
                            end
                            ask({ op = "restart" }, "Starting the core afresh.")
                        end,
                    },
                    {
                        text = "Stop the core", id = "stop",
                        open = function()
                            if not menu.confirm_screen("Stop the core",
                                "Every phone loses service. The core starts again on its own computer: from this menu, or with 'cellcore start'.",
                                "Stop") then
                                return
                            end
                            local reply, err = request({ op = "stop" })
                            if not reply then
                                say(tostring(err), true)
                                return
                            end
                            hang_up()
                            status, problem = nil, "Connection refused"
                            say("Stopped the core.")
                            return "lost"
                        end,
                    },
                }
            end,
            choose = function(item) return item.open() end,
            note = function()
                if said then return note() end
                if problem then return tostring(problem), c(colours.red, colours.lightGrey) end
            end,
            hint = { "Enter: open", "Q: quit" },
            refresh = REFRESH,
            back = "quit",
        }
    end

    -- The menu, while there's a core to manage; and otherwise what may get one.
    local ok, err = pcall(function()
        if remote or fs.exists(CONFIG) then
            if connect(true) then refresh(true) end
        end
        while true do
            local left
            if manager and status then left = home_screen() else left = no_core_screen() end
            if left == "quit" then break end
            -- Lost the core, or found one: look again.
            if left == "lost" and manager then
                if not refresh(true) then hang_up() end
            end
        end
    end)
    hang_up()
    menu.clear()
    term.setCursorPos(1, 1)
    if not ok and err ~= "Terminated" then error(err, 0) end
end

return {
    wants = wants,
    offers = offers,
    describe = describe,
    since = since,
    how = how,
    network_lines = network_lines,
    status_lines = status_lines,
    where_is = where_is,
    routed_lines = routed_lines,
    setup = setup,
    run = run,
}
