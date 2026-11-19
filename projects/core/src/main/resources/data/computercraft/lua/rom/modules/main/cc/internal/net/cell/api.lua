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
local common = require "cc.internal.net.cell.common"
local bands = require "cc.internal.net.bands"

local to_hex, from_hex, read_table = files.hex.encode, files.hex.decode, files.read_table

-- What the net API gives: its network stack, and its ways to load it, to keep errors, to check for crypto and the
-- enclave, to know this computer's key and keys' fingerprints, to connect securely, and to check a timeout. Set by
-- `new`.
local stack, load, log_error, require_crypto, getIdentity, fingerprint, secure, check_timeout

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

-- Cellular networks. A phone runs in the background, once the computer has a SIM; or, without one, if it was told to
-- listen for cells.
local SIM_FILE = "/.net/sim"
local INBOX_FILE = "/.net/messages"
-- What the user has chosen: `off` (cell service is turned off), `listen` (without a SIM, it's turned on: the phone
-- listens for cells) and `network` (the only network to use).
local PHONE_FILE = "/.net/phone"
local MAX_INBOX = 100
-- How many sent messages may wait to be sent while cell service is off: as many as the phone keeps.
local MAX_WAITING = 20
local phone_instance
-- The radio side of this computer's cell, if it is one, which its service starts once a core welcomes it.
local tower_instance
-- Each cell this computer runs, by its ID: the first (`tower_instance`) has the computer's, and there's one more for
-- each further carrier the computer has a cell on.
local tower_instances = {}
-- The settings of the cell which runs now, which its towers and modem follow.
local running_cell

--[[ The power phones and cells send with, unless they were told otherwise, in dBm. A phone sends with as much as a
pocket computer may (a placed computer or a turtle as a phone too), and a cell with as much as a phone can answer: cells
(placed computers) hear 7dB better than pocket computers and turtles do, so a cell 7dB stronger than its phones is heard
as far away as it hears them. A stronger cell would be heard where its phones couldn't reach it. ]]
local PHONE_POWER, CELL_POWER = 23, 30

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

-- Phones and cells use a radio modem, each with an interface of its own on cellular bands. An ender modem will do
-- too: it's a weaker radio, which also reaches cells and phones where its signal appears in other dimensions. A
-- wireless modem the network stack uses is picked first, and its first by name.
local function radio_modem()
    local names = {}
    for name in pairs(stack.interfaces) do names[#names + 1] = name end
    table.sort(names)
    local found_ender
    for _, name in ipairs(names) do
        local interface = stack.interfaces[name]
        if interface.kind == "wireless" then return interface.modem, "wireless" end
        if interface.kind == "ender" and not found_ender then found_ender = interface.modem end
    end
    if found_ender then return found_ender, "ender" end
end

--[[ A modem which goes away takes all its interfaces with it, including those the phone and the cell's tower are on,
which the network stack doesn't make again by itself. This happens whenever the modem's block is replaced, such as
when it's moved (Sable copies a block to its new place, and then removes the old one). So when a modem comes, put them
back on a radio modem: the same one, if it's the same modem. ]]
-- A power, as a file keeps it: a number of dBm, or nil.
local function read_power(value)
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return nil end
    return value
end

--[[ The power this computer's radio modem should send with: its cell's (what it was set to, or CELL_POWER) while it
runs one, which a relay's phone sends with too, as they share the modem; or else its phone's (what it was set to, or
PHONE_POWER) while it runs one; or else nil, the modem's own. ]]
local function wanted_power()
    if running_cell then return running_cell.power or CELL_POWER end
    if phone_instance then return read_power(read_table(PHONE_FILE).power) or PHONE_POWER end
    return nil
end

--[[ Set the radio modem's power to what it should be. A modem forgets its power when it's replaced, or its chunk
unloads, so this is done whenever a phone or cell starts or stops, its power is changed, or a modem comes. ]]
local function apply_power(modem)
    modem = modem or radio_modem()
    if modem then pcall(peripheral.call, modem, "setTransmitPower", wanted_power()) end
end

local function restore_interface(radio)
    if not radio or radio.stopped or stack.interfaces[radio.interface] then return end
    local modem, kind = radio_modem()
    if modem then
        radio:set_modem(modem, kind)
        if radio.apply_power then radio.apply_power(modem) end
    end
end

local function restore_interfaces()
    restore_interface(phone_instance)
    for _, tower in pairs(tower_instances) do restore_interface(tower) end
end

-- The bands a phone was told it may use, as its file keeps them: those which are cellular bands, lowest first, or nil
-- for any (as when none of them is one).
local function phone_bands(list)
    if type(list) ~= "table" then return nil end
    local wanted, result = {}, {}
    for _, name in pairs(list) do
        if type(name) == "string" then wanted[name:lower()] = true end
    end
    for _, band in ipairs(bands.cellular()) do
        if wanted[band.name] then result[#result + 1] = band.name end
    end
    return result[1] and result or nil
end

local function new_phone(operator, partners, equivalent)
    -- A computer may be a phone and a cell at once: a relay, whose cell reaches the core through its phone.
    local modem, kind = radio_modem()
    if not modem then return nil, "This needs a wireless modem" end
    local cell = require("cc.internal.net.cell.phone")
    local chosen = read_table(PHONE_FILE)
    phone_instance = cell.new {
        stack = stack, crypto = crypto, modem = modem, kind = kind, epoch = function() return os.epoch("utc") end,
        sim = sim_key(), operator = operator, partners = partners, equivalent = equivalent,
        selection = type(chosen.network) == "string" and chosen.network or nil,
        bands = phone_bands(chosen.bands), pinned = common.is_id(chosen.pinned) and chosen.pinned or nil,
        -- The operator says which other networks the phone may use (and which it treats as home): remember them, for
        -- when it starts out of reach of its own.
        on_partners = function(list, equivalent)
            local sim = read_table(SIM_FILE)
            sim.roaming, sim.equivalent = {}, {}
            for network, signing in pairs(list) do sim.roaming[network] = to_hex(signing) end
            for network in pairs(equivalent or {}) do sim.equivalent[network] = true end
            write_table(SIM_FILE, sim)
        end,
        -- The network has a new name (or so its operator's key says): it's the SIM's from now on, and the one the
        -- phone was told to use, if it was told to use that one.
        on_renamed = function(network, since, was)
            local sim = read_table(SIM_FILE)
            sim.network, sim.since = network, since
            write_table(SIM_FILE, sim)
            local told = read_table(PHONE_FILE)
            if told.network == was then
                told.network = network
                write_table(PHONE_FILE, told)
            end
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

    phone_instance.apply_power = apply_power
    apply_power(modem)

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

-- Start the phone, if this computer has been activated on a network; or, without a SIM, one which only listens for
-- cells, if it was told to.
function start_phone()
    if phone_instance or not crypto or not enclave then return end
    local chosen = read_table(PHONE_FILE)
    if chosen.off then return end
    local sim = read_table(SIM_FILE)
    local key, signing = from_hex(sim.key), from_hex(sim.signing)
    if type(sim.network) ~= "string" or not key or not signing then
        if chosen.listen == true then new_phone(nil) end
        return
    end
    local partners, equivalent = {}, {}
    for network, partner in pairs(type(sim.roaming) == "table" and sim.roaming or {}) do
        local partner_key = from_hex(partner)
        if type(network) == "string" and partner_key and #partner_key == 32 then partners[network] = partner_key end
    end
    for network in pairs(type(sim.equivalent) == "table" and sim.equivalent or {}) do
        if partners[network] then equivalent[network] = true end
    end
    new_phone({
        network = sim.network, key = key, signing = signing, since = type(sim.since) == "number" and sim.since or nil,
    }, partners, equivalent)
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
        stack = stack, crypto = crypto, network = options.network, former = options.former, prefix = options.prefix,
        operator = { public = public, exchange = function(peer) return enclave.exchange("cell.operator", peer) end },
        signing = signing, subscribers = options.subscribers, codes = options.codes, number_prefix = options.number_prefix,
        dns = options.dns, domain = options.domain,
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

-- The cellular bands, by name, for saying which there are.
local function band_names()
    local names = {}
    for _, band in ipairs(bands.cellular()) do names[#names + 1] = band.name end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

--[[ Where a cell's computer should have its cells, as its "band" setting says: one band's name (`"b3"`), as it always
was, for one cell on any of its core's carriers there; or a list of bands and carriers (`{ "b20", "b3/2" }`) for a cell
on each. A list of one band is that band. Gives nil, and what's wrong, for anything else. ]]
local function read_band(value)
    local list = type(value) == "string" and { value } or value
    if type(list) ~= "table" or list[1] == nil then
        return nil, "A cell's band is a band, or a list of bands and carriers"
    end
    if #list > common.MAX_CARRIERS then return nil, ("A computer runs at most %d cells"):format(common.MAX_CARRIERS) end
    local result, seen = {}, {}
    for i = 1, #list do
        local want = list[i]
        if type(want) ~= "string" then return nil, ("Band %d isn't a band's name"):format(i) end
        want = want:lower()
        local carrier = common.want_carrier(want)
        if carrier then
            want = bands.carrier_name(carrier)
            if seen[want] then return nil, ("%s is there twice: a computer has one cell on a carrier"):format(want) end
            seen[want] = true
        elseif want:find("/", 1, true) then
            return nil, ("There's no carrier called %s: a band's carriers are numbered from 1, as in b20/1"):format(want)
        elseif not common.is_wants({ want }) then
            return nil, ("There's no cellular band called %s: they're %s"):format(want, band_names())
        end
        result[i] = want
    end
    if #result == 1 and not seen[result[1]] then return result[1] end
    return result
end

-- Whether two "band" settings ask for the same.
local function same_band(a, b)
    if type(a) == "table" then a = table.concat(a, " ") end
    if type(b) == "table" then b = table.concat(b, " ") end
    return a == b
end

-- A cell's settings, besides its cores, as its file keeps them: what doesn't make sense is left out (as an older
-- version, or someone editing the file, might have it).
local function cell_settings(config)
    return {
        area = common.is_id(config.area) and config.area or 0,
        band = config.band ~= nil and read_band(config.band) or nil,
        interval = common.is_interval(config.interval) and config.interval or nil,
        pos = common.is_position(config.pos) and { config.pos[1], config.pos[2], config.pos[3] } or nil,
        power = read_power(config.power),
        service = config.service == "sms" and "sms" or nil,
        -- Whether the cell may be on carriers its networks don't offer.
        override = config.override == true or nil,
        -- A cell which was only just set up stands by until its bands are confirmed. Older ones never asked.
        confirmed = config.confirmed ~= false,
    }
end

-- Run a cell in the background: one cell, which serves the network of each core it reaches.
local function start_cell_service(config)
    if background.cell then return true end
    require_crypto()
    load()
    if not settings.get("net.enabled") then return nil, "The network stack is turned off" end
    if not radio_modem() then return nil, "A cell needs a wireless modem" end
    local signing = enclave.publicKey("cell.tower") or enclave.generate("cell.tower", "ed25519")
    running_cell = config
    apply_power()
    background.cell = require("cc.internal.net.cell.cell_service").new {
        cores = config.cores, area = config.area, band = config.band, interval = config.interval, pos = config.pos,
        service = config.service, standby = config.confirmed == false, override = config.override == true,
        id = os.getComputerID(), identity = getIdentity(), fingerprint = fingerprint, signing = to_hex(signing),
        connect = function(core) return secure.connect(core, CONTROL_PORT) end,
        start_tower = function(welcome, control)
            local modem, kind = radio_modem()
            if not modem then error("A cell needs a wireless modem", 0) end
            -- Each of the computer's cells has a tower of its own, on the one modem.
            local tower = tower_instances[welcome.id]
            if not tower or tower.stopped then
                for id, other in pairs(tower_instances) do
                    if other.stopped then tower_instances[id] = nil end
                end
                tower = require("cc.internal.net.cell.tower").new {
                    stack = stack, crypto = crypto, modem = modem, kind = kind, area = welcome.area, id = welcome.id,
                    carrier = welcome.carrier, ul = welcome.ul, interval = welcome.interval,
                    fixed_interval = welcome.fixed_interval, core_interval = welcome.core_interval, pos = welcome.pos,
                    service = welcome.service,
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
                tower.apply_power = apply_power
                apply_power(modem)
                tower_instances[welcome.id] = tower
                if welcome.id == os.getComputerID() then tower_instance = tower end
            end
            return tower:add_network(welcome.network, {
                certificate = welcome.certificate, core = address.parse(welcome.core), tunnel_key = welcome.tunnel_key,
                control = control, carriers = welcome.carriers,
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
        local config = cell_settings(cell)
        config.cores = cores
        local ok, err = start_cell_service(config)
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

--- Change a subscriber: bar them (their phone is cut off, and refused), say whether they may roam, or give them a
-- network of their own behind their phone, which the core routes to it.
--
-- @tparam string subscriber Their ID or number.
-- @tparam { barred? = boolean, roaming? = boolean, range? = string|boolean, subnet? = string|boolean } changes What to
-- change. `range` is part of the network's own addresses (such as `"10.64.5.0/28"`), and `subnet` a network which
-- isn't the network's own (such as `"192.168.5.0/24"`): `false` takes it away. A subscriber has one or the other.
-- @treturn[1] table The subscriber's `id` and `number`, whether they're `barred` and may use `roaming`, and their
-- `range` or `subnet`, if they have one.
-- @treturn[2] nil If it couldn't be done.
-- @treturn[2] string Why not.
function Manager:set(subscriber, changes)
    expect(1, subscriber, "string")
    expect(2, changes, "table")
    return self:request({
        op = "set", subscriber = subscriber, barred = changes.barred, roaming = changes.roaming,
        range = changes.range, subnet = changes.subnet,
    })
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

--- Rename the network. Its core starts afresh under the new name: cells join again by themselves, phones take the
-- name from their operator's cells (or as they next attach), and other networks' cores keep their agreements, as they
-- know this core by its key. The names it had are remembered, so phones which were away still attach.
--
-- @tparam string network The new name: letters, digits and dashes, up to 32 of them.
-- @treturn[1] table The `network`, and the name it had (`was`).
-- @treturn[2] nil If it couldn't be renamed.
-- @treturn[2] string Why not.
function Manager:rename(network)
    expect(1, network, "string")
    return self:request({ op = "rename", network = network })
end

--- See or set the carriers this network's cells use: 5MHz blocks of cellular bands, by name, such as `"b20/1"` (a band
-- on its own means its first). A network has none until some are set, and its cells stay off the air. Cells connected
-- now are told at once: one on a carrier which is no longer the network's leaves it, and one which waited for a
-- carrier takes it.
--
-- @tparam[opt] { string... } carriers The carriers, up to 8 of them: none, for none.
-- @treturn[1] table The `carriers`, by name.
-- @treturn[2] nil If they couldn't be set.
-- @treturn[2] string Why not.
function Manager:spectrum(carriers)
    expect(1, carriers, "table", "nil")
    return self:request({ op = "spectrum", carriers = carriers })
end

--- See or set how often this network's cells send system information, in seconds. Cells connected now are told at
-- once, unless their own setting says otherwise.
--
-- @tparam[opt] number interval The interval, from 0.5 to 10 seconds.
-- @treturn[1] table The `interval`.
-- @treturn[2] nil If it couldn't be set.
-- @treturn[2] string Why not.
function Manager:beacon(interval)
    expect(1, interval, "number", "nil")
    return self:request({ op = "beacon", interval = interval })
end

--[[- See or set the DNS servers and domain the network's phones are given, to look names up with. Phones attached now
hear of a change at once.

@tparam { string... }|false|nil servers The servers' addresses; `false` for none; or `nil` to leave them as they are.
@tparam string|false|nil domain The domain; `false` for none; or `nil` to leave it as it is.
@treturn table|nil `servers` (a list, maybe empty) and `domain` (if there is one), or `nil` if it couldn't be changed.
@treturn string|nil Why not.
]]
function Manager:dns(servers, domain)
    expect(1, servers, "table", "boolean", "nil")
    expect(2, domain, "string", "boolean", "nil")
    return self:request({ op = "dns", servers = servers, domain = domain })
end

--[[- See or set where the network's phones' names are registered: at a DNS server (`dnsd`) which lets the core set
names, in a zone (by default, the domain phones are given). A phone's name is its subscriber's ID, such as
`acme-0042`.

@tparam string|false|nil server The server's address; `false` to register no names; or `nil` to leave it as it is.
@tparam string|false|nil zone The zone; `false` for the domain phones are given; or `nil` to leave it as it is.
@tparam string|false|nil key The secret the server asks updates to be signed with; `false` for none; or `nil` to leave
it as it is.
@treturn table|nil `server`, `zone` and `domain` (if there are), and whether there's a `key`; or `nil` if it couldn't be
changed.
@treturn string|nil Why not.
]]
function Manager:hostnames(server, zone, key)
    expect(1, server, "string", "boolean", "nil")
    expect(2, zone, "string", "boolean", "nil")
    expect(3, key, "string", "boolean", "nil")
    return self:request({ op = "hostnames", server = server, zone = zone, key = key })
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
        -- What the SIM file says, if it makes sense: anything may have written it.
        info = { state = "none", network = type(sim.network) == "string" and sim.network or nil }
    end
    if off then info.state = "off" end
    if not info.partners then
        info.partners, info.equivalent = {}, {}
        for network in pairs(type(sim.roaming) == "table" and sim.roaming or {}) do
            if type(network) == "string" then info.partners[network] = true end
        end
        for network in pairs(type(sim.equivalent) == "table" and sim.equivalent or {}) do
            if info.partners[network] then info.equivalent[network] = true end
        end
    end
    if not info.subscriber and type(sim.id) == "string" and type(sim.number) == "string" then
        info.subscriber = { id = sim.id, number = sim.number }
    end
    -- Without a SIM, cell service is only on once it's told to listen for cells.
    info.enabled = chosen.off ~= true and (type(sim.network) == "string" or chosen.listen == true)
    info.selection = type(chosen.network) == "string" and chosen.network or "auto"
    info.bands, info.pinned = phone_bands(chosen.bands), common.is_id(chosen.pinned) and chosen.pinned or nil
    info.power = read_power(chosen.power)
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
    if phone_instance then
        -- A phone which is camped only listens on the carriers it heard lately: for the monitor, listen on every one
        -- for a moment.
        phone_instance:rescan()
        return true
    end
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
        apply_power()
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
        chosen.off, chosen.listen = true, nil
        write_table(PHONE_FILE, chosen)
        if phone_instance then
            phone_instance:stop()
            phone_instance = nil
            apply_power()
        end
        os.queueEvent("cell_state", "off")
        return true
    end

    require_crypto()
    -- Without a SIM, the phone listens for cells, and shows the strongest: from when the computer starts too. This is
    -- kept even without a modem, so the phone starts once one comes.
    local sim = has_sim()
    chosen.off, chosen.listen = nil, not sim or nil
    write_table(PHONE_FILE, chosen)
    -- A phone which was only listening (for the monitor) has no SIM to attach with, if there is one now.
    if sim and phone_instance and not phone_instance.operator then
        phone_instance:stop()
        phone_instance = nil
        apply_power()
    end
    if not phone_instance then
        local ok, err = pcall(start_phone)
        if not ok then return nil, tostring(err) end
    end
    if not phone_instance then return nil, "This needs a wireless modem" end
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

function api.setBands(list)
    load()
    local wanted
    if list ~= nil then
        wanted = {}
        for i, name in ipairs(list) do
            local band = type(name) == "string" and bands.get(name:lower())
            if not band or not band.downlink then
                return nil, ("There's no cellular band called %s: they're %s"):format(tostring(name), band_names())
            end
            wanted[i] = name:lower()
        end
        wanted = phone_bands(wanted)
        if not wanted then return nil, "Name at least one band, or none for every band" end
        -- Every band is no choice at all.
        if #wanted == #bands.cellular() then wanted = nil end
    end
    local chosen = read_table(PHONE_FILE)
    chosen.bands = wanted
    write_table(PHONE_FILE, chosen)
    if phone_instance and phone_instance.restrict then phone_instance:restrict(wanted, phone_instance.pinned) end
    os.queueEvent("cell_state", api.info().state)
    return true
end

function api.pinCell(cell)
    load()
    if cell ~= nil and not common.is_id(cell) then return nil, "A cell's ID is a whole number" end
    local chosen = read_table(PHONE_FILE)
    chosen.pinned = cell
    write_table(PHONE_FILE, chosen)
    if phone_instance and phone_instance.restrict then
        local allowed = phone_instance:info().bands
        phone_instance:restrict(allowed, cell)
    end
    os.queueEvent("cell_state", api.info().state)
    return true
end

-- The least and most power this computer's radio modem may send with, if it has one, and the power it sends with now.
local function power_limits()
    local modem = radio_modem()
    if not modem then return nil end
    local ok, now, most, least = pcall(peripheral.call, modem, "getTransmitPower")
    if not ok or type(most) ~= "number" then return nil end
    return type(least) == "number" and least or -30, most, now
end

-- What this computer is, to say whose limits they are.
local function device_name()
    if pocket then return "pocket computer" end
    if turtle then return "turtle" end
    return "computer"
end

function api.setPower(power)
    load()
    if power ~= nil then
        if not read_power(power) then return nil, "A phone's power is a number of dBm" end
        local least, most = power_limits()
        if least and (power < least or power > most) then
            return nil, ("This %s sends with %g to %g dBm"):format(device_name(), least, most)
        end
    end
    local chosen = read_table(PHONE_FILE)
    chosen.power = power
    write_table(PHONE_FILE, chosen)
    apply_power()
    return true
end

function api.transmitPower()
    load()
    local least, most, now = power_limits()
    local _, kind = radio_modem()
    return {
        power = read_power(read_table(PHONE_FILE).power), default = PHONE_POWER, device = device_name(), kind = kind,
        now = now, least = least, most = most,
        cell = running_cell and (running_cell.power or CELL_POWER) or nil,
    }
end

-- A cell's settings, besides its cores, in the order they're checked.
local CELL_SETTINGS = { "area", "band", "interval", "pos", "power", "service", "override" }

-- What's wrong with a value for one of a cell's settings, if it won't do.
local function check_setting(key, value)
    if key == "area" then
        if not common.is_id(value) then return "A cell's area is a whole number, 0 or more" end
    elseif key == "band" then
        local band, err = read_band(value)
        if not band then return err end
    elseif key == "interval" then
        if not common.is_interval(value) then
            return ("A cell sends its system information every %g to %g seconds"):format(common.MIN_INTERVAL, common.MAX_INTERVAL)
        end
    elseif key == "pos" then
        if not common.is_position(value) then return "A cell's position is three whole numbers: its computer's x, y and z" end
    elseif key == "power" then
        if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
            return "A cell's power is a number of dBm"
        end
    elseif key == "service" then
        if value ~= "sms" then return "A cell's service is \"sms\" (messages only), or everything" end
    elseif key == "override" then
        if value ~= true then return "A cell overrides its networks' carriers (true), or it doesn't" end
    end
end

-- A cell's cores, checked: each once (names aren't case sensitive), as many as a cell can name in its system
-- information. Gives the list, or nil and why it won't do.
local function check_cores(cores)
    local list, seen = {}, {}
    for i, core in ipairs(cores) do
        if type(core) ~= "string" or core == "" or #core > 255 or core:find("[%s%c]") then
            return nil, ("Core %d isn't a name or an address"):format(i)
        end
        if not seen[core:lower()] then
            seen[core:lower()] = true
            list[#list + 1] = core
        end
    end
    if #list > common.MAX_SIB_NETWORKS then
        return nil, ("A cell serves at most %d networks"):format(common.MAX_SIB_NETWORKS)
    end
    return list
end

function api.startCell(core, settings)
    if core == nil then
        -- As it was set up: with each core added, and each setting set, since.
        local config = read_table(CELL_CONFIG)
        local cores = cell_cores(config)
        if not cores then return nil, "The cell has no cores to connect to" end
        require_crypto()
        if config.enabled == false then
            config.enabled = nil
            write_table(CELL_CONFIG, config)
        end
        local start = cell_settings(config)
        start.cores = cores
        return start_cell_service(start)
    end

    local given = type(settings) == "table" and settings or { area = settings }
    local config = { area = 0 }
    for _, key in ipairs(CELL_SETTINGS) do
        local value = given[key]
        -- (No override is the same as not saying.)
        if value ~= nil and not (key == "override" and value == false) then
            local err = check_setting(key, value)
            if err then return nil, err end
            if key == "band" then value = read_band(value) end
            config[key] = key == "pos" and { value[1], value[2], value[3] } or value
        end
    end
    local names = {}
    if type(core) == "string" then
        names[1] = core
    else
        for i, name in ipairs(core) do
            if type(name) ~= "string" then error(("bad argument #1 (core %d is a %s, not a string)"):format(i, type(name)), 2) end
            names[i] = name
        end
        if not names[1] then error("bad argument #1 (expected at least one core)", 2) end
    end
    local cores, err = check_cores(names)
    if not cores then return nil, err end
    config.cores = cores
    require_crypto()
    -- Start again with new settings, or to try again at once after losing a core.
    if background.cell then
        local old = running_cell
        local function place(p) return p and table.concat(p, ",") or "" end
        local again = table.concat(old.cores, " ") ~= table.concat(cores, " ") or old.area ~= config.area
            or not same_band(old.band, config.band) or old.interval ~= config.interval
            or place(old.pos) ~= place(config.pos) or old.power ~= config.power or old.service ~= config.service
            or old.override ~= config.override
        for _, link in ipairs(background.cell:info().links) do
            if link.state ~= "serving" then again = true end
        end
        if again then
            background.cell:stop()
            background.cell, running_cell = nil, nil
        end
    end
    write_table(CELL_CONFIG, config)
    return start_cell_service(config)
end

function api.configureCell(changes)
    load()
    local config = read_table(CELL_CONFIG)
    local service = background.cell
    -- What the cell runs with now, or would start with.
    local old = service and running_cell or cell_settings(config)
    local new = {}
    for _, key in ipairs(CELL_SETTINGS) do new[key] = old[key] end
    local cores = service and running_cell.cores or cell_cores(config) or {}
    if changes.cores ~= nil then
        -- A core it has already, spelt another way, is the same core: keep it as it is, so it isn't removed and added.
        local known = {}
        for _, core in ipairs(cores) do known[core:lower()] = core end
        local err
        cores, err = check_cores(changes.cores)
        if not cores then return nil, err end
        for i, core in ipairs(cores) do cores[i] = known[core:lower()] or core end
    end
    for _, key in ipairs(CELL_SETTINGS) do
        local value = changes[key]
        if value == false then
            new[key] = key == "area" and 0 or nil
        elseif value ~= nil then
            local err = check_setting(key, value)
            if err then return nil, err end
            if key == "band" then value = read_band(value) end
            new[key] = key == "pos" and { value[1], value[2], value[3] } or value
        end
    end
    -- Whether the cell's bands are confirmed, so it may go on the air: once they're said (to be some, or any), or it's
    -- told so. A cell which gets its first core, with no band said yet, stands by until then.
    local confirmed = old.confirmed ~= false
    if not cell_cores(config) and not (service and running_cell.cores[1]) and cores[1] and new.band == nil then
        confirmed = false
    end
    if changes.band ~= nil or changes.confirmed == true then confirmed = true end
    if changes.power then
        local least, most = power_limits()
        if least and (new.power < least or new.power > most) then
            return nil, ("This computer's modem sends with %g to %g dBm"):format(least, most)
        end
    end
    -- A band the networks the cell serves have no carrier in would take it off the air: their cores would refuse it.
    -- So would a carrier none of them uses; and a band wanted more often than any of them has carriers in it is a cell
    -- too many.
    -- (A cell which may override what its networks offer is put where it says.)
    local wants = type(new.band) == "string" and { new.band } or new.band
    if service and changes.band and not same_band(new.band, old.band) and not new.override then
        local want, have = service:unplaceable(wants), service:bands()
        if want and have then
            local names = {}
            for band in pairs(have) do names[#names + 1] = band end
            table.sort(names)
            if not names[1] then
                return nil, "The networks this cell serves have no carriers yet"
            elseif common.want_carrier(want) then
                return nil, ("No network this cell serves uses the carrier %s"):format(want)
            elseif not have[want] then
                return nil, ("No network this cell serves has a carrier in band %s, only in %s"):format(
                    want, table.concat(names, ", ")
                )
            end
            return nil, ("No network this cell serves has that many carriers in band %s"):format(want)
        end
    end

    config.core = nil
    config.cores = cores[1] and cores or nil
    for _, key in ipairs(CELL_SETTINGS) do config[key] = new[key] end
    if confirmed then config.confirmed = nil else config.confirmed = false end
    write_table(CELL_CONFIG, config)
    if not service then return true, false end

    if not cores[1] then
        service:stop()
        background.cell, running_cell = nil, nil
        apply_power()
        return true, false
    end
    -- The area, and bands other than those it's on, are said to each core when the cell connects: so connect again.
    -- (Not if its cells are just where it's now told to have them: each on a carrier it's told, and no others.)
    local moves = false
    if wants and not same_band(new.band, old.band) then
        local on = {}
        for i, cell in ipairs(service:radio()) do on[i] = cell.carrier end
        local answered, answers = common.match_wants(wants, on)
        for i = 1, math.max(#wants, #on) do
            if (wants[i] and not answered[i]) or (on[i] and not answers[on[i]]) then moves = true end
        end
    end
    if new.area ~= old.area or moves then
        service:stop()
        background.cell, running_cell = nil, nil
        local start = {}
        for _, key in ipairs(CELL_SETTINGS) do start[key] = new[key] end
        start.cores, start.confirmed = cores, confirmed
        local ok, err = start_cell_service(start)
        if not ok then return nil, err end
        -- A cell which stood by had no phones to lose.
        return true, old.confirmed ~= false
    end

    -- Everything else changes at once, without disturbing the networks the cell serves (but those it stops serving).
    local wanted = {}
    for _, core in ipairs(cores) do wanted[core] = true end
    for _, core in ipairs(running_cell.cores) do
        if not wanted[core] then service:remove_core(core) end
    end
    for _, core in ipairs(cores) do service:add_core(core) end
    running_cell.cores = cores
    for _, key in ipairs(CELL_SETTINGS) do running_cell[key] = new[key] end
    service:configure(new)
    service:set_override(new.override == true)
    -- Its bands are confirmed: it goes on the air.
    if confirmed and running_cell.confirmed == false then service:go_on_air() end
    running_cell.confirmed = confirmed
    -- (`old` is the running cell's settings, which were changed just now: so set the power whether it changed or not.)
    apply_power()
    return true, false
end

function api.stopCell()
    local config = read_table(CELL_CONFIG)
    if cell_cores(config) then
        config.enabled = false
        write_table(CELL_CONFIG, config)
    end
    if background.cell then
        background.cell:stop()
        background.cell, running_cell = nil, nil
        apply_power()
    end
end

function api.cellInfo()
    local config = read_table(CELL_CONFIG)
    local saved, cores = cell_settings(config), cell_cores(config)
    local info
    if background.cell then
        info = background.cell:info()
        if tower_instance and not tower_instance.stopped then info.current_interval = tower_instance.interval end
    else
        info = {
            state = "stopped", core = cores and cores[1], id = os.getComputerID(),
            fingerprint = crypto and enclave and fingerprint(getIdentity()) or nil,
        }
    end
    info.cores, info.enabled = cores, config.enabled ~= false
    for _, key in ipairs(CELL_SETTINGS) do info[key] = saved[key] end
    info.default_power = CELL_POWER
    info.confirmed, info.override = saved.confirmed, saved.override == true
    return info
end

function api.locate()
    load()
    if not phone_instance then return nil, "Not listening for cells" end
    return phone_instance:locate()
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

function api.coreInfo()
    local config = read_table(CORE_CONFIG)
    if type(config.network) ~= "string" then return nil end
    return { network = config.network, running = background.core ~= nil, enabled = config.enabled ~= false }
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

--[[- The DNS servers and domain the phone's network gives it, for looking names up: while it's attached at a cell
which carries packets, as there's no reaching a server otherwise.

@treturn { servers? = { string... }, domain? = string }|nil The servers and domain, or nil if there are none to use.
]]
local function phone_dns()
    local phone = phone_instance
    if not phone or phone.state ~= "attached" or not phone.subscriber or phone:messages_only() then return nil end
    return phone.subscriber.dns
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
the core and cell (`start_cellular`), to pass an event to the services in the background (`resume`), and to put the
phone and cell back on the air when a modem comes (`restore_interfaces`).
]]
local function new(context)
    stack, load, log_error, require_crypto = context.stack, context.load, context.log_error, context.require_crypto
    getIdentity, fingerprint, secure = context.getIdentity, context.fingerprint, context.secure
    check_timeout = context.check_timeout
    return {
        api = api, start_phone = start_phone, start_cellular = start_cellular, resume = resume,
        restore_interfaces = restore_interfaces, phone_dns = phone_dns,
    }
end

return { new = new }
