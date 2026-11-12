-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A distance-vector routing protocol, modelled on RIP, so routers learn routes from each other.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `net.rip` setting instead.

Every 15 seconds, and soon after anything changes, a router tells each of its links which networks it can reach, and
at what cost. A neighbour accepts a route if it's cheaper than what it has, adding the cost of the link the update came
over. Routes aren't advertised back over the link they were learned from (they're advertised as unreachable instead,
"poisoned reverse"), which stops most routing loops. A route which isn't refreshed for 90 seconds becomes unreachable,
and is forgotten a minute later.

Links cost 1, except radio links, which cost more the weaker the neighbour's signal: 1 at -60 dBm or better, and 1 more
for each 10 dB weaker. Routes prefer strong links, which lose fewer packets.

With a shared key, updates are signed: their routes, the time they were sent (in milliseconds, as `os.epoch("utc")`
gives, and never the same twice from one router) and the sender's address. A router takes an update only if it's newer
than the last it took from that neighbour, and no more than a minute out, so an update which was overheard can't be
sent again later to bring back a route which was withdrawn.

@local
]]

local address = require "cc.net.address"

--- The port routers talk on.
local PORT = 520

local INFINITY = 16
-- The most routes a router learns. More than this is probably a misbehaving neighbour, and would slow down every packet.
local MAX_ROUTES = 1024
local UPDATE_INTERVAL, UPDATE_JITTER = 15, 3
local TIMEOUT, GARBAGE = 90, 60
local CHECK_INTERVAL = 5
local TRIGGER_DELAY = 1
local MAX_LINK_COST = 8
-- The version of the updates we send. Version 2 signs the time and the sender's address too.
local VERSION = 2
-- How far a signed update's time may be from ours, in milliseconds, before it's taken for a recording.
local MAX_AGE = 60 * 1000

local Rip = {}
Rip.__index = Rip

--- The canonical text of a list of routes, for signing.
--
-- @tparam { table... } routes The routes.
-- @treturn string The text.
local function canonical(routes)
    local parts = {}
    for i, route in ipairs(routes) do parts[i] = ("%d/%d/%d"):format(route.network, route.prefix, route.metric) end
    return table.concat(parts, ";")
end

--- The text of an update which is signed: its routes, when it was sent, and who sent it.
local function signed_text(routes, time, from)
    return ("%s|%d|%d"):format(canonical(routes), time, from)
end

local function usable(interface)
    return interface ~= nil and interface.address ~= nil and not interface.duplicate
end

--- Whether a network may be routed: not loopback, link-local or multicast addresses, which only mean something on
-- this computer or this link.
--
-- @tparam number network The network.
-- @tparam number prefix Its prefix length.
-- @treturn boolean Whether routers may share routes to it.
local function routable(network, prefix)
    if prefix == 0 then return true end
    return not address.is_loopback(network) and not address.is_link_local(network) and network < 0xE0000000
end

--[[- Start the routing protocol on a stack.

@tparam table stack The network stack.
@tparam {
    default? = boolean,
    key? = string,
    hmac? = function(key:string, data:string):string,
    equals? = function(a:string, b:string):boolean,
    epoch? = function():number,
} options Whether to tell other routers this one is the way to everywhere else (a default route); a shared key, with a
way to compute an HMAC, to sign updates and ignore unsigned ones, and a way to compare signatures which takes as long
whatever they are (`crypto.equals`); and the time, in milliseconds (`os.epoch("utc")` by default).
@treturn table The running protocol, with a `stop` method.
]]
local function start(stack, options)
    options = options or {}
    local self = setmetatable({
        stack = stack, options = options, epoch = options.epoch or function() return os.epoch("utc") end,
        -- Signed updates: the time of the last we sent, and of the last we took from each neighbour.
        sent_time = 0, heard = {},
    }, Rip)
    self.socket = stack:udp_open(PORT, function(message, from, _, name) self:receive(message, from, name) end)
    if not self.socket then error("Port " .. PORT .. " is in use", 2) end

    self.update_timer = stack:schedule(math.random() * UPDATE_JITTER, function() self:periodic() end)
    self.check_timer = stack:schedule(CHECK_INTERVAL, function() self:check() end)
    return self
end

--- Stop the routing protocol, forgetting every route it learned.
function Rip:stop()
    local stack = self.stack
    stack:udp_close(self.socket)
    stack:cancel(self.update_timer)
    stack:cancel(self.check_timer)
    stack:cancel(self.trigger_timer)
    stack:remove_routes(function(route) return route.source == "rip" end)
end

function Rip:link_cost(interface, neighbour)
    -- Radio links: wireless modems', and ender modems', which are radios too.
    if interface.kind ~= "wireless" and interface.kind ~= "ender" then return 1 end
    local known = interface.neighbours[neighbour]
    local signal = known and known.signal
    if not signal then return 1 end
    return math.min(MAX_LINK_COST, 1 + math.max(0, math.floor((-60 - signal) / 10)))
end

--- The routes to tell the neighbours on an interface about. Each network appears once, with its lowest cost.
--
-- @tparam table interface The interface.
-- @treturn { table... } The routes.
function Rip:routes_for(interface)
    local routes, seen = {}, {}
    local function add(network, prefix, metric)
        local key = network .. "/" .. prefix
        local existing = seen[key]
        if existing then
            existing.metric = math.min(existing.metric, metric)
        else
            existing = { network = network, prefix = prefix, metric = metric }
            seen[key] = existing
            routes[#routes + 1] = existing
        end
    end

    local names = {}
    for name in pairs(self.stack.interfaces) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local other = self.stack.interfaces[name]
        if usable(other) and routable(other.network, other.prefix) then add(other.network, other.prefix, 0) end
    end
    for _, route in ipairs(self.stack.routes) do
        if route.source == "rip" or route.source == "static" then
            local metric = route.metric
            -- Never advertise a route back over the link it goes through: the router there would send traffic straight
            -- back to us.
            if route.source == "rip" and route.interface == interface.name then metric = INFINITY end
            if route.gateway and address.contains(interface.network, interface.prefix, route.gateway) then metric = INFINITY end
            add(route.network, route.prefix, metric)
        end
    end
    if self.options.default then add(0, 0, 0) end
    return routes
end

--- Tell every neighbour our routes.
function Rip:advertise()
    for name, interface in pairs(self.stack.interfaces) do
        -- Routers don't talk over virtual links, such as to phones.
        if usable(interface) and not interface.no_rip then
            local routes = self:routes_for(interface)
            local message = { version = VERSION, routes = routes }
            if self.options.key then
                local time = math.max(math.floor(self.epoch()), self.sent_time + 1)
                self.sent_time = time
                message.time = time
                message.mac = self.options.hmac(self.options.key, signed_text(routes, time, interface.address))
            end
            self.stack:send_broadcast(name, "udp", { sp = PORT, dp = PORT, data = message })
        end
    end
end

function Rip:periodic()
    self:advertise()
    self.update_timer = self.stack:schedule(UPDATE_INTERVAL + math.random() * UPDATE_JITTER, function() self:periodic() end)
end

--- Send an update soon, after something changed. Several changes close together only send one.
function Rip:trigger()
    if self.trigger_timer then return end
    self.trigger_timer = self.stack:schedule(TRIGGER_DELAY, function()
        self.trigger_timer = nil
        self:advertise()
    end)
end

--- Mark routes which haven't been refreshed as unreachable, and forget them a while later.
function Rip:check()
    local now, changed = self.stack.clock(), false
    self.stack:remove_routes(function(route)
        if route.source ~= "rip" or route.expires > now then return false end
        if route.metric < INFINITY then
            route.metric, route.expires, changed = INFINITY, now + GARBAGE, true
            return false
        end
        return true
    end)
    if changed then self:trigger() end
    -- Forget when we last heard from neighbours which have gone quiet: anything older is refused by its age anyway.
    for from, heard in pairs(self.heard) do
        if now - heard.at > TIMEOUT + GARBAGE then self.heard[from] = nil end
    end
    self.check_timer = self.stack:schedule(CHECK_INTERVAL, function() self:check() end)
end

-- The routes we learned, by network and prefix, and how many there are.
local function learned(stack)
    local index, count = {}, 0
    for _, route in ipairs(stack.routes) do
        if route.source == "rip" then
            index[route.network * 64 + route.prefix] = route
            count = count + 1
        end
    end
    return index, count
end

-- Our own networks, by network and prefix.
local function connected(stack)
    local result = {}
    for _, interface in pairs(stack.interfaces) do
        if usable(interface) then result[interface.network * 64 + interface.prefix] = true end
    end
    return result
end

local function is_integer(value, min, max)
    return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

--- Handle an update from a neighbour.
--
-- @param message The update.
-- @tparam number from The neighbour's address.
-- @tparam string|nil name The interface it arrived on.
function Rip:receive(message, from, name)
    local stack = self.stack
    local interface = name and stack.interfaces[name]
    if not usable(interface) or interface.no_rip or type(message) ~= "table" or type(message.routes) ~= "table" then return end
    -- Only listen to routers on this link.
    if from == interface.address or not address.contains(interface.network, interface.prefix, from) then return end

    -- Ignore anything which isn't a route, so nothing odd ends up in the routing table.
    local routes = {}
    for _, route in ipairs(message.routes) do
        if type(route) == "table" and address.is_valid(route.network) and is_integer(route.prefix, 0, 32)
            and is_integer(route.metric, 0, math.huge) then
            routes[#routes + 1] = route
        end
    end
    local now = stack.clock()
    if self.options.key then
        local time = message.time
        if not is_integer(time, 0, 2 ^ 53) or type(message.mac) ~= "string" then return end
        local expected = self.options.hmac(self.options.key, signed_text(routes, time, from))
        local equals = self.options.equals
        if equals then
            if not equals(message.mac, expected) then return end
        elseif message.mac ~= expected then
            return
        end
        -- A recording, sent again: older than the last we took from this neighbour, or than a minute ago.
        local heard = self.heard[from]
        if (heard and time <= heard.time) or math.abs(time - self.epoch()) > MAX_AGE then return end
        self.heard[from] = { time = time, at = now }
    end

    local cost, changed = self:link_cost(interface, from), false
    local index, count = learned(stack)
    local ours = connected(stack)
    for _, entry in ipairs(routes) do
        local network = address.network(entry.network, entry.prefix)
        -- A router offering the default route is the way to everywhere else, so mustn't learn another way there: it
        -- would send packets for unknown places to a neighbour, which sends them straight back.
        local default = entry.prefix == 0 and self.options.default
        if not default and not ours[network * 64 + entry.prefix] and routable(network, entry.prefix) then
            local metric = math.min(INFINITY, entry.metric + cost)
            local existing = index[network * 64 + entry.prefix]
            if existing and existing.gateway == from then
                -- News from the router we already use: believe it, good or bad.
                if metric < INFINITY then
                    existing.expires = now + TIMEOUT
                elseif existing.metric < INFINITY then
                    existing.expires = now + GARBAGE
                end
                if metric ~= existing.metric then
                    existing.metric, changed = metric, true
                end
            elseif metric < INFINITY and (not existing or metric < existing.metric) then
                if existing then
                    existing.gateway, existing.interface, existing.metric, existing.expires = from, name, metric, now + TIMEOUT
                    changed = true
                elseif count < MAX_ROUTES then
                    index[network * 64 + entry.prefix] = stack:add_route {
                        network = network, prefix = entry.prefix, gateway = from, interface = name, metric = metric,
                        source = "rip", expires = now + TIMEOUT,
                    }
                    count, changed = count + 1, true
                end
            end
        end
    end

    if changed then self:trigger() end
end

return {
    PORT = PORT,
    start = start,
}
