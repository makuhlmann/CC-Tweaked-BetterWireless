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
    print(name .. " roaming")
    print(name .. " carry <network> <core>")
    print(name .. " uncarry <network>")
    print(name .. " partner <network> home|roaming")
    print(name .. " numbers <prefix>")
    print(name .. " peers")
    print(name .. " peer <network> <core>")
    print(name .. " unpeer <network>")
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
    status = 1, log = 1, add = 1, subscribers = 1, remove = 1, set = 1, cells = 1, allow = 1, deny = 1,
    roaming = 1, carry = 1, uncarry = 1, partner = 1, numbers = 1, peers = 1, peer = 1, unpeer = 1, stop = 1, restart = 1,
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
local WANTS = {
    cell = "be a cell", admin = "manage the network", roam = "carry this network's phones",
    peer = "exchange messages with this network's phones",
}

local function describe(entry)
    local network = "network " .. tostring(entry.network or "?")
    local role = ({ admin = "manager", roam = network, peer = network .. " (messages)" })[entry.role] or entry.role
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
    local away = 0
    for _, partner in ipairs(status.partners or {}) do away = away + partner.phones end
    if away > 0 then print(("Roaming on other networks: %d"):format(away)) end
    local visiting = 0
    for _, carried in ipairs(status.carrying or {}) do visiting = visiting + carried.phones end
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
    local groups = { cell = {}, admin = {}, roam = {}, peer = {}, denied = {} }
    for _, entry in ipairs(status.allowed) do table.insert(groups[entry.role], entry) end
    for _, group in ipairs {
        { "cell", "Allowed cells:" }, { "admin", "Allowed to manage the network:" },
        { "roam", "Allowed to carry this network's phones:" },
        { "peer", "Allowed to exchange messages with this network's phones:" }, { "denied", "Refused:" },
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
            error(("Nothing called %s is waiting. Start 'celld <core>' on the cell ('cellcore remote <core>' on a computer to manage this one from, or 'cellcore carry' or 'cellcore peer' on another network's core) first."):format(who), 0)
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
                WANTS[target.role] or "be a cell"
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
    print(("Allowed #%s to %s, as %s."):format(tostring(reply.id or "?"), WANTS[reply.role] or "be a cell", reply.label))
    if reply.role == "roam" then
        print("This network's phones are told they may use its cells when they next attach.")
    elseif reply.role == "peer" then
        print("Its phones and this network's can now send each other messages.")
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

function commands.roaming()
    local status = request({ op = "status" })
    if #status.partners == 0 and #status.carrying == 0 then
        print("No roaming. Another network carries this one's phones once its core runs")
        print(("  cellcore carry %s <this core>"):format(status.network))
        print("and you allow it here. This network carries another's with 'cellcore carry'.")
        return
    end
    if #status.partners > 0 then
        print(("Networks which carry %s's phones:"):format(status.network))
        for _, partner in ipairs(status.partners) do
            local how = partner.connected and ("%d phone(s) there"):format(partner.phones) or "not connected"
            print(("  %s, core #%s%s: %s"):format(partner.network, tostring(partner.id or "?"), partner.home and ", as home" or "", how))
        end
    end
    if #status.carrying > 0 then
        print(("Networks whose phones %s carries:"):format(status.network))
        local states = {
            connecting = "connecting", waiting = "waiting to be allowed by its core", serving = "%d phone(s) here",
            lost = "can't reach its core", refused = "refused",
        }
        for _, carried in ipairs(status.carrying) do
            local how = (states[carried.state] or tostring(carried.state)):format(carried.phones)
            if carried.error and carried.state ~= "serving" then how = how .. ": " .. carried.error end
            print(("  %s, through %s: %s"):format(carried.network, carried.core, how))
        end
    end
end

function commands.carry(network, core)
    if not network or not core then return usage() end
    local reply = request({ op = "carry", network = network, core = core })
    print(("Set up to carry the phones of %s."):format(network))
    print(("Its core must allow this one: there, run 'cellcore allow %s', and check it shows this fingerprint:"):format(tostring(reply.id or "<ID>")))
    print("  " .. tostring(reply.fingerprint))
    print("'cellcore roaming' shows how it's going.")
end

function commands.partner(network, how)
    if not network or (how ~= "home" and how ~= "roaming") then return usage() end
    request({ op = "partner", network = network, home = how == "home" })
    if how == "home" then
        print(("This network's phones treat %s as home: they aren't roaming there, and use its cells as they would"):format(network))
        print("this network's own. They hear of it when they next attach.")
    else
        print(("This network's phones roam on %s. They hear of it when they next attach."):format(network))
    end
end

function commands.numbers(prefix)
    if not prefix then return usage() end
    request({ op = "numbers", prefix = prefix })
    print(("Other networks' phones reach this network's at %s<number>."):format(prefix))
end

function commands.peers()
    local status = request({ op = "status" })
    if status.number_prefix then
        print(("Other networks' phones reach this network's at %s<number>."):format(status.number_prefix))
    else
        print("This network has no number prefix yet: set one with 'cellcore numbers <digits>'.")
    end
    if #status.peers == 0 then
        print("It exchanges messages with no other network. Set it up with 'cellcore peer <network> <core>' on")
        print("either network's core, and allow it on the other.")
        return
    end
    print("Exchanges messages with:")
    local states = {
        connecting = "connecting", waiting = "waiting to be allowed by its core", serving = "connected",
        lost = "can't reach its core", refused = "refused",
    }
    for _, peer in ipairs(status.peers) do
        local how
        if peer.connected then
            how = "connected"
        elseif peer.state then
            how = states[peer.state] or tostring(peer.state)
            if peer.error then how = how .. ": " .. peer.error end
        else
            how = "not connected"
        end
        if (peer.waiting or 0) > 0 then how = ("%s, %d message(s) waiting"):format(how, peer.waiting) end
        print(("  %s%s%s: %s"):format(
            peer.network, peer.prefix and " (" .. peer.prefix .. "...)" or "", peer.core and ", through " .. peer.core or "", how
        ))
    end
end

function commands.peer(network, core)
    if not network or not core then return usage() end
    local reply = request({ op = "peer", network = network, core = core })
    print(("Set up to exchange messages with %s."):format(network))
    print(("Its core must allow this one: there, run 'cellcore allow %s', and check it shows this fingerprint:"):format(tostring(reply.id or "<ID>")))
    print("  " .. tostring(reply.fingerprint))
    print("'cellcore peers' shows how it's going.")
end

function commands.unpeer(network)
    if not network then return usage() end
    request({ op = "unpeer", network = network })
    print(("Stopped connecting to %s's core. Its core can end it too, with 'cellcore deny'."):format(network))
end

function commands.uncarry(network)
    if not network then return usage() end
    request({ op = "uncarry", network = network })
    print(("Stopped carrying the phones of %s. Those here lose service."):format(network))
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
