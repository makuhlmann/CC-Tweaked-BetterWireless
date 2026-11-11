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

Every connection starts with a hello, `{ role = "cell", "admin", "roam" or "peer", id = <computer ID> }`, which the core
answers: `{ waiting = true, fingerprint = ... }` while the computer waits, then the cell's details (for a cell) or
`{ ok = true }` (for an administrator), or `{ error = ... }`. Administrators then send requests, each with an `op`, and
get a reply to each: `status`, `allow`, `deny`, `add`, `remove`, `set`, `log`, `carry`, `uncarry`, `partner`,
`numbers`, `peer`, `unpeer`, `stop` and `restart`.

Roaming: the core of another network which carries this network's phones connects with the role `roam`, giving its
network's name and signing key. Once it's allowed, it's to this core what a cell is (see [`cc.internal.net.cell.core`]),
and this network's phones are told they may use its cells. The other way round, this core connects to the cores of the
networks whose phones it carries (`carry`), kept in the file `roaming`, and tries again when it loses them. A partner
may be one this network's phones treat as home (`partner`), kept with its key.

Messages between networks: the core of a network which exchanges messages with this one (a peer) connects with the role
`peer`, giving its network's name and number prefix, and waits to be allowed. Once it is, messages between the two
networks' phones go over that connection, both ways. The other way round, this core connects to the cores of the
networks it was told to exchange messages with (`peer`), kept in the file `peers`. Another network's core may be both a
roaming partner and a peer: it's allowed for each, apart. This network's number prefix is in its `config`, and each
peer's is kept with it (in `peers` or `cells`), so messages for a peer which hasn't connected since the core started
are kept for it, rather than refused.

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
    roam = { name = "Network", wants = "to carry this network's phones" },
    peer = { name = "Network", wants = "to exchange messages with this network's phones" },
}

-- Roles a computer may have more than one of: another network's core's.
local NETWORK_ROLES = { roam = true, peer = true }

-- Whether a computer allowed in has a role.
local function has_role(entry, role)
    return entry.role == role or (entry.roles ~= nil and entry.roles[role] == true)
end

-- Number prefixes: digits, up to 8 of them.
local function is_number_prefix(text)
    return type(text) == "string" and #text >= 1 and #text <= 8 and not text:find("%D")
end

-- How long to wait before connecting again to a network whose phones we carry, at first and at most, in seconds.
local FIRST_DELAY, MAX_DELAY = 2, 60

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
    id? = number, connect? = function(core:string):table, sleep? = function(seconds:number),
    stop? = function(), restart? = function(),
} options Where the core's files are, with its `config` (the network's name and prefix, from `cellcore setup`); this
computer's key, as hexadecimal digits, and a way to get a key's fingerprint; a way to listen for secure connections on
the control port; a way to start the core itself (given the network, prefix, subscribers, activation codes, and a
function told about events); the operator's Ed25519 key and a way to sign with it, for cells' certificates; the time,
as `os.clock` and `os.epoch("utc")` give it; a way to wake tasks waiting for something to change; and, to carry other
networks' phones, this computer's ID, a way to connect securely to another core's control port, and a way to wait;
and ways to stop the whole service for good, and to start it afresh, when an administrator asks.
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
            cells = fs.combine(options.dir, "cells"), roaming = fs.combine(options.dir, "roaming"),
            peers = fs.combine(options.dir, "peers"), config = fs.combine(options.dir, "config"),
        },
        waiting = {}, cells = {}, admins = {}, lines = {}, line_count = 0,
        -- Roaming: the cores of networks which carry our phones, connected now, by network; and the networks whose
        -- phones we carry, by name.
        partners = {}, carrying = {},
        -- Messages between networks: the connections to other networks' cores, either way, by network; and the
        -- networks whose cores we connect to, by name.
        peer_links = {}, peering = {},
    }, Service)
    self.subscribers = read_table(self.files.subscribers)
    self:read_codes()
    self:read_allowed()

    local listener, err = options.listen()
    if not listener then return nil, "Cannot listen for cells: " .. tostring(err) end

    if config.number_prefix ~= nil and not is_number_prefix(config.number_prefix) then config.number_prefix = nil end
    local ok, core = pcall(options.start_core, {
        network = config.network, prefix = config.prefix, subscribers = self.subscribers, codes = self.codes,
        number_prefix = config.number_prefix, on_event = function(...) self:event(...) end,
    })
    if not ok then
        listener:close()
        return nil, core
    end
    self.listener, self.core = listener, core

    self.tasks = tasks.new(function(task_err) self:log("Error: " .. tostring(task_err)) end)
    self.tasks:spawn(function() self:accept() end)
    self:log(("Started the core of %s, giving phones addresses in %s"):format(config.network, config.prefix))

    self:update_partner_keys()
    for network, entry in pairs(read_table(self.files.roaming)) do
        if common.is_network(network) and network ~= config.network and type(entry) == "table" and type(entry.core) == "string" then
            self:start_carrying(network, entry.core)
        end
    end
    for network, entry in pairs(read_table(self.files.peers)) do
        if common.is_network(network) and network ~= config.network and type(entry) == "table" and type(entry.core) == "string" then
            self:start_peering(network, entry.core, is_number_prefix(entry.prefix) and entry.prefix or nil)
        end
    end
    -- Networks we exchange messages with, by the prefixes they had when they last connected: messages for them wait.
    for network, entry in pairs(self.peering) do
        if entry.prefix then core:know_peer(network, entry.prefix) end
    end
    for _, entry in pairs(self.allowed) do
        if has_role(entry, "peer") and entry.network and entry.prefix then core:know_peer(entry.network, entry.prefix) end
    end
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
                self.allowed[key:lower()] = {
                    label = tostring(entry.label or ""), role = entry.role, id = tonumber(entry.id),
                    -- For a roaming partner: its network, the key its cells are certified with, and whether our
                    -- phones treat it as home.
                    network = common.is_network(entry.network) and entry.network or nil,
                    signing = is_key(entry.signing) and entry.signing or nil,
                    home = entry.home == true or nil,
                    -- For a peer: its number prefix, when it last connected.
                    prefix = is_number_prefix(entry.prefix) and entry.prefix or nil,
                }
                -- Another network's core may have a second role.
                if type(entry.roles) == "table" and NETWORK_ROLES[entry.role] then
                    local roles = {}
                    for role in pairs(NETWORK_ROLES) do
                        if entry.roles[role] == true and role ~= entry.role then roles[role] = true end
                    end
                    self.allowed[key:lower()].roles = next(roles) and roles or nil
                end
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
        self:log(("%s attached at cell #%d%s, as %s"):format(
            self:subscriber_name(details[1]), details[3], details[4] and " of " .. details[4] or "", details[2]
        ))
    elseif event == "visitor" then
        self:log(("A phone of %s attached at cell #%d"):format(tostring(details[1]), details[2]))
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
    return entry ~= nil and has_role(entry, role)
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
    -- Computers' IDs are whole numbers, and small enough to write out.
    local id = common.is_id(hello.id) and hello.id < 2 ^ 31 and hello.id or nil

    if not self:allows(key, role) then
        local entry = self.allowed[key]
        if entry and entry.role == "denied" then
            return refuse(connection, "The core has refused this computer.")
        elseif entry and not (NETWORK_ROLES[entry.role] and NETWORK_ROLES[role]) then
            -- Another network's core may wait to be allowed for its second role.
            local may = {
                cell = "be a cell", admin = "manage the network", roam = "carry the network's phones",
                peer = "exchange messages with the network's phones",
            }
            return refuse(connection, ("This computer may %s, but not %s."):format(may[entry.role], may[role]))
        end
        if not self:wait(connection, key, role, id, hello) then return end
    end

    if role == "cell" then return self:serve_cell(connection, key, hello, id) end
    if role == "roam" then return self:serve_partner(connection, key, hello, id) end
    if role == "peer" then return self:serve_peer(connection, key, hello, id) end
    return self:serve_admin(connection, key)
end

-- Keep a computer waiting until it's allowed. Returns whether it was.
function Service:wait(connection, key, role, id, hello)
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
        -- Another network's core says which it is.
        network = NETWORK_ROLES[role] and common.is_network(hello.network) and hello.network or nil,
    }
    self.waiting[key] = entry
    self:log(("%s #%s%s wants %s. Fingerprint %s. Allow it with 'cellcore allow %s'"):format(
        ROLES[role].name, tostring(id or "?"), entry.network and " (" .. entry.network .. ")" or "", ROLES[role].wants,
        fingerprint, tostring(id or fingerprint:sub(1, 9))
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

    local area = common.is_id(hello.area) and hello.area or 0
    local entry = { id = id, key = key, address = peer, area = area, since = self.options.epoch(), connection = connection }
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

-- Tell the core which networks' cells our phones may use: every partner we've allowed, connected now or not, so
-- phones keep hearing of a partner whose core is away for a moment.
function Service:update_partner_keys()
    local keys = {}
    for _, entry in pairs(self.allowed) do
        local signing = has_role(entry, "roam") and entry.network and from_hex(entry.signing)
        if signing and #signing == 32 then keys[entry.network] = { signing = signing, home = entry.home } end
    end
    self.core:set_partner_keys(keys)
end

-- Another network's core, which carries our phones at its cells. To our core, it's a cell.
function Service:serve_partner(connection, key, hello, id)
    local network, signing = hello.network, from_hex(hello.signing)
    if not common.is_network(network) or not signing or #signing ~= 32 or not id then return connection:abort() end
    if network == self.config.network then return refuse(connection, "That's this network's own name.") end
    -- A partner is allowed as one network, and can't come back as another. Nor can two be the same network.
    local known = self.allowed[key]
    if known and known.network and known.network ~= network then
        return refuse(connection, ("This computer was allowed as the core of %s, not of %s."):format(known.network, network))
    end
    for other_key, other in pairs(self.allowed) do
        if other_key ~= key and has_role(other, "roam") and other.network == network then
            return refuse(connection, ("Another computer is the core of %s."):format(network))
        end
    end

    local old = self.partners[network]
    if old then old.connection:abort() end

    local outbox, done = {}, false
    local function send(message)
        outbox[#outbox + 1] = message
        self.options.wake()
    end
    local peer = connection:getPeer()
    local tunnel_key = self.core:add_tower(id, address.parse(peer), send, network)
    if not connection:send({ network = self.config.network, tunnel_key = tunnel_key }) then
        self.core:remove_tower(id, send)
        return connection:abort()
    end

    local entry = { id = id, key = key, network = network, address = peer, since = self.options.epoch(), connection = connection }
    self.partners[network] = entry
    if known and (known.id ~= id or known.network ~= network or known.signing ~= hello.signing:lower()) then
        known.id, known.network, known.signing = id, network, hello.signing:lower()
        self:save_allowed()
    end
    self:update_partner_keys()
    self:log(("%s (core #%d, from %s) now carries this network's phones"):format(network, id, peer))

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
    if self.partners[network] == entry then
        self.partners[network] = nil
        self:log(("Lost the core of %s, which carries this network's phones"):format(network))
    end
end

-- Keep a connection to another network's core: connect, run it, and connect again once it's lost, less often each
-- time. `list` is where it's kept, by network.
function Service:keep_connecting(list, network, core, run)
    local options = self.options
    local entry = { network = network, core = core, state = "connecting" }
    local old = list[network]
    list[network] = entry
    if old and old.connection then old.connection:abort() end
    if not options.connect or not options.sleep then
        entry.state, entry.error = "lost", "This computer can't connect to other cores"
        return entry
    end

    self.tasks:spawn(function()
        local delay = FIRST_DELAY
        while not self.stopped and list[network] == entry do
            entry.state, entry.error = "connecting", nil
            local connected, connection, err = pcall(options.connect, core)
            if not connected then connection, err = nil, tostring(connection) end
            if connection then
                entry.connection = connection
                local ok, reason = pcall(run, self, entry, connection)
                entry.connection = nil
                connection:abort()
                if entry.served then delay, entry.served = FIRST_DELAY, false end
                if not ok then reason = tostring(reason) end
                if entry.state ~= "refused" then entry.state, entry.error = "lost", reason or "Its core closed the connection" end
            else
                entry.state, entry.error = "lost", tostring(err)
            end
            if self.stopped or list[network] ~= entry then return end
            entry.retry = delay
            options.sleep(delay)
            delay = math.min(delay * 2, MAX_DELAY)
        end
    end)
    return entry
end

-- Carry another network's phones: connect to its core, and keep connecting.
function Service:start_carrying(network, core)
    self:keep_connecting(self.carrying, network, core, self.carry)
end

-- Exchange messages with another network's phones: connect to its core, and keep connecting.
function Service:start_peering(network, core, prefix)
    self:keep_connecting(self.peering, network, core, self.exchange).prefix = prefix
end

-- Whether a number prefix is another network's we exchange messages with (or one of its which has connected).
function Service:prefix_taken(prefix, network)
    for other, peer in pairs(self.core.peers) do
        if other ~= network and peer.prefix == prefix then return other end
    end
    for other, links in pairs(self.peer_links) do
        if other ~= network and links[1] and links[1].prefix == prefix then return other end
    end
    return nil
end

-- Stop exchanging messages with a network, unless we still connect to its core, or allow it to connect to ours.
function Service:forget_peer(network)
    if self.peering[network] then return end
    for _, entry in pairs(self.allowed) do
        if entry.network == network and has_role(entry, "peer") then return end
    end
    self.core:forget_peer(network)
end

-- Messages between our phones and another network's, over one connection to its core (either way), until it ends.
-- Returns why it ended.
function Service:peer_link(network, prefix, connection, link)
    local outbox, done = {}, false
    local function send(message)
        outbox[#outbox + 1] = message
        self.options.wake()
    end
    link.network, link.prefix, link.connection = network, prefix, connection
    local links = self.peer_links[network] or {}
    self.peer_links[network] = links
    links[#links + 1] = link
    self.core:add_peer(network, prefix, send)

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
    local reason
    while not done do
        local message, receive_err = connection:receive()
        if message == nil then
            reason = receive_err or "Its core closed the connection"
            break
        end
        local ok, err = pcall(self.core.peer_control, self.core, network, message, send)
        if not ok then self:log("Error: " .. tostring(err)) end
    end
    done = true
    connection:abort()
    self.core:remove_peer(network, send)
    for i, other in ipairs(links) do
        if other == link then
            table.remove(links, i)
            break
        end
    end
    if not links[1] and self.peer_links[network] == links then self.peer_links[network] = nil end
    return reason
end

-- Another network's core, which exchanges messages with ours.
function Service:serve_peer(connection, key, hello, id)
    local network, prefix = hello.network, hello.number_prefix
    if not common.is_network(network) or not is_number_prefix(prefix) or not id then return connection:abort() end
    if network == self.config.network then return refuse(connection, "That's this network's own name.") end
    local own = self.config.number_prefix
    if not own then return refuse(connection, ("%s has no number prefix yet."):format(self.config.network)) end
    if prefix == own then return refuse(connection, ("%s has the number prefix %s too."):format(self.config.network, own)) end
    -- A peer is allowed as one network (the same as it carries our phones as), and two can't be the same network.
    local known = self.allowed[key]
    if known and known.network and known.network ~= network then
        return refuse(connection, ("This computer was allowed as the core of %s, not of %s."):format(known.network, network))
    end
    for other_key, other in pairs(self.allowed) do
        if other_key ~= key and has_role(other, "peer") and other.network == network then
            return refuse(connection, ("Another computer is the core of %s."):format(network))
        end
    end
    local taken = self:prefix_taken(prefix, network)
    if taken then return refuse(connection, ("%s has the number prefix %s already."):format(taken, prefix)) end
    if not connection:send({ network = self.config.network, number_prefix = own }) then return connection:abort() end
    if known and (known.id ~= id or known.network ~= network or known.prefix ~= prefix) then
        known.id, known.network, known.prefix = id, network, prefix
        self:save_allowed()
    end

    local peer = connection:getPeer()
    self:log(("%s (core #%d, from %s) exchanges messages with this network, its numbers starting %s"):format(network, id, peer, prefix))
    self:peer_link(network, prefix, connection, { key = key, address = peer, incoming = true })
    self:log(("Lost the core of %s, which exchanges messages with this network"):format(network))
end

-- One connection to the core of a network we exchange messages with, which we connected to. Returns why it ended.
function Service:exchange(entry, connection)
    local options, network = self.options, entry.network
    local own = self.config.number_prefix
    if not own then
        entry.state, entry.error = "refused", "This network has no number prefix yet: set one with 'cellcore numbers'"
        return
    end
    connection:send({ role = "peer", id = options.id, network = self.config.network, number_prefix = own })
    local reply, err = connection:receive(HELLO_TIMEOUT)
    if type(reply) == "table" and reply.waiting then
        entry.state = "waiting"
        reply, err = connection:receive(WAIT_TIMEOUT + 60)
    end
    if type(reply) == "table" and type(reply.error) == "string" then
        entry.state, entry.error = "refused", reply.error
        return
    end
    if type(reply) ~= "table" or not is_number_prefix(reply.number_prefix) then return err or "Its core didn't answer" end
    if reply.network ~= network then
        entry.state, entry.error = "refused", ("That's the core of %s, not of %s"):format(tostring(reply.network), network)
        return
    end
    if reply.number_prefix == own then
        entry.state, entry.error = "refused", ("%s has the number prefix %s too"):format(network, own)
        return
    end
    local taken = self:prefix_taken(reply.number_prefix, network)
    if taken then
        entry.state, entry.error = "refused", ("%s has the number prefix %s already"):format(taken, reply.number_prefix)
        return
    end

    entry.state, entry.served = "serving", true
    if entry.prefix ~= reply.number_prefix then
        entry.prefix = reply.number_prefix
        self:save_peering()
    end
    self:log(("Exchanging messages with %s, through its core %s, its numbers starting %s"):format(network, entry.core, reply.number_prefix))
    local reason = self:peer_link(network, reply.number_prefix, connection, { address = connection:getPeer() })
    self:log(("Lost the core of %s: messages for its phones wait until it's back"):format(network))
    return reason
end

function Service:save_peering()
    local saved = {}
    for network, entry in pairs(self.peering) do saved[network] = { core = entry.core, prefix = entry.prefix } end
    write_table(self.files.peers, saved)
end

-- One connection to the core of a network whose phones we carry. Returns why it ended.
function Service:carry(entry, connection)
    local options, network = self.options, entry.network
    connection:send({ role = "roam", id = options.id, network = self.config.network, signing = to_hex(options.signing) })
    local reply, err = connection:receive(HELLO_TIMEOUT)
    if type(reply) == "table" and reply.waiting then
        entry.state = "waiting"
        reply, err = connection:receive(WAIT_TIMEOUT + 60)
    end
    if type(reply) == "table" and type(reply.error) == "string" then
        entry.state, entry.error = "refused", reply.error
        return
    end
    if type(reply) ~= "table" or type(reply.tunnel_key) ~= "string" or #reply.tunnel_key ~= 32 then
        return err or "Its core didn't answer"
    end
    if reply.network ~= network then
        entry.state, entry.error = "refused", ("That's the core of %s, not of %s"):format(tostring(reply.network), network)
        return
    end

    local outbox, done = {}, false
    local function send(message)
        outbox[#outbox + 1] = message
        options.wake()
    end
    self.core:add_partner(network, { address = address.parse(connection:getPeer()), tunnel_key = reply.tunnel_key, send = send })
    entry.state, entry.served = "serving", true
    self:log(("Carrying the phones of %s, through its core %s"):format(network, entry.core))

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
    local reason
    while not done do
        local message, receive_err = connection:receive()
        if message == nil then
            reason = receive_err or "Its core closed the connection"
            break
        end
        local ok, control_err = pcall(self.core.partner_control, self.core, network, message)
        if not ok then self:log("Error: " .. tostring(control_err)) end
    end
    done = true
    self.core:remove_partner(network, send)
    self:log(("Lost the core of %s: its phones here have no service"):format(network))
    return reason
end

function Service:save_carrying()
    local saved = {}
    for network, entry in pairs(self.carrying) do saved[network] = { core = entry.core } end
    write_table(self.files.roaming, saved)
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
            -- Asked to stop, or start afresh: once the answer has gone.
            if self.ending then
                local ending = self.ending
                self.ending = nil
                connection:close()
                if self.options.sleep then self.options.sleep(1) end
                return self.options[ending]()
            end
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
        cells = {}, allowed = {}, waiting = {}, subscribers = {}, partners = {}, carrying = {}, peers = {},
        number_prefix = self.config.number_prefix,
    }
    for id, cell in pairs(self.cells) do
        result.cells[#result.cells + 1] = {
            id = id, key = cell.key, address = cell.address, area = cell.area, since = cell.since,
            path = self.core:path_of(id),
        }
    end
    table.sort(result.cells, by_id)
    local peers = {}
    for key, entry in pairs(self.allowed) do
        result.allowed[#result.allowed + 1] = {
            key = key, fingerprint = fingerprint(key), label = entry.label, role = entry.role, id = entry.id,
            network = entry.network,
        }
        for role in pairs(entry.roles or {}) do
            result.allowed[#result.allowed + 1] = {
                key = key, fingerprint = fingerprint(key), label = entry.label, role = role, id = entry.id,
                network = entry.network,
            }
        end
        -- Networks which connect to us to exchange messages.
        if has_role(entry, "peer") and entry.network then peers[entry.network] = { network = entry.network, id = entry.id } end
        -- Networks which carry our phones.
        if has_role(entry, "roam") and entry.network then
            local connected = self.partners[entry.network]
            result.partners[#result.partners + 1] = {
                network = entry.network, id = entry.id, key = key, fingerprint = fingerprint(key), phones = 0,
                connected = connected ~= nil and connected.key == key, address = connected and connected.address or nil,
                home = entry.home == true,
            }
        end
    end
    table.sort(result.partners, function(a, b) return a.network < b.network end)
    -- Networks whose phones we carry.
    local visitors = {}
    for _, visitor in ipairs(self.core:visitor_info()) do visitors[visitor.network] = (visitors[visitor.network] or 0) + 1 end
    for network, entry in pairs(self.carrying) do
        result.carrying[#result.carrying + 1] = {
            network = network, core = entry.core, state = entry.state, error = entry.error, phones = visitors[network] or 0,
        }
    end
    table.sort(result.carrying, function(a, b) return a.network < b.network end)
    -- Networks we exchange messages with: those we connect to, and those which connect to us.
    for network, entry in pairs(self.peering) do
        local peer = peers[network] or { network = network }
        peers[network] = peer
        peer.core, peer.state, peer.error = entry.core, entry.state, entry.error
    end
    local held = self.core:held_info()
    for network, peer in pairs(peers) do
        local links = self.peer_links[network]
        peer.connected = links ~= nil
        peer.prefix = links and links[#links].prefix or (self.core.peers[network] and self.core.peers[network].prefix)
        peer.waiting = held[network] or 0
        result.peers[#result.peers + 1] = peer
    end
    table.sort(result.peers, function(a, b) return a.network < b.network end)
    table.sort(result.allowed, by_id)
    for key, entry in pairs(self.waiting) do
        result.waiting[#result.waiting + 1] = {
            key = key, fingerprint = entry.fingerprint, id = entry.id, role = entry.role, network = entry.network,
            waited = math.floor(self.options.clock() - entry.since),
        }
    end
    table.sort(result.waiting, by_id)

    local sessions = {}
    for _, session in ipairs(self.core:info()) do sessions[session.sim] = session end
    for sim, subscriber in pairs(self.subscribers) do
        local session = sessions[sim]
        local attached = session and session.attached
        result.subscribers[#result.subscribers + 1] = {
            id = subscriber.id, number = subscriber.number, fingerprint = fingerprint(sim),
            address = session and session.address, cell = attached and session.cell or nil,
            roaming = attached and session.roaming or nil, barred = subscriber.barred or nil,
            may_roam = subscriber.roaming ~= false,
        }
        if attached and session.roaming then
            for _, partner in ipairs(result.partners) do
                if partner.network == session.roaming then partner.phones = partner.phones + 1 end
            end
        end
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
    local role = waiting and waiting.role or (ROLES[request.role] and request.role ~= "cell" and request.role)
        or (known and known.role) or "cell"
    local id = waiting and waiting.id or (known and known.id) or (self.allowed[key] and self.allowed[key].id)
    local network = NETWORK_ROLES[role] and ((waiting and waiting.network) or (known and known.network)) or nil
    local names = { cell = "cell", admin = "administrator", roam = "roaming partner", peer = "messaging peer" }

    -- Another network's core, allowed already, gets its second role, as the same network.
    if known and known.role ~= role and NETWORK_ROLES[known.role] and NETWORK_ROLES[role] then
        if known.network and network and known.network ~= network then
            return { error = ("That computer was allowed as the core of %s, not of %s"):format(known.network, network) }
        end
        known.roles = known.roles or {}
        known.roles[role] = true
        known.network = known.network or network
        self:save_allowed()
        self:log(("Allowed %s #%s, %s%s"):format(names[role], tostring(known.id or id or "?"), known.label, self:by(by)))
        self.options.wake()
        return { role = role, id = known.id or id, label = known.label, network = known.network, fingerprint = self.options.fingerprint(key) }
    end
    local label = type(request.label) == "string" and request.label ~= "" and request.label:sub(1, 32)
        or (known and known.label ~= "" and known.label) or network
        or (({ cell = "cell #", admin = "admin #", roam = "partner #", peer = "peer #" })[role] .. tostring(id or "?"))

    self.allowed[key] = {
        label = label, role = role, id = id, network = network, signing = known and known.signing or nil,
        home = known and known.home or nil,
    }
    self:save_allowed()
    self:log(("Allowed %s #%s, %s%s"):format(names[role], tostring(id or "?"), label, self:by(by)))
    self.options.wake()
    return { role = role, id = id, label = label, network = network, fingerprint = self.options.fingerprint(key) }
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
    -- A network which carried our phones no longer does, and they're told its cells aren't for them. One which
    -- exchanged messages with ours no longer does either.
    for _, partner in pairs(self.partners) do
        if partner.key == key then partner.connection:abort() end
    end
    for _, links in pairs(self.peer_links) do
        for _, link in ipairs(links) do
            if link.key == key then link.connection:abort() end
        end
    end
    if known and known.network and has_role(known, "peer") then self:forget_peer(known.network) end
    self:update_partner_keys()
    return { id = id }
end

--- Carry another network's phones at our cells: connect to its core, from now on.
function requests.carry(self, request, by)
    local network, core = request.network, request.core
    if not common.is_network(network) then return { error = "Network names are letters, digits and dashes, up to 32 of them" } end
    if network == self.config.network then return { error = "That's this network" } end
    if type(core) ~= "string" or #core < 1 or #core > 64 or core:find("[^%w%.%-_:]") then
        return { error = "Expected the name or address of the other network's core" }
    end
    self:start_carrying(network, core)
    self:save_carrying()
    self:log(("Set up to carry the phones of %s, through its core %s%s"):format(network, core, self:by(by)))
    -- What the other core's administrator needs, to allow this one.
    return { network = network, core = core, id = self.options.id, fingerprint = self.options.fingerprint(self.options.identity) }
end

--- Stop carrying another network's phones.
function requests.uncarry(self, request, by)
    local entry = type(request.network) == "string" and self.carrying[request.network]
    if not entry then return { error = "This network doesn't carry the phones of " .. tostring(request.network) } end
    self.carrying[request.network] = nil
    if entry.connection then entry.connection:abort() end
    self.core:remove_partner(request.network)
    self:save_carrying()
    self:log(("Stopped carrying the phones of %s%s"):format(request.network, self:by(by)))
    self.options.wake()
    return { network = request.network }
end

--- Say whether our phones treat a partner (a network which carries them) as home.
function requests.partner(self, request, by)
    local network, home = request.network, request.home
    if type(home) ~= "boolean" then return { error = "Expected home to be true or false" } end
    local found
    for _, entry in pairs(self.allowed) do
        if has_role(entry, "roam") and entry.network == network then found = entry end
    end
    if not found then return { error = ("%s doesn't carry this network's phones"):format(tostring(network)) } end
    found.home = home or nil
    self:save_allowed()
    self:update_partner_keys()
    self:log(("%s is %s%s"):format(network, home and "home to this network's phones" or "a roaming partner", self:by(by)))
    return { network = network, home = home }
end

--- Set this network's number prefix, which other networks' phones reach ours by.
function requests.numbers(self, request, by)
    local prefix = request.prefix
    if not is_number_prefix(prefix) then return { error = "Number prefixes are 1 to 8 digits" } end
    local taken = self:prefix_taken(prefix)
    if taken then return { error = ("%s has the number prefix %s"):format(taken, prefix) } end
    -- The file may have changed since the core started (it says whether the core starts with the computer).
    local config = read_table(self.files.config)
    config.number_prefix = prefix
    write_table(self.files.config, config)
    self.config.number_prefix = prefix
    self.core:set_number_prefix(prefix)
    -- Networks we exchange messages with heard the old one when they connected: they connect again.
    for _, links in pairs(self.peer_links) do
        for _, link in ipairs(links) do link.connection:abort() end
    end
    self:log(("This network's numbers now start %s%s"):format(prefix, self:by(by)))
    return { prefix = prefix }
end

--- Exchange messages with another network's phones: connect to its core, from now on.
function requests.peer(self, request, by)
    local network, core = request.network, request.core
    if not common.is_network(network) then return { error = "Network names are letters, digits and dashes, up to 32 of them" } end
    if network == self.config.network then return { error = "That's this network" } end
    if type(core) ~= "string" or #core < 1 or #core > 64 or core:find("[^%w%.%-_:]") then
        return { error = "Expected the name or address of the other network's core" }
    end
    if not self.config.number_prefix then return { error = "Set this network's number prefix first, with 'cellcore numbers'" } end
    self:start_peering(network, core)
    self:save_peering()
    self:log(("Set up to exchange messages with %s, through its core %s%s"):format(network, core, self:by(by)))
    -- What the other core's administrator needs, to allow this one.
    return { network = network, core = core, id = self.options.id, fingerprint = self.options.fingerprint(self.options.identity) }
end

--- Stop connecting to another network's core to exchange messages.
function requests.unpeer(self, request, by)
    local entry = type(request.network) == "string" and self.peering[request.network]
    if not entry then return { error = "This network doesn't connect to the core of " .. tostring(request.network) } end
    self.peering[request.network] = nil
    if entry.connection then entry.connection:abort() end
    self:save_peering()
    self:forget_peer(request.network)
    self:log(("Stopped connecting to the core of %s%s"):format(request.network, self:by(by)))
    self.options.wake()
    return { network = request.network }
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

--- Change a subscriber, found by ID or number: whether they're barred, and whether they may roam.
function requests.set(self, request, by)
    local who = request.subscriber
    if type(who) ~= "string" then return { error = "Expected a subscriber's ID or number" } end
    if request.barred ~= nil and type(request.barred) ~= "boolean" then return { error = "Expected barred to be true or false" } end
    if request.roaming ~= nil and type(request.roaming) ~= "boolean" then return { error = "Expected roaming to be true or false" } end

    local found
    for sim, subscriber in pairs(self.subscribers) do
        if subscriber.id == who or subscriber.number == who then
            found = subscriber
            if request.barred ~= nil then
                subscriber.barred = request.barred or nil
                -- A barred subscriber's phone is cut off, and refused when it tries again.
                if request.barred then self.core:detach(sim) end
            end
            if request.roaming ~= nil then
                -- Only "no" is kept, as roaming is allowed unless it's forbidden. A phone which is roaming now
                -- is cut off, and refused when it tries again from there.
                if request.roaming then subscriber.roaming = nil else subscriber.roaming = false end
                if not request.roaming then
                    for _, session in ipairs(self.core:info()) do
                        if session.sim == sim and session.roaming then self.core:detach(sim) end
                    end
                end
            end
        end
    end
    if not found then return { error = "There's no subscriber " .. who } end
    self:save_subscribers()
    local changes = {}
    if request.barred ~= nil then changes[#changes + 1] = request.barred and "barred" or "no longer barred" end
    if request.roaming ~= nil then changes[#changes + 1] = request.roaming and "may roam" or "may not roam" end
    if #changes > 0 then self:log(("%s: %s%s"):format(who, table.concat(changes, ", "), self:by(by))) end
    return { id = found.id, number = found.number, barred = found.barred == true, roaming = found.roaming ~= false }
end

--- Stop the core, until it's started again on its own computer.
function requests.stop(self, _, by)
    if not self.options.stop then return { error = "This core can't be stopped from here" } end
    self:log("Stopping" .. self:by(by))
    self.ending = "stop"
    return { stopping = true }
end

--- Start the core afresh: cells and phones lose it for a moment, and phones get new addresses.
function requests.restart(self, _, by)
    if not self.options.restart then return { error = "This core can't be started again from here" } end
    self:log("Starting afresh" .. self:by(by))
    self.ending = "restart"
    return { restarting = true }
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
    for _, partner in pairs(self.partners) do partner.connection:abort() end
    for _, entry in pairs(self.carrying) do
        if entry.connection then entry.connection:abort() end
    end
    for _, entry in pairs(self.peering) do
        if entry.connection then entry.connection:abort() end
    end
    for _, links in pairs(self.peer_links) do
        for _, link in ipairs(links) do link.connection:abort() end
    end
    self.waiting, self.cells, self.admins, self.partners, self.carrying = {}, {}, {}, {}, {}
    self.peering, self.peer_links = {}, {}
end

return {
    new = new,
    MAX_WAITING = MAX_WAITING,
    WAIT_TIMEOUT = WAIT_TIMEOUT,
    LOG_SIZE = LOG_SIZE,
}
