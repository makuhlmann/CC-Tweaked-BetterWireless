-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- DHCP: computers asking for network addresses, and servers handing them out.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the [`net`] API instead.

A client broadcasts a `discover` on its link, servers `offer` an address, the client `request`s one offer, and that
server confirms it with an `ack` (or refuses with a `nak`). The address is leased for a while, and the client renews the
lease halfway through. If no server answers, the client gives itself a link-local address (`169.254.0.0/16`), and tries
again later.

Clients run inside the network stack. The server's logic is here too, but a server is run by the `dhcpd` program.

@local
]]

local address = require "cc.net.address"
local is_integer = require "cc.internal.net.checks".is_integer

--- The port DHCP clients listen on.
local CLIENT_PORT = 68

--- The port DHCP servers listen on.
local SERVER_PORT = 67

local REQUEST_TIMEOUT = 2
local ATTEMPTS = 3
local FIRST_RETRY, MAX_RETRY = 15, 300
local OFFER_LIFETIME = 10

-- Leases are at least 30 seconds, so a server handing out very short ones can't make clients renew constantly, and at
-- most a week.
local MIN_LEASE, MAX_LEASE = 30, 7 * 24 * 3600

-- How long a client waits after taking an address to hear whether another computer already has it, and how long a
-- server then avoids that address.
local CONFLICT_CHECK = 1
local DECLINE_TIME = 600

local LINK_LOCAL_NETWORK = address.LINK_LOCAL
--- The prefix length of link-local addresses.
local LINK_LOCAL_PREFIX = address.LINK_LOCAL_PREFIX
local LINK_LOCAL_TRIES = 8

--- Pick a link-local address for a computer. The first attempt depends on the computer's ID, so it usually gets the
-- same address each time. Later attempts, after a clash, are random: two computers whose IDs give the same first
-- address mustn't keep picking the same addresses as each other.
--
-- @tparam number id The computer's ID.
-- @tparam number attempt Which attempt this is, from 1.
-- @treturn number The address, from `169.254.1.0` to `169.254.254.255`.
local function link_local(id, attempt)
    local n = attempt == 1 and id % (254 * 256) or math.random(0, 254 * 256 - 1)
    return LINK_LOCAL_NETWORK + (1 + math.floor(n / 256)) * 256 + n % 256
end


--- Whether an address may be given to a computer: not the network's own address or its broadcast address, nor a
-- loopback, link-local or multicast address.
--
-- @param addr The address, which may be anything.
-- @param prefix The network's prefix length, which may be anything.
-- @treturn boolean Whether it may be used.
local function assignable(addr, prefix)
    if not address.is_valid(addr) or not is_integer(prefix, 1, 32) or address.is_link_local(addr) then return false end
    return (address.check_host(addr, prefix))
end

--- Make a hostname safe: lower case letters, digits and hyphens only.
--
-- @param name The name, which may be anything.
-- @treturn string|nil The cleaned name, or `nil` if nothing is left.
local function clean_hostname(name)
    if type(name) ~= "string" then return nil end
    name = name:lower():gsub("[^%w%-]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 63)
    return name ~= "" and name or nil
end

local function addresses(list)
    local result = {}
    if type(list) == "table" then
        for _, value in ipairs(list) do
            if address.is_valid(value) then result[#result + 1] = value end
        end
    end
    return result
end

local Client = {}
Client.__index = Client

local function clients(stack)
    if stack.dhcp_clients then return stack.dhcp_clients end

    local registry = {}
    stack.dhcp_clients = registry
    stack:udp_open(CLIENT_PORT, function(message, _, _, name)
        local client = name and registry[name]
        if client and type(message) == "table" then client:receive(message) end
    end)
    return registry
end

--[[- Start asking for an address on an interface, replacing any client already running there.

@tparam table stack The network stack.
@tparam string name The interface's name.
@tparam {
    hostname? = function():string,
    on_change? = function(client:table),
} options How to find this computer's hostname, sent to servers; and what to call when the address changes.
@treturn table The client.
]]
local function start(stack, name, options)
    local registry = clients(stack)
    if registry[name] then registry[name]:stop(false) end

    local self = setmetatable({
        stack = stack, name = name, options = options or {},
        state = "init", retry = FIRST_RETRY, link_local_attempt = 0,
    }, Client)
    registry[name] = self
    self:discover()
    return self
end

function Client:set_timer(delay, fn)
    self.stack:cancel(self.timer)
    self.timer = self.stack:schedule(delay, fn)
end

function Client:send(message)
    message.xid, message.client = self.xid, self.stack.id
    message.hostname = self.options.hostname and self.options.hostname()
    self.stack:send_broadcast(self.name, "udp", { sp = CLIENT_PORT, dp = SERVER_PORT, data = message })
end

function Client:changed()
    if self.options.on_change then self.options.on_change(self) end
end

--- Start asking for an address from scratch.
function Client:discover()
    self.state, self.attempts = "discovering", 0
    self.xid = math.random(1, 0x7FFFFFFF)
    self:send_discover()
end

-- Send a discover, unless we've tried enough times already. Offers which come to nothing count as attempts too, so a
-- server which never finishes can't keep us asking.
function Client:send_discover()
    self.state = "discovering"
    if self.attempts >= ATTEMPTS then
        -- Nobody answered. Make do with a link-local address, and try again later, less often each time.
        self:fall_back()
        self:set_timer(self.retry, function() self:discover() end)
        self.retry = math.min(self.retry * 2, MAX_RETRY)
        return
    end

    self.attempts = self.attempts + 1
    self:send({ op = "discover", requested = self.lease and self.lease.address })
    self:set_timer(REQUEST_TIMEOUT, function() self:send_discover() end)
end

function Client:fall_back()
    if self.state ~= "bound" then self.state = "link-local" end

    local interface = self.stack.interfaces[self.name]
    if not interface or self.lease then return end
    if interface.address and interface.address == self.link_local_address and not interface.duplicate then return end

    self.link_local_attempt = self.link_local_attempt + 1
    if self.link_local_attempt > LINK_LOCAL_TRIES then return end

    self.link_local_address = link_local(self.stack.id, self.link_local_attempt)
    self.stack:set_address(self.name, self.link_local_address, LINK_LOCAL_PREFIX)
    self:changed()

    -- If another computer already has this address, we'll have heard by now. Try another.
    self.stack:cancel(self.check)
    self.check = self.stack:schedule(1, function()
        local current = self.stack.interfaces[self.name]
        if current and current.duplicate and current.address == self.link_local_address then self:fall_back() end
    end)
end

function Client:receive(message)
    if message.xid ~= self.xid or message.client ~= self.stack.id then return end

    if message.op == "offer" and self.state == "discovering" then
        if not assignable(message.address, message.prefix) or not address.is_valid(message.server) then return end
        self.state = "requesting"
        self:send({ op = "request", server = message.server, address = message.address })
        self:set_timer(REQUEST_TIMEOUT, function() self:send_discover() end)
    elseif message.op == "ack" and (self.state == "requesting" or self.state == "renewing") then
        self:bind(message)
    elseif message.op == "nak" and (self.state == "requesting" or self.state == "renewing") then
        if self.state == "renewing" then self.attempts = 0 end
        self:unbind()
        -- Ask again, but not straight away: a server which refuses everything mustn't make us flood the network.
        self.state = "discovering"
        self:set_timer(REQUEST_TIMEOUT, function() self:send_discover() end)
    end
end

function Client:bind(message)
    if not assignable(message.address, message.prefix) or not address.is_valid(message.server)
        or type(message.lease) ~= "number" or message.lease ~= message.lease then
        return
    end
    local interface = self.stack.interfaces[self.name]
    if not interface then return end
    local lease_time = math.max(MIN_LEASE, math.min(MAX_LEASE, message.lease))
    -- The gateway must be on the network, or it couldn't be reached.
    local gateway = message.gateway
    if not address.is_valid(gateway) or gateway == message.address or not address.contains(message.address, message.prefix, gateway) then
        gateway = nil
    end

    if interface.address ~= message.address or interface.prefix ~= message.prefix then
        self.stack:set_address(self.name, message.address, message.prefix)
    end
    self.stack:cancel(self.check)
    self.state, self.retry, self.link_local_attempt, self.link_local_address = "bound", FIRST_RETRY, 0, nil
    self.lease = {
        address = message.address, prefix = message.prefix, server = message.server,
        expires = self.stack.clock() + lease_time,
        dns = addresses(message.dns),
        domain = clean_hostname(message.domain),
        gateway = gateway,
    }
    self:changed()

    -- Renew halfway through the lease.
    self:set_timer(lease_time / 2, function() self:renew() end)

    -- If another computer already has the address (the server didn't know), it tells us so straight away. Then tell
    -- the server, so it doesn't hand the address out again, and ask for another.
    self.check = self.stack:schedule(CONFLICT_CHECK, function()
        local current = self.stack.interfaces[self.name]
        if self.lease and current and current.duplicate and current.address == self.lease.address then self:decline() end
    end)
end

function Client:decline()
    self:send({ op = "decline", server = self.lease.server, address = self.lease.address })
    self:unbind()
    self.state, self.attempts = "discovering", 0
    self.xid = math.random(1, 0x7FFFFFFF)
    self:set_timer(REQUEST_TIMEOUT, function() self:send_discover() end)
end

function Client:renew()
    local remaining = self.lease.expires - self.stack.clock()
    if remaining <= 0 then
        self:unbind()
        return self:discover()
    end

    self.state = "renewing"
    self.xid = math.random(1, 0x7FFFFFFF)
    self:send({ op = "request", server = self.lease.server, address = self.lease.address })
    -- Keep trying, more often as the lease runs out.
    self:set_timer(math.min(remaining, math.max(REQUEST_TIMEOUT, remaining / 2)), function() self:renew() end)
end

function Client:unbind()
    if not self.lease then return end
    self.lease = nil
    local interface = self.stack.interfaces[self.name]
    if interface and interface.address then self.stack:set_address(self.name, nil) end
    self:changed()
end

--- Stop the client, optionally telling the server we're done with our address. The address itself is left alone.
--
-- @tparam boolean release Whether to release the lease.
function Client:stop(release)
    if release and self.lease then
        self:send({ op = "release", server = self.lease.server, address = self.lease.address })
    end
    self.stack:cancel(self.timer)
    self.stack:cancel(self.check)
    local registry = self.stack.dhcp_clients
    if registry and registry[self.name] == self then registry[self.name] = nil end
end

--- Describe the client's state.
--
-- @treturn table `state`, and for a lease, its `address`, `server`, `expires` (seconds left), `dns`, `domain` and
-- `gateway`.
function Client:info()
    local info = { state = self.state }
    local lease = self.lease
    if lease then
        info.address, info.server, info.expires = lease.address, lease.server, lease.expires - self.stack.clock()
        info.dns, info.domain, info.gateway = lease.dns, lease.domain, lease.gateway
    end
    return info
end

local Server = {}
Server.__index = Server

--[[- Create a DHCP server's logic. The server itself (receiving requests and sending replies) is up to the caller.

@tparam {
    address = number, prefix = number, first = number, last = number, lease = number,
    dns? = { number... }, domain? = string, gateway? = number,
    clock = function():number, leases? = table, in_use? = function(address:number):boolean,
} options The server's own address and prefix length; the range of addresses to hand out; the lease time in seconds;
what to tell clients about DNS servers, their domain and gateway; a clock in seconds, which should be real time so
leases survive restarts; the leases from last time; and a way to check an address isn't already used by a computer with
a fixed address.
@treturn table The server.
]]
local function new_server(options)
    return setmetatable({
        address = options.address, prefix = options.prefix, first = options.first, last = options.last,
        lease_time = options.lease, dns = options.dns or {}, domain = options.domain, gateway = options.gateway,
        clock = options.clock, in_use = options.in_use,
        leases = options.leases or {}, offers = {}, declined = {},
    }, Server)
end

--- Find the addresses which are in use, other than by one client: leased, offered, or declined because another
-- computer was using them. Expired offers and declines are forgotten.
--
-- @tparam number client The client.
-- @treturn { [number] = true } The addresses.
function Server:used(client)
    local now, used = self.clock(), { [self.address] = true }
    for id, lease in pairs(self.leases) do
        if id ~= client and type(lease) == "table" and address.is_valid(lease.address) and type(lease.expires) == "number"
            and lease.expires > now then
            used[lease.address] = true
        end
    end
    for id, offer in pairs(self.offers) do
        if offer.expires <= now then
            self.offers[id] = nil
        elseif id ~= client then
            used[offer.address] = true
        end
    end
    for addr, expires in pairs(self.declined) do
        if expires <= now then self.declined[addr] = nil else used[addr] = true end
    end
    return used
end

function Server:in_range(addr)
    return address.is_valid(addr) and addr >= self.first and addr <= self.last
end

function Server:choose(client, requested)
    local used = self:used(client)

    -- Prefer the address a client had before, then the one it asks for, so addresses rarely change.
    local previous = self.leases[client]
    if type(previous) == "table" and self:in_range(previous.address) and not used[previous.address] then
        return previous.address
    end
    if self:in_range(requested) and not used[requested] then return requested end

    for addr = self.first, self.last do
        if not used[addr] and not (self.in_use and self.in_use(addr)) then return addr end
    end
end

function Server:reply(message, op, addr)
    return {
        op = op, xid = message.xid, client = message.client, server = self.address, address = addr,
        prefix = self.prefix, lease = self.lease_time, dns = self.dns, domain = self.domain, gateway = self.gateway,
    }
end

--[[- Handle a message from a client.

@param message The message.
@treturn table|nil A reply to broadcast to the client, on port 68.
@treturn boolean Whether the leases changed, and should be saved.
@treturn string|nil A description of what happened, for logging.
]]
function Server:handle(message)
    -- Computer IDs are whole numbers, from 0 up.
    if type(message) ~= "table" or not is_integer(message.client, 0, 0x7FFFFFFF) or not is_integer(message.xid, 0, 0x7FFFFFFF) then
        return nil, false
    end

    local now, client = self.clock(), message.client
    local hostname = clean_hostname(message.hostname)

    if message.op == "discover" then
        local addr = self:choose(client, message.requested)
        if not addr then return nil, false, "No addresses left for #" .. client end
        self.offers[client] = { address = addr, expires = now + OFFER_LIFETIME }
        return self:reply(message, "offer", addr), false
    elseif message.op == "request" then
        if message.server ~= self.address then
            -- The client picked another server's offer.
            self.offers[client] = nil
            return nil, false
        end

        local addr = message.address
        if not self:in_range(addr) or self:used(client)[addr] then
            local text = address.is_valid(addr) and address.format(addr) or "an invalid address"
            return self:reply(message, "nak", nil), false, "Refused " .. text .. " to #" .. client
        end

        self.offers[client] = nil
        -- An address is only ever in one lease, so leases can't pile up however many clients there are.
        for id, lease in pairs(self.leases) do
            if id ~= client and type(lease) == "table" and lease.address == addr then self.leases[id] = nil end
        end
        self.leases[client] = { address = addr, expires = now + self.lease_time, hostname = hostname }
        return self:reply(message, "ack", addr), true,
            ("Leased %s to %s (#%d)"):format(address.format(addr), hostname or "?", client)
    elseif message.op == "release" then
        local lease = self.leases[client]
        if type(lease) == "table" and message.server == self.address and address.is_valid(message.address)
            and lease.address == message.address then
            self.leases[client] = nil
            return nil, true, ("Released %s from #%d"):format(address.format(lease.address), client)
        end
    elseif message.op == "decline" and message.server == self.address and self:in_range(message.address) then
        -- The client found another computer already using the address we gave it.
        local addr = message.address
        self.declined[addr] = now + DECLINE_TIME
        local lease = self.leases[client]
        if type(lease) == "table" and lease.address == addr then self.leases[client] = nil end
        return nil, true, ("%s is used by a computer with a fixed address (declined by #%d)"):format(address.format(addr), client)
    end
    return nil, false
end

--[[- The DHCP client on an interface, if one runs there.

@tparam table stack The network stack.
@tparam string name The interface's name.
@treturn table|nil The client.
]]
local function client(stack, name)
    return stack.dhcp_clients and stack.dhcp_clients[name]
end

--[[- The DHCP clients running, by interface.

@tparam table stack The network stack.
@treturn { [string] = table } Each interface's client.
]]
local function running(stack)
    return stack.dhcp_clients or {}
end

return {
    CLIENT_PORT = CLIENT_PORT,
    client = client,
    running = running,
    SERVER_PORT = SERVER_PORT,
    link_local = link_local,
    clean_hostname = clean_hostname,
    start = start,
    server = new_server,
}
