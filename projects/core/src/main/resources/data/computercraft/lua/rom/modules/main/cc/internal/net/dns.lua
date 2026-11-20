-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Names: answering questions about `.local` names and services, resolving names, and DNS servers.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the [`net`] API instead.

There are two ways to find a name:

 - Names ending in `.local` are asked about by broadcast on every interface, and whoever has the name answers (port
   5353). Services work the same way: every computer offering one answers. This needs no servers at all.
 - Other names are asked of DNS servers (port 53), which answer from a zone file. Servers are found through DHCP, or the
   `net.dns` setting. A server may serve several zones, and forward questions about names in others to other servers
   (see [`relay`]).

A question is `{ id = number, name = string, type = "A" or "SRV", hops? = number }`, and an answer
`{ id = number, code = "ok" or "not_found" or "refused", records = { { name, type, value, ttl }... } }`. An `"A"` record's
value is an address, and an `"SRV"` record's is `{ host = string, address = number, port = number }`. A name may be an
alias for another name: its `"CNAME"` record's value is that name, and the records for that name come after it (as many
as there are, if it's an alias too). `hops` is how many times a question has been forwarded already: none, if it isn't
there.

A DNS server may also be told to set or delete a name in one of its zones (see [`update_message`]), as DHCP servers do
for their clients' names: `{ op = "update", id, zone, name, address?, lifetime?, owner, time?, mac? }`, answered with
`{ id, code = "ok" or "refused" or "not_found" or "taken" or "invalid", error? = string }`.

@local
]]

local address = require "cc.net.address"
local is_integer = require "cc.internal.net.checks".is_integer

--- The port DNS servers listen on.
local DNS_PORT = 53

--- The port every computer answers `.local` questions on.
local MDNS_PORT = 5353

local DNS_TIMEOUT, MDNS_TIMEOUT = 1.5, 1
local MAX_TTL = 300

--- How long a DNS server waits for the servers it forwards a question to, in seconds, by how many times the question
-- has been forwarded already: always less than whoever asked waits, so their answer gets back in time. A question
-- forwarded more times than this has deadlines for isn't forwarded again.
local FORWARD_DEADLINES = { [0] = 1.2, 0.8, 0.4 }

--- How long a DNS server waits for any one server it forwards a question to, before asking the next, in seconds.
local FORWARD_TIMEOUT = 0.6

--- How many aliases a DNS server follows for one question, at most: a name which is an alias for an alias for another,
-- more times than this (or round in a circle), isn't found.
local MAX_ALIASES = 8

--- How long a DNS server remembers that a name it forwarded a question about doesn't exist, in seconds.
local NOT_FOUND_TTL = 10

--- How many forwarded questions a DNS server waits on at once. Beyond that, it refuses questions it would forward.
local MAX_FORWARDING = 64

--- How far a signed update's time may be from the server's, in milliseconds, and so how long its signature is good for.
local UPDATE_WINDOW = 60000

--- The longest a name set by an update lasts, in seconds, unless it's set again.
local MAX_LIFETIME = 7 * 24 * 3600

--- How many names a DNS server keeps from updates, at most.
local MAX_NAMES = 1024

--- How long whoever sends an update waits for each answer, in seconds.
local UPDATE_TIMEOUT = 2

--- How many times whoever sends an update tries.
local UPDATE_ATTEMPTS = 3

--- Normalise a name: lower case, without a trailing dot.
--
-- @tparam string name The name.
-- @treturn string The normalised name.
local function normalise(name)
    return (name:lower():gsub("%.$", ""))
end

-- Whether text is a name within a zone, as a computer's hostname is: one label.
local function is_label(value)
    return type(value) == "string" and #value >= 1 and #value <= 63 and value:find("^[%l%d%-]+$") ~= nil
end

-- Whether text is a full name: labels, separated by dots.
local function is_name(value)
    if type(value) ~= "string" or #value < 1 or #value > 253 then return false end
    for label in (value .. "."):gmatch("([^%.]*)%.") do
        if not is_label(label) then return false end
    end
    return true
end

--[[- Answer questions about this computer's `.local` name and services.

@tparam table stack The network stack.
@tparam {
    hostname = function():string,
    services = { [string] = number },
} options This computer's hostname (without `.local`), and the services it offers, with their ports.
]]
local function respond(stack, options)
    local socket
    socket = stack:udp_open(MDNS_PORT, function(question, from, port, name)
        if type(question) ~= "table" or type(question.id) ~= "number" or type(question.name) ~= "string" then return end
        local interface = name and stack.interfaces[name]
        if not interface or not interface.address or from == address.ANY then return end

        local wanted = normalise(question.name)
        local host = options.hostname() .. ".local"
        local record
        if question.type == "A" and wanted == host then
            record = { name = host, type = "A", value = interface.address, ttl = 60 }
        elseif question.type == "SRV" and options.services[wanted] then
            record = {
                name = wanted, type = "SRV", ttl = 60,
                value = { host = host, address = interface.address, port = options.services[wanted] },
            }
        end

        -- Only answer when we know something: other computers may know the answer.
        if record then stack:udp_send(socket, from, port, { id = question.id, code = "ok", records = { record } }) end
    end)
end

--[[- Ask a question and wait for answers.

@tparam table stack The network stack.
@tparam number dst Who to ask. The broadcast address asks everyone, on every interface with an address.
@tparam number port The port to ask on.
@tparam table question The question.
@tparam number timeout How long to wait, in seconds.
@tparam function(answer:table, from:number):boolean on_answer Called with each answer. Return `true` to stop waiting.
@tparam function(err:string|nil) on_done Called once, when finished: with `nil` if `on_answer` stopped it, or why it
finished otherwise (such as `"Timed out"`).
]]
local function ask(stack, dst, port, question, timeout, on_answer, on_done)
    local socket, timer
    local finished = false
    local function finish(err)
        if finished then return end
        finished = true
        stack:cancel(timer)
        if socket then stack:udp_close(socket) end
        on_done(err)
    end

    local err
    socket, err = stack:udp_open(nil, function(answer, from)
        if finished or type(answer) ~= "table" or answer.id ~= question.id then return end
        if on_answer(answer, from) then finish(nil) end
    end)
    if not socket then return finish(err) end
    socket.on_error = function(message) finish(message) end
    timer = stack:schedule(timeout, function() finish("Timed out") end)

    if dst == address.BROADCAST then
        local sent = false
        for name, interface in pairs(stack.interfaces) do
            if interface.address and not interface.duplicate then
                stack:udp_send(socket, dst, port, question, name)
                sent = true
            end
        end
        if not sent then finish("No interface has an address") end
    else
        local ok
        ok, err = stack:udp_send(socket, dst, port, question)
        if not ok then finish(err) end
    end
end

local function find_record(answer, kind)
    if answer.code ~= "ok" or type(answer.records) ~= "table" then return nil end
    for _, record in ipairs(answer.records) do
        if type(record) == "table" and record.type == kind then return record end
    end
end

-- How many answers to keep, at most.
local MAX_CACHE = 256

local function ttl(record)
    local value = record.ttl
    if type(value) ~= "number" or value ~= value then return 60 end
    return math.max(0, math.min(value, MAX_TTL))
end

--[[- Resolve a name to an address.

The name may be an address already; a name in the `hosts` table; this computer's own name; a `.local` name; or a name
for a DNS server. A name without dots is tried in the search domain, then as a `.local` name.

@tparam table stack The network stack.
@tparam string name The name.
@tparam {
    hosts? = { [string] = string },
    servers? = { number... },
    domain? = string,
    hostname = string,
    cache = table,
} options Fixed names, DNS servers, the search domain, this computer's hostname, and a cache of answers.
@tparam function(addr:number|nil, err:string|nil) callback Called with the address, or why there isn't one.
]]
local function resolve(stack, name, options, callback)
    name = normalise(name)

    local literal = address.parse(name)
    if literal then return callback(literal) end

    local fixed = options.hosts and options.hosts[name]
    if type(fixed) == "string" and address.parse(fixed) then return callback((address.parse(fixed))) end

    local cached = options.cache[name]
    if cached and cached.expires > stack.clock() then return callback(cached.address) end

    if name == options.hostname or name == options.hostname .. ".local" then
        -- With several interfaces, always pick the same one.
        local names = {}
        for interface_name, interface in pairs(stack.interfaces) do
            if interface.address and not interface.duplicate then names[#names + 1] = interface_name end
        end
        table.sort(names)
        if names[1] then return callback(stack.interfaces[names[1]].address) end
        return callback((address.parse("127.0.0.1")))
    end

    -- The names to try, in order: { name, how }.
    local candidates = {}
    if name:sub(-6) == ".local" then
        candidates[1] = { name, "mdns" }
    elseif not name:find(".", 1, true) then
        if options.domain then candidates[#candidates + 1] = { name .. "." .. options.domain, "dns" } end
        candidates[#candidates + 1] = { name .. ".local", "mdns" }
    else
        candidates[1] = { name, "dns" }
    end

    local servers = options.servers or {}
    local last_error = "Name not found"

    local function found(addr, record)
        local now, cache = stack.clock(), options.cache
        if cache[name] == nil then
            -- A name we hadn't kept: forget those which have expired, and keep no more than so many.
            local count = 0
            for key, entry in pairs(cache) do
                if entry.expires <= now then cache[key] = nil else count = count + 1 end
            end
            if count >= MAX_CACHE then
                for key in pairs(cache) do cache[key] = nil end
            end
        end
        cache[name] = { address = addr, expires = now + ttl(record) }
        callback(addr)
    end

    local try_candidate
    local function try_server(candidate, index, server)
        if server > #servers then return try_candidate(index + 1) end

        local result, record, missing
        ask(stack, servers[server], DNS_PORT, { id = math.random(1, 0x7FFFFFFF), name = candidate, type = "A" }, DNS_TIMEOUT,
            function(answer)
                record = find_record(answer, "A")
                if record and address.is_valid(record.value) then
                    result = record.value
                elseif answer.code == "not_found" then
                    missing = true
                end
                return true
            end,
            function(err)
                if result then return found(result, record) end
                if missing then return try_candidate(index + 1) end
                if err then last_error = err end
                return try_server(candidate, index, server + 1)
            end)
    end

    function try_candidate(index)
        local candidate = candidates[index]
        if not candidate then return callback(nil, last_error) end

        if candidate[2] == "dns" then
            if #servers == 0 then
                last_error = "No DNS server"
                return try_candidate(index + 1)
            end
            return try_server(candidate[1], index, 1)
        end

        local result, record
        ask(stack, address.BROADCAST, MDNS_PORT, { id = math.random(1, 0x7FFFFFFF), name = candidate[1], type = "A" }, MDNS_TIMEOUT,
            function(answer)
                record = find_record(answer, "A")
                if record and address.is_valid(record.value) then
                    result = record.value
                    return true
                end
                return false
            end,
            function()
                if result then return found(result, record) end
                return try_candidate(index + 1)
            end)
    end

    try_candidate(1)
end

--[[- Find every computer offering a service on the local network.

@tparam table stack The network stack.
@tparam string service The service's name.
@tparam number timeout How long to wait for answers, in seconds.
@tparam function(results:{ { host = string, address = number, port = number }... }) callback Called with everyone who
answered.
]]
local function lookup(stack, service, timeout, callback)
    local results, seen = {}, {}
    ask(stack, address.BROADCAST, MDNS_PORT, { id = math.random(1, 0x7FFFFFFF), name = normalise(service), type = "SRV" }, timeout,
        function(answer)
            local record = find_record(answer, "SRV")
            local value = record and record.value
            if type(value) == "table" and address.is_valid(value.address) and type(value.port) == "number" and value.port % 1 == 0
                and not seen[value.address] then
                seen[value.address] = true
                results[#results + 1] = { host = tostring(value.host), address = value.address, port = value.port }
            end
            return false
        end,
        function() callback(results) end)
end

--[[- Read a name in a zone, as a zone file has it: the name, then its address, or the name it's an alias for. A name
without dots is in the same zone (`@` is the zone itself), and a name with dots is written in full, with or without a
dot at the end.

@tparam string name The name within the zone, such as `"www"`, or `"@"` for the zone itself.
@tparam string value Its address, or the name it's an alias for, such as `"10.0.0.5"`, `"shop"` or `"mail.corp."`.
@tparam string zone The zone the name is in, such as `"home"`.
@treturn[1] string The name within the zone, as it's kept.
@treturn[1] number|string Its address, or the full name it's an alias for.
@treturn[2] nil If it can't be read.
@treturn[2] string Why not.
]]
local function parse_record(name, value, zone)
    zone = normalise(zone)
    local key = normalise(name)
    local addr, prefix = address.parse(value)
    if addr and not prefix then return key, addr end
    if value:find("^[%d%./]+$") and value:find("[%./]") then return nil, ("%s isn't an address"):format(value) end

    local target
    if value == "@" then
        target = zone
    elseif value:find(".", 1, true) then
        target = normalise(value)
    else
        target = value:lower() .. "." .. zone
    end
    if not is_name(target) then return nil, ("%s isn't an address or a name"):format(value) end
    if target == "local" or target:sub(-6) == ".local" then
        return nil, ("%s is a .local name, which only the computers on a link answer for"):format(value)
    end
    if target == (key == "@" and zone or key .. "." .. zone) then return nil, ("%s is an alias for itself"):format(name) end
    return key, target
end

--- The error for a line which isn't a name and what it stands for.
local BAD_LINE = "expected a name, then its address or the name it's an alias for"

--- Parse a zone file: a name and its address (or the name it's an alias for) on each line, as [`parse_record`] reads
-- them, with `#` starting a comment.
--
-- @tparam string text The file's contents.
-- @tparam string zone The zone it's for.
-- @treturn { [string] = number|string } The records: each name within the zone, and its address or the full name
-- it's an alias for.
-- @treturn { string... } Any lines which couldn't be read.
local function parse_zone(text, zone)
    local records, errors = {}, {}
    local line_number = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line_number = line_number + 1
        line = line:gsub("#.*", "")
        local name, value = line:match("^%s*(%S+)%s+(%S+)%s*$")
        if name then
            local key, result = parse_record(name, value, zone)
            if key then
                records[key] = result
            else
                errors[#errors + 1] = ("Line %d: %s"):format(line_number, result)
            end
        elseif line:find("%S") then
            errors[#errors + 1] = ("Line %d: %s"):format(line_number, BAD_LINE)
        end
    end
    return records, errors
end

local Server = {}
Server.__index = Server

--[[- Create a DNS server's logic, for one zone. The server itself is up to the caller.

@tparam string zone The zone, such as `"home"`. The server answers for names ending in it.
@tparam { [string] = number|string } records Names within the zone (such as `"bank"` for `bank.home`), with their
addresses, or the full names they're aliases for.
@tparam[opt] function():{ [string] = number } extra More names, looked up for each question, such as DHCP clients.
@treturn table The server.
]]
local function new_server(zone, records, extra)
    return setmetatable({ zone = normalise(zone), records = records, extra = extra }, Server)
end

--- Find a name within the zone.
--
-- @tparam string name The name, such as `"bank.home"`.
-- @treturn string|nil The name within the zone (`"bank"`, or `"@"` for the zone itself), or `nil` if it isn't in it.
function Server:within(name)
    name = normalise(name)
    if name == self.zone then return "@" end
    local suffix = "." .. self.zone
    if name:sub(-#suffix) == suffix then return name:sub(1, -#suffix - 1) end
    return nil
end

--- Answer a question. An alias is answered with the name it's an alias for, alone: following it is up to whoever asked
-- (see [`relay`]).
--
-- @param question The question.
-- @treturn table|nil The answer, or `nil` if the question wasn't valid.
function Server:handle(question)
    if type(question) ~= "table" or type(question.id) ~= "number" or type(question.name) ~= "string" then return nil end

    local name = normalise(question.name)
    local relative = self:within(name)
    if not relative then return { id = question.id, code = "refused" } end

    if question.type ~= "A" then return { id = question.id, code = "not_found" } end

    local value = self.records[relative]
    if value == nil and self.extra then value = self.extra()[relative] end
    if value == nil then return { id = question.id, code = "not_found" } end
    local kind = type(value) == "string" and "CNAME" or "A"
    return { id = question.id, code = "ok", records = { { name = name, type = kind, value = value, ttl = 60 } } }
end

local Forward = { within = Server.within }
Forward.__index = Forward

--[[- A zone a DNS server asks other servers about, rather than answering for it.

@tparam string zone The zone, such as `"corp"`.
@tparam { number... } servers The servers to ask, in turn.
@treturn table The zone, for [`relay`].
]]
local function new_forward(zone, servers)
    return setmetatable({ zone = normalise(zone), servers = servers }, Forward)
end

local Relay = {}
Relay.__index = Relay

--[[- Create the logic of a DNS server for several zones, which forwards questions about names in other zones to other
DNS servers. Sending and receiving is up to the caller: each method returns what to send, as a list of
`{ client = client, answer = answer }` (an answer for whoever asked) and `{ server = address, question = question }` (a
question for another server's DNS port).

A name is answered by the most specific zone it's in. Names in a zone which is forwarded (from [`forward`]) are asked
of its servers, and names in none of the servers to forward to: each server in turn, until one answers, or says the
name doesn't exist, which is passed back. An alias in one of its zones is followed, wherever it leads, and the answer
says each alias, then the records for the name at the end: an alias for a name which doesn't exist, or for more aliases
than `MAX_ALIASES` (or round in a circle), isn't found. If every server refuses, or none answers in time, the
question is refused, so whoever asked tries their next server. Each forwarded question carries how many times it's been
forwarded, and the deadline for each time is shorter, so a chain of servers answers before the first gives up; one
forwarded too many times is refused, which also ends loops between servers. Answers are kept for as long as they say
(names which don't exist, briefly), and refusals never.

@tparam {
    zones = { table... }, forward = function():{ number... }, clock = function():number, random? = function():number,
} options The zones (from [`server`], and [`forward`]); the servers to forward other names to (asked for each question,
so they may change); a clock in seconds; and random question IDs.
@treturn table The relay.
]]
local function new_relay(options)
    return setmetatable({
        zones = options.zones, forward = options.forward, clock = options.clock,
        random = options.random or function() return math.random(1, 0x7FFFFFFF) end,
        waiting = {}, forwarding = 0, cache = {},
    }, Relay)
end

--- Find the zone a name is in: the most specific of those served.
--
-- @tparam string name The name.
-- @treturn table|nil The zone's server, or `nil` if it's in none.
function Relay:zone_of(name)
    local best
    for _, zone in ipairs(self.zones) do
        if zone:within(name) and (not best or #zone.zone > #best.zone) then best = zone end
    end
    return best
end

local function reply(client, id, code, records)
    return { client = client, answer = { id = id, code = code, records = records } }
end

-- The aliases followed to a name, then its records: new, so what's kept isn't changed.
local function joined(aliases, records)
    if not aliases[1] or type(records) ~= "table" then return records end
    local result = {}
    for i, record in ipairs(aliases) do result[i] = record end
    for _, record in ipairs(records) do result[#result + 1] = record end
    return result
end

--[[- A question from a client.

@param question The question.
@param client Whoever asked, given back with the answer.
@treturn { table... } What to send.
]]
function Relay:question(question, client)
    if type(question) ~= "table" or type(question.id) ~= "number" or type(question.name) ~= "string" then return {} end
    return self:resolve(question, client, normalise(question.name), {})
end

-- Answer a question about a name, which the aliases followed so far lead to.
function Relay:resolve(question, client, name, aliases)
    local zone = self:zone_of(name)
    if zone and not zone.servers then
        local answer = zone:handle({ id = question.id, name = name, type = question.type })
        local record = answer.code == "ok" and answer.records[1]
        if not record or record.type ~= "CNAME" then
            return { reply(client, question.id, answer.code, answer.code == "ok" and joined(aliases, answer.records) or nil) }
        end

        -- An alias: on to the name it's for, unless that's been followed too far, or comes back round.
        if #aliases >= MAX_ALIASES then return { reply(client, question.id, "not_found") } end
        for _, each in ipairs(aliases) do
            if each.name == record.value then return { reply(client, question.id, "not_found") } end
        end
        aliases[#aliases + 1] = record
        return self:resolve(question, client, record.value, aliases)
    end

    -- Forwarded more times than there are deadlines for (or nonsense): no further.
    local hops = question.hops or 0
    if not FORWARD_DEADLINES[hops] then return { reply(client, question.id, "refused") } end

    local now = self.clock()
    local key = name .. " " .. tostring(question.type)
    local cached = self.cache[key]
    if cached and cached.expires > now then
        return { reply(client, question.id, cached.code, joined(aliases, cached.records)) }
    end

    local servers = zone and zone.servers or self.forward()
    if not servers[1] or self.forwarding >= MAX_FORWARDING then return { reply(client, question.id, "refused") } end

    self.forwarding = self.forwarding + 1
    return self:ask_next({
        client = client, id = question.id, name = name, type = question.type, hops = hops + 1, key = key,
        aliases = aliases, servers = servers, server = 0, deadline = now + FORWARD_DEADLINES[hops],
    }, now)
end

-- Ask the next server about a forwarded question, or refuse it if there's none, or no time left.
function Relay:ask_next(forwarded, now)
    if forwarded.asked then self.waiting[forwarded.asked] = nil end
    forwarded.server = forwarded.server + 1
    local server = forwarded.servers[forwarded.server]
    if not server or now >= forwarded.deadline then
        self.forwarding = self.forwarding - 1
        return { reply(forwarded.client, forwarded.id, "refused") }
    end

    local id = self.random()
    while self.waiting[id] do id = self.random() end
    forwarded.asked, forwarded.until_time = id, math.min(now + FORWARD_TIMEOUT, forwarded.deadline)
    self.waiting[id] = forwarded
    return { { server = server, question = { id = id, name = forwarded.name, type = forwarded.type, hops = forwarded.hops } } }
end

-- Keep an answer, for as long as it says (but no longer than MAX_TTL), or a name which doesn't exist, briefly.
function Relay:keep(key, code, records)
    local keep = NOT_FOUND_TTL
    if code == "ok" then
        if type(records) ~= "table" or not records[1] then return end
        keep = MAX_TTL
        for _, record in ipairs(records) do
            if type(record) ~= "table" then return end
            keep = math.min(keep, ttl(record))
        end
    end

    local now = self.clock()
    local count = 0
    for name, entry in pairs(self.cache) do
        if entry.expires <= now then self.cache[name] = nil else count = count + 1 end
    end
    if count >= MAX_CACHE then self.cache = {} end
    self.cache[key] = { code = code, records = records, expires = now + keep }
end

--[[- An answer from a server a question was forwarded to.

@param answer The answer.
@tparam number from Who it's from. Only the server asked may answer.
@treturn { table... } What to send.
]]
function Relay:answer(answer, from)
    if type(answer) ~= "table" then return {} end
    local forwarded = self.waiting[answer.id]
    if not forwarded or forwarded.servers[forwarded.server] ~= from then return {} end

    if answer.code == "ok" or answer.code == "not_found" then
        self.waiting[answer.id] = nil
        self.forwarding = self.forwarding - 1
        local records = answer.code == "ok" and answer.records or nil
        self:keep(forwarded.key, answer.code, records)
        return { reply(forwarded.client, forwarded.id, answer.code, joined(forwarded.aliases, records)) }
    end

    -- Refused (or nonsense): another server may know.
    return self:ask_next(forwarded, self.clock())
end

--- Give up on servers which haven't answered in time, and ask the next.
--
-- @treturn { table... } What to send.
function Relay:expire()
    local now, due = self.clock(), {}
    for _, forwarded in pairs(self.waiting) do
        if now >= forwarded.until_time then due[#due + 1] = forwarded end
    end
    local result = {}
    for _, forwarded in ipairs(due) do
        for _, item in ipairs(self:ask_next(forwarded, now)) do result[#result + 1] = item end
    end
    return result
end

--- Whether any forwarded questions are waiting for an answer.
--
-- @treturn boolean Whether there are.
function Relay:busy()
    return self.forwarding > 0
end

--[[- Find the aliases in a DNS server's zones which are never found: those which lead round in a circle, or through more
aliases than `MAX_ALIASES`.

@tparam { table... } zones The zones (from [`server`] and [`forward`]).
@treturn { string... } What's wrong with each, sorted.
]]
local function bad_aliases(zones)
    local relay, result = new_relay { zones = zones, forward = function() return {} end, clock = function() return 0 end }, {}
    for _, zone in ipairs(zones) do
        for name, value in pairs(zone.servers and {} or zone.records) do
            local full = name == "@" and zone.zone or name .. "." .. zone.zone
            if type(value) == "string" and relay:zone_of(full) == zone then
                local seen, count = { [full] = true }, 0
                while type(value) == "string" do
                    count = count + 1
                    if seen[value] then
                        result[#result + 1] = ("%s isn't found: its aliases go round in a circle"):format(full)
                        break
                    elseif count > MAX_ALIASES then
                        result[#result + 1] = ("%s isn't found: it's an alias for an alias, more than %d times over")
                            :format(full, MAX_ALIASES)
                        break
                    end
                    seen[value] = true
                    local owner = relay:zone_of(value)
                    local relative = owner and not owner.servers and owner:within(value)
                    value = relative and owner.records[relative]
                end
            end
        end
    end
    table.sort(result)
    return result
end

-- What an update's signature covers: everything it says, in order.
local function signed_text(message)
    local parts = { "dns update" }
    for i, field in ipairs { "id", "zone", "name", "address", "lifetime", "owner", "time" } do
        parts[i + 1] = tostring(message[field])
    end
    return table.concat(parts, "\n")
end

local function signature(secret, message)
    return crypto.hmac(crypto.sha256("dnsd update key " .. secret), signed_text(message))
end

--[[- Make an update for a DNS server: to set a name in one of its zones to an address, for a while, or to delete it.

Whoever sets a name says who it's for (its `owner`, such as `"computer 12"`): the server won't let anyone else have the
name until it's deleted, or expires. With a secret, the update is signed, and the time it was made is in it, so it
can't be sent again much later.

@tparam {
    zone = string, name = string, address? = number, lifetime? = number, owner = string,
} fields The zone; the name within it; its address and how long it lasts, in seconds (or neither, to delete it); and who
it's for.
@tparam string|nil secret The secret the server asks for, if it does.
@tparam number epoch The time now, in milliseconds, as `os.epoch("utc")`.
@treturn table The update.
]]
local function update_message(fields, secret, epoch)
    local message = {
        op = "update", id = math.random(1, 0x7FFFFFFF), zone = fields.zone, name = fields.name, address = fields.address,
        lifetime = fields.lifetime, owner = fields.owner, time = epoch,
    }
    if secret then message.mac = signature(secret, message) end
    return message
end

local Names = {}
Names.__index = Names

local function is_owner(value)
    return type(value) == "string" and #value >= 1 and #value <= 64
end

--[[- The names a DNS server was told to set (by DHCP servers, say), which last until they expire, or are deleted.

@param saved What `Names:save` gave last time, which may be anything: what doesn't make sense is dropped.
@tparam function():number clock The time, in seconds: real time (as `os.epoch("utc") / 1000`), so names outlast restarts.
@treturn table The names.
]]
local function new_names(saved, clock)
    local self = setmetatable({ entries = {}, count = 0, clock = clock }, Names)
    for _, entry in pairs(type(saved) == "table" and saved or {}) do
        local addr = type(entry) == "table" and type(entry.address) == "string" and address.parse(entry.address)
        if addr and is_label(entry.name) and type(entry.zone) == "string" and type(entry.expires) == "number"
            and entry.expires == entry.expires and is_owner(entry.owner) and self.count < MAX_NAMES then
            local full = entry.name .. "." .. entry.zone
            if not self.entries[full] then self.count = self.count + 1 end
            self.entries[full] = { zone = entry.zone, name = entry.name, address = addr, expires = entry.expires, owner = entry.owner }
        end
    end
    self:prune()
    return self
end

--- Forget names which have expired.
--
-- @treturn boolean Whether any were forgotten.
function Names:prune()
    local now, changed = self.clock(), false
    for full, entry in pairs(self.entries) do
        if entry.expires <= now then
            self.entries[full], self.count, changed = nil, self.count - 1, true
        end
    end
    return changed
end

--- The names in a zone, which haven't expired.
--
-- @tparam string zone The zone.
-- @treturn { [string] = number } Each name within the zone, and its address.
function Names:lookup(zone)
    local now, result = self.clock(), {}
    for _, entry in pairs(self.entries) do
        if entry.zone == zone and entry.expires > now then result[entry.name] = entry.address end
    end
    return result
end

--- What to keep, to read again next time.
--
-- @treturn table The names, with their addresses written out.
function Names:save()
    local result = {}
    for full, entry in pairs(self.entries) do
        result[full] = {
            zone = entry.zone, name = entry.name, address = address.format(entry.address), expires = entry.expires,
            owner = entry.owner,
        }
    end
    return result
end

--[[- Handle an update: set or delete a name in one of a DNS server's zones.

A name in a zone's file can't be set, nor can one another owner has until it's deleted or expires.

@param message The message, which may be anything.
@tparam {
    zones = { table... }, names = table, allowed = boolean, key? = string, epoch = number, seen = table, from = string,
} context The server's zones (from [`server`] and [`forward`]); its names (from [`names`]); whether whoever sent the
update may; the secret updates must be signed with, if there is one; the time now, in milliseconds; the signatures
seen lately (kept between updates, so none is used twice); and who sent it, to say so.
@treturn table|nil The answer, or `nil` if it isn't an update at all.
@treturn boolean Whether the names changed, and should be saved.
@treturn string|nil What happened, for the log.
]]
local function handle_update(message, context)
    if type(message) ~= "table" or message.op ~= "update" or not is_integer(message.id, 0, 0x7FFFFFFF) then
        return nil, false
    end
    local function refuse(code, why)
        return { id = message.id, code = code, error = why }, false,
            ("Refused an update from %s: %s"):format(context.from, why)
    end
    if not context.allowed then return refuse("refused", "it may not update names here") end

    if context.key then
        local now = context.epoch
        if type(message.mac) ~= "string" or type(message.time) ~= "number" then return refuse("refused", "it isn't signed") end
        if not (math.abs(message.time - now) <= UPDATE_WINDOW) then
            return refuse("refused", "it was signed too long ago, or the clocks differ")
        end
        if not crypto.equals(signature(context.key, message), message.mac) then
            return refuse("refused", "it's signed with another key")
        end
        for mac, time in pairs(context.seen) do
            if time < now - 2 * UPDATE_WINDOW then context.seen[mac] = nil end
        end
        if context.seen[message.mac] then return refuse("refused", "it was sent before") end
        context.seen[message.mac] = now
    end

    local zone_name = type(message.zone) == "string" and normalise(message.zone) or nil
    local name = type(message.name) == "string" and message.name:lower() or nil
    if not is_label(name) or not is_owner(message.owner) then
        return refuse("invalid", "it needs a name, without dots, and who it's for")
    end
    local zone
    for _, each in ipairs(context.zones) do
        if each.zone == zone_name and not each.servers then zone = each end
    end
    if not zone then return refuse("not_found", ("%s isn't a zone here"):format(tostring(message.zone))) end
    local full = name .. "." .. zone.zone
    -- A name which a more specific zone answers for would never be found.
    for _, each in ipairs(context.zones) do
        if #each.zone > #zone.zone and each:within(full) then
            return refuse("taken", ("%s is in the zone %s"):format(full, each.zone))
        end
    end

    local names, owner = context.names, message.owner
    names:prune()
    local entry = names.entries[full]
    if entry and entry.owner ~= owner then
        return refuse("taken", ("%s is %s's"):format(full, entry.owner))
    end

    if message.address == nil then
        if not entry then return { id = message.id, code = "ok" }, false end
        names.entries[full], names.count = nil, names.count - 1
        return { id = message.id, code = "ok" }, true, ("Deleted %s (%s, from %s)"):format(full, owner, context.from)
    end

    local addr, lifetime = message.address, message.lifetime
    if not address.is_valid(addr) or addr == 0 or addr == 0xFFFFFFFF or address.is_loopback(addr)
        or not is_integer(lifetime, 1, MAX_LIFETIME) then
        return refuse("invalid", "it needs an address, and how long the name lasts")
    end
    if zone.records[name] then return refuse("taken", ("%s is in the zone's file"):format(full)) end
    if not entry and names.count >= MAX_NAMES then return refuse("refused", "there are too many names") end

    local changed = not entry or entry.address ~= addr
    if not entry then names.count = names.count + 1 end
    names.entries[full] = { zone = zone.zone, name = name, address = addr, expires = names.clock() + lifetime, owner = owner }
    return { id = message.id, code = "ok" }, true,
        changed and ("Set %s to %s (%s, from %s)"):format(full, address.format(addr), owner, context.from) or nil
end

local Updater = {}
Updater.__index = Updater

--[[- Keep names up to date at a DNS server, as a DHCP server does for its clients: each name's latest change is sent,
one at a time, and what goes wrong is said.

@tparam {
    send = function(make:function():table, done:function(answer:table|nil, err:string|nil)),
    zone = string, key? = string, epoch = function():number, log? = function(text:string),
} options How to send an update and wait for its answer (`make` makes it, afresh for each attempt, and `done` is
called with the answer, or why there isn't one); the zone the names are in; the secret to sign updates with; a clock
in milliseconds (as `os.epoch("utc")`); and what to do with what went wrong.
@treturn table The updater.
@see stack_sender A way to send updates.
]]
local function new_updater(options)
    return setmetatable({
        send = options.send, zone = options.zone, key = options.key, epoch = options.epoch,
        log = options.log or function() end, busy = {}, waiting = {},
    }, Updater)
end

function Updater:queue(name, change)
    if self.busy[name] then
        self.waiting[name] = change
        return
    end
    self.busy[name] = true
    local fields = {
        zone = self.zone, name = name, address = change.address, lifetime = change.lifetime, owner = change.owner,
    }
    self.send(function() return update_message(fields, self.key, self.epoch()) end, function(answer, err)
        local what = ("%s %s.%s"):format(change.address and "set" or "delete", name, self.zone)
        if type(answer) ~= "table" then
            self.log(("Couldn't %s: %s"):format(what, tostring(err)))
        elseif answer.code ~= "ok" then
            self.log(("The DNS server wouldn't %s: %s"):format(what, tostring(answer.error or answer.code)))
        end
        self.busy[name] = nil
        local after = self.waiting[name]
        if after then
            self.waiting[name] = nil
            self:queue(name, after)
        end
    end)
end

--[[- Set a name to an address.

@tparam string name The name, within the zone (a computer's hostname, say).
@tparam number addr The address.
@tparam number lifetime How long it lasts, in seconds, unless it's set again.
@tparam string owner Who it's for, such as `"computer 12"`.
]]
function Updater:set(name, addr, lifetime, owner)
    self:queue(name, { address = addr, lifetime = math.max(1, math.min(math.floor(lifetime), MAX_LIFETIME)), owner = owner })
end

--- Delete a name.
--
-- @tparam string name The name, within the zone.
-- @tparam string owner Who it was for.
function Updater:delete(name, owner)
    self:queue(name, { owner = owner })
end

--[[- Send updates from a network stack, to a DNS server, trying a few times: for [`updater`].

@tparam table stack The network stack.
@tparam number server The server's address.
@treturn function(make:function():table, done:function) The way to send updates.
]]
local function stack_sender(stack, server)
    return function(make, done)
        local attempt = 0
        local function try()
            attempt = attempt + 1
            local got
            ask(stack, server, DNS_PORT, make(), UPDATE_TIMEOUT, function(answer)
                got = answer
                return true
            end, function(err)
                if got then return done(got) end
                if attempt < UPDATE_ATTEMPTS then return try() end
                done(nil, err or "No answer")
            end)
        end
        try()
    end
end

return {
    DNS_PORT = DNS_PORT,
    UPDATE_TIMEOUT = UPDATE_TIMEOUT,
    UPDATE_ATTEMPTS = UPDATE_ATTEMPTS,
    UPDATE_WINDOW = UPDATE_WINDOW,
    MAX_NAMES = MAX_NAMES,
    MAX_ALIASES = MAX_ALIASES,
    MDNS_PORT = MDNS_PORT,
    normalise = normalise,
    respond = respond,
    ask = ask,
    resolve = resolve,
    lookup = lookup,
    parse_record = parse_record,
    parse_zone = parse_zone,
    server = new_server,
    forward = new_forward,
    relay = new_relay,
    bad_aliases = bad_aliases,
    update_message = update_message,
    names = new_names,
    handle_update = handle_update,
    updater = new_updater,
    stack_sender = stack_sender,
}
