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
value is an address, and an `"SRV"` record's is `{ host = string, address = number, port = number }`. `hops` is how
many times a question has been forwarded already: none, if it isn't there.

@local
]]

local address = require "cc.net.address"

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

--- How long a DNS server remembers that a name it forwarded a question about doesn't exist, in seconds.
local NOT_FOUND_TTL = 10

--- How many forwarded questions a DNS server waits on at once. Beyond that, it refuses questions it would forward.
local MAX_FORWARDING = 64

--- Normalise a name: lower case, without a trailing dot.
--
-- @tparam string name The name.
-- @treturn string The normalised name.
local function normalise(name)
    return (name:lower():gsub("%.$", ""))
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

--- Parse a zone file: one `name address` pair per line, with `#` starting a comment. `@` means the zone itself.
--
-- @tparam string text The file's contents.
-- @treturn { [string] = number } The records.
-- @treturn { string... } Any lines which couldn't be read.
local function parse_zone(text)
    local records, errors = {}, {}
    local line_number = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line_number = line_number + 1
        line = line:gsub("#.*", "")
        local name, value = line:match("^%s*(%S+)%s+(%S+)%s*$")
        local addr = value and address.parse(value)
        if addr then
            records[normalise(name)] = addr
        elseif line:find("%S") then
            errors[#errors + 1] = ("Line %d: expected a name and an address"):format(line_number)
        end
    end
    return records, errors
end

local Server = {}
Server.__index = Server

--[[- Create a DNS server's logic, for one zone. The server itself is up to the caller.

@tparam string zone The zone, such as `"home"`. The server answers for names ending in it.
@tparam { [string] = number } records Names within the zone (such as `"bank"` for `bank.home`), with their addresses.
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

--- Answer a question.
--
-- @param question The question.
-- @treturn table|nil The answer, or `nil` if the question wasn't valid.
function Server:handle(question)
    if type(question) ~= "table" or type(question.id) ~= "number" or type(question.name) ~= "string" then return nil end

    local name = normalise(question.name)
    local relative = self:within(name)
    if not relative then return { id = question.id, code = "refused" } end

    if question.type ~= "A" then return { id = question.id, code = "not_found" } end

    local addr = self.records[relative]
    if not addr and self.extra then addr = self.extra()[relative] end
    if not addr then return { id = question.id, code = "not_found" } end
    return { id = question.id, code = "ok", records = { { name = name, type = "A", value = addr, ttl = 60 } } }
end

local Relay = {}
Relay.__index = Relay

--[[- Create the logic of a DNS server for several zones, which forwards questions about names in other zones to other
DNS servers. Sending and receiving is up to the caller: each method returns what to send, as a list of
`{ client = client, answer = answer }` (an answer for whoever asked) and `{ server = address, question = question }` (a
question for another server's DNS port).

A name is answered by the most specific zone it's in. Names in none are forwarded: to each server in turn, until one
answers, or says the name doesn't exist, which is passed back. If every server refuses, or none answers in time, the
question is refused, so whoever asked tries their next server. Each forwarded question carries how many times it's been
forwarded, and the deadline for each time is shorter, so a chain of servers answers before the first gives up; one
forwarded too many times is refused, which also ends loops between servers. Answers are kept for as long as they say
(names which don't exist, briefly), and refusals never.

@tparam {
    zones = { table... }, forward = function():{ number... }, clock = function():number, random? = function():number,
} options The zones (from [`server`]); the servers to forward to (asked for each question, so they may change); a clock in
seconds; and random question IDs.
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

--[[- A question from a client.

@param question The question.
@param client Whoever asked, given back with the answer.
@treturn { table... } What to send.
]]
function Relay:question(question, client)
    if type(question) ~= "table" or type(question.id) ~= "number" or type(question.name) ~= "string" then return {} end
    local name = normalise(question.name)
    local zone = self:zone_of(name)
    if zone then return { { client = client, answer = zone:handle(question) } } end

    -- Forwarded more times than there are deadlines for (or nonsense): no further.
    local hops = question.hops or 0
    if not FORWARD_DEADLINES[hops] then return { reply(client, question.id, "refused") } end

    local now = self.clock()
    local key = name .. " " .. tostring(question.type)
    local cached = self.cache[key]
    if cached and cached.expires > now then return { reply(client, question.id, cached.code, cached.records) } end

    local servers = self.forward()
    if not servers[1] or self.forwarding >= MAX_FORWARDING then return { reply(client, question.id, "refused") } end

    self.forwarding = self.forwarding + 1
    return self:ask_next({
        client = client, id = question.id, name = name, type = question.type, hops = hops + 1, key = key,
        servers = servers, server = 0, deadline = now + FORWARD_DEADLINES[hops],
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
        return { reply(forwarded.client, forwarded.id, answer.code, records) }
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

return {
    DNS_PORT = DNS_PORT,
    MDNS_PORT = MDNS_PORT,
    normalise = normalise,
    respond = respond,
    ask = ask,
    resolve = resolve,
    lookup = lookup,
    parse_zone = parse_zone,
    server = new_server,
    relay = new_relay,
}
