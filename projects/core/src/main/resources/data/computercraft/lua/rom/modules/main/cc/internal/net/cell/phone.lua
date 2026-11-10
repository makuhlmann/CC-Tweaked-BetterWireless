-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A phone: picks a cell of its network, attaches, and keeps its address and connections while it moves.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cell` program instead.

The phone listens for cells' system information, and only believes cells with a certificate from its operator. It
attaches through the strongest, with a `Noise_IK` handshake with the operator's key (which it knows from its SIM), and
gets an address. Packets go over a virtual interface named `cell`, sealed with the key it shares with its cell, with a
default route through it.

Every couple of seconds, it compares its cell with the others it hears. If another is 3 dB stronger for two seconds, it
tells its cell, which hands it over. If its cell goes quiet, it attaches again through the best one, keeping its
address.

@local
]]

local codec = require "cc.net.codec"
local noise = require "cc.internal.net.noise"
local common = require "cc.internal.net.cell.common"
local core = require "cc.internal.net.cell.core"
local PROLOGUE, ACTIVATE_PROLOGUE = core.PROLOGUE, core.ACTIVATE_PROLOGUE

-- Signals below this, in dBm, are too weak to use.
local NO_SERVICE = -100
-- How much stronger, in dB, and for how long, in seconds, another cell must be to move to it.
local HYSTERESIS, TIME_TO_TRIGGER = 3, 2
-- How often to compare cells, and how long a cell may be silent before we give up on it.
local MEASURE_INTERVAL, SILENCE = 1, 4
-- How long to wait for an attach to finish, and the longest to wait before trying again.
local ATTACH_TIMEOUT, MAX_RETRY = 5, 60
-- How many system information broadcasts to average a cell's signal over.
local SAMPLES = 3
-- How many cells (of any network) to remember, and for how long after they go quiet, in seconds. Anyone can send
-- system information, so there's a limit.
local MAX_HEARD, FORGET = 32, 30
-- How many events (attaching, moving between cells, losing service) to remember.
local MAX_EVENTS = 20

local Phone = {}
Phone.__index = Phone

--[[- Start a phone.

@tparam {
    stack = table, crypto = table, interface = string, epoch = function():number,
    sim = { public = string, exchange = function(public:string):string },
    operator? = { network = string, key = string, signing = string },
    on_change? = function(phone:table),
    on_message? = function(from:string, text:string),
    on_activated? = function(info:table), relay? = function():boolean,
} options The stack; the `crypto` API; the interface cells are heard on; the time, as `os.epoch("utc")` gives; the
phone's SIM key; its operator's network name, X25519 key and Ed25519 signing key, if it has been activated; what to call
when its state changes; what to call with each message; what to call when it's activated, with the operator's keys and
its subscription, to save them; and whether this computer is a relay, whose cell's backhaul is this phone (so it
avoids cells already as many relays from the core as a chain may have).
@treturn table The phone.
]]
local function new(options)
    local stack = options.stack
    local self = setmetatable({
        stack = stack, crypto = options.crypto, interface = options.interface, epoch = options.epoch,
        sim = options.sim, operator = options.operator, on_change = options.on_change or function() end,
        on_message = options.on_message or function() end, on_activated = options.on_activated or function() end,
        relay = options.relay or function() return false end,
        cells = {}, heard = {}, events = {}, state = options.operator and "searching" or "inactive", retry = 2,
        seen_messages = {},
    }, Phone)

    -- A cell may share this computer (a relay), so frames from phones come here too: they're ignored, as they don't
    -- come from our cell.
    self.frame_handler = stack:on_frame(common.FRAME, function(interface, src, body, signal)
        if interface.name == self.interface then self:radio(src, body, signal) end
    end, true)
    self.timer = stack:schedule(MEASURE_INTERVAL, function() self:measure() end)
    return self
end

function Phone:set_state(state)
    if self.state == state then return end
    self.state = state
    if state == "attached" then
        self:event("attached", { cell = self.cell })
    elseif state == "rejected" then
        self:event("rejected", { reason = self.rejected })
    end
    self.on_change(self)
end

-- Remember something which happened, for the cell program's monitor.
function Phone:event(kind, details)
    local event = { kind = kind, time = self.epoch() }
    for k, v in pairs(details) do event[k] = v end
    self.events[#self.events + 1] = event
    if #self.events > MAX_EVENTS then table.remove(self.events, 1) end
end

-- Remember a cell we heard, of any network, and average its signal. Whether its system information checked out is
-- only known for our own network.
function Phone:hear(src, message, signal, verified)
    local now = self.stack.clock()
    local cell = self.heard[src]
    if not cell then
        local count = 0
        for id, other in pairs(self.heard) do
            if now - other.heard > FORGET then self.heard[id] = nil else count = count + 1 end
        end
        if count >= MAX_HEARD then return end
        cell = { samples = {} }
        self.heard[src] = cell
    end
    table.insert(cell.samples, type(signal) == "number" and signal or -50)
    if #cell.samples > SAMPLES then table.remove(cell.samples, 1) end
    local total = 0
    for _, sample in ipairs(cell.samples) do total = total + sample end
    cell.signal, cell.heard, cell.network, cell.verified = total / #cell.samples, now, message.network, verified
    cell.area = type(message.area) == "number" and message.area or nil
    cell.load = type(message.load) == "number" and message.load or nil
end

function Phone:to_cell(cell, message)
    self.stack:send_frame(self.interface, cell, common.FRAME, message)
end

-- Whether a cell's backhaul goes through this computer: it's a relay, and this phone is its way to the core. Using it
-- would be a loop.
function Phone:behind_us(cell)
    for _, relay in ipairs(cell.path or {}) do
        if relay == self.stack.id then return true end
    end
    return false
end

-- The best cell we can hear, and its signal.
function Phone:best_cell(except)
    local best, best_signal
    local now = self.stack.clock()
    for id, cell in pairs(self.cells) do
        if id ~= except and now - cell.heard <= SILENCE and cell.signal >= NO_SERVICE and not self:behind_us(cell)
            and not (self.relay() and #(cell.path or {}) >= common.MAX_PATH)
            and (not best_signal or cell.signal > best_signal) then
            best, best_signal = id, cell.signal
        end
    end
    return best, best_signal
end

function Phone:radio(src, message, signal)
    if type(message) ~= "table" then return end
    local op = message.op

    if op == "sib" then
        if type(message.network) ~= "string" or #message.network > 64 then return end
        -- Cells of other networks (or of any network, before we're activated) can't be checked, but we can see what's
        -- around. A cell which claims to be ours, but isn't, may be a fake.
        if not self.operator or message.network ~= self.operator.network then
            return self:hear(src, message, signal, nil)
        end
        local ok = common.check_sib(self.crypto, message, {
            network = self.operator.network, signing = self.operator.signing, now = self.epoch(), sender = src,
        })
        self:hear(src, message, signal, ok == true)
        if not ok then return end
        -- Average the last few broadcasts' signals, so one strong or weak one doesn't move us.
        local cell = self.cells[src] or { samples = {} }
        self.cells[src] = cell
        table.insert(cell.samples, type(signal) == "number" and signal or -50)
        if #cell.samples > SAMPLES then table.remove(cell.samples, 1) end
        local total = 0
        for _, sample in ipairs(cell.samples) do total = total + sample end
        cell.signal, cell.heard, cell.area = total / #cell.samples, self.stack.clock(), message.area
        cell.path = message.path
        if self.state == "searching" then self:attach() end
        return
    end

    -- Everything else comes from the cell we're attaching through, or attached to.
    if src ~= self.cell then return end
    if op == "attach_reply" and self.state == "attaching" and self.handshake then
        local payload = self.handshake:read(message.handshake)
        local info = payload and codec.decode(payload)
        if type(info) ~= "table" then return end
        self.subscriber = { id = info.id, number = info.number }
        local send = self.handshake:split()
        self.secret = self.handshake.ck
        self.handshake = nil
        self:to_cell(self.cell, { op = "attach_complete", data = send:encrypt(codec.encode({ complete = true })) })
    elseif op == "accept" and self.state == "attaching" and self.secret then
        local sealer = common.new_sealer(self.crypto, common.cell_key(self.crypto, self.secret, self.cell), common.UPLINK, common.DOWNLINK)
        local value = sealer:open(message.sealed)
        if type(value) ~= "table" or type(value.address) ~= "number" then return end
        self.sealer = sealer
        self:set_address(value.address)
        self.retry = 2
        self:set_state("attached")
    elseif op == "data" and self.state == "attached" then
        local value = self.sealer:open(message.sealed)
        if type(value) ~= "table" then return end
        local packet = type(value.p) == "string" and codec.decode(value.p)
        if type(packet) == "table" then
            self.stack:inject("cell", packet)
        elseif type(value.sms) == "table" and type(value.sms.from) == "string" and type(value.sms.text) == "string" then
            -- Say we have it, even if we've seen it before (our last acknowledgement may have been lost).
            self:to_cell(self.cell, { op = "data", sealed = self.sealer:seal({ sms_ack = value.sms.id }) })
            if not self.seen_messages[value.sms.id] then
                self.seen_messages[value.sms.id] = true
                self.on_message(value.sms.from, value.sms.text)
            end
        end
    elseif op == "activate_reply" and self.state == "activating" and self.handshake then
        if not self.handshake:read(message.handshake) then return self:activation_failed("The network refused") end
        local finish = self.handshake:write(codec.encode({ v = 1 }))
        if not finish then return self:activation_failed("The network refused") end
        self:to_cell(self.cell, { op = "activate_finish", handshake = finish })
    elseif op == "activate_accept" and self.state == "activating" and self.handshake then
        local _, receive = self.handshake:split()
        local plaintext = type(message.data) == "string" and receive:decrypt(message.data)
        local info = plaintext and codec.decode(plaintext)
        if type(info) ~= "table" or type(info.network) ~= "string" or type(info.key) ~= "string" or #info.key ~= 32
            or type(info.signing) ~= "string" or #info.signing ~= 32 then
            return self:activation_failed("The network's answer was garbled")
        end
        -- Only someone who knew the code could have sent this, so these keys are the operator's.
        self.handshake = nil
        self.operator = { network = info.network, key = info.key, signing = info.signing }
        self.subscriber = { id = info.id, number = info.number }
        self:event("activated", { network = info.network })
        self.on_activated(info)
        self.retry = 2
        self:set_state("searching")
        self:attach()
    elseif op == "handover" and self.state == "attached" then
        local value = self.sealer:open(message.sealed)
        local target = type(value) == "table" and value.target
        if type(target) ~= "number" or not self.cells[target] then return end
        -- Move to the new cell, with the key we share with it, and say we're there. Our address stays the same.
        self:event("handover", { from = self.cell, to = target })
        self.cell, self.candidate = target, nil
        self.sealer = common.new_sealer(self.crypto, common.cell_key(self.crypto, self.secret, target), common.UPLINK, common.DOWNLINK)
        self:to_cell(target, { op = "confirm", sealed = self.sealer:seal({ confirm = true }) })
        self.on_change(self)
    elseif op == "reject" and self.state == "attaching" then
        self.rejected = type(message.reason) == "string" and message.reason or "Rejected"
        self:give_up()
    end
end

--[[- Activate with a code from the network's administrator, through the strongest cell of the network.

@tparam string network The network's name.
@tparam string code The activation code.
@treturn[1] true If activation started. The phone's state becomes `"searching"` once it's done.
@treturn[2] nil If it couldn't start.
@treturn[2] string Why not.
]]
function Phone:activate(network, code)
    local tag, secret = common.parse_code(code)
    if not tag then return nil, "That isn't an activation code" end
    local best, best_signal
    for id, heard in pairs(self.heard) do
        if heard.network == network and self.stack.clock() - heard.heard <= SILENCE
            and (not best_signal or heard.signal > best_signal) then
            best, best_signal = id, heard.signal
        end
    end
    if not best then return nil, "No cell of " .. network .. " in range" end

    self.cell = best
    self.handshake = noise.new {
        crypto = self.crypto, pattern = "XXpsk3", initiator = true, prologue = ACTIVATE_PROLOGUE .. network,
        static = self.sim, psk = common.activation_key(self.crypto, secret),
    }
    local message = self.handshake:write("")
    if not message then return nil, "The SIM can't be used" end
    self:set_state("activating")
    self:to_cell(best, { op = "activate", network = network, tag = tag, handshake = message })

    local attempt = {}
    self.attempt = attempt
    self.stack:schedule(ATTACH_TIMEOUT * 2, function()
        if self.attempt == attempt and self.state == "activating" then self:activation_failed("No answer: check the code") end
    end)
    return true
end

function Phone:activation_failed(reason)
    self.handshake, self.attempt, self.activation_error = nil, nil, reason
    self:event("activation_failed", { reason = reason })
    self:set_state("inactive")
end

--[[- Send a message to another phone, by its number. It's kept by the network until that phone is reachable.

@tparam string to The number.
@tparam string text The message, up to 1000 characters.
@treturn[1] true If it was sent.
@treturn[2] nil If it wasn't.
@treturn[2] string Why not.
]]
function Phone:send_message(to, text)
    if self.state ~= "attached" then return nil, "No service" end
    if #text > 1000 then return nil, "Messages can be at most 1000 characters" end
    self:to_cell(self.cell, { op = "data", sealed = self.sealer:seal({ sms = { to = to, text = text } }) })
    return true
end

-- Start attaching through the best cell.
function Phone:attach()
    local best = self:best_cell()
    if not best then return end
    self.cell, self.secret, self.rejected = best, nil, nil
    self.handshake = noise.new {
        crypto = self.crypto, pattern = "IK", initiator = true, prologue = PROLOGUE .. self.operator.network,
        static = self.sim, remote_static = self.operator.key,
    }
    local message = self.handshake:write(codec.encode({ v = 1 }))
    if not message then return self:give_up() end
    self:set_state("attaching")
    self:to_cell(best, { op = "attach", network = self.operator.network, handshake = message })

    local attempt = {}
    self.attempt = attempt
    self.stack:schedule(ATTACH_TIMEOUT, function()
        if self.attempt == attempt and self.state == "attaching" then self:give_up() end
    end)
end

-- Attaching didn't work: try again later, less often each time.
function Phone:give_up()
    self.handshake, self.attempt = nil, nil
    self:set_state(self.rejected and "rejected" or "searching")
    local delay = self.retry
    self.retry = math.min(self.retry * 2, MAX_RETRY)
    self.stack:schedule(delay, function()
        if self.state == "searching" or self.state == "rejected" then
            self:set_state("searching")
            self:attach()
        end
    end)
end

-- Our address: a virtual interface to the cell, and a default route through it.
function Phone:set_address(addr)
    local stack = self.stack
    if not stack.interfaces.cell then
        stack:add_virtual_interface("cell", "cell", function(packet) self:uplink(packet) end)
    end
    if stack.interfaces.cell.address ~= addr then stack:set_address("cell", addr, 32) end
    stack:remove_routes(function(route) return route.source == "cell" end)
    stack:add_route { network = 0, prefix = 0, interface = "cell", metric = 5, source = "cell" }
    self.address = addr
end

function Phone:uplink(packet)
    if self.state ~= "attached" then return end
    local sealed = self.sealer:seal({ p = codec.encode(packet) })
    if sealed then self:to_cell(self.cell, { op = "data", sealed = sealed }) end
end

-- Compare our cell with the others, every second.
function Phone:measure()
    self.timer = self.stack:schedule(MEASURE_INTERVAL, function() self:measure() end)
    if self.state ~= "attached" then return end

    local now = self.stack.clock()
    local serving = self.cells[self.cell]
    if not serving or now - serving.heard > SILENCE or serving.signal < NO_SERVICE then
        -- Our cell has gone: attach again through another, keeping our address.
        self:event("lost", { cell = self.cell })
        self:set_state("searching")
        self.cells[self.cell] = nil
        return self:attach()
    end

    local best, best_signal = self:best_cell(self.cell)
    if best and best_signal >= serving.signal + HYSTERESIS then
        if self.candidate ~= best then
            self.candidate, self.candidate_since = best, now
        elseif now - self.candidate_since >= TIME_TO_TRIGGER and not self.reported then
            self.reported = best
            self:to_cell(self.cell, { op = "data", sealed = self.sealer:seal({ target = best }) })
            -- If the handover doesn't happen, ask again later.
            self.stack:schedule(TIME_TO_TRIGGER * 2, function() self.reported = nil end)
        end
    else
        self.candidate = nil
    end
end

--- Describe the phone.
--
-- @treturn table Its state, cell, address and subscriber; the cells of its network it hears (`cells`); every cell it
-- has heard lately, of any network (`heard`); the networks around; and what has happened lately (`events`).
function Phone:info()
    local now = self.stack.clock()
    local cells = {}
    for id, cell in pairs(self.cells) do cells[#cells + 1] = { id = id, signal = cell.signal, area = cell.area } end
    table.sort(cells, function(a, b) return a.signal > b.signal end)

    local heard, names, networks = {}, {}, {}
    for id, cell in pairs(self.heard) do
        local age = now - cell.heard
        if age <= FORGET then
            heard[#heard + 1] = {
                id = id, network = cell.network, signal = cell.signal, area = cell.area, load = cell.load, age = age,
                verified = cell.verified, serving = id == self.cell and self.state == "attached",
            }
            if age <= SILENCE and not names[cell.network] then
                names[cell.network] = true
                networks[#networks + 1] = cell.network
            end
        end
    end
    table.sort(heard, function(a, b)
        if (a.age <= SILENCE) ~= (b.age <= SILENCE) then return a.age <= SILENCE end
        if a.signal ~= b.signal then return a.signal > b.signal end
        return a.id < b.id
    end)
    table.sort(networks)

    local events = {}
    for i, event in ipairs(self.events) do
        events[i] = {}
        for k, v in pairs(event) do events[i][k] = v end
    end

    return {
        state = self.state, cell = self.cell, address = self.address, subscriber = self.subscriber,
        rejected = self.rejected, activation_error = self.activation_error, cells = cells, networks = networks,
        heard = heard, events = events, network = self.operator and self.operator.network,
    }
end

--- Stop the phone, giving up its address.
function Phone:stop()
    self.stack:cancel(self.timer)
    self.stack:off_frame(common.FRAME, self.frame_handler)
    self.stack:remove_routes(function(route) return route.source == "cell" end)
    self.stack:remove_interface("cell")
end

return {
    new = new,
}
