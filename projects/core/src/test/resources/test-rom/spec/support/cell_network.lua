-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Cellular networks for testing, on a virtual network: operators, each with a core, cells and a server on a wired
backhaul, and phones and relays on the air.

Phones hear cells depending on how far away they are: `positions[id]` is where each computer is along a line.
Several operators can share the air and the backhaul, to test roaming: give the second one `join`, the first.
]]

local codec = require "cc.net.codec"
local address = require "cc.net.address"
local noise = require "cc.internal.net.noise"
local tcp = require "cc.internal.net.tcp"
local certificate = require "cc.internal.net.certificate"
local common = require "cc.internal.net.cell.common"
local cell_core = require "cc.internal.net.cell.core"
local cell_tower = require "cc.internal.net.cell.tower"
local cell_phone = require "cc.internal.net.cell.phone"
local network = require "support.virtual_network"

local function ip(text) return (address.parse(text)) end
local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function copy(value) return codec.decode(codec.encode(value)) end

local function x25519()
    local private = crypto.generateKeyPair("x25519")
    return { public = noise.public_key(crypto, private), exchange = function(public) return crypto.exchange(private, public) end }
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

    local operator_key = x25519()
    local signing_private, signing_public = crypto.generateKeyPair("ed25519")
    local now = function() return 1.7e12 + net.time * 1000 end

    local core_stack = net.stack(core_id)
    net.connect(core_stack, "backhaul", core_address .. "/24")
    core_stack.forwarding = true
    local subscribers, codes, events = {}, {}, {}
    local secret = crypto.random(32)
    local setup = {}
    local function start_core()
        setup.core = cell_core.new {
            stack = core_stack, crypto = crypto, network = name, operator = operator_key, signing = signing_public,
            prefix = prefix, subscribers = subscribers, codes = codes, secret = secret, epoch = now,
            number_prefix = options.numbers, on_event = function(...) events[#events + 1] = { ... } end,
        }
    end
    start_core()

    local server = join and join.server
    if not server then
        server = net.stack(60)
        net.connect(server, "backhaul", "10.0.0.60/24")
    end
    do
        local phones, length = address.parse(prefix)
        server:add_route { network = phones, prefix = length, gateway = ip(core_address), source = "static" }
    end

    -- Cells, each with a key of its own, certified by the operator.
    local towers = {}
    local function start_tower(entry)
        local stack, id, core = entry.stack, entry.id, setup.core
        local tower
        local tunnel_key = core:add_tower(id, entry.address, function(message)
            -- To this network's part of the cell: it may serve others too.
            stack:schedule(0.01, function()
                local link = tower.links[name]
                if towers[entry.index] == entry and entry.tower == tower and link then link:control(copy(message)) end
            end)
        end)
        tower = cell_tower.new {
            stack = stack, crypto = crypto, interface = "air", network = name, area = 1, certificate = entry.certificate,
            sign = entry.sign, epoch = now, core = ip(core_address), tunnel_key = tunnel_key,
            control = function(message)
                core_stack:schedule(0.01, function() if setup.core == core then core:control(id, copy(message)) end end)
            end,
        }
        entry.tower = tower
    end
    for i, position in ipairs(cell_positions) do
        local id = cell_base + i
        local stack = options.core_is_cell and i == 1 and core_stack or net.stack(id)
        id = stack.id
        if stack ~= core_stack then net.connect(stack, "backhaul", "10.0.0." .. (cell_base + i) .. "/24") end
        net.connect(stack, "air", nil, "wireless")
        positions[id] = position

        local cell_private, cell_public = crypto.generateKeyPair("ed25519")
        towers[i] = {
            index = i, id = id, stack = stack, address = stack.interfaces.backhaul.address, public = cell_public,
            certificate = certificate.encode(certificate.issue {
                name = common.cell_name(name, id), key = cell_public, expires = now() + 86400000, issuer = signing_public,
                sign = function(data) return crypto.sign(signing_private, data) end,
            }),
            sign = function(data) return crypto.sign(cell_private, data) end,
        }
        start_tower(towers[i])
    end

    --- Restart a cell, without it going quiet for long: it forgets its phones, and joins the core again.
    function setup.restart_cell(i)
        local entry = towers[i]
        entry.tower:stop()
        setup.core:remove_tower(entry.id)
        start_tower(entry)
    end

    --[[- Let this operator's phones roam on another operator's cells. The other's core joins ours as a cell would
    (and as `cellcore` has it do over a connection), and ours tells its phones about the other network.

    @tparam table visited The other operator.
    @tparam[opt] { home? = boolean } roam_options Whether this operator's phones treat the other's network as home.
    ]]
    function setup.roam_on(visited, roam_options)
        local home_core, visited_core = setup.core, visited.core
        local key = home_core:add_tower(visited.core_stack.id, visited.core_stack.interfaces.backhaul.address, function(message)
            visited.core_stack:schedule(0.01, function()
                if visited.core == visited_core then visited_core:partner_control(name, copy(message)) end
            end)
        end, visited.name)
        visited_core:add_partner(name, {
            address = core_stack.interfaces.backhaul.address, tunnel_key = key,
            send = function(message)
                core_stack:schedule(0.01, function()
                    if setup.core == home_core then home_core:control(visited.core_stack.id, copy(message)) end
                end)
            end,
        })
        local keys = {}
        for network, partner in pairs(home_core.partner_keys) do keys[network] = partner end
        keys[visited.name] = { signing = visited.signing_public, home = roam_options and roam_options.home or nil }
        home_core:set_partner_keys(keys)
    end

    --[[- Have one of this operator's cells serve another operator's network too, as operators sharing a cell site
    do. The other's core takes it as one of its own cells (as `celld` with both cores has it do), and certifies it.

    @tparam number i Which of this operator's cells.
    @tparam table other The other operator.
    @treturn table The cell's link for the other network, which stops serving it with `stop()`.
    ]]
    function setup.share_cell(i, other)
        local entry = towers[i]
        local stack, id, tower, other_core = entry.stack, entry.id, entry.tower, other.core
        local link
        local key = other_core:add_tower(id, entry.address, function(message)
            stack:schedule(0.01, function() if link and tower.links[other.name] == link then link:control(copy(message)) end end)
        end)
        link = tower:add_network(other.name, {
            certificate = certificate.encode(certificate.issue {
                name = common.cell_name(other.name, id), key = entry.public, expires = now() + 86400000,
                issuer = other.signing_public, sign = function(data) return crypto.sign(other.signing_private, data) end,
            }),
            core = ip(other.core_address), tunnel_key = key,
            control = function(message)
                other.core_stack:schedule(0.01, function()
                    if other.core == other_core then other_core:control(id, copy(message)) end
                end)
            end,
        })
        return link
    end

    --[[- Exchange messages with another operator's phones. The cores pass them to each other, as `cellcore` has them
    do over a connection.

    @tparam table other The other operator.
    ]]
    function setup.peer_with(other)
        local to_other, to_us
        to_other = function(message)
            other.core_stack:schedule(0.01, function() other.core:peer_control(name, copy(message), to_us) end)
        end
        to_us = function(message)
            core_stack:schedule(0.01, function() setup.core:peer_control(other.name, copy(message), to_other) end)
        end
        setup.core:add_peer(other.name, other.number_prefix, to_other)
        other.core:add_peer(name, options.numbers, to_us)
    end

    --- Restart the core: it forgets every phone, and its cells join it again, forgetting their phones too.
    function setup.restart_core()
        for _, entry in ipairs(towers) do entry.tower:stop() end
        setup.core:stop()
        start_core()
        for _, entry in ipairs(towers) do start_tower(entry) end
    end

    local function add_phone(id, position, subscribed, phone_options)
        phone_options = phone_options or {}
        local stack = net.stack(id)
        net.connect(stack, "air", nil, "wireless")
        positions[id] = position
        local sim = x25519()
        if subscribed ~= false then subscribers[hex(sim.public)] = { id = name .. "-" .. id, number = tostring(id) } end
        local phone = cell_phone.new {
            stack = stack, crypto = crypto, interface = "air", epoch = now, sim = sim,
            operator = phone_options.activated ~= false and { network = name, key = operator_key.public, signing = signing_public } or nil,
            on_message = phone_options.on_message, on_activated = phone_options.on_activated,
            on_sent = phone_options.on_sent, partners = phone_options.partners, selection = phone_options.selection,
            on_partners = phone_options.on_partners,
        }
        return phone, stack
    end

    -- The core's end of relays' control connections. Like cellcore, it learns a cell's address from its connection,
    -- and only sends a cell anything else once it has had its key for the tunnel.
    local relay_connections
    local function listen_for_relays()
        if relay_connections then return end
        relay_connections = {}
        local listener = assert(tcp.listen(core_stack, 2123))
        local function poll()
            core_stack:schedule(0.05, poll)
            while true do
                local connection = listener:accept()
                if not connection then break end
                relay_connections[#relay_connections + 1] = { connection = connection, outbox = {} }
            end
            for _, entry in ipairs(relay_connections) do
                while true do
                    local ok, message = entry.connection:take()
                    if not ok then break end
                    if not entry.id then
                        entry.id = message.id
                        local key = setup.core:add_tower(message.id, entry.connection.remote_addr, function(reply)
                            entry.outbox[#entry.outbox + 1] = copy(reply)
                        end)
                        entry.connection:send({ tunnel_key = key })
                    else
                        setup.core:control(entry.id, message)
                    end
                end
                if entry.id then
                    while entry.outbox[1] do entry.connection:send(table.remove(entry.outbox, 1)) end
                end
            end
        end
        poll()
    end

    --[[ A relay: a computer only on the air, which is a phone of the network and a cell. Once its phone is attached,
    its cell connects to the core over TCP, through its phone, and its tunnel goes the same way. ]]
    local function add_relay(id, position)
        listen_for_relays()
        local phone, stack = add_phone(id, position)
        local relay = { id = id, stack = stack, phone = phone, cells = {} }
        local cell_private, cell_public = crypto.generateKeyPair("ed25519")
        local cert = certificate.encode(certificate.issue {
            name = common.cell_name(name, id), key = cell_public, expires = now() + 86400000, issuer = signing_public,
            sign = function(data) return crypto.sign(signing_private, data) end,
        })

        local connection
        local function poll()
            stack:schedule(0.05, poll)
            -- Which cells the relay's phone has used.
            if phone.cell and relay.cells[#relay.cells] ~= phone.cell then relay.cells[#relay.cells + 1] = phone.cell end
            if not connection then
                if phone.state == "attached" then connection = assert(tcp.connect(stack, ip(core_address), 2123)) end
                return
            end
            if connection.state == "established" and not relay.hello then
                relay.hello = true
                connection:send({ id = id })
            end
            while true do
                local ok, message = connection:take()
                if not ok then break end
                if not relay.tower then
                    relay.tower = cell_tower.new {
                        stack = stack, crypto = crypto, interface = "air", network = name, area = 1, certificate = cert,
                        sign = function(data) return crypto.sign(cell_private, data) end, epoch = now,
                        core = ip(core_address), tunnel_key = message.tunnel_key,
                        control = function(control) connection:send(copy(control)) end,
                        -- As the net API's: only serve while the phone, our way to the core, has service.
                        can_serve = function()
                            if phone.state == "attached" then return true end
                            local interface = stack:route(ip(core_address))
                            return not (interface and interface.name == "cell")
                        end,
                    }
                else
                    relay.tower:control(message)
                end
            end
        end
        poll()
        return relay
    end

    for k, v in pairs {
        net = net, core_stack = core_stack, server = server, towers = towers, positions = positions,
        events = events, add_phone = add_phone, add_relay = add_relay, signing_public = signing_public, now = now,
        operator_key = operator_key, subscribers = subscribers, signing_private = signing_private, name = name,
        core_address = core_address, number_prefix = options.numbers,
    } do
        setup[k] = v
    end
    return setup
end

return { operator = operator, x25519 = x25519 }
