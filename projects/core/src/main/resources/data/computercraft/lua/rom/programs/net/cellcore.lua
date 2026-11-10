-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- Set up, start and manage a cellular network's core. The core runs in the background; everything else talks to it
-- over the control port, on this computer or (with "remote") on another.

local CONFIG = "/.cell/config"
local CONTROL_PORT = 2123

local args = { ... }
local name = arg[0] or fs.getName(shell.getRunningProgram())

local function usage()
    print("Usages:")
    print(name .. " setup <network> <prefix>")
    print(name .. " [status]")
    print(name .. " start|stop")
    print(name .. " log")
    print(name .. " add <id> <number> [file]")
    print(name .. " subscribers")
    print(name .. " remove <id|number>")
    print(name .. " cells")
    print(name .. " allow <computer> [label]")
    print(name .. " deny <computer>")
    print(name .. " remote <core> <command...>")
end

if not crypto or not enclave then
    printError("The core needs the crypto and enclave APIs, which are turned off on this server")
    return
end

local function read_table(path)
    local file = fs.open(path, "r")
    if not file then return {} end
    local value = textutils.unserialise(file.readAll() or "")
    file.close()
    return type(value) == "table" and value or {}
end

local function write_table(path, value)
    local file = assert(fs.open(path, "w"))
    file.write(textutils.serialise(value))
    file.close()
end

-- Commands which only work on the core's own computer.
local command = args[1] or "status"
if command == "setup" then
    if #args ~= 3 then return usage() end
    local network, prefix = args[2], args[3]
    if not network:match("^[%w%-]+$") or #network > 32 then
        printError("Network names are letters, digits and dashes, up to 32 of them.")
        return
    end
    local addr, length = require("cc.net.address").parse(prefix)
    if not addr or not length or length > 30 then
        printError("Expected the network for phones' addresses, such as 10.64.0.0/16.")
        return
    end
    local config = read_table(CONFIG)
    config.network, config.prefix, config.enabled = network, prefix, nil
    -- Start again with the new settings.
    net.cell.stopCore()
    write_table(CONFIG, config)
    local ok, err = net.cell.startCore()
    if not ok then
        printError(err)
        return
    end
    print(("%s is set up and running, giving phones addresses in %s."):format(network, prefix))
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
local target, remote = "127.0.0.1", false
if command == "remote" then
    if #args < 2 then return usage() end
    target, remote = args[2], true
    table.remove(args, 1)
    table.remove(args, 1)
    command = args[1] or "status"
    if command == "setup" or command == "start" or command == "stop" then
        printError(("'%s' only works on the core itself."):format(command))
        return
    end
end

local known = {
    status = 1, log = 1, add = 1, subscribers = 1, remove = 1, cells = 1, allow = 1, deny = 1,
}
if not known[command] then return usage() end

local connection

-- Send a request, and wait for the reply.
local function request(message)
    local sent, err = connection:send(message)
    if not sent then error("Lost the core: " .. tostring(err), 0) end
    local reply, receive_err = connection:receive(15)
    if type(reply) ~= "table" then error("The core didn't answer: " .. tostring(receive_err or "it hung up"), 0) end
    if reply.error then error(reply.error, 0) end
    return reply
end

local function connect()
    local err
    connection, err = net.secure.connect(target, CONTROL_PORT)
    if not connection then
        if not remote then
            if not fs.exists(CONFIG) then
                error("This computer isn't a network's core. Set one up with 'cellcore setup', or manage another with 'cellcore remote'.", 0)
            end
            error("The core isn't running. Start it with 'cellcore start'.", 0)
        end
        error(("Cannot reach the core %s: %s"):format(target, err), 0)
    end

    connection:send({ role = "admin", id = os.getComputerID() })
    local reply, receive_err = connection:receive(15)
    if type(reply) == "table" and reply.waiting then
        print("The core hasn't allowed this computer to manage it yet. On the core, run:")
        print(("  cellcore allow %d"):format(os.getComputerID()))
        print("and check it shows this fingerprint:")
        print("  " .. tostring(reply.fingerprint))
        print("Waiting... Press Ctrl+T to give up.")
        reply, receive_err = connection:receive()
    end
    if type(reply) ~= "table" then error("The core didn't answer: " .. tostring(receive_err or "it hung up"), 0) end
    if reply.error then error(reply.error, 0) end
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

local function describe(entry)
    local role = entry.role == "admin" and "manager" or entry.role
    return ("#%s %s, %s"):format(tostring(entry.id or "?"), role, entry.fingerprint)
end

local function since(epoch)
    return os.date("%H:%M", math.floor(epoch / 1000))
end

local commands = {}

function commands.status()
    local status = request({ op = "status" })
    print(("Core of %s, phones in %s"):format(status.network, status.prefix))
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
    for _, entry in ipairs(status.allowed) do table.insert(groups[entry.role], entry) end
    for _, group in ipairs { { "cell", "Allowed cells:" }, { "admin", "Allowed to manage the network:" }, { "denied", "Refused:" } } do
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
            error(("Nothing called %s is waiting. Start 'celld <core>' on the cell (or 'cellcore remote <core>' on the computer) first."):format(who), 0)
        elseif #found > 1 then
            print("More than one computer matches:")
            for _, entry in ipairs(found) do print("  " .. describe(entry)) end
            error("Allow one by the start of its fingerprint instead.", 0)
        end
        target = found[1]

        -- Unless they typed enough of the fingerprint, check it's the computer they think.
        if not (digits:match("^%x+$") and #digits >= 8) then
            print(("#%s wants to %s. Its fingerprint is"):format(
                tostring(target.id or "?"), target.role == "admin" and "manage the network" or "be a cell"
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
    print(("Allowed #%s to %s, as %s."):format(
        tostring(reply.id or "?"), reply.role == "admin" and "manage the network" or "be a cell", reply.label
    ))
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
        local where = subscriber.cell and ("cell #%d, %s"):format(subscriber.cell, subscriber.address) or "-"
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
if connection then connection:close() end
if not ok and err ~= "Terminated" then error(err, 0) end
