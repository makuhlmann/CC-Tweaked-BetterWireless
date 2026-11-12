-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Set up, start and manage a cellular network's core. The core runs in the background; everything else talks to it
-- over the control port, on this computer or (with "remote") on another.

local CONFIG = "/.cell/config"

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " setup <network> <prefix> [numbers]")
    print(name .. " [status]")
    print(name .. " start|stop|restart")
    print(name .. " log")
    print(name .. " add <id> <number> [file]")
    print(name .. " subscribers")
    print(name .. " remove <id|number>")
    print(name .. " set <id|number> barred|roaming yes|no")
    print(name .. " cells")
    print(name .. " allow <computer> [label]")
    print(name .. " deny <computer>")
    print(name .. " networks")
    print(name .. " network <network>")
    print(name .. " network <network> carry|roaming|home|messages on|off")
    print(name .. " network <network> core <core>|none")
    print(name .. " network <network> forget")
    print(name .. " numbers <prefix>")
    print(name .. " remote <core> <command...>")
end

if not crypto or not enclave then
    printError("The core needs the crypto and enclave APIs, which are turned off on this server")
    return
end

local files = require "cc.internal.net.files"
local read_table, write_table = files.read_table, files.write_table

-- Commands which only work on the core's own computer.
local command = args[1] or "status"
if command == "setup" then
    if #args ~= 3 and #args ~= 4 then return usage() end
    local network, prefix, numbers = args[2], args[3], args[4]
    if not network:match("^[%w%-]+$") or #network > 32 then
        printError("Network names are letters, digits and dashes, up to 32 of them.")
        return
    end
    local addr, length = require("cc.net.address").parse(prefix)
    if not addr or not length or length > 30 then
        printError("Expected the network for phones' addresses, such as 10.64.0.0/16.")
        return
    end
    if numbers and (#numbers > 8 or not numbers:match("^%d+$")) then
        printError("Number prefixes are 1 to 8 digits, such as 555.")
        return
    end
    local config = read_table(CONFIG)
    config.network, config.prefix, config.enabled = network, prefix, nil
    if numbers then config.number_prefix = numbers end
    -- Start again with the new settings.
    net.cell.stopCore()
    write_table(CONFIG, config)
    local ok, err = net.cell.startCore()
    if not ok then
        printError(err)
        return
    end
    print(("%s is set up and running, giving phones addresses in %s."):format(network, prefix))
    if config.number_prefix then
        print(("Other networks' phones reach its phones at %s<number>, once they exchange messages."):format(config.number_prefix))
    end
    print("Cells join with 'celld <this computer's address>', and wait for you to allow them here.")
    return
elseif command == "start" then
    if #args ~= 1 then return usage() end
    local ok, err = net.cell.startCore()
    if not ok then
        printError(err)
        return
    end
    print("The core is running, and starts with this computer.")
    return
elseif command == "stop" then
    if #args ~= 1 then return usage() end
    net.cell.stopCore()
    print("Stopped the core. It starts again with 'cellcore start'.")
    return
end

-- Everything else is a request to a core: this computer's, or another's.
local target, remote = nil, false
if command == "remote" then
    if #args < 2 then return usage() end
    target, remote = args[2], true
    table.remove(args, 1)
    table.remove(args, 1)
    command = args[1] or "status"
    if command == "setup" or command == "start" then
        printError(("'%s' only works on the core itself."):format(command))
        return
    end
end

local known = {
    status = 1, log = 1, add = 1, subscribers = 1, remove = 1, set = 1, cells = 1, allow = 1, deny = 1, networks = 1,
    network = 1, numbers = 1, stop = 1, restart = 1,
    -- As older versions had them: they show or change agreements with other networks, as 'network' does.
    roaming = 1, carry = 1, uncarry = 1, partner = 1, peers = 1, peer = 1, unpeer = 1,
}
if not known[command] then return usage() end

local manager

-- Send a request, and wait for the reply.
local function request(message)
    local reply, err = manager:request(message)
    if not reply then error(err, 0) end
    return reply
end

local function connect()
    local err
    manager, err = net.cell.manage(target, function(fingerprint)
        print("The core hasn't allowed this computer to manage it yet. On the core, run:")
        print(("  cellcore allow %d"):format(os.getComputerID()))
        print("and check it shows this fingerprint:")
        print("  " .. fingerprint)
        print("Waiting... Press Ctrl+T to give up.")
    end)
    if manager then return end
    if not remote then
        if not fs.exists(CONFIG) then
            error("This computer isn't a network's core. Set one up with 'cellcore setup', or manage another with 'cellcore remote'.", 0)
        end
        if err == "Connection refused" then error("The core isn't running. Start it with 'cellcore start'.", 0) end
        error("Cannot manage the core: " .. tostring(err), 0)
    end
    error(("Cannot manage the core %s: %s"):format(target, tostring(err)), 0)
end

-- Find computers by what someone typed: an ID, the start of a fingerprint, a full key or a label.
local function find(entries, who)
    local digits = who:lower():gsub("%s", "")
    local hex = digits:match("^%x+$") and #digits >= 4
    local found, seen = {}, {}
    for _, entry in ipairs(entries) do
        local fingerprint = entry.fingerprint and entry.fingerprint:gsub(" ", "") or ""
        if not seen[entry.key] and (tostring(entry.id) == who or entry.key == digits or entry.label == who
            or (hex and fingerprint:sub(1, #digits) == digits)) then
            seen[entry.key] = true
            found[#found + 1] = entry
        end
    end
    return found
end

-- What each kind of computer does, as "wants to ..." and "allowed to ...".
local WANTS = { cell = "be a cell", admin = "manage the network" }

-- What another network's core offers, in words.
local function offers(asks)
    local parts = {}
    if asks and asks.carry then parts[#parts + 1] = "carry this network's phones" end
    if asks and asks.messages then parts[#parts + 1] = "exchange messages with this network's phones" end
    return #parts > 0 and table.concat(parts, " and ") or "make an agreement with this network"
end

local function describe(entry)
    local role = ({ admin = "manager", network = "core of " .. tostring(entry.network or "?") })[entry.role] or entry.role
    return ("#%s %s, %s"):format(tostring(entry.id or "?"), role, entry.fingerprint)
end

local function since(epoch)
    return os.date("%H:%M", math.floor(epoch / 1000))
end

local commands = {}

function commands.status()
    local status = request({ op = "status" })
    print(("Core of %s, phones in %s%s"):format(
        status.network, status.prefix, status.number_prefix and ", numbers +" .. status.number_prefix or ""
    ))
    local cells = {}
    for _, cell in ipairs(status.cells) do cells[#cells + 1] = "#" .. cell.id end
    print(#cells > 0 and "Cells: " .. table.concat(cells, ", ") or "No cells connected.")
    local attached = 0
    for _, subscriber in ipairs(status.subscribers) do
        if subscriber.cell then attached = attached + 1 end
    end
    print(("Phones: %d attached, of %d subscribers"):format(attached, #status.subscribers))
    if status.messages > 0 then print(("Messages waiting: %d"):format(status.messages)) end
    if status.codes > 0 then print(("Activation codes not used yet: %d"):format(status.codes)) end
    local away, visiting = 0, 0
    for _, network in ipairs(status.networks or {}) do away, visiting = away + network.phones, visiting + network.visitors end
    if away > 0 then print(("Roaming on other networks: %d"):format(away)) end
    if visiting > 0 then print(("Other networks' phones here: %d"):format(visiting)) end
    if #status.waiting > 0 then
        print("Waiting to be allowed:")
        for _, entry in ipairs(status.waiting) do print("  " .. describe(entry)) end
        print("Allow one with 'cellcore allow <ID>'.")
    end
end

function commands.cells()
    local status = request({ op = "status" })
    if #status.cells == 0 then
        print("No cells connected.")
    else
        print("Connected:")
        for _, cell in ipairs(status.cells) do
            print(("  #%d from %s, area %s, since %s"):format(cell.id, cell.address, tostring(cell.area or 0), since(cell.since)))
            -- A relay: its backhaul goes through other cells.
            if cell.path and #cell.path > 0 then
                local through = {}
                for i, relay in ipairs(cell.path) do through[i] = "#" .. relay end
                print("    a relay, through cell " .. table.concat(through, ", "))
            end
        end
    end
    local groups = { cell = {}, admin = {}, denied = {} }
    for _, entry in ipairs(status.allowed) do
        if groups[entry.role] then table.insert(groups[entry.role], entry) end
    end
    for _, group in ipairs {
        { "cell", "Allowed cells:" }, { "admin", "Allowed to manage the network:" }, { "denied", "Refused:" },
    } do
        local entries = groups[group[1]]
        if #entries > 0 then
            print(group[2])
            for _, entry in ipairs(entries) do
                print(("  #%s %s, %s"):format(tostring(entry.id or "?"), entry.label, entry.fingerprint))
            end
        end
    end
    if #status.waiting > 0 then
        print("Waiting to be allowed:")
        for _, entry in ipairs(status.waiting) do print("  " .. describe(entry)) end
    end
end

function commands.allow(who, label)
    if not who then return usage() end
    local status = request({ op = "status" })
    local digits = who:lower():gsub("%s", "")
    local target
    if #digits == 64 and digits:match("^%x+$") then
        target = { key = digits }
    else
        -- Computers waiting, and those refused before.
        local candidates = {}
        for _, entry in ipairs(status.waiting) do candidates[#candidates + 1] = entry end
        for _, entry in ipairs(status.allowed) do
            if entry.role == "denied" then candidates[#candidates + 1] = entry end
        end
        local found = find(candidates, who)
        if #found == 0 then
            error(("Nothing called %s is waiting. Start 'celld <core>' on the cell ('cellcore remote <core>' on a computer to manage this one from, or 'cellcore network <this network> core <this core>' on another network's core) first."):format(who), 0)
        elseif #found > 1 then
            print("More than one computer matches:")
            for _, entry in ipairs(found) do print("  " .. describe(entry)) end
            error("Allow one by the start of its fingerprint instead.", 0)
        end
        target = found[1]

        -- Unless they typed enough of the fingerprint, check it's the computer they think.
        if not (digits:match("^%x+$") and #digits >= 8) then
            print(("#%s%s wants to %s. Its fingerprint is"):format(
                tostring(target.id or "?"), target.network and ", the core of " .. target.network .. "," or "",
                target.role == "network" and offers(target.asks) or WANTS[target.role] or "be a cell"
            ))
            print("  " .. target.fingerprint)
            write("Does it show the same one? [y/N] ")
            local answer = read()
            if not answer:lower():match("^y") then
                print("Not allowed.")
                return
            end
        end
    end
    local reply = request({ op = "allow", key = target.key, label = label })
    if reply.role == "network" then
        print(("Allowed the core of %s (#%s)."):format(reply.network, tostring(reply.id or "?")))
        if reply.roam then print("This network's phones are told they may use its cells when they next attach.") end
        if reply.messages then print("Its phones and this network's can send each other messages.") end
        print(("'cellcore network %s' shows the agreement, and changes it."):format(reply.network))
    else
        print(("Allowed #%s to %s, as %s."):format(tostring(reply.id or "?"), WANTS[reply.role] or "be a cell", reply.label))
    end
end

function commands.deny(who)
    if not who then return usage() end
    local status = request({ op = "status" })
    local digits = who:lower():gsub("%s", "")
    local key
    if #digits == 64 and digits:match("^%x+$") then
        key = digits
    else
        local candidates = {}
        for _, entry in ipairs(status.waiting) do candidates[#candidates + 1] = entry end
        for _, entry in ipairs(status.allowed) do
            if entry.role ~= "denied" then candidates[#candidates + 1] = entry end
        end
        for _, cell in ipairs(status.cells) do
            candidates[#candidates + 1] = { key = cell.key, id = cell.id, role = "cell", fingerprint = net.fingerprint(cell.key) }
        end
        -- Other networks' cores, by their network's name too.
        for _, network in ipairs(status.networks or {}) do
            if network.key then
                candidates[#candidates + 1] = {
                    key = network.key, id = network.id, role = "network", network = network.network,
                    label = network.network, fingerprint = network.fingerprint,
                }
            end
        end
        local found = find(candidates, who)
        if #found == 0 then error(("Nothing called %s is allowed or waiting."):format(who), 0) end
        if #found > 1 then
            print("More than one computer matches:")
            for _, entry in ipairs(found) do print("  " .. describe(entry)) end
            error("Refuse one by the start of its fingerprint instead.", 0)
        end
        key = found[1].key
    end
    local reply = request({ op = "deny", key = key })
    print(("Refused #%s. Allow it again with 'cellcore allow %s'."):format(tostring(reply.id or "?"), tostring(reply.id or key)))
    if reply.network then print(("The agreement with %s does nothing from now on."):format(reply.network)) end
end

function commands.add(id, number, file)
    if not id or not number then return usage() end
    local reply = request({ op = "add", id = id, number = number })
    print(("Activation code for %s (number %s), for a day:"):format(id, number))
    print(reply.code)
    if file then
        local handle = assert(fs.open(shell.resolve(file), "w"))
        handle.write(reply.code)
        handle.close()
    end
end

function commands.subscribers()
    local status = request({ op = "status" })
    if #status.subscribers == 0 then
        print("No subscribers yet. Add one with 'cellcore add'.")
        return
    end
    local rows = { { "ID", "Number", "Phone" } }
    for _, subscriber in ipairs(status.subscribers) do
        local where = "-"
        if subscriber.barred then
            where = "barred"
        elseif subscriber.cell then
            where = ("cell #%d%s, %s"):format(subscriber.cell, subscriber.roaming and " of " .. subscriber.roaming or "", subscriber.address)
        end
        if subscriber.may_roam == false then where = where .. " (no roaming)" end
        rows[#rows + 1] = { tostring(subscriber.id), tostring(subscriber.number), where }
    end
    textutils.tabulate(table.unpack(rows))
end

function commands.remove(who)
    if not who then return usage() end
    local reply = request({ op = "remove", subscriber = who })
    if reply.removed > 0 then print(("Removed %s. Their phone can't attach any more."):format(who)) end
    if reply.codes > 0 then print(("Cancelled %d activation code(s) for %s."):format(reply.codes, who)) end
end

function commands.set(who, what, value)
    local values = { yes = true, on = true, ["true"] = true, no = false, off = false, ["false"] = false }
    if not who or (what ~= "barred" and what ~= "roaming") or values[value or ""] == nil then return usage() end
    local reply = request({ op = "set", subscriber = who, [what] = values[value] })
    if what == "barred" then
        print(reply.barred and ("%s is barred: their phone is cut off, and refused."):format(reply.id)
            or ("%s is no longer barred."):format(reply.id))
    else
        print(reply.roaming and ("%s may use other networks' cells."):format(reply.id)
            or ("%s may only use this network's cells."):format(reply.id))
    end
end

function commands.stop()
    request({ op = "stop" })
    print("Stopping the core. It starts again with 'cellcore start', on its own computer.")
end

function commands.restart()
    request({ op = "restart" })
    print("Starting the core afresh. Cells join again by themselves, and phones attach again, with new addresses.")
end

-- How the connection to another network's core is going, in words.
local STATES = {
    connecting = "connecting", waiting = "waiting to be allowed by its core", connected = "connected",
    lost = "can't reach its core", refused = "refused",
}

local function how(network)
    if network.connected then return "connected" end
    if not network.state then return network.key and "waiting for its core to connect" or "not met yet" end
    local text = STATES[network.state] or tostring(network.state)
    if network.error then text = text .. ": " .. network.error end
    return text
end

-- Show an agreement: who the other network's core is, what the two do for each other, and how it's going.
local function show(network, status)
    local where = network.core and (" at " .. network.core) or ""
    print(("%s, core #%s%s: %s"):format(network.network, tostring(network.id or "?"), where, how(network)))
    if network.carry then
        print(("  Carries its phones%s"):format(network.carrying and (" (%d here)"):format(network.visitors) or ""))
    end
    if network.roam then
        print(("  This network's phones %s its cells%s"):format(
            network.roam == "home" and "treat as home" or "roam on", network.carried and (" (%d there)"):format(network.phones) or ""
        ))
    end
    if network.messages then
        local text = "  Messages between the networks' phones"
        if network.prefix then text = text .. (", its numbers starting %s"):format(network.prefix) end
        if (network.waiting or 0) > 0 then text = text .. (", %d waiting"):format(network.waiting) end
        print(text)
        if not status.number_prefix then print("  (This network needs a number prefix first: 'cellcore numbers')") end
    end
    if not network.carry and not network.roam and not network.messages then print("  Nothing agreed") end
    if network.fingerprint then print("  Its fingerprint: " .. network.fingerprint) end
end

function commands.networks()
    local status = request({ op = "status" })
    if #status.networks == 0 then
        print("No agreements with other networks. Make one with")
        print("  cellcore network <network> carry|roaming|messages on")
        print("  cellcore network <network> core <its core>")
        print("and allow this core on the other one, if it asks.")
        return
    end
    for _, network in ipairs(status.networks) do show(network, status) end
end

local SWITCHES = { on = true, yes = true, ["true"] = true, off = false, no = false, ["false"] = false }

function commands.network(name, what, value)
    if not name then return usage() end
    -- With nothing to change, it's shown.
    local change = { op = "network", network = name }
    if what == "forget" and value == nil then
        change.forget = true
    elseif what == "core" and value then
        change.core = value ~= "none" and value or false
    elseif (what == "carry" or what == "messages") and SWITCHES[value or ""] ~= nil then
        change[what] = SWITCHES[value]
    elseif what == "roaming" and SWITCHES[value or ""] ~= nil then
        change.roam = SWITCHES[value] and "partner" or false
    elseif what == "home" and SWITCHES[value or ""] ~= nil then
        change.roam = SWITCHES[value] and "home" or "partner"
    elseif what ~= nil then
        return usage()
    end
    local reply = request(change)
    if reply.forgotten then
        print(("Forgot the agreement with %s."):format(name))
        return
    end
    local status = request({ op = "status" })
    for _, network in ipairs(status.networks) do
        if network.network == name then show(network, status) end
    end
    if what ~= nil and not reply.key then
        print(("Its core must allow this one, unless it's this core which waits for it: there, run 'cellcore allow %s',"):format(tostring(reply.our_id or "<ID>")))
        print("and check it shows this fingerprint:")
        print("  " .. tostring(reply.our_fingerprint))
    end
end

-- The commands older versions had.

function commands.roaming()
    local status = request({ op = "status" })
    local any = false
    for _, network in ipairs(status.networks) do
        if network.carry or network.roam then
            show(network, status)
            any = true
        end
    end
    if not any then
        print("No roaming. Another network carries this one's phones once its core runs")
        print(("  cellcore network %s carry on"):format(status.network))
        print("and this network's agreement lets its phones use its cells ('cellcore network <it> roaming on').")
    end
end

function commands.peers()
    local status = request({ op = "status" })
    if status.number_prefix then
        print(("Other networks' phones reach this network's at %s<number>."):format(status.number_prefix))
    else
        print("This network has no number prefix yet: set one with 'cellcore numbers <digits>'.")
    end
    local any = false
    for _, network in ipairs(status.networks) do
        if network.messages then
            show(network, status)
            any = true
        end
    end
    if not any then print("It exchanges messages with no other network: 'cellcore network <network> messages on' sets it up.") end
end

function commands.carry(network, core)
    if not network or not core then return usage() end
    commands.network(network, "core", core)
    commands.network(network, "carry", "on")
end

function commands.uncarry(network)
    if not network then return usage() end
    commands.network(network, "carry", "off")
end

function commands.partner(network, how_much)
    if not network or (how_much ~= "home" and how_much ~= "roaming") then return usage() end
    commands.network(network, "home", how_much == "home" and "on" or "off")
end

function commands.peer(network, core)
    if not network or not core then return usage() end
    commands.network(network, "core", core)
    commands.network(network, "messages", "on")
end

function commands.unpeer(network)
    if not network then return usage() end
    commands.network(network, "messages", "off")
end

function commands.numbers(prefix)
    if not prefix then return usage() end
    request({ op = "numbers", prefix = prefix })
    print(("Other networks' phones reach this network's at %s<number>."):format(prefix))
end

function commands.log()
    local last = 0
    local function show()
        local reply = request({ op = "log", after = last })
        for _, line in ipairs(reply.lines) do print(("%s %s"):format(since(line.time), line.text)) end
        last = reply.last
    end
    show()
    print("Showing new lines as they come. Press Ctrl+T to stop.")
    while true do
        sleep(1)
        show()
    end
end

-- Hang up however this ends, so the core isn't left waiting.
local ok, err = pcall(function()
    connect()
    commands[command](table.unpack(args, 2))
end)
if manager then manager:close() end
if not ok and err ~= "Terminated" then error(err, 0) end
