-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cellular network's core, run in the network stack's background process: the core itself, with the connections of
its cells and of the computers which manage it, all on the control port. The shell stays free, and the core keeps
running while it's managed.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cellcore` program instead.

Computers connect securely, and say what they want to be: a cell, or an administrator. The core's own computer is
always allowed. Others wait, with their connection open, until someone allows their key. That's done by the computer's
ID, after checking its fingerprint, so nobody needs to type a key in.

Every connection starts with a hello, `{ role = "cell" or "admin", id = <computer ID> }`, which the core answers:
`{ waiting = true, fingerprint = ... }` while the computer waits, then the cell's details (for a cell) or `{ ok = true }`
(for an administrator), or `{ error = ... }`. Administrators then send requests, each with an `op`, and get a reply to
each: `status`, `allow`, `deny`, `add`, `remove` and `log`.

@local
]]

local address = require "cc.net.address"
local certificate = require "cc.internal.net.certificate"
local common = require "cc.internal.net.cell.common"
local tasks = require "cc.internal.net.tasks"

--- How many computers may wait to be allowed at once.
local MAX_WAITING = 16

--- How long a computer may wait to be allowed, in seconds.
local WAIT_TIMEOUT = 10 * 60

-- How long a computer has to say who it is, and how long an administrator may stay quiet, in seconds.
local HELLO_TIMEOUT = 15
local ADMIN_TIMEOUT = 5 * 60

--- How many lines of the log to keep.
local LOG_SIZE = 100

local CERTIFICATE_LIFETIME = 365 * 24 * 60 * 60 * 1000

-- What each role is called, as "<Computer> #7 wants <to do this>".
local ROLES = {
    cell = { name = "Cell", wants = "to join as a cell" },
    admin = { name = "Computer", wants = "to manage the network" },
}

local Service = {}
Service.__index = Service

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

local function from_hex(text)
    if type(text) ~= "string" or #text % 2 ~= 0 or text:find("[^%x]") then return nil end
    return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function is_key(text) return type(text) == "string" and #text == 64 and not text:find("[^%x]") end

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

-- Subscribers' IDs and numbers: short, and printable.
local function is_name(text) return type(text) == "string" and #text >= 1 and #text <= 32 and not text:find("[^%w%-%._+]") end

-- Tell a computer why it can't come in, and hang up.
local function refuse(connection, reason)
    connection:send({ error = reason })
    connection:close()
end

--[[- Start a network's core.

@tparam {
    dir = string, identity = string, fingerprint = function(key:string):string,
    listen = function():table, start_core = function(options:table):table,
    signing = string, sign = function(data:string):string,
    clock = function():number, epoch = function():number, wake = function(),
} options Where the core's files are, with its `config` (the network's name and prefix, from `cellcore setup`); this
computer's key, as hexadecimal digits, and a way to get a key's fingerprint; a way to listen for secure connections on
the control port; a way to start the core itself (given the network, prefix, subscribers, activation codes, and a
function told about events); the operator's Ed25519 key and a way to sign with it, for cells' certificates; the time,
as `os.clock` and `os.epoch("utc")` give it; and a way to wake tasks waiting for something to change.
@treturn[1] table The service. Pass it every event with `resume`.
@treturn[2] nil If it couldn't start.
@treturn[2] string Why not.
]]
local function new(options)
    local config = read_table(fs.combine(options.dir, "config"))
    if type(config.network) ~= "string" or type(config.prefix) ~= "string" then
        return nil, "Set the network up first, with 'cellcore setup'."
    end

    local self = setmetatable({
        options = options, config = config,
        files = {
            subscribers = fs.combine(options.dir, "subscribers"), codes = fs.combine(options.dir, "codes"),
            cells = fs.combine(options.dir, "cells"),
        },
        waiting = {}, cells = {}, admins = {}, lines = {}, line_count = 0,
    }, Service)
    self.subscribers = read_table(self.files.subscribers)
    self:read_codes()
    self:read_allowed()

    local listener, err = options.listen()
    if not listener then return nil, "Cannot listen for cells: " .. tostring(err) end

    local ok, core = pcall(options.start_core, {
        network = config.network, prefix = config.prefix, subscribers = self.subscribers, codes = self.codes,
        on_event = function(...) self:event(...) end,
    })
    if not ok then
        listener:close()
        return nil, core
    end
    self.listener, self.core = listener, core

    self.tasks = tasks.new(function(task_err) self:log("Error: " .. tostring(task_err)) end)
    self.tasks:spawn(function() self:accept() end)
    self:log(("Started the core of %s, giving phones addresses in %s"):format(config.network, config.prefix))
    return self
end

-- Activation codes are kept with their keys in hexadecimal, so the file can be edited.
function Service:read_codes()
    self.codes = {}
    for tag, code in pairs(read_table(self.files.codes)) do
        if type(code) == "table" and from_hex(code.key) then
            self.codes[tag] = {
                id = code.id, number = code.number, key = from_hex(code.key), tries = code.tries or 0, expires = code.expires,
            }
        end
    end
end

function Service:save_codes()
    local saved = {}
    for tag, code in pairs(self.codes) do
        saved[tag] = { id = code.id, number = code.number, key = to_hex(code.key), tries = code.tries, expires = code.expires }
    end
    write_table(self.files.codes, saved)
end

-- The computers allowed in (and those refused), by key: `{ label, role, id }`. Older versions kept only a label, for
-- cells.
function Service:read_allowed()
    self.allowed = {}
    for key, entry in pairs(read_table(self.files.cells)) do
        if is_key(key) then
            if type(entry) == "string" then entry = { label = entry, role = "cell" } end
            if type(entry) == "table" and (ROLES[entry.role] or entry.role == "denied") then
                self.allowed[key:lower()] = { label = tostring(entry.label or ""), role = entry.role, id = tonumber(entry.id) }
            end
        end
    end
end

function Service:save_allowed()
    write_table(self.files.cells, self.allowed)
end

function Service:save_subscribers()
    write_table(self.files.subscribers, self.subscribers)
end

--[[- Add a line to the log, which `cellcore log` shows.

@tparam string text The line.
]]
function Service:log(text)
    self.line_count = self.line_count + 1
    self.lines[#self.lines + 1] = { n = self.line_count, time = self.options.epoch(), text = text }
    while #self.lines > LOG_SIZE do table.remove(self.lines, 1) end
end

-- Who did something, for the log.
function Service:by(key)
    if key == self.options.identity then return "" end
    local entry = self.allowed[key]
    return " (by " .. (entry and entry.label ~= "" and entry.label or self.options.fingerprint(key)) .. ")"
end

function Service:subscriber_name(sim)
    local subscriber = self.subscribers[sim]
    return subscriber and subscriber.id or "A phone"
end

-- Something happened in the core.
function Service:event(event, ...)
    local details = table.pack(...)
    if event == "activated" then
        self:save_subscribers()
        self:log(("Activated %s, number %s"):format(tostring(details[2]), tostring(details[3])))
    elseif event == "attached" then
        self:log(("%s attached at cell #%d, as %s"):format(self:subscriber_name(details[1]), details[3], details[2]))
    elseif event == "handover" then
        self:log(("%s moved from cell #%d to #%d"):format(self:subscriber_name(details[1]), details[2], details[3]))
    elseif event == "rejected" then
        self:log("Refused a phone which isn't a subscriber")
    elseif event == "activation_failed" then
        self:log("A phone tried a wrong activation code")
    end
    if event == "code_used" or event == "activation_failed" then self:save_codes() end
end

function Service:allows(key, role)
    if key == self.options.identity then return true end
    local entry = self.allowed[key]
    return entry ~= nil and entry.role == role
end

function Service:accept()
    while not self.stopped do
        local ok, connection = pcall(self.listener.accept, self.listener)
        if not ok then
            self:log("Error: " .. tostring(connection))
            coroutine.yield()
        elseif not connection then
            return
        else
            self.tasks:spawn(function()
                local served, err = pcall(self.serve, self, connection)
                if not served then
                    self:log("Error: " .. tostring(err))
                    connection:abort()
                end
            end)
        end
    end
end

-- A computer has connected: find out who it is, and what it wants.
function Service:serve(connection)
    local hello = connection:receive(HELLO_TIMEOUT)
    local key = connection:getPeerKey()
    local role = type(hello) == "table" and hello.role
    if not key or not ROLES[role] then return connection:abort() end
    local id = type(hello.id) == "number" and hello.id >= 0 and hello.id == math.floor(hello.id) and hello.id or nil

    if not self:allows(key, role) then
        local entry = self.allowed[key]
        if entry and entry.role == "denied" then
            return refuse(connection, "The core has refused this computer.")
        elseif entry then
            return refuse(connection, entry.role == "cell"
                and "This computer may be a cell, but not manage the network."
                or "This computer may manage the network, but not be a cell.")
        end
        if not self:wait(connection, key, role, id) then return end
    end

    if role == "cell" then return self:serve_cell(connection, key, hello, id) end
    return self:serve_admin(connection, key)
end

-- Keep a computer waiting until it's allowed. Returns whether it was.
function Service:wait(connection, key, role, id)
    local count = 0
    for _ in pairs(self.waiting) do count = count + 1 end
    local old = self.waiting[key]
    if not old and count >= MAX_WAITING then
        refuse(connection, "Too many computers are waiting for the core to allow them. Try again later.")
        return false
    end
    -- A computer which connects again replaces its old connection.
    if old then old.connection:abort() end

    local fingerprint = self.options.fingerprint(key)
    local entry = {
        key = key, id = id, role = role, fingerprint = fingerprint, since = self.options.clock(), connection = connection,
    }
    self.waiting[key] = entry
    self:log(("%s #%s wants %s. Fingerprint %s. Allow it with 'cellcore allow %s'"):format(
        ROLES[role].name, tostring(id or "?"), ROLES[role].wants, fingerprint, tostring(id or fingerprint:sub(1, 9))
    ))
    connection:send({ waiting = true, fingerprint = fingerprint })

    while true do
        -- Replaced by a newer connection, or refused.
        if self.waiting[key] ~= entry then return false end
        if self:allows(key, role) then
            self.waiting[key] = nil
            return true
        end
        if self.options.clock() - entry.since >= WAIT_TIMEOUT then
            self.waiting[key] = nil
            refuse(connection, "Nobody allowed this computer in time. Try again.")
            return false
        end
        -- Check again every second, or as soon as the computer hangs up.
        local message, err = connection:receive(1)
        if message == nil and err ~= "Timed out" then
            if self.waiting[key] == entry then self.waiting[key] = nil end
            return false
        end
    end
end

function Service:serve_cell(connection, key, hello, id)
    local signing = from_hex(hello.signing)
    if not signing or #signing ~= 32 or not id then return connection:abort() end

    local network = self.config.network
    local cert = certificate.encode(certificate.issue {
        name = common.cell_name(network, id), key = signing, expires = self.options.epoch() + CERTIFICATE_LIFETIME,
        issuer = self.options.signing, sign = self.options.sign,
    })

    -- A cell which connects again (it restarted, or lost its connection) replaces its old connection.
    local old = self.cells[id]
    if old then old.connection:abort() end

    -- The core sends control messages from inside the network stack, where nothing may wait: queue them.
    local outbox, done = {}, false
    local function send(message)
        outbox[#outbox + 1] = message
        self.options.wake()
    end
    local peer = connection:getPeer()
    local tunnel_key = self.core:add_tower(id, address.parse(peer), send)
    if not connection:send({ network = network, certificate = cert, tunnel_key = tunnel_key }) then
        self.core:remove_tower(id, send)
        return connection:abort()
    end

    local entry = { id = id, key = key, address = peer, area = hello.area, since = self.options.epoch(), connection = connection }
    self.cells[id] = entry
    local known = self.allowed[key]
    if known and known.id ~= id then
        known.id = id
        self:save_allowed()
    end
    self:log(("Cell #%d connected, from %s"):format(id, peer))

    self.tasks:spawn(function()
        while not done do
            local message = table.remove(outbox, 1)
            if message then
                if not connection:send(message) then done = true end
            else
                coroutine.yield()
            end
        end
    end)
    while not done do
        local message = connection:receive()
        if message == nil then break end
        local ok, err = pcall(self.core.control, self.core, id, message)
        if not ok then self:log("Error: " .. tostring(err)) end
    end
    done = true
    connection:abort()
    self.core:remove_tower(id, send)
    if self.cells[id] == entry then
        self.cells[id] = nil
        self:log(("Cell #%d disconnected"):format(id))
    end
end

local requests = {}

function Service:serve_admin(connection, key)
    self.admins[connection] = key
    if connection:send({ ok = true, network = self.config.network }) then
        while true do
            local request = connection:receive(ADMIN_TIMEOUT)
            if type(request) ~= "table" then break end
            local handler = requests[request.op]
            local ok, reply
            if handler then
                ok, reply = pcall(handler, self, request, key)
                if not ok then reply = { error = tostring(reply) } end
            else
                reply = { error = "Unknown request " .. tostring(request.op) }
            end
            if not connection:send(reply) then break end
        end
    end
    self.admins[connection] = nil
    connection:close()
end

local function by_id(a, b)
    if a.id ~= b.id then return (a.id or -1) < (b.id or -1) end
    return a.key < b.key
end

--- Everything about the network: its cells, the computers allowed in and waiting, and the subscribers.
function requests.status(self)
    local fingerprint, now = self.options.fingerprint, self.options.epoch()
    local result = {
        network = self.config.network, prefix = self.config.prefix, messages = #self.core.messages, codes = 0,
        cells = {}, allowed = {}, waiting = {}, subscribers = {},
    }
    for id, cell in pairs(self.cells) do
        result.cells[#result.cells + 1] = { id = id, key = cell.key, address = cell.address, area = cell.area, since = cell.since }
    end
    table.sort(result.cells, by_id)
    for key, entry in pairs(self.allowed) do
        result.allowed[#result.allowed + 1] = {
            key = key, fingerprint = fingerprint(key), label = entry.label, role = entry.role, id = entry.id,
        }
    end
    table.sort(result.allowed, by_id)
    for key, entry in pairs(self.waiting) do
        result.waiting[#result.waiting + 1] = {
            key = key, fingerprint = entry.fingerprint, id = entry.id, role = entry.role,
            waited = math.floor(self.options.clock() - entry.since),
        }
    end
    table.sort(result.waiting, by_id)

    local sessions = {}
    for _, session in ipairs(self.core:info()) do sessions[session.sim] = session end
    for sim, subscriber in pairs(self.subscribers) do
        local session = sessions[sim]
        result.subscribers[#result.subscribers + 1] = {
            id = subscriber.id, number = subscriber.number, fingerprint = fingerprint(sim),
            address = session and session.address, cell = session and session.attached and session.cell or nil,
        }
    end
    table.sort(result.subscribers, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _, code in pairs(self.codes) do
        if type(code.expires) == "number" and code.expires >= now then result.codes = result.codes + 1 end
    end
    return result
end

--- Allow a computer in, by its key: in the role it asked for, if it's waiting.
function requests.allow(self, request, by)
    local key = is_key(request.key) and request.key:lower()
    if not key then return { error = "Expected a key, of 64 hexadecimal digits" } end

    local waiting, known = self.waiting[key], self.allowed[key]
    if known and known.role == "denied" then known = nil end
    local role = waiting and waiting.role or (request.role == "admin" and "admin") or (known and known.role) or "cell"
    local id = waiting and waiting.id or (known and known.id) or (self.allowed[key] and self.allowed[key].id)
    local label = type(request.label) == "string" and request.label ~= "" and request.label:sub(1, 32)
        or (known and known.label ~= "" and known.label)
        or ((role == "cell" and "cell #" or "admin #") .. tostring(id or "?"))

    self.allowed[key] = { label = label, role = role, id = id }
    self:save_allowed()
    self:log(("Allowed %s #%s, %s%s"):format(role == "cell" and "cell" or "administrator", tostring(id or "?"), label, self:by(by)))
    self.options.wake()
    return { role = role, id = id, label = label, fingerprint = self.options.fingerprint(key) }
end

--- Refuse a computer, by its key, from now on. Any connections it has are dropped.
function requests.deny(self, request, by)
    local key = is_key(request.key) and request.key:lower()
    if not key then return { error = "Expected a key, of 64 hexadecimal digits" } end
    if key == self.options.identity then return { error = "The core's own computer is always allowed" } end

    local known, waiting = self.allowed[key], self.waiting[key]
    local id = (known and known.id) or (waiting and waiting.id)
    self.allowed[key] = { label = known and known.label or "", role = "denied", id = id }
    self:save_allowed()
    self:log(("Refused #%s, %s%s"):format(tostring(id or "?"), self.options.fingerprint(key), self:by(by)))

    if waiting then
        self.waiting[key] = nil
        waiting.connection:abort()
    end
    for _, cell in pairs(self.cells) do
        if cell.key == key then cell.connection:abort() end
    end
    for connection, admin in pairs(self.admins) do
        if admin == key then connection:abort() end
    end
    return { id = id }
end

--- Make an activation code for a subscriber.
function requests.add(self, request, by)
    local id, number = request.id, request.number
    if not is_name(id) or not is_name(number) then
        return { error = "IDs and numbers are up to 32 letters, digits, and . - _ or +" }
    end
    for _, subscriber in pairs(self.subscribers) do
        if subscriber.number == number and subscriber.id ~= id then
            return { error = ("%s already has the number %s"):format(tostring(subscriber.id), number) }
        end
    end
    local code = self.core:add_code(id, number)
    self:save_codes()
    self:log(("Made an activation code for %s, number %s%s"):format(id, number, self:by(by)))
    return { code = code }
end

--- Remove a subscriber, by their ID or number, and any codes for them which haven't been used.
function requests.remove(self, request, by)
    local who = request.subscriber
    if type(who) ~= "string" then return { error = "Expected a subscriber's ID or number" } end

    local removed = 0
    for sim, subscriber in pairs(self.subscribers) do
        if subscriber.id == who or subscriber.number == who then
            self.core:remove_subscriber(sim)
            removed = removed + 1
        end
    end
    local codes = 0
    for tag, code in pairs(self.codes) do
        if code.id == who or code.number == who then
            self.codes[tag] = nil
            codes = codes + 1
        end
    end
    if removed == 0 and codes == 0 then return { error = "There's no subscriber " .. who } end
    self:save_subscribers()
    self:save_codes()
    self:log(("Removed %s%s"):format(who, self:by(by)))
    return { removed = removed, codes = codes }
end

--- The log, after the line numbered `after`.
function requests.log(self, request)
    local after = type(request.after) == "number" and request.after or 0
    local lines = {}
    for _, line in ipairs(self.lines) do
        if line.n > after then lines[#lines + 1] = line end
    end
    return { lines = lines, last = self.line_count }
end

--[[- Pass an event to the service's tasks.

@tparam string|nil event The event's name.
@param ... Its arguments.
]]
function Service:resume(...)
    self.tasks:resume(...)
end

--- Stop the core. Its cells and phones lose it, and the port and the gateway's interface are freed.
function Service:stop()
    if self.stopped then return end
    self.stopped = true
    self.tasks:stop()
    self.core:stop()
    self.listener:close()
    for _, entry in pairs(self.waiting) do entry.connection:abort() end
    for _, cell in pairs(self.cells) do cell.connection:abort() end
    for connection in pairs(self.admins) do connection:abort() end
    self.waiting, self.cells, self.admins = {}, {}, {}
end

return {
    new = new,
    MAX_WAITING = MAX_WAITING,
    WAIT_TIMEOUT = WAIT_TIMEOUT,
    LOG_SIZE = LOG_SIZE,
}
