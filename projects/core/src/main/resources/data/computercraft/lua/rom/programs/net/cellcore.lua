-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local address = require "cc.net.address"
local certificate = require "cc.internal.net.certificate"
local common = require "cc.internal.net.cell.common"

local CONFIG, SUBSCRIBERS, CODES, CELLS = "/.cell/config", "/.cell/subscribers", "/.cell/codes", "/.cell/cells"
local CERTIFICATE_LIFETIME = 365 * 24 * 60 * 60 * 1000

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name .. " setup <network> <prefix>")
    print(name)
    print(name .. " add <id> <number> [file]")
    print(name .. " allow <cell key> [label]")
    print(name .. " subscribers")
end

if not crypto or not enclave then
    printError("The core needs the crypto and enclave APIs, which are turned off on this server")
    return
end

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function from_hex(text)
    if type(text) ~= "string" or #text % 2 ~= 0 or text:find("[^%x]") then return nil end
    return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
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

-- Activation codes are kept with their keys in hexadecimal, so the file can be edited.
local function read_codes()
    local codes = {}
    for tag, code in pairs(read_table(CODES)) do
        if type(code) == "table" and from_hex(code.key) then
            codes[tag] = { id = code.id, number = code.number, key = from_hex(code.key), tries = code.tries or 0, expires = code.expires }
        end
    end
    return codes
end

local function write_codes(codes)
    local saved = {}
    for tag, code in pairs(codes) do
        saved[tag] = { id = code.id, number = code.number, key = to_hex(code.key), tries = code.tries, expires = code.expires }
    end
    write_table(CODES, saved)
end

local function run()
    local config = read_table(CONFIG)
    if type(config.network) ~= "string" then
        printError("Set the network up first, with 'cellcore setup'.")
        return
    end
    pcall(os.setKeepLoaded, true)

    local subscribers, codes = read_table(SUBSCRIBERS), read_codes()
    local core = net.cell.startCore {
        network = config.network, prefix = config.prefix, subscribers = subscribers, codes = codes,
        on_event = function(event, ...)
            local details = { ... }
            if event == "activated" then
                print(("Activated %s (number %s)"):format(tostring(details[2]), tostring(details[3])))
                write_table(SUBSCRIBERS, subscribers)
            elseif event == "attached" then
                print(("Attached: %s, at cell #%d"):format(details[2], details[3]))
            elseif event == "handover" then
                print(("Handover: #%d to #%d"):format(details[2], details[3]))
            elseif event == "rejected" then
                print("Refused a phone which isn't a subscriber")
            end
            if event == "code_used" or event == "activation_failed" then write_codes(codes) end
        end,
    }
    local signing = enclave.publicKey("cell.signing")
    print(("Core of %s, giving phones addresses in %s. Press Ctrl+T to stop."):format(config.network, config.prefix))

    local listener = assert(net.secure.listen(common.CONTROL_PORT))

    -- Serve one cell's connection.
    local function serve(connection)
        local hello = connection:receive(15)
        local key = connection:getPeerKey()
        local allowed = read_table(CELLS)
        -- A cell on this computer is always allowed.
        if not (allowed[key] or key == net.getIdentity()) then
            connection:send({ error = "This cell isn't allowed: run 'cellcore allow " .. tostring(key) .. "' on the core." })
            print("Refused a cell which isn't allowed: " .. net.fingerprint(key))
            return connection:close()
        end
        local signing_key = type(hello) == "table" and from_hex(hello.signing)
        if not signing_key or #signing_key ~= 32 or type(hello.id) ~= "number" then return connection:close() end

        local cert = certificate.encode(certificate.issue {
            name = common.cell_name(config.network, hello.id), key = signing_key,
            expires = os.epoch("utc") + CERTIFICATE_LIFETIME, issuer = signing,
            sign = function(data) return enclave.sign("cell.signing", data) end,
        })
        local outbox = {}
        local cell_address = address.parse((connection:getPeer()))
        local tunnel_key = core:add_tower(hello.id, cell_address, function(message)
            outbox[#outbox + 1] = message
            os.queueEvent("cellcore_outbox", hello.id)
        end)
        connection:send({ network = config.network, certificate = cert, tunnel_key = tunnel_key })
        print(("Cell #%d connected"):format(hello.id))

        parallel.waitForAny(
            function()
                while true do
                    while outbox[1] do
                        if not connection:send(table.remove(outbox, 1)) then return end
                    end
                    os.pullEvent("cellcore_outbox")
                end
            end,
            function()
                while true do
                    local message = connection:receive()
                    if message == nil then return end
                    core:control(hello.id, message)
                end
            end
        )
        print(("Cell #%d disconnected"):format(hello.id))
        connection:abort()
    end

    -- Run every cell's connection side by side, adding them as they come.
    local threads = {}
    local function spawn(fn, ...)
        local thread = { co = coroutine.create(fn) }
        threads[#threads + 1] = thread
        local ok, filter = coroutine.resume(thread.co, ...)
        if not ok then printError(filter) end
        thread.filter = filter
    end

    spawn(function()
        while true do
            local connection = listener:accept()
            if connection then spawn(serve, connection) end
        end
    end)
    -- New activation codes are added to the file by 'cellcore add' while this runs.
    spawn(function()
        while true do
            sleep(2)
            for tag, code in pairs(read_codes()) do
                if not codes[tag] then codes[tag] = code end
            end
        end
    end)

    while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then break end
        for i = #threads, 1, -1 do
            local thread = threads[i]
            if thread.filter == nil or thread.filter == event[1] then
                local ok, filter = coroutine.resume(thread.co, table.unpack(event, 1, event.n))
                if not ok then printError(filter) end
                thread.filter = filter
            end
            if coroutine.status(thread.co) == "dead" then table.remove(threads, i) end
        end
    end
    listener:close()
end

local command = args[1]
if command == nil then
    run()
elseif command == "setup" and #args == 3 then
    local network, prefix = args[2], args[3]
    if not network:match("^[%w%-]+$") or #network > 32 then
        printError("Network names are letters, digits and dashes, up to 32 of them.")
        return
    end
    write_table(CONFIG, { network = network, prefix = prefix })
    -- The operator's keys live in this computer's enclave.
    if not enclave.publicKey("cell.operator") then enclave.generate("cell.operator", "x25519") end
    if not enclave.publicKey("cell.signing") then enclave.generate("cell.signing", "ed25519") end
    print(("%s is set up, giving phones addresses in %s. Run 'cellcore' to start it."):format(network, prefix))
elseif command == "add" and (#args == 3 or #args == 4) then
    -- Make the code here, in the same way the core does, and leave it for the running core to pick up.
    local code, tag, secret = common.make_code(crypto)
    local codes = read_codes()
    codes[tag] = {
        id = args[2], number = args[3], key = common.activation_key(crypto, secret), tries = 0,
        expires = os.epoch("utc") + 24 * 60 * 60 * 1000,
    }
    write_codes(codes)
    print(("Activation code for %s (number %s), for a day:"):format(args[2], args[3]))
    print(code)
    if args[4] then
        local file = assert(fs.open(args[4], "w"))
        file.write(code)
        file.close()
    end
elseif command == "allow" and (#args == 2 or #args == 3) then
    local key = args[2]:lower()
    if #key ~= 64 or not from_hex(key) then
        printError("Expected a cell's key, of 64 hexadecimal digits, as 'celld' shows.")
        return
    end
    local cells = read_table(CELLS)
    cells[key] = args[3] or "added by hand"
    write_table(CELLS, cells)
    print("Allowed the cell " .. net.fingerprint(key))
elseif command == "subscribers" and #args == 1 then
    local any = false
    for sim, subscriber in pairs(read_table(SUBSCRIBERS)) do
        print(("%-12s %-8s %s"):format(tostring(subscriber.id), tostring(subscriber.number), net.fingerprint(sim)))
        any = true
    end
    if not any then print("No subscribers yet. Add one with 'cellcore add'.") end
else
    usage()
end
