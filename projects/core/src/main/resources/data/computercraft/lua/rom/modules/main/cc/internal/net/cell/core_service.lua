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

Every connection starts with a hello, `{ role = "cell", "admin" or "network", id = <computer ID> }`, which the core
answers: `{ waiting = true, fingerprint = ... }` while the computer waits; then the cell's details (for a cell),
`{ ok = true }` (for an administrator) or its own hello (for another network's core); or `{ error = ... }`.
Administrators then send requests, each with an `op`, and get a reply to each: `status`, `allow`, `deny`, `add`,
`remove`, `set`, `log`, `network`, `numbers`, `stop` and `restart`; and `carry`, `uncarry`, `partner`, `peer` and
`unpeer`, as older versions had them, which change agreements as `network` does.

Other networks: for each, an agreement (see [`cc.internal.net.cell.networks`]) says what the two do for each other:
whether we carry its phones at our cells, whether ours may use its cells (roaming there, or as at home), and whether
the two networks' phones exchange messages. One secure connection between the two cores carries all of it, which either
may open: ours does when the agreement says where the other core is. Each core's hello says who it is and what it does
for the other (`carry`, `messages`, and its signing key and number prefix), and each message after says what it's for
(`s`): `home` (for the core of a phone, from the core whose cells it's at), `visited` (the other way), `messages`,
`tunnel` (a phone's core's tunnel key, for the core which carries its phones) and `prefix` (a new number prefix). If both
cores connect at once, the connection opened by the core with the smaller key is kept.

Another network's core waits to be allowed the first time it connects, as a cell does, and allowing it accepts what it
offers. A core we connect to needn't be allowed: being told where it is says we want to.

@local
]]

local address = require "cc.net.address"
local bands = require "cc.internal.net.bands"
local certificate = require "cc.internal.net.certificate"
local common = require "cc.internal.net.cell.common"
local dhcp = require "cc.internal.net.dhcp"
local dns = require "cc.internal.net.dns"
local files = require "cc.internal.net.files"
local networks = require "cc.internal.net.cell.networks"
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
    network = { name = "Network", wants = "an agreement with this network" },
}

local is_number_prefix = common.is_number_prefix

-- What another network's core offers, in words: "to carry this network's phones and exchange messages".
local function offers(asks)
    local parts = {}
    if asks.carry then parts[#parts + 1] = "to carry this network's phones" end
    if asks.messages then parts[#parts + 1] = "to exchange messages with this network's phones" end
    return #parts > 0 and table.concat(parts, " and ") or "an agreement with this network"
end

-- How long to wait before connecting again to another network's core, at first and at most, in seconds.
local FIRST_DELAY, MAX_DELAY = 2, 60

--- How long phones' names last at the DNS server they're registered at, in seconds. They're registered again every
-- half of that, while the core runs.
local HOSTNAME_LIFETIME = 3600

-- A secret to sign updates for a DNS server with: as dnsd.conf can hold it.
local function is_secret(value)
    return type(value) == "string" and #value >= 1 and #value <= 128 and not value:find("[%s#]")
end

-- A DNS server's address, as text: one address, not a network, nor nothing or everyone.
local function server_address(value)
    if type(value) ~= "string" then return nil end
    local addr, prefix = address.parse(value)
    if not addr or prefix or addr == 0 or addr == 0xFFFFFFFF then return nil end
    return address.format(addr)
end

-- Where phones' names are registered, from the config file, if it makes sense: anyone may have edited it.
local function read_hostnames(value)
    if type(value) ~= "table" then return nil end
    local result = {
        server = server_address(value.server),
        zone = common.is_domain(value.zone) and value.zone or nil,
        key = is_secret(value.key) and value.key or nil,
    }
    if not result.server and not result.zone and not result.key then return nil end
    return result
end

local Service = {}
Service.__index = Service

local to_hex, from_hex, is_key = files.hex.encode, files.hex.decode, files.hex.is_key
local read_table, write_table = files.read_table, files.write_table

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
the control port; a way to start the core itself (given the network, the names it had before, prefix, subscribers,
activation codes, and a function told about events); the operator's Ed25519 key and a way to sign with it, for cells' certificates; the time,
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
            cells = fs.combine(options.dir, "cells"), config = fs.combine(options.dir, "config"),
        },
        waiting = {}, cells = {}, standby = {}, admins = {}, lines = {}, line_count = 0,
        -- Other networks: the connection to each one's core, either way; and our tries to connect to those we know
        -- where to find, by network.
        links = {}, dialing = {},
    }, Service)
    self.subscribers = read_table(self.files.subscribers)
    self:read_codes()
    self:read_allowed()

    local listener, err = options.listen()
    if not listener then return nil, "Cannot listen for cells: " .. tostring(err) end

    if config.number_prefix ~= nil and not is_number_prefix(config.number_prefix) then config.number_prefix = nil end
    -- What the file says of DNS, if it makes sense: anyone may have edited it.
    config.dns = common.read_dns(config.dns)
    if not common.is_domain(config.domain) then config.domain = nil end
    config.hostnames = read_hostnames(config.hostnames)
    local ok, core = pcall(options.start_core, {
        network = config.network, prefix = config.prefix, subscribers = self.subscribers, codes = self.codes,
        number_prefix = config.number_prefix, dns = config.dns, domain = config.domain,
        on_event = function(...) self:event(...) end,
        -- The names the network had before it was renamed, which phones may not have heard of yet.
        former = common.former_names(config.former, config.network),
    })
    if not ok then
        listener:close()
        return nil, core
    end
    self.listener, self.core = listener, core

    self.tasks = tasks.new(function(task_err) self:log("Error: " .. tostring(task_err)) end)
    self.tasks:spawn(function() self:accept() end)
    self:log(("Started the core of %s, giving phones addresses in %s"):format(config.network, config.prefix))

    -- Phones' names, registered at a DNS server as they attach, and again before they expire.
    self:start_hostnames()
    if options.sleep then
        self.tasks:spawn(function()
            while true do
                options.sleep(HOSTNAME_LIFETIME / 2)
                self:register_all()
            end
        end)
    end

    -- Agreements with other networks: from older versions' files the first time, which are left as they were.
    local migrated
    self.networks, migrated = networks.read(options.dir, config.network)
    if migrated and next(self.networks) then
        self:save_networks()
        self:log("Made agreements with other networks from the files of an older version")
    end
    self:update_partner_keys()
    for network, agreement in pairs(self.networks) do
        -- Messages for a network we exchange them with wait while its core is away, by the prefix it last had.
        if agreement.messages and agreement.prefix then core:know_peer(network, agreement.prefix) end
        self:dial(network)
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

-- The cells and administrators allowed in, and computers refused, by key: `{ label, role, id }`. Older versions kept
-- only a label, for cells; and other networks' cores here too, which are agreements now (see `networks`).
function Service:read_allowed()
    self.allowed = {}
    for key, entry in pairs(read_table(self.files.cells)) do
        if is_key(key) then
            if type(entry) == "string" then entry = { label = entry, role = "cell" } end
            if type(entry) == "table" and (entry.role == "cell" or entry.role == "admin" or entry.role == "denied") then
                self.allowed[key:lower()] = { label = tostring(entry.label or ""), role = entry.role, id = tonumber(entry.id) }
            end
        end
    end
end

function Service:save_allowed()
    -- What older versions kept here for other networks' cores stays, for a version which still reads it.
    local saved = {}
    for key, entry in pairs(read_table(self.files.cells)) do
        if type(entry) == "table" and (entry.role == "roam" or entry.role == "peer") then saved[key] = entry end
    end
    for key, entry in pairs(self.allowed) do saved[key] = entry end
    write_table(self.files.cells, saved)
end

function Service:save_networks()
    networks.write(self.options.dir, self.networks)
end

function Service:save_subscribers()
    write_table(self.files.subscribers, self.subscribers)
    -- Whatever changed them, the core looks them up afresh.
    if self.core then self.core:subscribers_changed() end
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
        self:log(("%s attached at cell #%s%s, as %s"):format(
            self:subscriber_name(details[1]), common.cell_label(details[3]), details[4] and " of " .. details[4] or "", details[2]
        ))
        self:register(details[1], address.parse(tostring(details[2])))
    elseif event == "detached" then
        self:unregister(details[1])
    elseif event == "visitor" then
        self:log(("A phone of %s attached at cell #%s"):format(tostring(details[1]), common.cell_label(details[2])))
    elseif event == "handover" then
        self:log(("%s moved from cell #%s to #%s"):format(
            self:subscriber_name(details[1]), common.cell_label(details[2]), common.cell_label(details[3])
        ))
    elseif event == "rejected" then
        self:log("Refused a phone which isn't a subscriber")
    elseif event == "activation_failed" then
        self:log("A phone tried a wrong activation code")
    end
    if event == "code_used" or event == "activation_failed" then self:save_codes() end
end

-- Whether a computer may come in, as it asked: another network's core, as the core of that network.
function Service:allows(key, role, network)
    if role == "network" then
        local agreement = self.networks[network]
        return agreement ~= nil and agreement.key == key
    end
    if key == self.options.identity then return true end
    local entry = self.allowed[key]
    return entry ~= nil and entry.role == role
end

-- The network whose core a computer is, if it's one we have an agreement with.
function Service:network_of(key)
    for network, agreement in pairs(self.networks) do
        if agreement.key == key then return network end
    end
    return nil
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
    -- Another network's core says which network it is before anything else, so that what's allowed has a name.
    if role == "network" and not common.is_network(hello.network) then
        return refuse(connection, "Another network's core must say which network it is.")
    end
    if role == "network" and hello.network == self.config.network then
        return refuse(connection, "That's this network's own name.")
    end
    self:note_version(hello.v, ("%s #%s"):format(ROLES[role].name, tostring(id or "?")))
    -- A core we have an agreement with, whose network has another name now: it's the same core, by its key.
    if role == "network" then
        local known = self:network_of(key)
        if known and known ~= hello.network and not self.networks[hello.network] then
            self:rename_network(known, hello.network)
        end
    end

    local entry = self.allowed[key]
    if entry and entry.role == "denied" then return refuse(connection, "The core has refused this computer.") end
    if not self:allows(key, role, hello.network) then
        local may = { cell = "be a cell", admin = "manage the network" }
        local core_of = self:network_of(key)
        if core_of then
            return refuse(connection, ("This computer is the core of %s, not of %s."):format(core_of, tostring(hello.network)))
        elseif entry and role == "network" then
            return refuse(connection, ("This computer may %s, but isn't another network's core."):format(may[entry.role]))
        elseif entry then
            return refuse(connection, ("This computer may %s, but not %s."):format(may[entry.role], may[role]))
        end
        if not self:wait(connection, key, role, id, hello) then return end
    end

    if role == "cell" then return self:serve_cell(connection, key, hello, id) end
    if role == "network" then return self:serve_network(connection, key, hello, id) end
    return self:serve_admin(connection, key)
end

-- Log that a computer speaks a newer version of the cellular network than we do, if it does.
function Service:note_version(version, who)
    if not common.is_newer(version) then return end
    self:log(("%s speaks a newer version of the cellular network (%d) than this core (%d). If they don't work together, update this core's ROM."):format(
        who, version, common.VERSION
    ))
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
    }
    if role == "network" then
        -- Another network's core says which it is (`serve` checked it's a name), and what it offers.
        entry.network = hello.network
        entry.asks = { carry = hello.carry == true, messages = hello.messages == true }
    end
    self.waiting[key] = entry
    self:log(("%s #%s%s wants %s. Fingerprint %s. Allow it with 'cellcore allow %s'"):format(
        ROLES[role].name, tostring(id or "?"), entry.network and " (" .. entry.network .. ")" or "",
        entry.asks and offers(entry.asks) or ROLES[role].wants, fingerprint, tostring(id or fingerprint:sub(1, 9))
    ))
    connection:send({ waiting = true, fingerprint = fingerprint })

    while true do
        -- Replaced by a newer connection, or refused.
        if self.waiting[key] ~= entry then return false end
        if self:allows(key, role, entry.network) then
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

--[[- The carriers this network's cells use, by their beacon channels: those its administrator chose (`cellcore
spectrum`, or the menu). A network has none until some are chosen, and its cells stay off the air until then. It may
have more than any one site serves: each site's cells go on those it asks for.

@treturn { number... } The carriers.
]]
function Service:spectrum()
    local list = {}
    for _, carrier in ipairs(type(self.config.spectrum) == "table" and self.config.spectrum or {}) do
        if common.is_id(carrier) and bands.carrier(carrier) and #list < common.MAX_SPECTRUM then list[#list + 1] = carrier end
    end
    return list
end

--- How often this network's cells send system information, in seconds.
--
-- @treturn number The interval.
function Service:beacon_interval()
    local interval = self.config.beacon_interval
    return common.is_interval(interval) and interval or common.DEFAULT_INTERVAL
end

-- Whether a carrier and an uplink channel, as a cell says it has them, go together.
local function is_placed(carrier, ul)
    return common.is_id(carrier) and bands.carrier(carrier) ~= nil and common.is_uplink(ul) and bands.carrier_of(ul) == carrier
end

--[[- Read what a cell's computer asks for in its hello: the carriers its cells are on already, and what it wants.

@tparam table hello The hello.
@treturn[1] { { carrier = number, ul = number }... } The cells it has: on the air already, for another network it
serves.
@treturn[1] { string... }|false What it wants, each a band (`"b20"`: any of our carriers there) or a carrier
(`"b3/2"`); or `false` for the cells it has, or else one cell on any carrier.
@treturn[2] nil If what it asks for makes no sense.
@treturn[2] string Why not.
]]
local function read_wanted(hello)
    local has = {}
    if type(hello.cells) == "table" then
        -- A computer's first cell is first, and no two of its cells share a carrier.
        local seen = {}
        for i = 1, common.MAX_CARRIERS do
            local cell = hello.cells[i]
            if cell == nil then break end
            if type(cell) ~= "table" or not is_placed(cell.carrier, cell.ul) or seen[cell.carrier] then
                return nil, "The cell's carriers can't be used"
            end
            seen[cell.carrier] = true
            has[i] = { carrier = cell.carrier, ul = cell.ul }
        end
    elseif is_placed(hello.carrier, hello.ul) then
        has[1] = { carrier = hello.carrier, ul = hello.ul }
    end

    if hello.bands ~= nil then
        if not common.is_wants(hello.bands) then return nil, "There are no cellular bands like those the cell asks for" end
        return has, hello.bands
    elseif hello.band ~= nil then
        -- A cell which names one band (an older one, or one which wants no more) keeps the carrier it has.
        if not common.is_wants({ hello.band }) or common.want_carrier(hello.band) then
            return nil, "There's no cellular band called " .. tostring(hello.band)
        end
        if not has[1] then return has, { hello.band } end
    end
    return has, false
end

--[[- Put a computer's cells on carriers, and give each its own uplink channel.

Cells which already have a carrier, as they serve another network on it, keep it. Each other thing the computer wants
gets one of this network's carriers: the one it names, or whichever of the band's has fewest cells, and none of this
computer's yet. A cell's uplink channel is the first on its carrier which no other cell connected now uses. What
there's no carrier for is left out, and said.

A computer whose administrator overrode what its networks offer (`override` in its hello) may have cells on carriers
which aren't this network's: what it wants that this network has no carrier for goes on the carrier it names, or on
whichever of the band's has fewest cells.

@tparam number id The computer's ID.
@tparam table hello What it said: the `bands` (or `band`) it wants, the `cells` (or `carrier` and `ul`) it has, and
whether it may `override` this network's carriers.
@treturn[1] { { id = number, carrier = number, ul = number }... } Its cells: the first has the computer's ID. None, if
there's no carrier for anything it wants: it waits until there is one.
@treturn[1] { string... } What it wanted which we've no carrier for.
@treturn[2] nil If what it asks for makes no sense.
@treturn[2] string Why not.
]]
function Service:place_cells(id, hello)
    local has, wants = read_wanted(hello)
    if not has then return nil, wants end

    -- How many cells of other computers are on each carrier, and the uplink channels they use.
    local count, used = {}, {}
    for other, entry in pairs(self.cells) do
        if other ~= id then
            for _, cell in ipairs(entry.cells) do
                count[cell.carrier] = (count[cell.carrier] or 0) + 1
                used[cell.ul] = true
            end
        end
    end

    local cells, taken = {}, {}
    local function add(carrier, ul)
        if not ul then
            local uplink = bands.carrier(carrier).uplink
            ul = uplink[1]
            for channel = uplink[1], uplink[2] do
                if not used[channel] then
                    ul = channel
                    break
                end
            end
        end
        taken[carrier] = true
        cells[#cells + 1] = { id = cells[1] and common.carrier_cell(id, carrier) or id, carrier = carrier, ul = ul }
    end
    local on = {}
    for i, cell in ipairs(has) do
        add(cell.carrier, cell.ul)
        on[i] = cell.carrier
    end

    -- Carriers this computer has no cell on yet, those with fewest cells first: so each want gets the emptiest.
    local function free_of(carriers)
        local free = {}
        for i, carrier in ipairs(carriers) do
            if not taken[carrier] then free[#free + 1] = { carrier = carrier, count = count[carrier] or 0, order = i } end
        end
        table.sort(free, function(a, b)
            if a.count ~= b.count then return a.count < b.count end
            return a.order < b.order
        end)
        for i, entry in ipairs(free) do free[i] = entry.carrier end
        return free
    end
    local free = free_of(self:spectrum())

    local unplaced = {}
    if wants then
        -- What it has answers what it wants, one for one. The rest go on our carriers.
        local answered = common.match_wants(wants, on)
        local rest = {}
        for i, want in ipairs(wants) do
            if not answered[i] then rest[#rest + 1] = want end
        end
        local placed = common.match_wants(rest, free)
        for i, want in ipairs(rest) do
            if placed[i] then add(placed[i]) else unplaced[#unplaced + 1] = want end
        end
        -- And what's left on any carrier at all, for a computer which may override ours.
        if hello.override == true and unplaced[1] then
            rest, unplaced = unplaced, {}
            placed = common.match_wants(rest, free_of(bands.beacon_channels()))
            for i, want in ipairs(rest) do
                if placed[i] then add(placed[i]) else unplaced[#unplaced + 1] = want end
            end
        end
    elseif not cells[1] and free[1] then
        -- A computer which doesn't say gets one cell, on any carrier.
        add(free[1])
    end
    return cells, unplaced
end

--- Why a computer has no cell: what it wants that this network has no carrier for, in words.
--
-- @tparam { string... } unplaced What it wants, as [`Service:place_cells`] left it out.
-- @treturn string Why.
function Service:no_carrier(unplaced)
    local want = unplaced[1]
    if not self:spectrum()[1] then return ("%s has no carriers yet"):format(self.config.network) end
    if common.want_carrier(want) then return ("%s doesn't use the carrier %s"):format(self.config.network, want) end
    if want then return ("%s has no carrier in band %s"):format(self.config.network, tostring(want)) end
    return ("%s has no carrier for it"):format(self.config.network)
end

-- A computer which was let in as a cell, but has none: it stands by, as whoever sets it up hasn't said which bands it
-- should use yet; or this network has no carrier for what it wants (`unplaced`). It's told the network's carriers, to
-- choose from (and when they change, so it can try again), and shown to the administrator.
function Service:serve_standby(connection, key, id, unplaced)
    local old = self.standby[id]
    if old then old.connection:abort() end
    -- A computer which stands by runs no cell: one it ran before, on another connection, has gone.
    if self.cells[id] then self.cells[id].connection:abort() end
    local send, stop_sending = self.tasks:sender(connection, self.options.wake)
    local entry = {
        id = id, key = key, address = connection:getPeer(), since = self.options.epoch(), connection = connection,
        send = send, unplaced = unplaced,
    }
    if not connection:send({
        v = common.VERSION, network = self.config.network, standby = true, interval = self:beacon_interval(),
        carriers = self:spectrum(), unplaced = unplaced and unplaced[1] and unplaced or nil,
    }) then
        stop_sending()
        return connection:abort()
    end
    self.standby[id] = entry
    local known = self.allowed[key]
    if known and known.id ~= id then
        known.id = id
        self:save_allowed()
    end
    if unplaced then
        self:log(("Cell #%d is off the air, from %s: %s"):format(id, entry.address, self:no_carrier(unplaced)))
    else
        self:log(("Cell #%d is standing by, from %s, until its bands are chosen"):format(id, entry.address))
    end
    while connection:receive() ~= nil do end
    stop_sending()
    connection:abort()
    if self.standby[id] == entry then self.standby[id] = nil end
end

function Service:serve_cell(connection, key, hello, id)
    local signing = from_hex(hello.signing)
    if not signing or #signing ~= 32 or not id then return connection:abort() end
    if hello.standby == true then return self:serve_standby(connection, key, id) end
    local cells, unplaced = self:place_cells(id, hello)
    if not cells then return refuse(connection, unplaced) end
    -- Nothing it wants has a carrier here: it waits, off the air, until one does.
    if not cells[1] then return self:serve_standby(connection, key, id, unplaced) end
    -- It's no longer standing by, if it was.
    if self.standby[id] then self.standby[id].connection:abort() end

    -- A cell which connects again (it restarted, or lost its connection) replaces its old connection.
    local old = self.cells[id]
    if old then old.connection:abort() end

    -- The core sends control messages from inside the network stack, where nothing may wait: queue them.
    local send, stop_sending = self.tasks:sender(connection, self.options.wake)
    local peer = connection:getPeer()
    local network, expires = self.config.network, self.options.epoch() + CERTIFICATE_LIFETIME
    -- Each of the computer's cells is a cell of its own to the core, with its own certificate and tunnel. They share
    -- the connection: each message says which cell it's about.
    local welcome_cells = {}
    for i, cell in ipairs(cells) do
        local cell_id = cell.id
        -- Its first cell's messages don't say so: a computer with one cell needn't know of any of this.
        cell.send = cell_id == id and send or function(message)
            message.at = cell_id
            return send(message)
        end
        local cert = certificate.encode(certificate.issue {
            name = common.cell_name(network, cell_id), key = signing, expires = expires,
            issuer = self.options.signing, sign = self.options.sign,
        })
        local tunnel_key = self.core:add_tower(cell_id, address.parse(peer), cell.send)
        welcome_cells[i] = { id = cell_id, carrier = cell.carrier, ul = cell.ul, certificate = cert, tunnel_key = tunnel_key }
    end
    local function remove_towers()
        for _, cell in ipairs(cells) do self.core:remove_tower(cell.id, cell.send) end
    end
    -- The first cell's are said as they were when a computer ran one cell, for a cell which knows no better.
    local welcome = {
        v = common.VERSION, network = network, certificate = welcome_cells[1].certificate,
        tunnel_key = welcome_cells[1].tunnel_key, carrier = cells[1].carrier, ul = cells[1].ul,
        interval = self:beacon_interval(), carriers = self:spectrum(),
        cells = welcome_cells, unplaced = unplaced[1] and unplaced or nil,
    }
    if not connection:send(welcome) then
        remove_towers()
        return connection:abort()
    end

    local area = common.is_id(hello.area) and hello.area or 0
    local entry = {
        id = id, key = key, address = peer, area = area, since = self.options.epoch(), connection = connection,
        carrier = cells[1].carrier, ul = cells[1].ul, cells = cells,
    }
    self.cells[id] = entry
    local known = self.allowed[key]
    if known and known.id ~= id then
        known.id = id
        self:save_allowed()
    end
    local names, ours_too, outside = {}, {}, {}
    for _, carrier in ipairs(self:spectrum()) do ours_too[carrier] = true end
    for i, cell in ipairs(cells) do
        names[i] = bands.carrier_name(cell.carrier)
        if not ours_too[cell.carrier] then outside[#outside + 1] = names[i] end
    end
    self:log(("Cell #%d connected, from %s, on %s%s"):format(
        id, peer, table.concat(names, " and "),
        outside[1] and (" (not this network's: %s)"):format(table.concat(outside, ", ")) or ""
    ))

    local ours = {}
    for _, cell in ipairs(cells) do ours[cell.id] = true end
    while true do
        local message = connection:receive()
        if message == nil then break end
        -- Which of the computer's cells it's about: its first, if it doesn't say.
        local at = type(message) == "table" and message.at
        if at == nil then at = id end
        if ours[at] then
            local ok, err = pcall(self.core.control, self.core, at, message)
            if not ok then self:log("Error: " .. tostring(err)) end
        end
    end
    stop_sending()
    connection:abort()
    remove_towers()
    if self.cells[id] == entry then
        self.cells[id] = nil
        self:log(("Cell #%d disconnected"):format(id))
    end
end

--- Send a control message to every cell connected now: each computer's every cell, and those which stand by.
--
-- @tparam table message The message. Each cell gets a copy.
function Service:tell_cells(message)
    for _, entry in pairs(self.standby) do
        local copy = {}
        for k, v in pairs(message) do copy[k] = v end
        entry.send(copy)
    end
    for _, entry in pairs(self.cells) do
        for _, cell in ipairs(entry.cells) do
            local copy = {}
            for k, v in pairs(message) do copy[k] = v end
            self.core:send(cell.id, copy)
        end
    end
end

-- Tell the core which networks' cells our phones may use: every network whose cells our agreements let them use, its
-- core connected now or not, so phones keep hearing of a partner whose core is away for a moment.
function Service:update_partner_keys()
    local keys = {}
    for network, agreement in pairs(self.networks) do
        local signing = agreement.roam and from_hex(agreement.signing)
        if signing and #signing == 32 then keys[network] = { signing = signing, home = agreement.roam == "home" } end
    end
    self.core:set_partner_keys(keys)
end

-- Our hello to another network's core: who we are, and what we do for it.
function Service:network_hello(agreement)
    return {
        role = "network", v = common.VERSION, id = self.options.id, network = self.config.network,
        signing = to_hex(self.options.signing), number_prefix = self.config.number_prefix,
        carry = agreement.carry, messages = agreement.messages,
        -- The names our network had before: its phones may still attach by one, where the other network carries them.
        former = common.former_names(self.config.former, self.config.network),
    }
end

-- Whether a number prefix is another network's (one we have an agreement with).
function Service:prefix_taken(prefix, network)
    for other, agreement in pairs(self.networks) do
        if other ~= network and agreement.prefix == prefix then return other end
    end
    return nil
end

-- Keep a connection to another network's core, if we know where it is: connect, and connect again once it's lost,
-- less often each time. While its core is connected to ours, the other way, there's nothing to do.
function Service:dial(network)
    local options = self.options
    local old = self.dialing[network]
    if old and old.connection then old.connection:abort() end
    local agreement = self.networks[network]
    if not agreement or not agreement.core or not (agreement.carry or agreement.roam or agreement.messages) then
        self.dialing[network] = nil
        return
    end
    local entry = { network = network, core = agreement.core, state = "connecting" }
    self.dialing[network] = entry
    if not options.connect or not options.sleep then
        entry.state, entry.error = "lost", "This computer can't connect to other cores"
        return
    end

    self.tasks:spawn(function()
        local delay = FIRST_DELAY
        while not self.stopped and self.dialing[network] == entry do
            if self.links[network] then
                entry.state, entry.error, entry.retry, delay = "connected", nil, nil, FIRST_DELAY
                options.sleep(1)
            else
                entry.state, entry.error = "connecting", nil
                local connected, connection, err = pcall(options.connect, entry.core)
                if not connected then connection, err = nil, tostring(connection) end
                if connection then
                    entry.connection = connection
                    local ok, reason = pcall(self.call, self, entry, connection)
                    entry.connection = nil
                    connection:abort()
                    if entry.served then delay, entry.served = FIRST_DELAY, false end
                    if not ok then reason = tostring(reason) end
                    if entry.state ~= "refused" then entry.state, entry.error = "lost", reason or "Its core closed the connection" end
                else
                    entry.state, entry.error = "lost", tostring(err)
                end
                if self.stopped or self.dialing[network] ~= entry then return end
                if not self.links[network] then
                    entry.retry = delay
                    options.sleep(delay)
                    delay = math.min(delay * 2, MAX_DELAY)
                end
            end
        end
    end)
end

-- Our connection to another network's core: say hello, and wait for its. Returns why it ended.
function Service:call(entry, connection)
    local network = entry.network
    local agreement = self.networks[network]
    if not agreement then return "There's no agreement with " .. network end
    connection:send(self:network_hello(agreement))
    local reply, err = connection:receive(HELLO_TIMEOUT)
    if type(reply) == "table" and reply.waiting then
        entry.state = "waiting"
        reply, err = connection:receive(WAIT_TIMEOUT + 60)
    end
    if type(reply) == "table" then self:note_version(reply.v, "The core of " .. network) end
    if type(reply) == "table" and type(reply.error) == "string" then
        entry.state, entry.error = "refused", reply.error
        return
    end
    if type(reply) ~= "table" or reply.role ~= "network" then return err or "Its core didn't answer" end
    if reply.network ~= network then
        -- The core we met before, by its key, whose network has another name now: the agreement is with that one,
        -- and it's connected to afresh under its name.
        if agreement.key and agreement.key == connection:getPeerKey() and common.is_network(reply.network)
            and reply.network ~= self.config.network and not self.networks[reply.network] then
            self:rename_network(network, reply.network)
            return ("%s is called %s now"):format(network, reply.network)
        end
        entry.state, entry.error = "refused", ("That's the core of %s, not of %s"):format(tostring(reply.network), network)
        return
    end
    -- The core we were told where to find: met before, it must be the same one, and met now, it's this one from now on.
    local key = connection:getPeerKey()
    if agreement.key and agreement.key ~= key then
        entry.state, entry.error = "refused", ("That isn't the core of %s met before: its key has changed. If it should have, run 'cellcore network %s forget' and set the agreement up again"):format(network, network)
        return
    end
    if not agreement.key then
        agreement.key = key
        self:save_networks()
    end
    entry.state, entry.served = "connected", true
    return self:run_link(network, connection, reply, { key = key, dialer = self.options.identity })
end

-- Another network's core has connected to ours, and is allowed.
function Service:serve_network(connection, key, hello, id)
    local network = hello.network
    local agreement = self.networks[network]
    if not agreement or not id then return connection:abort() end
    if not connection:send(self:network_hello(agreement)) then return connection:abort() end
    self:run_link(network, connection, hello, { key = key, dialer = key })
end

--[[ The one connection between our core and another network's, either way, once both have said hello: everything the
two networks do for each other goes over it, until it ends. Returns why it ended.

`other` is the other core's hello, and `link` says who it is (`key`) and which core connected (`dialer`, its key).
]]
function Service:run_link(network, connection, other, link)
    local agreement = self.networks[network]
    if not agreement then return "There's no agreement with " .. network end

    -- If both cores connected at once, the connection opened by the core with the smaller key is kept, by both.
    local current = self.links[network]
    if current then
        if current.dialer <= link.dialer then
            connection:abort()
            return "Connected already"
        end
        current.connection:abort()
    end
    link.connection, link.address = connection, connection:getPeer()
    self.links[network] = link

    -- What the other core says of itself.
    local changed = false
    local id = common.is_id(other.id) and other.id < 2 ^ 31 and other.id or agreement.id
    if id ~= agreement.id then agreement.id, changed = id, true end
    local signing = is_key(other.signing) and other.signing:lower() or nil
    if signing and signing ~= agreement.signing then agreement.signing, changed = signing, true end
    local prefix = is_number_prefix(other.number_prefix) and other.number_prefix ~= self.config.number_prefix
        and not self:prefix_taken(other.number_prefix, network) and other.number_prefix or nil
    if prefix and prefix ~= agreement.prefix then agreement.prefix, changed = prefix, true end
    -- The names it had before, which its phones may still attach by: but none which is ours, or another network's.
    local former = {}
    for _, name in ipairs(common.former_names(other.former, network)) do
        if name ~= self.config.network and not self.networks[name] then former[#former + 1] = name end
    end
    if table.concat(former, " ") ~= table.concat(agreement.former or {}, " ") then
        agreement.former, changed = former[1] and former or nil, true
    end
    if changed then
        self:save_networks()
        self:update_partner_keys()
    end
    if not id then
        if self.links[network] == link then self.links[network] = nil end
        return "Its core didn't say which computer it is"
    end
    link.id, link.wants_messages = id, other.messages == true

    local send, stop_sending = self.tasks:sender(connection, self.options.wake)
    link.send = send
    local function to(service) return function(message) send({ s = service, m = message }) end end
    local to_visited, to_home, to_messages = to("visited"), to("home"), to("messages")
    local peer_address = address.parse(link.address)
    local done = {}
    self:log(("Connected to %s's core #%d, at %s"):format(network, id, link.address))

    -- It carries our phones, and our agreement lets them use its cells: to our core, it's a cell. Its core gets our
    -- tunnel's key.
    if other.carry == true and agreement.roam then
        local tunnel_key = self.core:add_tower(id, peer_address, to_visited, network)
        link.tower = true
        send({ s = "tunnel", key = tunnel_key })
        self:log(("%s carries this network's phones%s"):format(network, agreement.roam == "home" and ", as home" or ""))
    end
    -- Messages, if both networks want them, and both have number prefixes.
    local function start_messages(peer_prefix)
        if other.messages == true and agreement.messages and self.config.number_prefix and peer_prefix then
            self.core:add_peer(network, peer_prefix, to_messages)
            link.peer = true
        end
    end
    start_messages(agreement.prefix)
    if link.peer then self:log(("Exchanging messages with %s, its numbers starting %s"):format(network, agreement.prefix)) end

    local reason
    while true do
        local message, receive_err = connection:receive()
        if message == nil then
            reason = receive_err or "Its core closed the connection"
            break
        end
        if type(message) == "table" then
            local service, inner = message.s, message.m
            local ok, err = true, nil
            if service == "home" and link.tower then
                ok, err = pcall(self.core.control, self.core, id, inner)
            elseif service == "visited" and link.partner then
                ok, err = pcall(self.core.partner_control, self.core, network, inner)
            elseif service == "messages" and link.peer then
                ok, err = pcall(self.core.peer_control, self.core, network, inner, to_messages)
            elseif service == "tunnel" and agreement.carry and not link.partner
                and type(message.key) == "string" and #message.key == 32 then
                -- We carry its phones: our core is one big cell to its.
                self.core:add_partner(network, {
                    address = peer_address, tunnel_key = message.key, send = to_home, former = agreement.former,
                })
                link.partner = true
                self:log(("Carrying the phones of %s"):format(network))
            elseif service == "prefix" and is_number_prefix(message.prefix) and message.prefix ~= self.config.number_prefix
                and not self:prefix_taken(message.prefix, network) and message.prefix ~= agreement.prefix then
                -- Its numbers start differently now.
                agreement.prefix = message.prefix
                self:save_networks()
                if link.peer then self.core:remove_peer(network, to_messages) end
                link.peer = false
                start_messages(message.prefix)
                self:log(("%s's numbers now start %s"):format(network, message.prefix))
            end
            if not ok and not done[err] then
                done[err] = true
                self:log("Error: " .. tostring(err))
            end
        end
    end

    stop_sending()
    connection:abort()
    if link.tower then self.core:remove_tower(id, to_visited) end
    if link.partner then self.core:remove_partner(network, to_home) end
    if link.peer then self.core:remove_peer(network, to_messages) end
    if self.links[network] == link then
        self.links[network] = nil
        self:log(("Lost %s's core: %s"):format(network, tostring(reason)))
    end
    return reason
end

--[[- Another network has a new name: its core, which we know by its key, says so. The agreement with it is kept under
the new name, and so is what waits for its phones; the connection between the cores is made again.

@tparam string old The name it had.
@tparam string new The name it has now, which no other agreement is under.
]]
function Service:rename_network(old, new)
    local agreement = self.networks[old]
    if not agreement or self.networks[new] or new == self.config.network then return end
    self.networks[old], self.networks[new] = nil, agreement
    local link, dialing = self.links[old], self.dialing[old]
    if link then link.connection:abort() end
    self.dialing[old] = nil
    if dialing and dialing.connection then dialing.connection:abort() end
    self.core:rename_peer(old, new)
    self:save_networks()
    self:log(("%s is called %s now: the agreement with it is kept"):format(old, new))
    self:agreement_changed(new)
end

-- Forget what a network's core was doing for ours, now its agreement has changed: drop the connection, which is made
-- again (by whichever core knows where the other is) with what's agreed now. Messages for it wait if they're agreed.
function Service:agreement_changed(network)
    local agreement = self.networks[network]
    local link = self.links[network]
    if link then link.connection:abort() end
    if agreement and agreement.messages and agreement.prefix then
        self.core:know_peer(network, agreement.prefix)
    else
        self.core:forget_peer(network)
    end
    self:update_partner_keys()
    self:dial(network)
    self.options.wake()
end

local requests = {}

function Service:serve_admin(connection, key)
    self.admins[connection] = key
    if connection:send({ ok = true, v = common.VERSION, network = self.config.network }) then
        while true do
            local request = connection:receive(ADMIN_TIMEOUT)
            if type(request) ~= "table" then break end
            if not connection:send(self:request(request, key)) then break end
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

--[[- Answer an administrator's request, as one sent over a connection is answered.

@tparam table request The request, with its `op`.
@tparam[opt] string by The key of whoever asked, as hexadecimal digits: by default, this computer's.
@treturn table The reply: what was asked for, or `error`.
]]
function Service:request(request, by)
    by = by or self.options.identity
    local handler = requests[request.op]
    if not handler then return { error = "Unknown request " .. tostring(request.op) } end
    local ok, reply = pcall(handler, self, request, by)
    if not ok then return { error = tostring(reply) } end
    return reply
end

local function by_id(a, b)
    if a.id ~= b.id then return (a.id or -1) < (b.id or -1) end
    return a.key < b.key
end

--- Everything about the network: its cells, the computers allowed in and waiting, other networks, and the subscribers.
function requests.status(self)
    local fingerprint, now = self.options.fingerprint, self.options.epoch()
    local result = {
        network = self.config.network, prefix = self.config.prefix, messages = #self.core.messages, codes = 0,
        cells = {}, allowed = {}, waiting = {}, subscribers = {}, networks = {},
        number_prefix = self.config.number_prefix, interval = self:beacon_interval(),
        dns = self.config.dns or {}, domain = self.config.domain,
        hostnames = self.config.hostnames and {
            server = self.config.hostnames.server, zone = self.config.hostnames.zone,
            key = self.config.hostnames.key ~= nil, registering = self.hostnames and self.hostnames.zone,
        },
    }
    local spectrum, ours = self:spectrum(), {}
    result.spectrum = {}
    for i, carrier in ipairs(spectrum) do result.spectrum[i], ours[carrier] = bands.carrier_name(carrier), true end
    for id, cell in pairs(self.cells) do
        -- Each carrier the computer has a cell on, its first cell's first: and whether it's one of ours (a cell which
        -- serves another network too, or whose administrator overrode ours, may be on another).
        local carriers = {}
        for i, each in ipairs(cell.cells) do
            carriers[i] = {
                id = each.id, carrier = bands.carrier_name(each.carrier), ul = each.ul,
                outside = not ours[each.carrier] or nil,
            }
        end
        result.cells[#result.cells + 1] = {
            id = id, key = cell.key, address = cell.address, area = cell.area, since = cell.since,
            path = self.core:path_of(id), carrier = cell.carrier and bands.carrier_name(cell.carrier), ul = cell.ul,
            carriers = carriers,
        }
    end
    table.sort(result.cells, by_id)
    -- Computers let in as cells which are off the air: they stand by until their bands are chosen, or we've no carrier
    -- for what they want (`unplaced`, and `reason`).
    result.standby = {}
    for id, entry in pairs(self.standby) do
        result.standby[#result.standby + 1] = {
            id = id, key = entry.key, address = entry.address, since = entry.since,
            unplaced = entry.unplaced, reason = entry.unplaced and self:no_carrier(entry.unplaced) or nil,
        }
    end
    table.sort(result.standby, by_id)
    for key, entry in pairs(self.allowed) do
        result.allowed[#result.allowed + 1] = {
            key = key, fingerprint = fingerprint(key), label = entry.label, role = entry.role, id = entry.id,
        }
    end
    table.sort(result.allowed, by_id)
    for key, entry in pairs(self.waiting) do
        result.waiting[#result.waiting + 1] = {
            key = key, fingerprint = entry.fingerprint, id = entry.id, role = entry.role, network = entry.network,
            asks = entry.asks, waited = math.floor(self.options.clock() - entry.since),
        }
    end
    table.sort(result.waiting, by_id)

    -- Other networks: what's agreed, and how it's going.
    local here, there = {}, {}
    for _, visitor in ipairs(self.core:visitor_info()) do here[visitor.network] = (here[visitor.network] or 0) + 1 end
    local sessions = {}
    for _, session in ipairs(self.core:info()) do
        sessions[session.sim] = session
        if session.attached and session.roaming then there[session.roaming] = (there[session.roaming] or 0) + 1 end
    end
    local held = self.core:held_info()
    for network, agreement in pairs(self.networks) do
        local link, dialing = self.links[network], self.dialing[network]
        result.networks[#result.networks + 1] = {
            network = network, key = agreement.key, fingerprint = agreement.key and fingerprint(agreement.key) or nil,
            id = agreement.id, label = agreement.label, core = agreement.core, prefix = agreement.prefix,
            carry = agreement.carry, roam = agreement.roam, messages = agreement.messages,
            connected = link ~= nil, address = link and link.address or nil,
            state = dialing and dialing.state or nil, error = dialing and dialing.error or nil,
            retry = dialing and dialing.retry or nil,
            -- What's under way: its phones here, ours there, and messages for its phones waiting.
            carrying = link ~= nil and link.partner == true, carried = link ~= nil and link.tower == true,
            messaging = link ~= nil and link.peer == true,
            visitors = here[network] or 0, phones = there[network] or 0, waiting = held[network] or 0,
        }
    end
    table.sort(result.networks, function(a, b) return a.network < b.network end)

    for sim, subscriber in pairs(self.subscribers) do
        local session = sessions[sim]
        local attached = session and session.attached
        result.subscribers[#result.subscribers + 1] = {
            id = subscriber.id, number = subscriber.number, fingerprint = is_key(sim) and fingerprint(sim) or nil,
            address = session and session.address, cell = attached and session.cell or nil,
            roaming = attached and session.roaming or nil, barred = subscriber.barred or nil,
            may_roam = subscriber.roaming ~= false,
            range = type(subscriber.range) == "string" and subscriber.range or nil,
            subnet = type(subscriber.subnet) == "string" and subscriber.subnet or nil,
        }
    end
    table.sort(result.subscribers, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _, code in pairs(self.codes) do
        if type(code.expires) == "number" and code.expires >= now then result.codes = result.codes + 1 end
    end
    return result
end

--- Allow a computer in, by its key: as a cell or administrator, or as another network's core, accepting what it
-- offered.
function requests.allow(self, request, by)
    local key = is_key(request.key) and request.key:lower()
    if not key then return { error = "Expected a key, of 64 hexadecimal digits" } end

    local waiting, known = self.waiting[key], self.allowed[key]
    if known and known.role == "denied" then known = nil end

    -- Another network's core: the agreement is made, with what it offered.
    if waiting and waiting.role == "network" then
        local network = waiting.network
        local core_of = self:network_of(key)
        if core_of and core_of ~= network then
            return { error = ("That computer is the core of %s, not of %s"):format(core_of, network) }
        end
        local agreement = self.networks[network] or networks.empty()
        self.networks[network] = agreement
        agreement.key, agreement.id = key, waiting.id or agreement.id
        agreement.label = type(request.label) == "string" and request.label ~= "" and request.label:sub(1, 32) or agreement.label
        if waiting.asks.carry and not agreement.roam then agreement.roam = "partner" end
        if waiting.asks.messages then agreement.messages = true end
        -- Allowing it again lifts a refusal.
        if self.allowed[key] and self.allowed[key].role == "denied" then
            self.allowed[key] = nil
            self:save_allowed()
        end
        self:save_networks()
        self:update_partner_keys()
        self:log(("Allowed the core of %s (#%s), %s%s"):format(network, tostring(agreement.id or "?"), offers(waiting.asks), self:by(by)))
        self.options.wake()
        return {
            role = "network", network = network, id = agreement.id, label = agreement.label or network,
            fingerprint = self.options.fingerprint(key), roam = agreement.roam, messages = agreement.messages,
        }
    end

    local role = waiting and waiting.role or (ROLES[request.role] and request.role ~= "cell" and request.role ~= "network" and request.role)
        or (known and known.role) or "cell"
    local id = waiting and waiting.id or (known and known.id) or (self.allowed[key] and self.allowed[key].id)
    local names = { cell = "cell", admin = "administrator" }
    local label = type(request.label) == "string" and request.label ~= "" and request.label:sub(1, 32)
        or (known and known.label ~= "" and known.label)
        or (({ cell = "cell #", admin = "admin #" })[role] .. tostring(id or "?"))

    self.allowed[key] = { label = label, role = role, id = id }
    self:save_allowed()
    self:log(("Allowed %s #%s, %s%s"):format(names[role], tostring(id or "?"), label, self:by(by)))
    self.options.wake()
    return { role = role, id = id, label = label, fingerprint = self.options.fingerprint(key) }
end

--- Refuse a computer, by its key, from now on. Any connections it has are dropped. For another network's core, the
-- agreement does nothing from now on.
function requests.deny(self, request, by)
    local key = is_key(request.key) and request.key:lower()
    if not key then return { error = "Expected a key, of 64 hexadecimal digits" } end
    if key == self.options.identity then return { error = "The core's own computer is always allowed" } end

    local known, waiting = self.allowed[key], self.waiting[key]
    local network = self:network_of(key)
    local agreement = network and self.networks[network]
    local id = (known and known.id) or (waiting and waiting.id) or (agreement and agreement.id)
    self.allowed[key] = { label = known and known.label or (network or ""), role = "denied", id = id }
    self:save_allowed()
    self:log(("Refused #%s, %s%s"):format(tostring(id or "?"), self.options.fingerprint(key), self:by(by)))

    if waiting then
        self.waiting[key] = nil
        waiting.connection:abort()
    end
    for _, cell in pairs(self.cells) do
        if cell.key == key then cell.connection:abort() end
    end
    for _, cell in pairs(self.standby) do
        if cell.key == key then cell.connection:abort() end
    end
    for connection, admin in pairs(self.admins) do
        if admin == key then connection:abort() end
    end
    -- A network's core: our phones are told its cells aren't for them, and nothing more is done for it.
    if agreement then
        agreement.carry, agreement.roam, agreement.messages = false, false, false
        self:save_networks()
        self:agreement_changed(network)
    end
    return { id = id, network = network }
end

--[[- See or change an agreement with another network: whether we carry its phones (`carry`), whether ours may use its
cells (`roam`: `"partner"`, `"home"` or `false`), whether the two exchange messages (`messages`), and where its core is
(`core`, or `false` to wait for it to connect). `forget` drops the agreement altogether.
]]
function requests.network(self, request, by)
    local network = request.network
    if not common.is_network(network) then return { error = "Network names are letters, digits and dashes, up to 32 of them" } end
    if network == self.config.network then return { error = "That's this network" } end
    local agreement = self.networks[network]

    if request.forget then
        if not agreement then return { error = "There's no agreement with " .. network } end
        self.networks[network] = nil
        self:save_networks()
        self:agreement_changed(network)
        self:log(("Forgot the agreement with %s%s"):format(network, self:by(by)))
        return { network = network, forgotten = true }
    end

    local changes = {}
    if request.carry ~= nil then
        if type(request.carry) ~= "boolean" then return { error = "Expected carry to be true or false" } end
        changes.carry = request.carry
    end
    if request.roam ~= nil then
        if request.roam ~= false and request.roam ~= "partner" and request.roam ~= "home" then
            return { error = "Expected roam to be partner, home or false" }
        end
        changes.roam = request.roam
    end
    if request.messages ~= nil then
        if type(request.messages) ~= "boolean" then return { error = "Expected messages to be true or false" } end
        if request.messages and not self.config.number_prefix then
            return { error = "Set this network's number prefix first, with 'cellcore numbers'" }
        end
        changes.messages = request.messages
    end
    if request.core ~= nil then
        if request.core ~= false and not networks.is_core(request.core) then
            return { error = "Expected the name or address of the other network's core" }
        end
        changes.core = request.core or nil
        if request.core == false then changes.no_core = true end
    end

    if next(changes) then
        agreement = agreement or networks.empty()
        self.networks[network] = agreement
        local said = {}
        for field, value in pairs(changes) do
            if field == "no_core" then
                agreement.core = nil
            else
                agreement[field] = value
            end
            said[#said + 1] = field == "no_core" and "core none" or ("%s %s"):format(field, tostring(value))
        end
        table.sort(said)
        self:save_networks()
        self:agreement_changed(network)
        self:log(("Agreement with %s: %s%s"):format(network, table.concat(said, ", "), self:by(by)))
    elseif not agreement then
        return { error = "There's no agreement with " .. network }
    end

    local view = { network = network }
    for field, value in pairs(agreement) do view[field] = value end
    if view.key then view.fingerprint = self.options.fingerprint(view.key) end
    view.connected = self.links[network] ~= nil
    -- What the other core's administrator needs, to allow ours.
    view.our_id, view.our_fingerprint = self.options.id, self.options.fingerprint(self.options.identity)
    return view
end

-- The requests older versions had, which change agreements as `network` does.
local function as_network(self, by, network, changes, check)
    if check then
        local agreement = type(network) == "string" and self.networks[network]
        local err = check(agreement)
        if err then return { error = err } end
    end
    changes.op, changes.network = "network", network
    local reply = requests.network(self, changes, by)
    if not reply.error then reply.id, reply.fingerprint = self.options.id, self.options.fingerprint(self.options.identity) end
    return reply
end

--- Carry another network's phones at our cells, connecting to its core.
function requests.carry(self, request, by)
    if type(request.core) ~= "string" then return { error = "Expected the name or address of the other network's core" } end
    return as_network(self, by, request.network, { carry = true, core = request.core })
end

--- Stop carrying another network's phones.
function requests.uncarry(self, request, by)
    return as_network(self, by, request.network, { carry = false }, function(agreement)
        if not agreement or not agreement.carry then return "This network doesn't carry the phones of " .. tostring(request.network) end
    end)
end

--- Say whether our phones treat a network which carries them as home, or roam there.
function requests.partner(self, request, by)
    if type(request.home) ~= "boolean" then return { error = "Expected home to be true or false" } end
    return as_network(self, by, request.network, { roam = request.home and "home" or "partner" }, function(agreement)
        if not agreement or not agreement.roam then return ("%s doesn't carry this network's phones"):format(tostring(request.network)) end
    end)
end

--- Exchange messages with another network's phones, connecting to its core.
function requests.peer(self, request, by)
    if type(request.core) ~= "string" then return { error = "Expected the name or address of the other network's core" } end
    return as_network(self, by, request.network, { messages = true, core = request.core })
end

--- Stop exchanging messages with another network.
function requests.unpeer(self, request, by)
    return as_network(self, by, request.network, { messages = false }, function(agreement)
        if not agreement or not agreement.messages then return "This network doesn't exchange messages with " .. tostring(request.network) end
    end)
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
    -- Other networks' cores hear of it over the connection, which stays: phones roaming there keep their service. One
    -- we'd exchange messages with, but couldn't before (we had no prefix, or the same as it), is connected afresh, so
    -- both look again.
    for network, link in pairs(self.links) do
        local agreement = self.networks[network]
        if not link.peer and link.wants_messages and agreement and agreement.messages then
            self:agreement_changed(network)
        else
            link.send({ s = "prefix", prefix = prefix })
        end
    end
    self:log(("This network's numbers now start %s%s"):format(prefix, self:by(by)))
    return { prefix = prefix }
end

-- Change a setting in the config file, which may have changed since the core started (it says whether the core starts
-- with the computer).
function Service:set_config(field, value)
    local config = read_table(self.files.config)
    config[field] = value
    write_table(self.files.config, config)
    self.config[field] = value
end

--[[- Set the carriers this network's cells use (its spectrum): none, for a network whose cells should all be off the
air. Cells connected now hear of them at once: one on a carrier which is no longer the network's leaves it, and one
which waited for a carrier takes it.

@tparam { string... } names The carriers, by name, such as `"b20/1"`.
@tparam[opt] string by The key of whoever asked, for the log.
@treturn[1] true If they were set.
@treturn[2] nil If they weren't.
@treturn[2] string Why not.
]]
function Service:set_spectrum(names, by)
    if type(names) ~= "table" or #names > common.MAX_SPECTRUM then
        return nil, ("A network has up to %d carriers"):format(common.MAX_SPECTRUM)
    end
    local list, seen = {}, {}
    for _, name in ipairs(names) do
        local carrier = bands.parse_carrier(name)
        if not carrier then return nil, ("There's no carrier called %s"):format(tostring(name)) end
        if not seen[carrier] then
            seen[carrier] = true
            list[#list + 1] = carrier
        end
    end
    self:set_config("spectrum", list[1] and list or nil)
    self:tell_cells({ op = "carriers", carriers = self:spectrum() })
    local who = by and self:by(by) or ""
    if list[1] then
        local shown = {}
        for i, carrier in ipairs(list) do shown[i] = bands.carrier_name(carrier) end
        self:log(("This network's carriers are now %s%s"):format(table.concat(shown, ", "), who))
    else
        self:log(("This network has no carriers now%s"):format(who))
    end
    return true
end

--- See or set the carriers this network's cells use, by name: see [`Service:set_spectrum`].
function requests.spectrum(self, request, by)
    if request.carriers ~= nil then
        local ok, err = self:set_spectrum(request.carriers, by)
        if not ok then return { error = err } end
    end
    local names = {}
    for i, carrier in ipairs(self:spectrum()) do names[i] = bands.carrier_name(carrier) end
    return { carriers = names }
end

--[[- Rename the network, in its settings: it goes by the new name once the core has started afresh. The name it had
is kept with those it had before, the newest few, for phones which haven't heard.

@tparam string name The new name.
@tparam[opt] string by The key of whoever asked, for the log.
@treturn[1] string The name it had.
@treturn[2] nil If it can't be called that.
@treturn[2] string Why not.
]]
function Service:rename(name, by)
    local old = self.config.network
    if not common.is_network(name) then return nil, "Network names are letters, digits and dashes, up to 32 of them" end
    if name == old then return nil, ("The network is called %s already"):format(name) end
    if self.networks[name] then return nil, ("There's an agreement with a network called %s"):format(name) end
    -- The file may have changed since the core started (it says whether the core starts with the computer).
    local config = read_table(self.files.config)
    local former = common.former_names(config.former, name)
    for i = #former, 1, -1 do
        if former[i] == old then table.remove(former, i) end
    end
    former[#former + 1] = old
    config.network, config.former = name, common.former_names(former, name)
    write_table(self.files.config, config)
    self.config.network, self.config.former = config.network, config.former
    self:log(("This network is called %s now, not %s%s"):format(name, old, by and self:by(by) or ""))
    return old
end

--[[- Rename the network. The core starts afresh under the new name: its cells join again by themselves, and name the
network as it's now called; phones find their operator's cells under the new name, and take it; and other networks'
cores, which know this one by its key, keep their agreements. The name it had is remembered, for phones which were
away: they still attach by it, and are told the new one.
]]
function requests.rename(self, request, by)
    if not self.options.restart then return { error = "This core can't be started again from here" } end
    local old, err = self:rename(request.network, by)
    if not old then return { error = err } end
    self.ending = "restart"
    return { network = self.config.network, was = old, restarting = true }
end

--- See or set how often this network's cells send system information, in seconds. Cells connected now hear of it at
-- once, unless they were told otherwise.
function requests.beacon(self, request, by)
    if request.interval ~= nil then
        if not common.is_interval(request.interval) then
            return { error = ("Cells send system information every %s to %s seconds"):format(common.MIN_INTERVAL, common.MAX_INTERVAL) }
        end
        self:set_config("beacon_interval", request.interval)
        self:tell_cells({ op = "interval", interval = request.interval })
        self:log(("Cells now send system information every %s seconds%s"):format(request.interval, self:by(by)))
    end
    return { interval = self:beacon_interval() }
end

--[[- See or set the DNS servers and domain this network's phones are given, to look names up with. `servers` is a list
of addresses, or `false` for none; `domain` a domain, or `false` for none; either left out stays as it is. Phones
attached now hear of a change at once.
]]
function requests.dns(self, request, by)
    local servers, domain = self.config.dns, self.config.domain
    if request.servers ~= nil then
        if request.servers == false then
            servers = nil
        else
            servers = common.read_dns(request.servers)
            if not servers then
                return { error = ("DNS servers are up to %d addresses, such as 10.64.0.1"):format(common.MAX_DNS) }
            end
        end
    end
    if request.domain ~= nil then
        if request.domain == false then
            domain = nil
        else
            domain = type(request.domain) == "string" and request.domain:lower():gsub("%.$", "") or nil
            if not common.is_domain(domain) then
                return { error = "A domain is names of letters, digits and dashes, separated by dots, such as acme" }
            end
        end
    end

    if request.servers ~= nil or request.domain ~= nil then
        self:set_config("dns", servers)
        self:set_config("domain", domain)
        self.core:set_dns(servers, domain)
        self:log(("Phones now look names up with %s%s%s"):format(
            servers and table.concat(servers, ", ") or "no DNS server of this network's",
            domain and (", in " .. domain) or "", self:by(by)
        ))
        -- Phones' names are registered in the domain, unless they've a zone of their own.
        local hostnames = self.config.hostnames
        if hostnames and hostnames.server and not hostnames.zone then self:move_hostnames() end
    end
    return { servers = servers or {}, domain = domain }
end

--[[- Start registering phones' names at a DNS server (`dnsd`), if the network does, as its settings say now: in their
zone, or else the domain phones are given. A phone's name is its subscriber's ID, as a hostname (`acme-0042`).
]]
function Service:start_hostnames()
    self.hostnames = nil
    local settings = self.config.hostnames
    local zone = settings and settings.server and (settings.zone or self.config.domain)
    if not zone or not self.core.stack then return end
    self.hostnames = {
        zone = zone, names = {},
        updater = dns.updater {
            send = dns.stack_sender(self.core.stack, (address.parse(settings.server))), zone = zone, key = settings.key,
            epoch = self.options.epoch, log = function(text) self:log(text) end,
        },
    }
end

--- Register an attached phone's name, for its address.
--
-- @tparam string sim The subscriber's SIM key, as hexadecimal digits.
-- @tparam number|nil addr The phone's address.
function Service:register(sim, addr)
    local hostnames, subscriber = self.hostnames, self.subscribers[sim]
    local name = subscriber and dhcp.clean_hostname(subscriber.id)
    if not hostnames or not name or not addr then return end
    local owner = "subscriber " .. subscriber.id
    local old = hostnames.names[sim]
    if old and old.name ~= name then hostnames.updater:delete(old.name, old.owner) end
    hostnames.names[sim] = { name = name, owner = owner }
    hostnames.updater:set(name, addr, HOSTNAME_LIFETIME, owner)
end

--- Delete a phone's name, as it's detached (or its subscriber removed).
--
-- @tparam string sim The subscriber's SIM key, as hexadecimal digits.
function Service:unregister(sim)
    local old = self.hostnames and self.hostnames.names[sim]
    if not old then return end
    self.hostnames.names[sim] = nil
    self.hostnames.updater:delete(old.name, old.owner)
end

--- Register every attached phone's name again: they expire otherwise.
function Service:register_all()
    for sim, session in pairs(self.core.sessions) do
        if session.teid and session.address then self:register(sim, session.address) end
    end
end

--- Register phones' names where the settings say now, deleting them where they were.
function Service:move_hostnames()
    local before = self.hostnames
    if before then
        for _, old in pairs(before.names) do before.updater:delete(old.name, old.owner) end
    end
    self:start_hostnames()
    self:register_all()
end

--[[- See or set where this network's phones' names are registered: at a DNS server (`dnsd`) which lets the core set
names, in a zone (by default, the domain phones are given), with the key the server asks for. `server` is an address,
or `false` to register none; `zone` a zone, or `false` for the domain; `key` a secret, or `false` for none; any left
out stays as it is.
]]
function requests.hostnames(self, request, by)
    local current = self.config.hostnames or {}
    local server, zone, key = current.server, current.zone, current.key
    if request.server ~= nil then
        if request.server == false then
            server = nil
        else
            server = server_address(request.server)
            if not server then return { error = "The DNS server is an address, such as 10.0.0.53" } end
        end
    end
    if request.zone ~= nil then
        if request.zone == false then
            zone = nil
        else
            zone = type(request.zone) == "string" and request.zone:lower():gsub("%.$", "") or nil
            if not common.is_domain(zone) then
                return { error = "A zone is names of letters, digits and dashes, separated by dots, such as acme" }
            end
        end
    end
    if request.key ~= nil then
        if request.key == false then
            key = nil
        elseif is_secret(request.key) then
            key = request.key
        else
            return { error = "A key is up to 128 characters, without spaces or #" }
        end
    end

    if request.server ~= nil or request.zone ~= nil or request.key ~= nil then
        local value = { server = server, zone = zone, key = key }
        self:set_config("hostnames", (server or zone or key) and value or nil)
        self:move_hostnames()
        local where = self.hostnames and ("%s, in %s"):format(server, self.hostnames.zone)
        self:log(("Phones' names are registered %s%s"):format(
            where and "at " .. where or server and "nowhere: there's no zone for them" or "nowhere", self:by(by)
        ))
    end
    return { server = server, zone = zone, domain = self.config.domain, key = key ~= nil }
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

--- Change a subscriber, found by ID or number: whether they're barred, whether they may roam, and whether they have a
-- network of their own behind their phone: a `range` of this network's addresses, or a `subnet` which isn't its own.
function requests.set(self, request, by)
    local who = request.subscriber
    if type(who) ~= "string" then return { error = "Expected a subscriber's ID or number" } end
    for _, kind in ipairs { "range", "subnet" } do
        if request[kind] ~= nil and request[kind] ~= false and type(request[kind]) ~= "string" then
            return { error = ("Expected %s to be a network, such as 10.64.5.0/28, or false"):format(kind) }
        end
    end
    if request.range and request.subnet then return { error = "A subscriber has a range or a subnet, not both" } end
    -- Their network is checked before anything changes: it may not be one they can have.
    local kind = request.range and "range" or request.subnet and "subnet" or nil
    local unset = not kind and (request.range == false or request.subnet == false)
    if kind or unset then
        local count, sim = 0, nil
        for key, subscriber in pairs(self.subscribers) do
            if subscriber.id == who or subscriber.number == who then count, sim = count + 1, key end
        end
        if count == 0 then return { error = "There's no subscriber " .. who } end
        if count > 1 then return { error = ("More than one subscriber is called %s"):format(who) } end
        -- Taking away one kind leaves the other, if that's what they have.
        local subscriber = self.subscribers[sim]
        if kind or (request.range == false and subscriber.range) or (request.subnet == false and subscriber.subnet) then
            local ok, err = self.core:set_network(sim, kind, kind and request[kind])
            if not ok then return { error = err } end
        end
    end
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
    if kind then changes[#changes + 1] = ("has the %s %s"):format(kind, tostring(found[kind])) end
    if unset then changes[#changes + 1] = "has no network of their own" end
    if #changes > 0 then self:log(("%s: %s%s"):format(who, table.concat(changes, ", "), self:by(by))) end
    return {
        id = found.id, number = found.number, barred = found.barred == true, roaming = found.roaming ~= false,
        range = found.range, subnet = found.subnet,
    }
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
    for _, link in pairs(self.links) do link.connection:abort() end
    for _, entry in pairs(self.dialing) do
        if entry.connection then entry.connection:abort() end
    end
    for _, cell in pairs(self.standby) do cell.connection:abort() end
    self.waiting, self.cells, self.standby, self.admins, self.links, self.dialing = {}, {}, {}, {}, {}, {}
end

return {
    new = new,
    MAX_WAITING = MAX_WAITING,
    WAIT_TIMEOUT = WAIT_TIMEOUT,
    LOG_SIZE = LOG_SIZE,
}
