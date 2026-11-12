-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Cellular networks for testing, on a virtual network: operators, each with a core, cells and a server on a wired
backhaul, and phones and relays on the air.

Each core and cell runs the service the game runs (`cc.internal.net.cell.core_service` and `cell_service`), and they
connect to each other as the game's do, over pipes (`support.pipe`) which stand in for secure connections. A relay's
cell, which reaches its core through its own phone, connects over TCP. Each core keeps its files in a folder of its own,
so it can be restarted, and its cells and other networks' cores join it again by themselves.

Phones hear cells depending on how far away they are: `positions[id]` is where each computer is along a line.
Several operators can share the air and the backhaul, to test roaming: give the second one `join`, the first.
]]

local address = require "cc.net.address"
local noise = require "cc.internal.net.noise"
local tcp = require "cc.internal.net.tcp"
local files = require "cc.internal.net.files"
local cell_core = require "cc.internal.net.cell.core"
local cell_tower = require "cc.internal.net.cell.tower"
local cell_phone = require "cc.internal.net.cell.phone"
local core_service = require "cc.internal.net.cell.core_service"
local cell_service = require "cc.internal.net.cell.cell_service"
local network = require "support.virtual_network"
local pipe = require "support.pipe"

-- How long a control message takes from one computer to another, in seconds.
local LATENCY = 0.01
-- How often relays' TCP connections are looked at, in seconds.
local POLL = 0.05
-- The control port, which relays' cells connect to over TCP.
local CONTROL_PORT = 2123
-- Where cores keep their files: a folder for each, by the order they were made in.
local DIR = "/.cell-harness"
local made = 0
fs.delete(DIR)

local function ip(text) return (address.parse(text)) end
local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function unhex(text) return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)) end
local function new_key() return hex(crypto.random(32)) end
local function fingerprint(key) return hex(crypto.sha256(unhex(key))):sub(1, 20):gsub("(....)", "%1 "):sub(1, -2) end

local function x25519()
    local private = crypto.generateKeyPair("x25519")
    return { public = noise.public_key(crypto, private), exchange = function(public) return crypto.exchange(private, public) end }
end

--[[ Run services on a computer, as its network stack's background process would: resume the service whenever
something it waits for may have changed (once, however many things did), and add its errors to the network's.

`identity` and `address` say who the computer is to those it connects to.
]]
local function new_driver(net, stack, label, identity, addr)
    local driver = { stack = stack, identity = identity, address = addr }
    function driver.poke()
        if driver.pending then return end
        driver.pending = true
        stack:schedule(0, function()
            driver.pending = false
            local service = driver.service
            if not service then return end
            service:resume()
            if service.error and service.error ~= driver.reported then
                driver.reported = service.error
                table.insert(net.errors, ("%s: %s"):format(label, service.error))
            end
        end)
    end
    -- Wait, as the services' tasks do, until enough time has passed.
    function driver.sleep(seconds)
        local deadline = net.time + seconds
        stack:schedule(seconds, driver.poke)
        while net.time < deadline do coroutine.yield() end
    end
    return driver
end

-- Connect a computer (`from`'s driver) to another's service (`to`'s), which it reached at `dialed`.
local function connect(net, from, to, dialed)
    local drivers = { from, to }
    local client, server = pipe(function() return net.time end,
        { key = from.identity, address = from.address }, { key = to.identity, address = dialed }, {
            deliver = function(side, fn) drivers[side].stack:schedule(LATENCY, fn) end,
            changed = function(side) drivers[side].poke() end,
            wake_at = function(side, seconds) drivers[side].stack:schedule(seconds, drivers[side].poke) end,
        })
    to.listener.queue[#to.listener.queue + 1] = server
    to.poke()
    return client
end

-- What a core listens with: the connections other computers have made to it.
local function new_listener(driver)
    local listener = { queue = {} }
    function listener.accept(self)
        while true do
            if self.queue[1] then return table.remove(self.queue, 1) end
            if self.closed then return nil, "Listener is closed" end
            coroutine.yield()
        end
    end
    function listener.close(self)
        self.closed = true
        driver.poke()
    end
    return listener
end

--[[ One end of a control connection over TCP, as a secure connection would be: `connection` is the TCP connection,
`driver` runs the service which uses it, and `peer_key` is the other end's key. What's sent waits until the connection
is open. Nothing says a message has arrived, so the driver must be woken every so often. ]]
local function tcp_end(net, connection, driver, peer_key)
    local outbox, ending = {}, false
    local function flush()
        while outbox[1] and connection.state == "established" do
            if not connection:send(outbox[1]) then break end
            table.remove(outbox, 1)
        end
    end
    local self = {}
    function self.send(_, value)
        if ending or connection.error or connection.state == "closed" then return nil, "Connection closed" end
        outbox[#outbox + 1] = value
        flush()
        return true
    end
    function self.receive(_, timeout)
        local deadline = timeout and net.time + timeout
        if timeout then driver.stack:schedule(timeout, driver.poke) end
        while true do
            flush()
            local ok, value = connection:take()
            if ok then return value end
            if value == "closed" then return nil end
            if value ~= nil then return nil, value end
            if deadline and net.time >= deadline then return nil, "Timed out" end
            coroutine.yield()
        end
    end
    function self.close()
        ending = true
        connection:close()
    end
    function self.abort()
        ending = true
        connection:abort()
    end
    function self.getPeerKey() return peer_key end
    function self.getPeer() return address.format(connection.remote_addr), connection.remote_port end
    return self
end

--[[- Make an operator: by default ACME, with a core (computer 50, which is also the gateway, at 10.0.0.1) and cells
along a line (computers 11 and up), all on a wired backhaul with a server (computer 60). Phones are on the radio link
"air", and hear cells depending on how far away they are: `positions[id]` is where each computer is along the line.

@tparam { number... } cell_positions Where each cell is.
@tparam[opt] {
    join? = table, name? = string, core_id? = number, core_host? = number, cell_base? = number, prefix? = string,
    core_is_cell? = boolean, numbers? = string,
} options Another operator to share the air, the backhaul and the server with; this network's name; its core's ID
and the last part of its address; the number its cells' IDs (and addresses) start after; its phones' network; whether
its first cell is on the core's computer; and its number prefix.
@treturn table The operator.
]]
local function operator(cell_positions, options)
    options = options or {}
    local join = options.join
    local name, prefix = options.name or "ACME", options.prefix or "10.64.0.0/16"
    local core_id, core_address = options.core_id or 50, "10.0.0." .. (options.core_host or 1)
    local cell_base = options.cell_base or 10

    local net = join and join.net or network()
    local positions = join and join.positions or {}
    if not join then
        net.frame_limit = 5000
        net.reach = function(link, sender, receiver)
            if link ~= "air" or not sender then return -50 end
            local a, b = positions[sender.id], positions[receiver.id]
            if not a or not b then return false end
            local signal = -50 - math.abs(a - b) * 0.5
            if signal < -110 then return false end
            return signal
        end
    end
    -- The operators which share the backhaul, and which pairs of cores can't reach each other.
    local world = join and join.world or { operators = {}, cut = {} }

    local operator_key = x25519()
    local signing_private, signing_public = crypto.generateKeyPair("ed25519")
    local now = function() return 1.7e12 + net.time * 1000 end
    local identity, secret = new_key(), crypto.random(32)
    made = made + 1
    local dir = fs.combine(DIR, made .. "-" .. name)

    local core_stack = net.stack(core_id)
    net.connect(core_stack, "backhaul", core_address .. "/24")
    core_stack.forwarding = true
    local core = new_driver(net, core_stack, name .. "'s core", identity, core_address)
    local events = {}
    local setup = {
        net = net, world = world, core_stack = core_stack, positions = positions, events = events, name = name,
        identity = identity, core_id = core_id, core_address = core_address, number_prefix = options.numbers,
        signing_public = signing_public, signing_private = signing_private, operator_key = operator_key, now = now,
    }
    world.operators[#world.operators + 1] = setup

    local server = join and join.server
    if not server then
        server = net.stack(60)
        net.connect(server, "backhaul", "10.0.0.60/24")
    end
    setup.server = server
    do
        local phones, length = address.parse(prefix)
        server:add_route { network = phones, prefix = length, gateway = ip(core_address), source = "static" }
    end

    -- The operator whose core has an address, if any does.
    local function core_at(text)
        local target = ip(text)
        for _, other in ipairs(world.operators) do
            for _, interface in pairs(other.core_stack.interfaces) do
                if interface.address == target then return other end
            end
        end
    end
    -- Connect to a core (as a cell, or as another core): over a pipe, unless the two cores can't reach each other.
    local function dial(from, text, from_network)
        local target = core_at(text)
        if not target then return nil, "No route to host" end
        if from_network and world.cut[from_network .. ">" .. target.name] then return nil, "No route to host" end
        return connect(net, from, target.driver, text)
    end
    setup.driver = core

    -- Cells, each with a key of its own, which the core certifies. The core's own computer may be one.
    local towers, allowed = {}, {}
    for i, position in ipairs(cell_positions) do
        local id = cell_base + i
        local stack = options.core_is_cell and i == 1 and core_stack or net.stack(id)
        id = stack.id
        if stack ~= core_stack then net.connect(stack, "backhaul", "10.0.0." .. (cell_base + i) .. "/24") end
        net.connect(stack, "air", nil, "wireless")
        positions[id] = position

        local cell_private, cell_public = crypto.generateKeyPair("ed25519")
        local key = stack == core_stack and identity or new_key()
        local addr = address.format(stack.interfaces.backhaul.address)
        towers[i] = {
            index = i, id = id, stack = stack, address = stack.interfaces.backhaul.address, public = cell_public,
            sign = function(data) return crypto.sign(cell_private, data) end, shared = {},
            driver = new_driver(net, stack, ("%s's cell #%d"):format(name, id), key, addr),
        }
        if key ~= identity then allowed[key] = { label = "cell #" .. id, role = "cell", id = id } end
    end
    setup.towers = towers

    files.write_table(fs.combine(dir, "config"), { network = name, prefix = prefix, number_prefix = options.numbers })
    files.write_table(fs.combine(dir, "cells"), allowed)

    local function start_core()
        core.listener = new_listener(core)
        local service = assert(core_service.new {
            dir = dir, identity = identity, fingerprint = fingerprint, id = core_id,
            listen = function() return core.listener end,
            start_core = function(core_options)
                return cell_core.new {
                    stack = core_stack, crypto = crypto, network = core_options.network, prefix = core_options.prefix,
                    operator = operator_key, signing = signing_public, subscribers = core_options.subscribers,
                    codes = core_options.codes, secret = secret, epoch = now, number_prefix = core_options.number_prefix,
                    on_event = function(...)
                        events[#events + 1] = { ... }
                        return core_options.on_event(...)
                    end,
                }
            end,
            signing = signing_public, sign = function(data) return crypto.sign(signing_private, data) end,
            clock = function() return net.time end, epoch = now, wake = core.poke, sleep = core.sleep,
            connect = function(text) return dial(core, text, name) end,
        })
        local log = service.log
        function service.log(self, text)
            if text:find("^Error") then table.insert(net.errors, ("%s's core: %s"):format(name, text)) end
            return log(self, text)
        end
        core.service = service
        setup.service, setup.core, setup.subscribers = service, service.core, service.subscribers
        core.poke()
    end
    start_core()

    -- A cell's tower, as the net API makes it: one for the cell, which serves the network of each core it joins.
    local function start_tower(entry)
        return function(welcome, control)
            if not entry.tower or entry.tower.stopped then
                entry.tower = cell_tower.new {
                    stack = entry.stack, crypto = crypto, interface = "air", area = welcome.area, sign = entry.sign,
                    epoch = now, can_serve = entry.can_serve,
                }
            end
            return entry.tower:add_network(welcome.network, {
                certificate = welcome.certificate, core = ip(welcome.core), tunnel_key = welcome.tunnel_key,
                control = control,
            })
        end
    end
    -- Run a cell's service for some cores, on a driver.
    local function start_cell(entry, driver, cores, connect_to)
        local service = cell_service.new {
            cores = cores, area = 1, id = entry.id, identity = driver.identity, fingerprint = fingerprint,
            signing = hex(entry.public), start_tower = start_tower(entry), sleep = driver.sleep, wake = driver.poke,
            connect = connect_to or function(text) return dial(driver, text) end,
        }
        driver.service = service
        driver.poke()
        return service
    end
    for _, entry in ipairs(towers) do entry.service = start_cell(entry, entry.driver, { core_address }) end

    -- Let a cell join this core: the service waits for anything it doesn't know to be allowed.
    function setup.allow_cell(key, id)
        setup.service.allowed[key] = { label = "cell #" .. id, role = "cell", id = id }
        setup.service:save_allowed()
    end

    --- Restart a cell, without it going quiet for long: it forgets its phones, and joins its core again. A cell
    -- serving other networks too stops serving them.
    function setup.restart_cell(i)
        local entry = towers[i]
        for _, link in pairs(entry.shared) do link:stop() end
        entry.shared = {}
        entry.service:stop()
        if entry.tower then entry.tower:stop() end
        entry.service = start_cell(entry, entry.driver, { core_address })
    end

    -- Our agreement with another network, made if there's none, and having changed it, saving it and acting on it, as
    -- `cellcore network` does.
    local function agreement(op, other)
        local agreements = op.service.networks
        agreements[other] = agreements[other] or { carry = false, roam = false, messages = false }
        return agreements[other]
    end
    local function agreed(op, other)
        op.service:save_networks()
        op.service:agreement_changed(other)
    end

    --[[- Change our agreement with another network, as `cellcore network` does.

    @tparam string other The other network's name.
    @tparam table changes The fields to change (`carry`, `roam`, `messages`, `core` and so on).
    ]]
    function setup.agree(other, changes)
        local entry = agreement(setup, other)
        for field, value in pairs(changes) do entry[field] = value end
        agreed(setup, other)
    end

    --[[- Let this operator's phones roam on another operator's cells: it carries them, and our phones may use its
    cells. The two cores agree, as `cellcore network` has them do, and one connects to the other.

    @tparam table visited The other operator.
    @tparam[opt] { home? = boolean, dial? = number, tower_address? = number } roam_options Whether this operator's
    phones treat the other's network as home; the address the other's core connects to ours at; or the address ours
    connects to the other's at instead (by default, the other's connects to our backhaul address).
    ]]
    function setup.roam_on(visited, roam_options)
        roam_options = roam_options or {}
        local ours, theirs = agreement(setup, visited.name), agreement(visited, name)
        ours.key, ours.id, ours.signing = visited.identity, visited.core_id, hex(visited.signing_public)
        ours.roam = roam_options.home and "home" or "partner"
        theirs.key, theirs.id, theirs.signing = identity, core_id, hex(signing_public)
        theirs.carry = true
        if roam_options.tower_address then
            ours.core = address.format(roam_options.tower_address)
        elseif not ours.core then
            theirs.core = roam_options.dial and address.format(roam_options.dial) or core_address
        end
        agreed(setup, visited.name)
        agreed(visited, name)
    end

    --[[- Have one of this operator's cells serve another operator's network too, as operators sharing a cell site
    do: it joins the other's core too, which certifies it as one of its own.

    @tparam number i Which of this operator's cells.
    @tparam table other The other operator.
    @treturn table What stops it serving the other network (`stop()`), and gives the cell messages as from the other's
    core (`control(message)`).
    ]]
    function setup.share_cell(i, other)
        local entry = towers[i]
        if entry.shared[other.name] then entry.shared[other.name]:stop() end
        other.allow_cell(entry.driver.identity, entry.id)
        local driver = new_driver(net, entry.stack, ("%s's cell #%d, for %s"):format(name, entry.id, other.name),
            entry.driver.identity, entry.driver.address)
        local service = start_cell(entry, driver, { other.core_address })
        local link = {}
        function link.control(_, message)
            local served = entry.tower and entry.tower.links[other.name]
            if served then served:control(message) end
        end
        function link.stop()
            service:stop()
            driver.service = nil
            if entry.shared[other.name] == link then entry.shared[other.name] = nil end
        end
        entry.shared[other.name] = link
        return link
    end

    --[[- Exchange messages with another operator's phones. The two cores agree, as `cellcore network` has them do, and
    one connects to the other (unless one does already, as they carry each other's phones).

    @tparam table other The other operator.
    @treturn table What cuts the cores off from each other (`cut()`), and lets them connect again at once (`mend()`).
    The one connection between them carries roaming too.
    ]]
    function setup.peer_with(other)
        local ours, theirs = agreement(setup, other.name), agreement(other, name)
        ours.key, ours.id, ours.messages, ours.prefix = other.identity, other.core_id, true, other.number_prefix
        theirs.key, theirs.id, theirs.messages, theirs.prefix = identity, core_id, true, options.numbers
        if not ours.core and not theirs.core then ours.core = other.core_address end
        agreed(setup, other.name)
        agreed(other, name)

        local connection = {}
        function connection.cut()
            world.cut[name .. ">" .. other.name], world.cut[other.name .. ">" .. name] = true, true
            for _, side in ipairs { { setup, other.name }, { other, name } } do
                local service = side[1].service
                local link, dialing = service.links[side[2]], service.dialing[side[2]]
                if link then link.connection:abort() end
                if dialing and dialing.connection then dialing.connection:abort() end
            end
        end
        function connection.mend()
            world.cut[name .. ">" .. other.name], world.cut[other.name .. ">" .. name] = nil, nil
            -- The core which connects to the other does so at once, rather than when it next would have.
            if setup.service.networks[other.name].core then setup.service:dial(other.name) end
            if other.service.networks[name].core then other.service:dial(name) end
        end
        return connection
    end

    -- Relays' cells connect over TCP, through the relays' phones: the core takes their connections too. Each says
    -- which computer it is first, as a secure connection would.
    local relays, relay_listener = {}, nil
    local function listen_for_relays()
        if relay_listener or not relays[1] then return end
        local listener = assert(tcp.listen(core_stack, CONTROL_PORT))
        relay_listener = listener
        local opening = {}
        local function poll()
            if relay_listener ~= listener then return end
            core_stack:schedule(POLL, poll)
            while true do
                local connection = listener:accept()
                if not connection then break end
                opening[#opening + 1] = connection
            end
            for i = #opening, 1, -1 do
                local connection = opening[i]
                local ok, hello = connection:take()
                if ok then
                    table.remove(opening, i)
                    if type(hello) == "table" and type(hello.key) == "string" then
                        core.listener.queue[#core.listener.queue + 1] = tcp_end(net, connection, core, hello.key)
                    end
                elseif hello ~= nil then
                    table.remove(opening, i)
                end
            end
            core.poke()
        end
        poll()
    end

    --- Restart the core: it forgets every phone, and its cells (and other networks' cores) join it again by themselves.
    function setup.restart_core()
        local old = setup.service
        old:save_subscribers()
        old:save_codes()
        old:stop()
        if relay_listener then
            relay_listener:close()
            relay_listener = nil
        end
        start_core()
        listen_for_relays()
    end

    local function add_phone(id, position, subscribed, phone_options)
        phone_options = phone_options or {}
        local stack = net.stack(id)
        net.connect(stack, "air", nil, "wireless")
        positions[id] = position
        local sim = x25519()
        if subscribed ~= false then setup.subscribers[hex(sim.public)] = { id = name .. "-" .. id, number = tostring(id) } end
        local phone = cell_phone.new {
            stack = stack, crypto = crypto, interface = "air", epoch = now, sim = sim,
            operator = phone_options.activated ~= false and { network = name, key = operator_key.public, signing = signing_public } or nil,
            on_message = phone_options.on_message, on_activated = phone_options.on_activated,
            on_sent = phone_options.on_sent, partners = phone_options.partners, selection = phone_options.selection,
            on_partners = phone_options.on_partners,
        }
        return phone, stack
    end

    --[[ A relay: a computer only on the air, which is a phone of the network and a cell. Once its phone is attached,
    its cell connects to the core over TCP, through its phone, and its tunnel goes the same way. ]]
    local function add_relay(id, position)
        local phone, stack = add_phone(id, position)
        local cell_private, cell_public = crypto.generateKeyPair("ed25519")
        local key = new_key()
        local relay = {
            id = id, stack = stack, phone = phone, cells = {}, public = cell_public, shared = {},
            sign = function(data) return crypto.sign(cell_private, data) end,
            -- As the net API's: only serve while the phone, our way to the core, has service.
            can_serve = function()
                if phone.state == "attached" then return true end
                local interface = stack:route(ip(core_address))
                return not (interface and interface.name == "cell")
            end,
        }
        local driver = new_driver(net, stack, ("%s's relay #%d"):format(name, id), key, nil)
        relays[#relays + 1] = relay
        setup.allow_cell(key, id)
        listen_for_relays()

        local function connect_to(text)
            local connection, err = tcp.connect(stack, ip(text), CONTROL_PORT)
            if not connection then return nil, err end
            local ends = tcp_end(net, connection, driver, identity)
            ends:send({ key = key })
            return ends
        end
        local function poll()
            stack:schedule(POLL, poll)
            -- Which cells the relay's phone has used.
            if phone.cell and relay.cells[#relay.cells] ~= phone.cell then relay.cells[#relay.cells + 1] = phone.cell end
            -- The cell starts once the phone, its way to the core, has service.
            if not relay.service and phone.state == "attached" then
                relay.service = start_cell(relay, driver, { core_address }, connect_to)
            end
            driver.poke()
        end
        poll()
        return relay
    end

    setup.add_phone, setup.add_relay = add_phone, add_relay
    return setup
end

return { operator = operator, x25519 = x25519 }
