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
   `net.dns` setting.

A question is `{ id = number, name = string, type = "A" or "SRV" }`, and an answer
`{ id = number, code = "ok" or "not_found" or "refused", records = { { name, type, value, ttl }... } }`. An `"A"` record's
value is an address, and an `"SRV"` record's is `{ host = string, address = number, port = number }`.

@local
]]

local address = require "cc.net.address"

--- The port DNS servers listen on.
local DNS_PORT = 53

--- The port every computer answers `.local` questions on.
local MDNS_PORT = 5353

local DNS_TIMEOUT, MDNS_TIMEOUT = 1.5, 1
local MAX_TTL = 300

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
        options.cache[name] = { address = addr, expires = stack.clock() + ttl(record) }
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

--- Answer a question.
--
-- @param question The question.
-- @treturn table|nil The answer, or `nil` if the question wasn't valid.
function Server:handle(question)
    if type(question) ~= "table" or type(question.id) ~= "number" or type(question.name) ~= "string" then return nil end

    local name = normalise(question.name)
    local suffix = "." .. self.zone
    local relative
    if name == self.zone then
        relative = "@"
    elseif name:sub(-#suffix) == suffix then
        relative = name:sub(1, -#suffix - 1)
    else
        return { id = question.id, code = "refused" }
    end

    if question.type ~= "A" then return { id = question.id, code = "not_found" } end

    local addr = self.records[relative]
    if not addr and self.extra then addr = self.extra()[relative] end
    if not addr then return { id = question.id, code = "not_found" } end
    return { id = question.id, code = "ok", records = { { name = name, type = "A", value = addr, ttl = 60 } } }
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
}
