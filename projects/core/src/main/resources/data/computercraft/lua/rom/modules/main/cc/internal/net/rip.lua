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

@local
]]

local address = require "cc.net.address"

--- The port routers talk on.
local PORT = 520

local INFINITY = 16
local UPDATE_INTERVAL, UPDATE_JITTER = 15, 3
local TIMEOUT, GARBAGE = 90, 60
local CHECK_INTERVAL = 5
local TRIGGER_DELAY = 1
local MAX_LINK_COST = 8

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

local function usable(interface)
    return interface ~= nil and interface.address ~= nil and not interface.duplicate
end

--[[- Start the routing protocol on a stack.

@tparam table stack The network stack.
@tparam {
    default? = boolean,
    key? = string,
    hmac? = function(key:string, data:string):string,
} options Whether to tell other routers this one is the way to everywhere else (a default route); and a shared key,
with a way to compute an HMAC, to sign updates and ignore unsigned ones.
@treturn table The running protocol, with a `stop` method.
]]
local function start(stack, options)
    local self = setmetatable({ stack = stack, options = options or {} }, Rip)
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
    if interface.kind ~= "wireless" then return 1 end
    local known = interface.neighbours[neighbour]
    local signal = known and known.signal
    if not signal then return 1 end
    return math.min(MAX_LINK_COST, 1 + math.max(0, math.floor((-60 - signal) / 10)))
end

--- The routes to tell the neighbours on an interface about.
--
-- @tparam table interface The interface.
-- @treturn { table... } The routes.
function Rip:routes_for(interface)
    local routes = {}
    for _, other in pairs(self.stack.interfaces) do
        if usable(other) then routes[#routes + 1] = { network = other.network, prefix = other.prefix, metric = 0 } end
    end
    for _, route in ipairs(self.stack.routes) do
        if route.source == "rip" or route.source == "static" then
            local metric = route.metric
            -- Never advertise a route back over the link it goes through: the router there would send traffic straight
            -- back to us.
            if route.source == "rip" and route.interface == interface.name then metric = INFINITY end
            if route.gateway and address.contains(interface.network, interface.prefix, route.gateway) then metric = INFINITY end
            routes[#routes + 1] = { network = route.network, prefix = route.prefix, metric = metric }
        end
    end
    if self.options.default then routes[#routes + 1] = { network = 0, prefix = 0, metric = 0 } end
    return routes
end

--- Tell every neighbour our routes.
function Rip:advertise()
    for name, interface in pairs(self.stack.interfaces) do
        if usable(interface) then
            local routes = self:routes_for(interface)
            local message = { version = 1, routes = routes }
            if self.options.key then message.mac = self.options.hmac(self.options.key, canonical(routes)) end
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
    self.check_timer = self.stack:schedule(CHECK_INTERVAL, function() self:check() end)
end

local function find(stack, network, prefix)
    for _, route in ipairs(stack.routes) do
        if route.source == "rip" and route.network == network and route.prefix == prefix then return route end
    end
end

local function connected(stack, network, prefix)
    for _, interface in pairs(stack.interfaces) do
        if usable(interface) and interface.network == network and interface.prefix == prefix then return true end
    end
    return false
end

--- Handle an update from a neighbour.
--
-- @param message The update.
-- @tparam number from The neighbour's address.
-- @tparam string|nil name The interface it arrived on.
function Rip:receive(message, from, name)
    local stack = self.stack
    local interface = name and stack.interfaces[name]
    if not usable(interface) or type(message) ~= "table" or type(message.routes) ~= "table" then return end
    -- Only listen to routers on this link.
    if from == interface.address or not address.contains(interface.network, interface.prefix, from) then return end

    local routes = {}
    for _, route in ipairs(message.routes) do
        if type(route) == "table" and type(route.network) == "number" and type(route.prefix) == "number"
            and type(route.metric) == "number" and route.prefix >= 0 and route.prefix <= 32 then
            routes[#routes + 1] = route
        end
    end
    if self.options.key and message.mac ~= self.options.hmac(self.options.key, canonical(routes)) then return end

    local now, cost, changed = stack.clock(), self:link_cost(interface, from), false
    for _, entry in ipairs(routes) do
        local network = address.network(entry.network, entry.prefix)
        -- A router offering the default route is the way to everywhere else, so mustn't learn another way there: it
        -- would send packets for unknown places to a neighbour, which sends them straight back.
        local ours = entry.prefix == 0 and self.options.default
        if not ours and not connected(stack, network, entry.prefix) then
            local metric = math.min(INFINITY, math.max(0, entry.metric) + cost)
            local existing = find(stack, network, entry.prefix)
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
                else
                    stack:add_route {
                        network = network, prefix = entry.prefix, gateway = from, interface = name, metric = metric,
                        source = "rip", expires = now + TIMEOUT,
                    }
                end
                changed = true
            end
        end
    end

    if changed then self:trigger() end
end

return {
    PORT = PORT,
    start = start,
}
