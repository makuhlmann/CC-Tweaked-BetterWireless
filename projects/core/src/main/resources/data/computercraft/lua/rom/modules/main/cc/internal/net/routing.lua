-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Routes and the firewall, for the network stack: which interface (and which router) a packet goes to, and which
packets a router forwards. [`cc.internal.net.stack`] gives its stacks these methods.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local address = require "cc.net.address"
local band = bit32.band

--- How costly a route may be, at most: routes which cost this much are unreachable.
local INFINITY = 16

-- The mask for each prefix length, as `address.mask` gives it, without its checks: routes are looked up for every
-- packet sent or forwarded.
local MASKS = {}
for prefix = 0, 32 do MASKS[prefix] = address.mask(prefix) end

--- Whether an address is a broadcast one on an interface: everyone's, or its network's.
--
-- @tparam table|nil interface The interface.
-- @tparam number addr The address.
-- @treturn boolean Whether it is.
local function is_broadcast(interface, addr)
    return addr == address.BROADCAST or (interface ~= nil and addr == interface.broadcast_address)
end

--- Whether an interface can be used: it has an address, which no other computer on its link has too.
--
-- @tparam table|nil interface The interface.
-- @treturn boolean Whether it can be used.
local function usable(interface)
    return interface ~= nil and interface.address ~= nil and not interface.duplicate
end

local Routing = {}

--- Find the interface on whose network an address is.
--
-- @tparam number addr The address.
-- @treturn table|nil The interface, or `nil` if the address isn't on any of our networks.
function Routing:on_link(addr)
    local best
    for _, interface in pairs(self.interfaces) do
        if usable(interface) and band(addr, MASKS[interface.prefix]) == interface.network
            and (not best or interface.prefix > best.prefix or (interface.prefix == best.prefix and interface.name < best.name)) then
            best = interface
        end
    end
    return best
end

--- Find how to reach an address: the most specific route, then the cheapest. Our own networks cost nothing.
--
-- @tparam number addr The address.
-- @treturn table|nil The interface to send on, or `nil` if there's no route.
-- @treturn number The next hop: the address itself, or the router to hand it to.
-- @treturn table|nil The route used, or `nil` for one of our own networks.
function Routing:route(addr)
    local best, best_hop, best_route, best_prefix, best_metric
    local function consider(interface, hop, route, prefix, metric)
        if not best or prefix > best_prefix or (prefix == best_prefix and (metric < best_metric
            or (metric == best_metric and interface.name < best.name))) then
            best, best_hop, best_route, best_prefix, best_metric = interface, hop, route, prefix, metric
        end
    end

    local direct = self:on_link(addr)
    if direct then consider(direct, addr, nil, direct.prefix, 0) end

    -- Routes are kept longest prefix first, so once one matches, those after it can't do better.
    for _, route in ipairs(self.routes) do
        if best and route.prefix < best_prefix then break end
        if route.metric < INFINITY and band(addr, MASKS[route.prefix]) == route.network then
            if route.gateway then
                -- A router must be on one of our own networks.
                local interface = route.interface and self.interfaces[route.interface] or self:on_link(route.gateway)
                if usable(interface) and band(route.gateway, MASKS[interface.prefix]) == interface.network then
                    consider(interface, route.gateway, route, route.prefix, route.metric)
                end
            elseif usable(self.interfaces[route.interface]) then
                consider(self.interfaces[route.interface], addr, route, route.prefix, route.metric)
            end
        end
    end

    return best, best_hop, best_route
end

--[[- Add a route.

@tparam {
    network = number, prefix = number, gateway? = number, interface? = string, metric? = number,
    source = string, expires? = number,
} route Where the route goes; the router to hand packets to (or the interface, for a network reached directly); its
cost (1 by default); and where it came from, such as `"static"`, `"dhcp"` or `"rip"`.
@treturn table The route, which may be changed in place.
]]
function Routing:add_route(route)
    route.network = address.network(route.network, route.prefix)
    route.metric = route.metric or 1
    -- Longest prefix first (see `route`), and in the order they were added for each length.
    local routes, at = self.routes, #self.routes + 1
    while at > 1 and routes[at - 1].prefix < route.prefix do at = at - 1 end
    table.insert(routes, at, route)
    return route
end

--- Remove every route matching a test.
--
-- @tparam function(route:table):boolean test Whether to remove a route.
-- @treturn number How many were removed.
function Routing:remove_routes(test)
    local kept, removed = {}, 0
    for _, route in ipairs(self.routes) do
        if test(route) then removed = removed + 1 else kept[#kept + 1] = route end
    end
    self.routes = kept
    return removed
end

--- Describe every route, including our own networks.
--
-- @treturn { table... } Each route's `network` and `prefix`; `gateway` and `interface`; `metric`; `source`; and, for
-- learned routes, `expires` (seconds left).
function Routing:route_info()
    local result, now = {}, self.clock()
    for _, interface in pairs(self.interfaces) do
        if usable(interface) then
            result[#result + 1] = {
                network = interface.network, prefix = interface.prefix, interface = interface.name, metric = 0,
                source = "connected",
            }
        end
    end
    for _, route in ipairs(self.routes) do
        result[#result + 1] = {
            network = route.network, prefix = route.prefix, gateway = route.gateway, metric = route.metric,
            interface = route.interface or (route.gateway and self:on_link(route.gateway) or {}).name,
            source = route.source, expires = route.expires and route.expires - now,
        }
    end
    table.sort(result, function(a, b)
        if a.prefix ~= b.prefix then return a.prefix > b.prefix end
        if a.network ~= b.network then return a.network < b.network end
        return a.metric < b.metric
    end)
    return result
end

--[[- Set the rules for which packets this computer forwards. Rules are tried in order, and the first which matches a
packet decides. Packets which match no rule are forwarded.

@tparam { {
    action = string, proto? = string, src? = number, src_prefix? = number, dst? = number, dst_prefix? = number,
    port? = number, interface? = string,
}... } rules Each rule's action (`"allow"` or `"deny"`), and what it matches: the protocol, source and destination
networks, destination port, and the interface the packet arrived on.
]]
function Routing:set_firewall(rules)
    self.firewall = #rules > 0 and rules or nil
end

local function firewall_matches(rule, packet, interface)
    if rule.proto and rule.proto ~= packet.proto then return false end
    if rule.src and not address.contains(rule.src, rule.src_prefix, packet.src) then return false end
    if rule.dst and not address.contains(rule.dst, rule.dst_prefix, packet.dst) then return false end
    if rule.interface and rule.interface ~= interface.name then return false end
    if rule.port then
        local body = packet.body
        if type(body) ~= "table" or body.dp ~= rule.port then return false end
    end
    return true
end

--- Check whether the firewall lets a packet through.
--
-- @tparam table packet The packet.
-- @tparam table interface The interface it arrived on.
-- @treturn boolean Whether to forward it.
function Routing:firewall_allows(packet, interface)
    for _, rule in ipairs(self.firewall or {}) do
        if firewall_matches(rule, packet, interface) then return rule.action ~= "deny" end
    end
    return true
end

--- Give a stack's class the methods here.
--
-- @tparam table Stack The class.
local function install(Stack)
    for name, method in pairs(Routing) do Stack[name] = method end
end

return {
    INFINITY = INFINITY,
    usable = usable,
    is_broadcast = is_broadcast,
    install = install,
}
