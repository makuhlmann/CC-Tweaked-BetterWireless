-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- The cellular part of the net API: the phone, a cell and a network's core, which run in the network stack's
background process, and the files they keep. `net.cell` documents what each does, checks what it's given, and hands it
here.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use `net.cell` instead.

@local
]]

local address = require "cc.net.address"
local expect = require "cc.expect".expect
local files = require "cc.internal.net.files"

local to_hex, from_hex, read_table = files.hex.encode, files.hex.decode, files.read_table

-- What the net API gives: its network stack, and its ways to load it, to keep errors, to check for crypto and the
-- enclave, to know this computer's key and keys' fingerprints, to connect securely, to check a timeout, and to add an
-- interface. Set by `new`.
local stack, load, log_error, require_crypto, getIdentity, fingerprint, secure, check_timeout, add_interface

-- The functions `net.cell` hands its work to, and the ways to start the phone, and the core and cell.
local api = {}
local start_phone, start_cellular

-- What's been read from files which are read often (see `read_cached`), by key.
local file_cache = {}

-- Write one of the small tables kept in /.net, and forget what was read of it.
local function write_table(path, value)
    files.write_table(path, value)
    for key, entry in pairs(file_cache) do
        if entry.path == path then file_cache[key] = nil end
    end
end

-- Read something from a file, or give what was read last time if the file hasn't changed since (by its modification
-- time and size). Our own writes forget it at once. `net.cell.info`, which the status bar and the menus call often,
-- reads its files so.
local function read_cached(key, path, read)
    local ok, attributes = pcall(fs.attributes, path)
    local stamp = ok and type(attributes) == "table" and ("%s:%s"):format(attributes.modified, attributes.size) or "none"
    local entry = file_cache[key]
    if entry and entry.stamp == stamp then return entry.value end
    local value = read()
    file_cache[key] = { path = path, stamp = stamp, value = value }
    return value
end

-- Services which run in the background process (a cellular network's core, a cell), by name. Each has a `resume`
-- method, which is passed every event.
local background = {}
-- Whether a "net_cell" event, which wakes services, is queued already.
local cell_wake_queued = false

-- Cellular networks. A phone runs in the background, once the computer has a SIM.
local SIM_FILE = "/.net/sim"
local INBOX_FILE = "/.net/messages"
-- What the user has chosen: `off` (cell service is turned off) and `network` (the only network to use).
local PHONE_FILE = "/.net/phone"
local MAX_INBOX = 100
-- How many sent messages may wait to be sent while cell service is off: as many as the phone keeps.
local MAX_WAITING = 20
local phone_instance

-- Messages received and sent, oldest first. Each has a number, `n`, which stays the same as others come and go.
local function read_messages()
    local list, last = {}, 0
    for _, message in ipairs(read_table(INBOX_FILE)) do
        if type(message) == "table" and type(message.text) == "string" then
            list[#list + 1] = message
            if type(message.n) == "number" and message.n > last then last = message.n end
        end
    end
    -- Messages kept by older versions have no numbers.
    for _, message in ipairs(list) do
        if type(message.n) ~= "number" then
            last = last + 1
            message.n = last
        end
    end
    return list, last
end

local function add_message(message)
    local list, last = read_messages()
    message.n = last + 1
    list[#list + 1] = message
    while #list > MAX_INBOX do table.remove(list, 1) end
    write_table(INBOX_FILE, list)
    return message.n
end

-- Change the stored messages a test picks. Returns how many there were.
local function change_messages(test, change)
    local list = read_messages()
    local count = 0
    for i = #list, 1, -1 do
        if test(list[i]) then
            count = count + 1
            if change(list[i]) == false then table.remove(list, i) end
        end
    end
    if count > 0 then write_table(INBOX_FILE, list) end
    return count
end

local function sim_key()
    require_crypto()
    local public = enclave.publicKey("sim") or enclave.generate("sim", "x25519")
    return { public = public, exchange = function(peer) return enclave.exchange("sim", peer) end }
end

-- Cellular radio uses a wireless modem's low band, for range: find (or make) an interface on it. An ender modem will
-- do too: it's a weaker radio, which also reaches cells and phones where its signal appears in other dimensions.
local RADIO_KINDS = { wireless = true, ender = true }
local function cell_interface()
    local names = {}
    for name in pairs(stack.interfaces) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local interface = stack.interfaces[name]
        if RADIO_KINDS[interface.kind] and interface.band == "low" then return name end
    end
    for _, name in ipairs(names) do
        local interface = stack.interfaces[name]
        if RADIO_KINDS[interface.kind] and interface.band == "high" and not stack.interfaces[interface.modem .. ":low"] then
            add_interface(interface.modem .. ":low", interface.modem, interface.kind, "low")
            return interface.modem .. ":low"
        end
    end
end

local function new_phone(operator, partners, equivalent)
    -- A computer may be a phone and a cell at once: a relay, whose cell reaches the core through its phone.
    local name = cell_interface()
    if not name then return nil, "This needs a wireless modem" end
    local cell = require("cc.internal.net.cell.phone")
    local chosen = read_table(PHONE_FILE)
    phone_instance = cell.new {
        stack = stack, crypto = crypto, interface = name, epoch = function() return os.epoch("utc") end,
        sim = sim_key(), operator = operator, partners = partners, equivalent = equivalent,
        selection = type(chosen.network) == "string" and chosen.network or nil,
        -- The operator says which other networks the phone may use (and which it treats as home): remember them, for
        -- when it starts out of reach of its own.
        on_partners = function(list, equivalent)
            local sim = read_table(SIM_FILE)
            sim.roaming, sim.equivalent = {}, {}
            for network, signing in pairs(list) do sim.roaming[network] = to_hex(signing) end
            for network in pairs(equivalent or {}) do sim.equivalent[network] = true end
            write_table(SIM_FILE, sim)
        end,
        -- With a cell on this computer, this phone may be its backhaul.
        relay = function() return background.cell ~= nil end,
        on_change = function(phone) os.queueEvent("cell_state", phone.state) end,
        on_sent = function(id, ok, reason)
            change_messages(function(message) return message.id == id and message.status == "sending" end, function(message)
                message.status, message.error = ok and "sent" or "failed", reason
            end)
            os.queueEvent("cell_sent", id, ok, reason)
        end,
        on_message = function(from, text)
            add_message({ from = from, text = text, time = os.epoch("utc"), read = false })
            os.queueEvent("cell_message", from, text)
        end,
        on_activated = function(info)
            write_table(SIM_FILE, {
                network = info.network, key = to_hex(info.key), signing = to_hex(info.signing), id = info.id,
                number = info.number,
            })
        end,
    }

    -- Messages which were waiting to be sent when the phone last stopped (or were sent while cell service was off) go
    -- now, or once it has service, with the IDs they had: the network knows any it took then, and doesn't deliver
    -- them twice.
    if operator then
        local refused = {}
        for _, message in ipairs(read_messages()) do
            if message.to and message.status == "sending" and type(message.id) == "number" then
                local ok, err = phone_instance:send_message(message.to, message.text, message.id)
                if not ok then refused[message.id] = err end
            end
        end
        change_messages(function(message) return message.status == "sending" and refused[message.id] ~= nil end,
            function(message) message.status, message.error = "failed", refused[message.id] end)
    end
    return phone_instance
end

-- Whether this computer has a SIM: it has been activated on a network.
local function has_sim()
    local sim = read_table(SIM_FILE)
    return type(sim.network) == "string" and from_hex(sim.key) ~= nil and from_hex(sim.signing) ~= nil
end

-- Start the phone, if this computer has been activated on a network.
function start_phone()
    if phone_instance or not crypto or not enclave then return end
    if read_table(PHONE_FILE).off then return end
    local sim = read_table(SIM_FILE)
    local key, signing = from_hex(sim.key), from_hex(sim.signing)
    if type(sim.network) ~= "string" or not key or not signing then return end
    local partners, equivalent = {}, {}
    for network, partner in pairs(type(sim.roaming) == "table" and sim.roaming or {}) do
        local partner_key = from_hex(partner)
        if type(network) == "string" and partner_key and #partner_key == 32 then partners[network] = partner_key end
    end
    for network in pairs(type(sim.equivalent) == "table" and sim.equivalent or {}) do
        if partners[network] then equivalent[network] = true end
    end
    new_phone({ network = sim.network, key = key, signing = signing }, partners, equivalent)
end

local CORE_CONFIG, CELL_CONFIG = "/.cell/config", "/.cell/cell"
local CONTROL_PORT = 2123

-- Services queue an event to wake their tasks. One at a time is enough, and many would fill the event queue.
local function cell_wake()
    if cell_wake_queued then return end
    cell_wake_queued = true
    os.queueEvent("net_cell")
end

-- Start a network's core: its controller, subscriber database and gateway.
local function new_core(options)
    local public = enclave.publicKey("cell.operator") or enclave.generate("cell.operator", "x25519")
    local signing = enclave.publicKey("cell.signing") or enclave.generate("cell.signing", "ed25519")
    if not enclave.list()["cell.secret"] then enclave.generate("cell.secret", "secret") end
    -- Phones' packets go through this computer. Keep the setting on too, or reloading the network settings (such as
    -- with the route program) would turn forwarding off again.
    if not settings.get("net.forwarding") then
        settings.set("net.forwarding", true)
        settings.save()
    end
    stack:set_forwarding(true)
    return require("cc.internal.net.cell.core").new {
        stack = stack, crypto = crypto, network = options.network, prefix = options.prefix,
        operator = { public = public, exchange = function(peer) return enclave.exchange("cell.operator", peer) end },
        signing = signing, subscribers = options.subscribers, codes = options.codes, number_prefix = options.number_prefix,
        tunnel_key = function(cell) return enclave.hmac("cell.secret", "tunnel key " .. cell) end,
        epoch = function() return os.epoch("utc") end, on_event = options.on_event,
    }
end

-- Run the core in the background.
local function start_core_service()
    if background.core then return true end
    require_crypto()
    load()
    -- The background process may not have started yet (as when startup.lua runs), but it will, unless it's turned off.
    if not settings.get("net.enabled") then return nil, "The network stack is turned off" end
    local signing = enclave.publicKey("cell.signing") or enclave.generate("cell.signing", "ed25519")
    local service, err = require("cc.internal.net.cell.core_service").new {
        dir = "/.cell", identity = getIdentity(), fingerprint = fingerprint,
        listen = function() return secure.listen(CONTROL_PORT) end,
        start_core = new_core,
        signing = signing, sign = function(data) return enclave.sign("cell.signing", data) end,
        clock = os.clock, epoch = function() return os.epoch("utc") end, wake = cell_wake,
        -- To carry other networks' phones (roaming), the core connects to their cores.
        id = os.getComputerID(), connect = function(core) return secure.connect(core, CONTROL_PORT) end, sleep = sleep,
        -- An administrator may stop the core, or start it afresh, from anywhere.
        stop = function() api.stopCore() end,
        restart = function()
            if background.core then
                background.core:stop()
                background.core = nil
            end
            local ok, restart_err = start_core_service()
            if not ok then log_error("Cannot start the cellular core again: " .. tostring(restart_err)) end
        end,
    }
    if not service then return nil, err end
    -- The core must keep running when nobody is nearby.
    pcall(os.setKeepLoaded, true)
    background.core = service
    return true
end

-- The cores a cell connects to, from its settings. Older versions kept only one.
local function cell_cores(config)
    local cores = {}
    for _, core in ipairs(type(config.cores) == "table" and config.cores or {}) do
        if type(core) == "string" then cores[#cores + 1] = core end
    end
    if not cores[1] and type(config.core) == "string" then cores[1] = config.core end
    return cores[1] and cores or nil
end

-- Run a cell in the background: one cell, which serves the network of each core it reaches.
local function start_cell_service(config)
    if background.cell then return true end
    require_crypto()
    load()
    if not settings.get("net.enabled") then return nil, "The network stack is turned off" end
    if not cell_interface() then return nil, "A cell needs a wireless modem" end
    local signing = enclave.publicKey("cell.tower") or enclave.generate("cell.tower", "ed25519")
    local tower
    background.cell = require("cc.internal.net.cell.cell_service").new {
        cores = config.cores, area = config.area, id = os.getComputerID(), identity = getIdentity(),
        fingerprint = fingerprint, signing = to_hex(signing),
        connect = function(core) return secure.connect(core, CONTROL_PORT) end,
        start_tower = function(welcome, control)
            local name = cell_interface()
            if not name then error("A cell needs a wireless modem", 0) end
            if not tower or tower.stopped then
                tower = require("cc.internal.net.cell.tower").new {
                    stack = stack, crypto = crypto, interface = name, area = welcome.area,
                    sign = function(data) return enclave.sign("cell.tower", data) end,
                    epoch = function() return os.epoch("utc") end,
                    -- A relay reaches a core through this computer's phone, so it can only serve that core's network
                    -- while the phone has service. Otherwise its phones would stay, with nowhere for their packets to go.
                    can_serve = function(core)
                        if not phone_instance or phone_instance.state == "attached" then return true end
                        local interface = stack:route(core)
                        return not (interface and interface.name == "cell")
                    end,
                }
            end
            return tower:add_network(welcome.network, {
                certificate = welcome.certificate, core = address.parse(welcome.core), tunnel_key = welcome.tunnel_key,
                control = control,
            })
        end,
        sleep = sleep, wake = cell_wake,
    }
    -- Cells must keep running when nobody is nearby.
    pcall(os.setKeepLoaded, true)
    return true
end

-- Start the core and the cell, if this computer is set up as either, when the computer starts.
function start_cellular()
    if not crypto or not enclave then return end
    local core = read_table(CORE_CONFIG)
    if type(core.network) == "string" and core.enabled ~= false then
        local ok, err = start_core_service()
        if not ok then log_error("Cannot start the cellular core: " .. tostring(err)) end
    end
    local cell = read_table(CELL_CONFIG)
    local cores = cell_cores(cell)
    if cores and cell.enabled ~= false then
        local ok, err = start_cell_service({ cores = cores, area = cell.area })
        if not ok then log_error("Cannot start the cell: " .. tostring(err)) end
    end
end

local Manager = {}
Manager.__index = Manager

--[[- Send the core a request, and wait for its answer.

@tparam table request The request: `op`, and whatever else that operation takes.
@tparam[opt=15] number timeout How long to wait for the answer, in seconds.
@treturn[1] table The core's answer.
@treturn[2] nil If the core refused, didn't answer, or was lost.
@treturn[2] string Why.
]]
function Manager:request(request, timeout)
    expect(1, request, "table")
    expect(2, timeout, "number", "nil")
    check_timeout(2, timeout)
    if self.closed then return nil, "Closed" end
    local sent, err = self.connection:send(request)
    if not sent then return nil, "Lost the core: " .. tostring(err) end
    local reply, receive_err = self.connection:receive(timeout or 15)
    if type(reply) ~= "table" then return nil, "The core didn't answer: " .. tostring(receive_err or "it hung up") end
    if reply.error ~= nil then return nil, tostring(reply.error) end
    return reply
end

--- Get everything about the network: its cells, the computers allowed in and waiting, its subscribers, roaming, and
-- the networks it exchanges messages with.
--
-- @treturn[1] table `network`, `prefix`, `number_prefix`, `cells`, `allowed`, `waiting`, `subscribers`, `networks`
-- (each other network, what's agreed with it, and how the connection to its core is going), and how many `messages`
-- and activation `codes` are waiting.
-- @treturn[2] nil If it couldn't be had.
-- @treturn[2] string Why not.
function Manager:status() return self:request({ op = "status" }) end

--- Get the core's log.
--
-- @tparam[opt] number after Only lines after the one with this number.
-- @treturn[1] table `lines` (each with `n`, `time` and `text`), and `last`, the number of the last line.
-- @treturn[2] nil If it couldn't be had.
-- @treturn[2] string Why not.
function Manager:log(after)
    expect(1, after, "number", "nil")
    return self:request({ op = "log", after = after })
end

--- Make an activation code for a subscriber.
--
-- @tparam string id The subscriber's ID, such as `"ACME-0042"`.
-- @tparam string number Their phone number.
-- @treturn[1] string The code, which works once, for a day.
-- @treturn[2] nil If it couldn't be made.
-- @treturn[2] string Why not.
function Manager:add(id, number)
    expect(1, id, "string")
    expect(2, number, "string")
    local reply, err = self:request({ op = "add", id = id, number = number })
    if not reply then return nil, err end
    return reply.code
end

--- Remove a subscriber, and any codes for them which haven't been used.
--
-- @tparam string subscriber Their ID or number.
-- @treturn[1] table How many subscribers were `removed`, and how many `codes`.
-- @treturn[2] nil If there's nobody to remove.
-- @treturn[2] string Why not.
function Manager:remove(subscriber)
    expect(1, subscriber, "string")
    return self:request({ op = "remove", subscriber = subscriber })
end

--- Change a subscriber: bar them (their phone is cut off, and refused), or say whether they may roam.
--
-- @tparam string subscriber Their ID or number.
-- @tparam { barred? = boolean, roaming? = boolean } changes What to change.
-- @treturn[1] table The subscriber's `id` and `number`, and whether they're `barred` and may use `roaming`.
-- @treturn[2] nil If it couldn't be done.
-- @treturn[2] string Why not.
function Manager:set(subscriber, changes)
    expect(1, subscriber, "string")
    expect(2, changes, "table")
    return self:request({ op = "set", subscriber = subscriber, barred = changes.barred, roaming = changes.roaming })
end

--- Allow a computer in: a cell, another network's core (to carry this network's phones, or to exchange messages with
-- them, or both), or a computer to manage this one. Check its fingerprint
-- (in `status().waiting`) against the one the computer shows first.
--
-- @tparam string key The computer's key, as 64 hexadecimal digits.
-- @tparam[opt] string label What to call it.
-- @treturn[1] table Its `role`, `id`, `label` and `fingerprint`.
-- @treturn[2] nil If it couldn't be allowed.
-- @treturn[2] string Why not.
function Manager:allow(key, label)
    expect(1, key, "string")
    expect(2, label, "string", "nil")
    return self:request({ op = "allow", key = key, label = label })
end

--- Refuse a computer from now on, dropping any connections it has.
--
-- @tparam string key The computer's key, as 64 hexadecimal digits.
-- @treturn[1] table Its `id`, if that's known.
-- @treturn[2] nil If it couldn't be refused.
-- @treturn[2] string Why not.
function Manager:deny(key)
    expect(1, key, "string")
    return self:request({ op = "deny", key = key })
end

--- Carry another network's phones at this network's cells, by connecting to that network's core, which must allow it.
--
-- @tparam string network The other network's name.
-- @tparam string core Its core's name or address.
-- @treturn[1] table The `id` and `fingerprint` of this core's computer, for the other core's administrator.
-- @treturn[2] nil If it couldn't be set up.
-- @treturn[2] string Why not.
function Manager:carry(network, core)
    expect(1, network, "string")
    expect(2, core, "string")
    return self:request({ op = "carry", network = network, core = core })
end

--- Say whether this network's phones treat a partner (a network which carries them) as home: they aren't roaming
-- there, use its cells as readily as this network's own, and may use it even if they mayn't roam. This is for national
-- roaming, and for a network with no cells of its own (a full MVNO). Phones hear of it when they next attach.
--
-- @tparam string network The partner's name.
-- @tparam boolean home Whether phones treat it as home.
-- @treturn[1] table The partner's `network`, and whether it's now `home`.
-- @treturn[2] nil If it isn't a partner.
-- @treturn[2] string Why not.
function Manager:partner(network, home)
    expect(1, network, "string")
    expect(2, home, "boolean")
    return self:request({ op = "partner", network = network, home = home })
end

--- Stop carrying another network's phones.
--
-- @tparam string network The other network's name.
-- @treturn[1] table If it was stopped.
-- @treturn[2] nil If it wasn't.
-- @treturn[2] string Why not.
function Manager:uncarry(network)
    expect(1, network, "string")
    return self:request({ op = "uncarry", network = network })
end

--- Set this network's number prefix. Other networks' phones send messages to this network's at the prefix followed by
-- their number (`5550042`), once the networks exchange messages (see `Manager:peer`).
--
-- @tparam string prefix The prefix: 1 to 8 digits.
-- @treturn[1] table The new `prefix`.
-- @treturn[2] nil If it couldn't be set.
-- @treturn[2] string Why not.
function Manager:numbers(prefix)
    expect(1, prefix, "string")
    return self:request({ op = "numbers", prefix = prefix })
end

--- Exchange messages with another network's phones, by connecting to that network's core, which must allow it. This
-- is apart from roaming. Both networks need a number prefix.
--
-- @tparam string network The other network's name.
-- @tparam string core Its core's name or address.
-- @treturn[1] table The `id` and `fingerprint` of this core's computer, for the other core's administrator.
-- @treturn[2] nil If it couldn't be set up.
-- @treturn[2] string Why not.
function Manager:peer(network, core)
    expect(1, network, "string")
    expect(2, core, "string")
    return self:request({ op = "peer", network = network, core = core })
end

--- Stop connecting to another network's core to exchange messages. (Its core ends it by refusing this one's.)
--
-- @tparam string network The other network's name.
-- @treturn[1] table If it was stopped.
-- @treturn[2] nil If it wasn't.
-- @treturn[2] string Why not.
function Manager:unpeer(network)
    expect(1, network, "string")
    return self:request({ op = "unpeer", network = network })
end

--- Stop the core. It can only be started again on its own computer. This closes the manager.
--
-- @treturn[1] true If it's stopping.
-- @treturn[2] nil If it isn't.
-- @treturn[2] string Why not.
function Manager:stop()
    local reply, err = self:request({ op = "stop" })
    if not reply then return nil, err end
    self:close()
    return true
end

--- Start the core afresh, as if its computer had restarted: cells and phones lose it for a moment, and phones get
-- new addresses. This closes the manager.
--
-- @treturn[1] true If it's starting again.
-- @treturn[2] nil If it isn't.
-- @treturn[2] string Why not.
function Manager:restart()
    local reply, err = self:request({ op = "restart" })
    if not reply then return nil, err end
    self:close()
    return true
end

--- Hang up. Do this once done, so the core isn't left waiting.
function Manager:close()
    if self.closed then return end
    self.closed = true
    self.connection:close()
end

function api.info()
    load()
    local sim = read_cached(SIM_FILE, SIM_FILE, function() return read_table(SIM_FILE) end)
    local chosen = read_cached(PHONE_FILE, PHONE_FILE, function() return read_table(PHONE_FILE) end)
    local off = chosen.off == true and type(sim.network) == "string"
    local info
    if phone_instance then
        info = phone_instance:info()
        info.address = info.address and address.format(info.address)
    else
        info = { state = "none", network = sim.network }
    end
    if off then info.state = "off" end
    if not info.partners then
        info.partners, info.equivalent = {}, {}
        for network in pairs(type(sim.roaming) == "table" and sim.roaming or {}) do info.partners[network] = true end
        for network in pairs(type(sim.equivalent) == "table" and sim.equivalent or {}) do
            if info.partners[network] then info.equivalent[network] = true end
        end
    end
    if not info.subscriber and sim.id then info.subscriber = { id = sim.id, number = sim.number } end
    info.enabled = not off
    info.selection = type(chosen.network) == "string" and chosen.network or "auto"
    info.roaming = info.roaming == true
    info.newer = info.newer == true
    info.unread = read_cached("unread", INBOX_FILE, function()
        local unread = 0
        for _, message in ipairs(read_messages()) do
            if message.from and message.read == false then unread = unread + 1 end
        end
        return unread
    end)
    for _, cell in ipairs(info.heard or {}) do
        if cell.serving then info.signal, info.serving_network = cell.signal, cell.network end
    end
    return info
end

function api.listen()
    require_crypto()
    load()
    if phone_instance then return true end
    local phone, err = new_phone(nil)
    if not phone then return nil, err end
    return true
end

function api.activate(network, code)
    require_crypto()
    load()
    if phone_instance and phone_instance.state ~= "inactive" and phone_instance.state ~= "rejected" then
        phone_instance:stop()
        phone_instance = nil
    end
    -- Activating turns cell service on.
    local chosen = read_table(PHONE_FILE)
    if chosen.off then
        chosen.off = nil
        write_table(PHONE_FILE, chosen)
    end
    if not phone_instance then
        local ok, err = new_phone(nil)
        if not ok then return nil, err end
    end
    return phone_instance:activate(network, code)
end

function api.send(number, text)
    load()
    local id
    if phone_instance then
        local ok, result = phone_instance:send_message(number, text)
        if not ok then return nil, result end
        id = result
    else
        -- Cell service is off (or the phone hasn't started): the message waits, and the phone sends it once it
        -- has service. It's numbered after those the phone numbered, so it's taken for none of them.
        if not has_sim() then return nil, "No SIM" end
        local ok, err = require("cc.internal.net.cell.phone").check_message(number, text)
        if not ok then return nil, err end
        local last, waiting = nil, 0
        for _, message in ipairs(read_messages()) do
            if type(message.id) == "number" and (not last or message.id > last) then last = message.id end
            if message.to and message.status == "sending" then waiting = waiting + 1 end
        end
        if waiting >= MAX_WAITING then return nil, "Too many messages are waiting to be sent" end
        id = last and last + 1 or math.random(0, 0x3FFFFFFF)
    end
    add_message({ to = number, text = text, time = os.epoch("utc"), id = id, status = "sending" })
    os.queueEvent("cell_messages")
    return true, id
end

function api.messages()
    local outbox = {}
    for _, message in ipairs(phone_instance and phone_instance.outbox or {}) do outbox[message.id] = true end
    local attached = phone_instance ~= nil and phone_instance.state == "attached"
    local sim = not phone_instance and has_sim()
    local list = read_messages()
    for _, message in ipairs(list) do
        if message.from then
            message.read = message.read ~= false
        elseif message.status == "sending" then
            if outbox[message.id] then
                if not attached then message.status = "waiting" end
            elseif sim and type(message.id) == "number" then
                -- Cell service is off: the phone sends it once it's on again.
                message.status = "waiting"
            else
                message.status, message.error = "failed", "Not sent"
            end
        end
        message.id = nil
    end
    return list
end

function api.markRead(n)
    local count = change_messages(function(message) return message.from and message.read == false and (n == nil or message.n == n) end,
        function(message) message.read = true end)
    if count > 0 then os.queueEvent("cell_messages") end
    return count
end

function api.deleteMessage(n)
    local found = change_messages(function(message) return message.n == n end, function() return false end) > 0
    if found then os.queueEvent("cell_messages") end
    return found
end

function api.setEnabled(enabled)
    load()
    local chosen = read_table(PHONE_FILE)
    if not enabled then
        chosen.off = true
        write_table(PHONE_FILE, chosen)
        if phone_instance then
            phone_instance:stop()
            phone_instance = nil
        end
        os.queueEvent("cell_state", "off")
        return true
    end

    require_crypto()
    chosen.off = nil
    write_table(PHONE_FILE, chosen)
    -- A phone which was only listening (for the monitor) has no SIM to attach with.
    if phone_instance and not phone_instance.operator then
        phone_instance:stop()
        phone_instance = nil
    end
    if not phone_instance then
        local ok, err = pcall(start_phone)
        if not ok then return nil, tostring(err) end
    end
    if not phone_instance then
        local sim = read_table(SIM_FILE)
        if type(sim.network) ~= "string" then return nil, "No SIM: activate one with 'cell activate'" end
        return nil, "This needs a wireless modem"
    end
    os.queueEvent("cell_state", phone_instance.state)
    return true
end

function api.networks()
    local info = api.info()
    local found, list = {}, {}
    local function entry(name)
        if not found[name] then
            found[name] = { name = name, kind = "other", allowed = false, serving = false, selected = info.selection == name }
            list[#list + 1] = found[name]
        end
        return found[name]
    end
    if info.network then
        local home = entry(info.network)
        home.kind, home.allowed = "home", true
    end
    for name in pairs(info.partners or {}) do
        local partner = entry(name)
        partner.kind, partner.allowed = "partner", true
        if (info.equivalent or {})[name] then partner.kind, partner.equivalent = "home", true end
    end
    if info.selection ~= "auto" then entry(info.selection) end
    for _, heard in ipairs(info.heard or {}) do
        -- Cells which have gone quiet don't count, nor do ones which only claim to be a network's.
        if heard.fresh and heard.verified ~= false then
            local network = entry(heard.network)
            if not network.signal or heard.signal > network.signal then network.signal = heard.signal end
            if heard.serving then network.serving = true end
        end
    end
    local order = { home = 1, partner = 3, other = 4 }
    local function rank(network) return network.equivalent and 2 or order[network.kind] end
    table.sort(list, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        if (a.signal or -math.huge) ~= (b.signal or -math.huge) then return (a.signal or -math.huge) > (b.signal or -math.huge) end
        return a.name < b.name
    end)
    return list
end

function api.setNetwork(name)
    load()
    if name == "auto" then name = nil end
    if name and (#name > 32 or not name:find("^[%w%-]+$")) then
        return nil, "Network names are letters, digits and dashes, up to 32 of them"
    end
    local chosen = read_table(PHONE_FILE)
    chosen.network = name
    write_table(PHONE_FILE, chosen)
    if phone_instance and phone_instance.select then phone_instance:select(name) end
    os.queueEvent("cell_state", api.info().state)
    return true
end

function api.startCell(core, area)
    local cores = {}
    if type(core) == "string" then
        cores[1] = core
    else
        for i, name in ipairs(core) do
            if type(name) ~= "string" then error(("bad argument #1 (core %d is a %s, not a string)"):format(i, type(name)), 2) end
            cores[i] = name
        end
        if not cores[1] then error("bad argument #1 (expected at least one core)", 2) end
    end
    require_crypto()
    local config = { cores = cores, area = area or 0 }
    local old = read_table(CELL_CONFIG)
    -- Start again with new settings, or to try again at once after losing a core.
    if background.cell then
        local again = table.concat(cell_cores(old) or {}, " ") ~= table.concat(cores, " ") or (old.area or 0) ~= config.area
        for _, link in ipairs(background.cell:info().links) do
            if link.state ~= "serving" then again = true end
        end
        if again then
            background.cell:stop()
            background.cell = nil
        end
    end
    write_table(CELL_CONFIG, config)
    return start_cell_service(config)
end

function api.stopCell()
    local config = read_table(CELL_CONFIG)
    if cell_cores(config) then
        config.enabled = false
        write_table(CELL_CONFIG, config)
    end
    if background.cell then
        background.cell:stop()
        background.cell = nil
    end
end

function api.cellInfo()
    if background.cell then return background.cell:info() end
    local config = read_table(CELL_CONFIG)
    local cores = cell_cores(config)
    return {
        state = "stopped", core = cores and cores[1], cores = cores, area = config.area, id = os.getComputerID(),
        fingerprint = crypto and enclave and fingerprint(getIdentity()) or nil,
    }
end

function api.startCore()
    require_crypto()
    local config = read_table(CORE_CONFIG)
    if config.enabled == false then
        config.enabled = nil
        write_table(CORE_CONFIG, config)
    end
    return start_core_service()
end

function api.manage(core, waiting)
    require_crypto()
    local connection, err = secure.connect(core or "127.0.0.1", CONTROL_PORT)
    if not connection then return nil, err end
    connection:send({ role = "admin", id = os.getComputerID() })
    local reply, receive_err = connection:receive(15)
    if type(reply) == "table" and reply.waiting then
        local shown = tostring(reply.fingerprint)
        if not waiting or waiting(shown) == false then
            connection:close()
            return nil, "The core hasn't allowed this computer to manage it", shown
        end
        reply, receive_err = connection:receive()
    end
    if type(reply) ~= "table" then
        connection:close()
        return nil, "The core didn't answer: " .. tostring(receive_err or "it hung up")
    end
    if reply.error ~= nil then
        connection:close()
        return nil, tostring(reply.error)
    end
    return setmetatable({ connection = connection, network = reply.network }, Manager)
end

function api.stopCore()
    local config = read_table(CORE_CONFIG)
    if type(config.network) == "string" then
        config.enabled = false
        write_table(CORE_CONFIG, config)
    end
    if background.core then
        background.core:stop()
        background.core = nil
    end
end

--[[- Pass an event to the services which run in the background process. One may stop itself, or start another.

@param ... The event.
]]
local function resume(...)
    if ... == "net_cell" then cell_wake_queued = false end
    local services = {}
    for _, service in pairs(background) do services[#services + 1] = service end
    for _, service in ipairs(services) do
        local ok, err = pcall(service.resume, service, ...)
        if not ok then log_error(err) end
    end
end

--[[- Make the cellular part of the net API, once its network stack is loaded.

@tparam table context What the net API gives (see above).
@treturn table The functions `net.cell` hands its work to (`api`), and ways to start the phone (`start_phone`) and
the core and cell (`start_cellular`), and to pass an event to the services in the background (`resume`).
]]
local function new(context)
    stack, load, log_error, require_crypto = context.stack, context.load, context.log_error, context.require_crypto
    getIdentity, fingerprint, secure = context.getIdentity, context.fingerprint, context.secure
    check_timeout, add_interface = context.check_timeout, context.add_interface
    return { api = api, start_phone = start_phone, start_cellular = start_cellular, resume = resume }
end

return { new = new }
