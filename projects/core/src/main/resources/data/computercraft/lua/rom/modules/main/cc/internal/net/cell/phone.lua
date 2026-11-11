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

A cell may be heard well enough, yet not hear the phone (at the edge of its coverage, say). So when an attach through a
cell gets no answer, the phone leaves that cell alone for a while (longer each time it happens again) and attaches
through the next best, of a partner if need be: only once there's nothing else does it try that cell again.

Roaming: where it can't hear its own network, the phone uses a cell of a network its operator has an agreement with (a
partner). Its operator tells it which those are, and the keys their cells are certified with, each time it attaches. It
still attaches to its own network's core, through the partner's cell and core, and keeps its address. It stays on its
own network until it loses it, and goes back to it once its own network's best cell has been stronger than the one it
roams on for a few seconds. Moving between networks, it attaches again rather than being handed over. It can also be
told to use one network only: any network, even one it doesn't know has an agreement with its own, which it tries.

Some partners are as good as home (like LTE's equivalent networks): for national roaming between two operators, or where
the phone's own network has a core but no cells (a full MVNO). The phone treats their cells as its own network's: it
uses them as readily, isn't roaming there, and stays on them until it loses them. It can activate through a partner's
cell too, where its network has none: it tries the strongest cell of each network around until one passes it on.

Agreements change, and the phone only hears of them when it attaches. So where it has heard neither its own network nor
a partner's for a few seconds, it tries the cells of other networks too, strongest first, as real phones do. (Not
straight away: every cell around should be heard first, and the phone can only check its own network's cells once it
has heard from them since it was activated or started.) The other network's core passes the attach on to its own if
they have an agreement, and turns it away if not. A network which turned it away is left alone for a minute. Its cells
can't be checked until the phone learns its key, but nothing depends on them: the handshake is with the phone's own
operator, end to end.

A cell may serve several networks (operators may share one), naming each in its system information. The phone
checks each network's part with that network's key, and chooses a cell and one of its networks together: the best
network first, then the strongest cell. It says which network it chose when it attaches, and the cell takes it to that
network's core. A shared cell may be a handover target for any network it serves, and a roaming phone whose cell also
serves its own network goes home through that same cell.

Radio frames get lost, and cells and cores restart and forget their phones. So the phone checks its cell still knows
it, every few seconds when nothing else has come from it, and attaches again if it doesn't. It says it has arrived at a
new cell until the cell answers. And it sends each message until the network says it has it.

Anyone in range can send a frame which says it's from the phone's cell. Whatever can't be checked (a refusal, or a
handshake message which doesn't read) never stops the phone waiting for the real answer.

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
-- How often to ask a quiet cell whether it still knows us, in seconds, and how many times in a row it may not answer.
local CHECK_INTERVAL, CHECK_MISSES = 5, 4
-- The same, once there's reason to think it has forgotten us.
local FAST_INTERVAL, FAST_MISSES = 1, 3
-- How many times to tell a new cell we've arrived, a second apart, before giving up on it.
local CONFIRM_TRIES = 5
-- How long a refusal has to be followed by the real answer, in seconds: anyone can send a refusal.
local REJECT_GRACE = 1
-- Messages: how many may wait to be sent, how often they're sent again, in seconds, how many times, and how many
-- received messages to remember, to tell when one comes twice.
local MAX_OUTBOX, MESSAGE_RETRY, MESSAGE_TRIES, MAX_SEEN = 20, 5, 12, 128
-- How many roaming partners a phone takes from its operator.
local MAX_PARTNERS = 16
-- How long a roaming phone's own network must be stronger than the network it's on (by HYSTERESIS), in seconds, before
-- it goes back.
local HOME_TIME = 5
-- How long to leave a network alone after it turned the phone away (or didn't answer), in seconds.
local FORBIDDEN_TIME = 60
-- How long a phone must search without finding a cell of its own network or a partner's before it tries other
-- networks, in seconds: long enough to hear every cell around.
local SCAN_TIME = 3
-- How long to leave a cell an attach through it got no answer from, in seconds: at first, then twice as long each time it
-- happens again, up to the most.
local FAILED_TIME, MAX_FAILED_TIME = 30, 300

local Phone = {}
Phone.__index = Phone

--[[- Start a phone.

@tparam {
    stack = table, crypto = table, interface = string, epoch = function():number,
    sim = { public = string, exchange = function(public:string):string },
    operator? = { network = string, key = string, signing = string },
    partners? = { [string] = string }, equivalent? = { [string] = boolean }, selection? = string,
    on_partners? = function(partners:table, equivalent:table),
    on_change? = function(phone:table),
    on_message? = function(from:string, text:string),
    on_sent? = function(id:number, ok:boolean, reason:string|nil),
    on_activated? = function(info:table), relay? = function():boolean,
} options The stack; the `crypto` API; the interface cells are heard on; the time, as `os.epoch("utc")` gives; the
phone's SIM key; its operator's network name, X25519 key and Ed25519 signing key, if it has been activated; the
networks it may roam on, by name, with their signing keys, as its operator last gave them, and which of those it
treats as home; the only network it should use, if it has been told to use one; what to call when its operator gives it
other networks to roam on (or treat as home); what to call
when its state changes; what to call with each message; what to call when the network has taken a message we sent (or
refused it, or it couldn't be sent); what to call when it's activated, with the operator's keys and its subscription,
to save them; and whether this computer is a relay, whose cell's backhaul is this phone (so it avoids cells already as
many relays from the core as a chain may have).
@treturn table The phone.
]]
local function new(options)
    local stack = options.stack
    local self = setmetatable({
        stack = stack, crypto = options.crypto, interface = options.interface, epoch = options.epoch,
        sim = options.sim, operator = options.operator, on_change = options.on_change or function() end,
        on_message = options.on_message or function() end, on_activated = options.on_activated or function() end,
        on_sent = options.on_sent or function() end, on_partners = options.on_partners or function() end,
        partners = options.partners or {}, equivalent = options.equivalent or {}, selection = options.selection,
        relay = options.relay or function() return false end,
        cells = {}, heard = {}, events = {}, forbidden = {}, failed = {},
        state = options.operator and "searching" or "inactive", retry = 2,
        seen_messages = {}, seen_order = {}, outbox = {}, next_message = math.random(0, 0x7FFFFFFF),
        unanswered = 0, last_heard = 0, last_check = 0, searching_since = stack.clock(),
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
    local old = self.state
    if old == state then return end
    self.state = state
    -- An attach which didn't work is part of the same search.
    if state == "searching" and old ~= "attaching" and old ~= "rejected" then self.searching_since = self.stack.clock() end
    if state == "attached" then
        self:event("attached", { cell = self.cell, roaming = self:roaming() and self.via or nil })
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

-- Remember a cell we heard, of any network (or of several: a cell may be shared), and average its signal. Whether its
-- system information checked out is only known for networks whose keys we have.
function Phone:hear(src, message, signal, networks)
    local now = self.stack.clock()
    local cell = self.heard[src]
    if not cell then
        -- Anyone can send system information, as from as many cells as they like. When there's no room, the weakest
        -- cell makes way for a stronger one, so the cells remembered are the ones most worth using.
        local count, weakest, weakest_signal = 0, nil, nil
        for id, other in pairs(self.heard) do
            if now - other.heard > FORGET then
                self.heard[id] = nil
            else
                count = count + 1
                local strength = now - other.heard > SILENCE and -math.huge or other.signal
                if id ~= self.cell and (not weakest_signal or strength < weakest_signal) then weakest, weakest_signal = id, strength end
            end
        end
        if count >= MAX_HEARD then
            if not weakest or (type(signal) == "number" and signal or -50) <= weakest_signal then return end
            self.heard[weakest] = nil
        end
        cell = { samples = {}, networks = {} }
        self.heard[src] = cell
    end
    table.insert(cell.samples, type(signal) == "number" and signal or -50)
    if #cell.samples > SAMPLES then table.remove(cell.samples, 1) end
    local total = 0
    for _, sample in ipairs(cell.samples) do total = total + sample end
    cell.signal, cell.heard = total / #cell.samples, now
    cell.area = type(message.area) == "number" and message.area or nil
    cell.load = type(message.load) == "number" and message.load or nil
    -- Each network the cell names, now. One it stops naming (it lost that network's core) goes quiet, and is soon
    -- forgotten.
    for name, entry in pairs(cell.networks) do
        if now - entry.heard > SILENCE then cell.networks[name] = nil end
    end
    for _, entry in ipairs(networks) do
        cell.networks[entry.network] = { heard = now, verified = entry.verified, path = entry.path }
    end
end

function Phone:to_cell(cell, message)
    self.stack:send_frame(self.interface, cell, common.FRAME, message)
end

-- Whether a cell's backhaul (to one network's core) goes through this computer: it's a relay, and this phone is its
-- way to the core. Using it would be a loop.
function Phone:behind_us(path)
    for _, relay in ipairs(path or {}) do
        if relay == self.stack.id then return true end
    end
    return false
end

-- Whether a cell's path to a network's core is fit for us: not through us, nor too long for a relay's phone.
function Phone:path_ok(path)
    return not self:behind_us(path) and not (self.relay() and #(path or {}) >= common.MAX_PATH)
end

-- Whether we may use a cell through one of its networks: we can hear it serve that network, it isn't behind us, and
-- it's a network we may use.
function Phone:usable(id, cell, network, now)
    local entry = cell.networks[network]
    return entry ~= nil and not entry.unverified and now - entry.heard <= SILENCE and cell.signal >= NO_SERVICE
        and self:path_ok(entry.path)
        and (self.selection == nil or network == self.selection)
        and (network == self.operator.network or self.partners[network] ~= nil)
        -- A relay's phone and cell share its computer.
        and id ~= self.stack.id
end

-- Whether an attach through a cell got no answer lately: it may not hear us.
function Phone:failed_lately(id, now)
    local failed = self.failed[id]
    return failed ~= nil and now - failed.time < math.min(FAILED_TIME * 2 ^ (failed.count - 1), MAX_FAILED_TIME)
end

-- Whether a network is ours, or one we treat as ours.
function Phone:home_class(network)
    return network == self.operator.network or self.equivalent[network] == true
end

--[[ The best cell we can hear, its signal, and the network to use it through.

Left to choose, that's the strongest of our own network (or of one we treat as home), and only without one, the
strongest of a partner's. A shared cell may offer several: our own network comes before one we treat as home, and
otherwise the one first by name. `network` limits the choice to one network (the one we're on, when looking for a
cell to be handed over to), and `fresh` to cells attaches through which haven't gone unanswered lately.
]]
function Phone:best_cell(except, network, fresh)
    local best, best_signal, best_network, best_home
    local now = self.stack.clock()
    for id, cell in pairs(self.cells) do
        if id ~= except and not (fresh and self:failed_lately(id, now)) then
            for name in pairs(cell.networks) do
                if (network == nil or name == network) and self:usable(id, cell, name, now) then
                    local home = self:home_class(name)
                    local better
                    if not best or home ~= best_home then
                        better = not best or home
                    elseif cell.signal ~= best_signal then
                        better = cell.signal > best_signal
                    elseif (name == self.operator.network) ~= (best_network == self.operator.network) then
                        better = name == self.operator.network
                    else
                        better = name < best_network or (name == best_network and id < best)
                    end
                    if better then best, best_signal, best_network, best_home = id, cell.signal, name, home end
                end
            end
        end
    end
    return best, best_signal, best_network
end

--[[ The strongest cell of a network we don't know to carry us (neither ours nor a partner's), to try when there's
nothing else, once we've searched long enough to have heard every cell around. Networks which turned us away lately are
left alone. Told to use such a network, we try it at once, and keep trying, as we were told to.
]]
function Phone:other_cell()
    local now = self.stack.clock()
    local chosen = self.selection
    if chosen and (chosen == self.operator.network or self.partners[chosen]) then return nil end
    if not chosen and now - self.searching_since < SCAN_TIME then return nil end
    local best, best_signal, best_network
    for id, cell in pairs(self.heard) do
        if now - cell.heard <= SILENCE and cell.signal >= NO_SERVICE and id ~= self.stack.id then
            for name, entry in pairs(cell.networks) do
                local refused = self.forbidden[name]
                if name ~= self.operator.network and not self.partners[name] and (chosen == nil or name == chosen)
                    and (chosen ~= nil or not (refused and now - refused < FORBIDDEN_TIME))
                    and now - entry.heard <= SILENCE and self:path_ok(entry.path)
                    and (not best or cell.signal > best_signal or (cell.signal == best_signal and name < best_network)) then
                    best, best_signal, best_network = id, cell.signal, name
                end
            end
        end
    end
    return best, best_network
end

-- Average a cell's last few signals, so one strong or weak broadcast doesn't move us.
local function sample(cell, message, signal, now)
    table.insert(cell.samples, type(signal) == "number" and signal or -50)
    if #cell.samples > SAMPLES then table.remove(cell.samples, 1) end
    local total = 0
    for _, value in ipairs(cell.samples) do total = total + value end
    cell.signal, cell.heard, cell.area = total / #cell.samples, now, message.area
end

--- Whether the network we're attached through is another network, which we don't treat as home.
--
-- @treturn boolean Whether we're roaming.
function Phone:roaming()
    return self.state == "attached" and self.operator ~= nil and self.via ~= nil and not self:home_class(self.via)
end

--[[- Use one network only, or go back to choosing.

@tparam[opt] string network The network's name, or `nil` to choose: our own when we can hear it, else a partner's. It
may be a network we don't know has an agreement with ours: we try it.
]]
function Phone:select(network)
    if self.selection == network then return end
    self.selection = network
    self.home_since = nil
    if not self.operator then return end
    -- If we're on a network we may no longer use, or attaching to one, look again.
    if (self.state == "attached" or self.state == "attaching") and network and self.via ~= network then
        if self.state == "attached" then self:event("lost", { cell = self.cell }) end
        self.handshake, self.attempt = nil, nil
        self:set_state("searching")
        self:attach()
    elseif self.state == "searching" or self.state == "rejected" then
        self:set_state("searching")
        self:attach()
    end
end

function Phone:radio(src, message, signal)
    if type(message) ~= "table" then return end
    local op = message.op

    if op == "sib" then
        -- Names are shown to people, so only take ones a network could have.
        local entries = common.sib_networks(message, src)
        if not entries then return end
        -- Cells of other networks (or of any network, before we're activated) can't be checked, but we can see what's
        -- around. A cell which claims to serve ours, or a partner's, but doesn't, may be a fake.
        local now, epoch, networks = self.stack.clock(), self.epoch(), {}
        for i, entry in ipairs(entries) do
            local name = entry.network
            local signing = self.operator and (name == self.operator.network and self.operator.signing or self.partners[name])
            local verified
            if signing then
                verified = common.check_sib(self.crypto, message, entry, {
                    network = name, signing = signing, now = epoch, sender = src,
                }) == true
            end
            networks[i] = { network = name, verified = verified, path = entry.path }
        end
        self:hear(src, message, signal, networks)

        -- The networks we may use the cell through: those whose part checked out, and one we're trying (or using)
        -- before we can check it.
        local cell, used = self.cells[src], false
        for _, network in ipairs(networks) do
            local known = cell and cell.networks[network.network]
            if network.verified or (network.verified == nil and known and known.unverified) then
                if not cell then
                    cell = { samples = {}, networks = {} }
                    self.cells[src] = cell
                end
                cell.networks[network.network] = { heard = now, path = network.path, unverified = not network.verified or nil }
                used = true
            end
        end
        if used then sample(cell, message, signal, now) end
        if self.state == "searching" then self:attach() end
        return
    end

    -- Everything else comes from the cell we're attaching through, or attached to: or says it does. Until a message
    -- has been opened with a key only our cell has, it may be from anyone, and mustn't spoil anything.
    if src ~= self.cell then return end
    if op == "attach_reply" and self.state == "attaching" and self.handshake then
        local handshake = self.handshake:clone()
        local payload = handshake:read(message.handshake)
        local info = payload and codec.decode(payload)
        if type(info) ~= "table" then return end
        self.subscriber = { id = info.id, number = info.number }
        -- Other networks' phones reach ours at "+", our network's number prefix, and our number.
        if type(info.numbers) == "string" and #info.numbers <= 8 and info.numbers:find("^%d+$") and type(info.number) == "string" then
            self.subscriber.full = "+" .. info.numbers .. info.number
        end
        self:set_partners(info.partners)
        local send = handshake:split()
        self.secret = handshake.ck
        self.handshake = nil
        self:to_cell(self.cell, { op = "attach_complete", via = self.via, data = send:encrypt(codec.encode({ complete = true })) })
    elseif op == "accept" and self.state == "attaching" and self.secret then
        local sealer = common.new_sealer(self.crypto, common.cell_key(self.crypto, self.secret, self.cell), common.UPLINK, common.DOWNLINK)
        local value = sealer:open(message.sealed)
        if type(value) ~= "table" or type(value.address) ~= "number" or value.address % 1 ~= 0
            or value.address < 1 or value.address >= 0xFFFFFFFF then
            return
        end
        self.sealer = sealer
        self:set_address(value.address)
        self.retry, self.failed[self.cell] = 2, nil
        self:heard_from_cell()
        self.confirming = nil
        self:set_state("attached")
        self:send_waiting()
    elseif op == "data" and self.state == "attached" then
        local value = self.sealer:open(message.sealed)
        if type(value) ~= "table" then return end
        self:heard_from_cell()
        local packet = type(value.p) == "string" and codec.decode(value.p)
        if type(packet) == "table" then
            self.stack:inject("cell", packet)
        elseif type(value.sms) == "table" and common.is_id(value.sms.id) and type(value.sms.from) == "string"
            and type(value.sms.text) == "string" then
            -- Say we have it, even if we've seen it before (our last acknowledgement may have been lost).
            local id = value.sms.id
            self:to_cell(self.cell, { op = "data", sealed = self.sealer:seal({ sms_ack = id }) })
            if not self.seen_messages[id] then
                self.seen_messages[id] = true
                self.seen_order[#self.seen_order + 1] = id
                if #self.seen_order > MAX_SEEN then self.seen_messages[table.remove(self.seen_order, 1)] = nil end
                self.on_message(value.sms.from:sub(1, 32), value.sms.text:sub(1, 1000))
            end
        elseif type(value.sms_sent) == "table" then
            -- The network has one of our messages (or won't take it).
            local reply = value.sms_sent
            for i, waiting in ipairs(self.outbox) do
                if waiting.id == reply.id then
                    table.remove(self.outbox, i)
                    local ok = reply.ok == true
                    self.on_sent(waiting.id, ok, not ok and (type(reply.error) == "string" and reply.error:sub(1, 100) or "Not sent") or nil)
                    break
                end
            end
        end
    elseif op == "activate_reply" and self.state == "activating" and self.handshake then
        local handshake = self.handshake:clone()
        if not handshake:read(message.handshake) then return end
        local finish = handshake:write(codec.encode({ v = 1 }))
        if not finish then return end
        self.handshake, self.finished = handshake, true
        self:to_cell(self.cell, { op = "activate_finish", via = self.activation.via, handshake = finish })
    elseif op == "activate_accept" and self.state == "activating" and self.handshake and self.finished then
        local _, receive = self.handshake:split()
        local plaintext = type(message.data) == "string" and receive:decrypt(message.data)
        local info = plaintext and codec.decode(plaintext)
        -- Only someone who knew the code could have sent something which decrypts, so these keys are the operator's.
        if type(info) ~= "table" then return end
        if type(info.network) ~= "string" or type(info.key) ~= "string" or #info.key ~= 32
            or type(info.signing) ~= "string" or #info.signing ~= 32 then
            return self:activation_failed("The network's answer was garbled")
        end
        self.handshake, self.finished = nil, nil
        self.operator = { network = info.network, key = info.key, signing = info.signing }
        self.subscriber = { id = info.id, number = info.number }
        self:event("activated", { network = info.network })
        self.on_activated(info)
        self.activation = nil
        -- Which networks we may use (or treat as home), so we can use them at once: a network may have no cells.
        self:set_partners(info.partners)
        self.retry = 2
        self:set_state("searching")
        self:attach()
    elseif op == "handover" and self.state == "attached" then
        local value = self.sealer:open(message.sealed)
        local target = type(value) == "table" and value.target
        -- Within the network we're on, to a cell which serves it.
        if not common.is_id(target) or not self.cells[target] or target == self.cell
            or not self.cells[target].networks[self.via] then
            return
        end
        -- Move to the new cell, with the key we share with it, and say we're there. Our address stays the same.
        self:event("handover", { from = self.cell, to = target })
        self.cell, self.candidate = target, nil
        self.sealer = common.new_sealer(self.crypto, common.cell_key(self.crypto, self.secret, target), common.UPLINK, common.DOWNLINK)
        -- The new cell may not hear us the first time, so we say so until it answers.
        self:heard_from_cell()
        self.confirming = { tries = 0, last = self.stack.clock() }
        self:to_cell(target, { op = "confirm", sealed = self.sealer:seal({ confirm = true }) })
        self.on_change(self)
    elseif op == "reject" and self.state == "activating" and self.handshake and not self.finished and not self.refusal then
        -- Another network's cell, whose core doesn't carry our network's phones: try the next. Anyone can send this,
        -- so the real answer still counts if it comes soon.
        self.refusal = type(message.reason) == "string" and message.reason:sub(1, 100) or "Rejected"
        local attempt = self.attempt
        self.stack:schedule(REJECT_GRACE, function()
            if self.attempt == attempt and self.state == "activating" and not self.finished then
                self.activation.refusal = self.refusal
                self:try_activation()
            end
        end)
    elseif op == "reject" and self.state == "attaching" and not self.secret and not self.refusal then
        -- Anyone can send this, so the real answer still counts if it comes soon.
        self.refusal = type(message.reason) == "string" and message.reason:sub(1, 100) or "Rejected"
        local attempt = self.attempt
        self.stack:schedule(REJECT_GRACE, function()
            if self.attempt == attempt and self.state == "attaching" and not self.secret then
                self.rejected = self.refusal
                self:give_up()
            end
        end)
    elseif op == "unknown" and self.state == "attached" and not self.fast_check then
        -- The cell says it doesn't know us (or someone says so for it): find out.
        self.fast_check, self.unanswered, self.last_check = true, 0, -math.huge
    end
end

-- Our operator says which other networks we may use (and which we treat as home), each time we attach.
function Phone:set_partners(list)
    if type(list) ~= "table" then return end
    local partners, equivalent, count, changed = {}, {}, 0, false
    for _, partner in ipairs(list) do
        if count < MAX_PARTNERS and type(partner) == "table" and common.is_network(partner.network)
            and partner.network ~= self.operator.network and type(partner.signing) == "string" and #partner.signing == 32
            and not partners[partner.network] then
            partners[partner.network] = partner.signing
            if partner.home == true then equivalent[partner.network] = true end
            count = count + 1
            if self.partners[partner.network] ~= partner.signing or self.equivalent[partner.network] ~= equivalent[partner.network] then
                changed = true
            end
        end
    end
    for network in pairs(self.partners) do
        if not partners[network] then changed = true end
    end
    if not changed then return end
    self.partners, self.equivalent = partners, equivalent
    -- Cells of networks which are no longer partners can't be used. (Ones of new partners are heard within a second.)
    -- A cell we're trying before we can check it stays: our operator has just answered through it.
    for id, cell in pairs(self.cells) do
        for name, entry in pairs(cell.networks) do
            if name ~= self.operator.network and not partners[name] and not entry.unverified then cell.networks[name] = nil end
        end
        if next(cell.networks) == nil then self.cells[id] = nil end
    end
    for network in pairs(partners) do self.forbidden[network] = nil end
    self.on_partners(partners, equivalent)
end

-- Something came from our cell which only it could have sent: it knows us.
function Phone:heard_from_cell()
    self.last_heard, self.unanswered, self.fast_check = self.stack.clock(), 0, false
    self.confirming = nil
end

--[[- Activate with a code from the network's administrator, through the strongest cell of the network. Where the
network has no cells in range (or none at all, as a full MVNO), it may be reached through another network's cell, if
that network carries its phones: the phone tries the strongest cell of each network around, until one passes it on.

@tparam string network The network's name.
@tparam string code The activation code.
@treturn[1] true If activation started. The phone's state becomes `"searching"` once it's done.
@treturn[2] nil If it couldn't start.
@treturn[2] string Why not.
]]
function Phone:activate(network, code)
    local tag, secret = common.parse_code(code)
    if not tag then return nil, "That isn't an activation code" end
    -- The strongest cell of each network.
    local now, strongest = self.stack.clock(), {}
    for id, heard in pairs(self.heard) do
        for name, entry in pairs(heard.networks) do
            local other = strongest[name]
            if now - entry.heard <= SILENCE and (not other or heard.signal > other.signal) then
                strongest[name] = { id = id, signal = heard.signal, network = name }
            end
        end
    end
    local candidates = {}
    if strongest[network] then
        candidates[1] = strongest[network]
    else
        for _, candidate in pairs(strongest) do candidates[#candidates + 1] = candidate end
        table.sort(candidates, function(a, b)
            if a.signal ~= b.signal then return a.signal > b.signal end
            return a.network < b.network
        end)
    end
    if not candidates[1] then return nil, "No cell of " .. network .. " in range" end

    self.activation = {
        network = network, tag = tag, key = common.activation_key(self.crypto, secret), candidates = candidates, next = 1,
    }
    self.activation_error = nil
    if not self:try_activation() then
        self.activation = nil
        return nil, "The SIM can't be used"
    end
    return true
end

-- Ask the next cell to pass our activation on, or give up if none is left. Returns false if the SIM can't be used.
function Phone:try_activation()
    local activation = self.activation
    local candidate = activation.candidates[activation.next]
    if not candidate then
        self:activation_failed(activation.refusal or "No answer: check the code")
        return true
    end
    activation.next = activation.next + 1
    local handshake = noise.new {
        crypto = self.crypto, pattern = "XXpsk3", initiator = true, prologue = ACTIVATE_PROLOGUE .. activation.network,
        static = self.sim, psk = activation.key,
    }
    local message = handshake:write("")
    if not message then return false end
    self.cell, self.handshake, self.finished, self.refusal = candidate.id, handshake, nil, nil
    activation.via = candidate.network
    self:set_state("activating")
    self:to_cell(candidate.id, {
        op = "activate", network = activation.network, via = candidate.network, tag = activation.tag, handshake = message,
    })

    local attempt = {}
    self.attempt = attempt
    self.stack:schedule(ATTACH_TIMEOUT * 2, function()
        if self.attempt == attempt and self.state == "activating" then self:activation_failed("No answer: check the code") end
    end)
    return true
end

function Phone:activation_failed(reason)
    self.handshake, self.attempt, self.activation_error, self.finished = nil, nil, reason, nil
    self.activation = nil
    self:event("activation_failed", { reason = reason })
    self:set_state("inactive")
end

--[[- Send a message to another phone, by its number. It's sent until the network says it has it, which then keeps
it until that phone is reachable.

@tparam string to The number.
@tparam string text The message, up to 1000 characters.
@treturn[1] true If it's being sent. `on_sent` is called once the network has it, or if it won't take it.
@treturn[1] number The message's ID, which `on_sent` is called with.
@treturn[2] nil If it can't be sent.
@treturn[2] string Why not.
]]
function Phone:send_message(to, text)
    if self.state ~= "attached" then return nil, "No service" end
    if type(to) ~= "string" or #to < 1 or #to > 32 then return nil, "Numbers are up to 32 characters" end
    if type(text) ~= "string" or #text > 1000 then return nil, "Messages can be at most 1000 characters" end
    if #self.outbox >= MAX_OUTBOX then return nil, "Too many messages are waiting to be sent" end

    self.next_message = self.next_message + 1
    local waiting = { id = self.next_message, to = to, text = text, tries = 0 }
    self.outbox[#self.outbox + 1] = waiting
    self:send_one(waiting)
    return true, waiting.id
end

function Phone:send_one(waiting)
    waiting.tries, waiting.sent = waiting.tries + 1, self.stack.clock()
    self:to_cell(self.cell, { op = "data", sealed = self.sealer:seal({ sms = { id = waiting.id, to = waiting.to, text = waiting.text } }) })
end

-- Send the messages the network hasn't said it has, again: all of them once we have service back, or those which
-- have waited a while. After enough tries, give up on one.
function Phone:send_waiting(only_old)
    local now = self.stack.clock()
    for i = #self.outbox, 1, -1 do
        local waiting = self.outbox[i]
        if not only_old or now - waiting.sent >= MESSAGE_RETRY then
            if waiting.tries >= MESSAGE_TRIES then
                table.remove(self.outbox, i)
                self.on_sent(waiting.id, false, "The network didn't answer")
            end
        end
    end
    for _, waiting in ipairs(self.outbox) do
        if not only_old or now - waiting.sent >= MESSAGE_RETRY then self:send_one(waiting) end
    end
end

-- Start attaching through the best cell: of our own network, else a partner's, else one of another network, which
-- may have an agreement with ours we don't know of yet. Cells which didn't answer lately come last.
function Phone:attach()
    local best, _, via = self:best_cell(nil, nil, true)
    if not best then
        best, via = self:other_cell()
        if best then
            -- We can't check its cell's part for that network until (and unless) our operator gives us the network's
            -- key, so go by what we heard.
            local heard = self.heard[best]
            local cell = self.cells[best]
            if not cell then
                cell = {
                    samples = { table.unpack(heard.samples) }, signal = heard.signal, heard = heard.heard, area = heard.area,
                    networks = {},
                }
                self.cells[best] = cell
            end
            local entry = heard.networks[via]
            cell.networks[via] = { heard = entry.heard, path = entry.path, unverified = true }
        else
            best, _, via = self:best_cell()
            if not best then return end
        end
    end
    self.cell, self.via, self.secret, self.rejected, self.refusal, self.home_since = best, via, nil, nil, nil, nil
    self.handshake = noise.new {
        crypto = self.crypto, pattern = "IK", initiator = true, prologue = PROLOGUE .. self.operator.network,
        static = self.sim, remote_static = self.operator.key,
    }
    local message = self.handshake:write(codec.encode({ v = 1 }))
    if not message then return self:give_up() end
    self:set_state("attaching")
    self:to_cell(best, { op = "attach", network = self.operator.network, via = via, handshake = message })

    local attempt = {}
    self.attempt = attempt
    self.stack:schedule(ATTACH_TIMEOUT, function()
        if self.attempt == attempt and self.state == "attaching" then
            -- A refusal which nothing else followed was the answer. Otherwise there was none: the cell may not hear us.
            if not self.secret then self.rejected = self.refusal end
            self:give_up(not self.rejected)
        end
    end)
end

-- Attaching didn't work: try again later, less often each time. A network we tried without knowing whether it would
-- carry us is left alone for a while, so we try the others (or it again, once its agreement may have changed). A cell
-- which didn't answer is left alone for a while too, while there are others.
function Phone:give_up(unanswered)
    self.handshake, self.attempt = nil, nil
    local now = self.stack.clock()
    local cell = self.cells[self.cell]
    local entry = cell and cell.networks[self.via]
    if entry and entry.unverified then
        self.forbidden[self.via] = now
        cell.networks[self.via] = nil
        if next(cell.networks) == nil then self.cells[self.cell] = nil end
    elseif cell and unanswered then
        for id, failed in pairs(self.failed) do
            if now - failed.time >= MAX_FAILED_TIME then self.failed[id] = nil end
        end
        local failed = self.failed[self.cell] or { count = 0 }
        failed.count, failed.time = failed.count + 1, now
        self.failed[self.cell] = failed
    end
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
    local entry = serving and serving.networks[self.via]
    if not entry or now - entry.heard > SILENCE or serving.signal < NO_SERVICE then
        -- Our cell has gone (or stopped serving our network): attach again through another, keeping our address.
        self:event("lost", { cell = self.cell })
        self:set_state("searching")
        if serving then
            serving.networks[self.via] = nil
            if next(serving.networks) == nil then self.cells[self.cell] = nil end
        end
        return self:attach()
    end

    -- A cell we've moved to may not have heard that we arrived: say so again, until it answers.
    local confirming = self.confirming
    if confirming and now - confirming.last >= 1 then
        if confirming.tries >= CONFIRM_TRIES then return self:forgotten() end
        confirming.tries, confirming.last = confirming.tries + 1, now
        self:to_cell(self.cell, { op = "confirm", sealed = self.sealer:seal({ confirm = true }) })
    end

    -- The cell may have forgotten us without going quiet (it restarted, or the core did). When nothing has come from
    -- it for a while, ask. If it doesn't answer several times running, attach again.
    local interval, misses = CHECK_INTERVAL, CHECK_MISSES
    if self.fast_check then interval, misses = FAST_INTERVAL, FAST_MISSES end
    if not confirming and now - self.last_heard >= interval and now - self.last_check >= interval then
        if self.unanswered >= misses then return self:forgotten() end
        self.unanswered, self.last_check = self.unanswered + 1, now
        self:to_cell(self.cell, { op = "data", sealed = self.sealer:seal({ ping = self.unanswered }) })
    end

    self:send_waiting(true)

    -- Roaming, and left to choose: go back to our own network (or one we treat as home) once its best cell has been
    -- stronger than ours for a while, or at once if ours serves it too (it's shared). We attach again, through its
    -- cell, rather than being handed over, and keep our address. On a network we treat as home, we stay until we lose
    -- it, as on our own.
    if not self:home_class(self.via) and not self.selection and not confirming then
        local home, home_signal, home_network = self:best_cell(nil, nil, true)
        if home and self:home_class(home_network) and (home_signal >= serving.signal + HYSTERESIS or home == self.cell) then
            self.home_since = self.home_since or now
            if now - self.home_since >= HOME_TIME then
                self:event("home", { from = self.cell })
                self:set_state("searching")
                return self:attach()
            end
        else
            self.home_since = nil
        end
    end

    -- Handovers stay within the network we're on.
    local best, best_signal = self:best_cell(self.cell, self.via)
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

-- Our cell is there, but doesn't answer as a cell which knows us would: attach again, to it or another, keeping our
-- address.
function Phone:forgotten()
    self:event("lost", { cell = self.cell })
    self.confirming, self.fast_check, self.unanswered = nil, false, 0
    self:set_state("searching")
    return self:attach()
end

--- Describe the phone.
--
-- @treturn table Its state, cell, address and subscriber; the cells it may use which it hears (`cells`); every cell it
-- has heard lately, of any network (`heard`); the networks around; what has happened lately (`events`); whether it's
-- roaming; the network it has been told to use (`selection`); the networks it may roam on (`partners`); and which of
-- those it treats as home (`equivalent`).
function Phone:info()
    local now = self.stack.clock()
    local cells = {}
    for id, cell in pairs(self.cells) do
        for name in pairs(cell.networks) do
            cells[#cells + 1] = { id = id, signal = cell.signal, area = cell.area, network = name }
        end
    end
    table.sort(cells, function(a, b)
        if a.signal ~= b.signal then return a.signal > b.signal end
        if a.id ~= b.id then return a.id < b.id end
        return a.network < b.network
    end)

    -- Each cell we heard, once for each network it serves.
    local heard, names, networks = {}, {}, {}
    for id, cell in pairs(self.heard) do
        if now - cell.heard <= FORGET then
            for name, entry in pairs(cell.networks) do
                local age = now - entry.heard
                heard[#heard + 1] = {
                    id = id, network = name, signal = cell.signal, area = cell.area, load = cell.load, age = age,
                    verified = entry.verified, serving = id == self.cell and name == self.via and self.state == "attached",
                }
                if age <= SILENCE and not names[name] then
                    names[name] = true
                    networks[#networks + 1] = name
                end
            end
        end
    end
    table.sort(heard, function(a, b)
        if (a.age <= SILENCE) ~= (b.age <= SILENCE) then return a.age <= SILENCE end
        if a.signal ~= b.signal then return a.signal > b.signal end
        if a.id ~= b.id then return a.id < b.id end
        return a.network < b.network
    end)
    table.sort(networks)

    local partners, equivalent = {}, {}
    for network in pairs(self.partners) do partners[network] = true end
    for network in pairs(self.equivalent) do equivalent[network] = true end

    local events = {}
    for i, event in ipairs(self.events) do
        events[i] = {}
        for k, v in pairs(event) do events[i][k] = v end
    end

    return {
        state = self.state, cell = self.cell, address = self.address, subscriber = self.subscriber,
        rejected = self.rejected, activation_error = self.activation_error, cells = cells, networks = networks,
        heard = heard, events = events, network = self.operator and self.operator.network,
        roaming = self:roaming(), selection = self.selection, partners = partners, equivalent = equivalent,
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
