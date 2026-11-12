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
roams on for a few seconds. Moving between networks, it attaches again rather than being handed over. Having just
started (or been activated), it listens for a few seconds before it uses a partner's cell, as it may not have heard
its own network's yet, and would stay on the partner's. It can also be
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
local recent = require "cc.internal.net.recent"
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
-- How many networks which turned us away, and cells which didn't answer, to remember. Anyone can make them up.
local MAX_FORBIDDEN, MAX_FAILED = 64, 64
-- How long a phone must search without finding a cell of its own network or a partner's before it tries other
-- networks, in seconds: long enough to hear every cell around.
local SCAN_TIME = 3
-- How long to leave a cell an attach through it got no answer from, in seconds: at first, then twice as long each time it
-- happens again, up to the most.
local FAILED_TIME, MAX_FAILED_TIME = 30, 300

-- What a network is to us, best first: our own (or one we treat as home), a partner, or one we don't know to carry us.
-- Cells an attach through which got no answer lately come after all of those, whatever their network.
local HOME, PARTNER, OTHER, FAILED = 1, 2, 3, 4

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
        cells = {}, heard = {}, events = {}, certificates = common.new_certificates(),
        forbidden = recent.new(MAX_FORBIDDEN, FORBIDDEN_TIME, stack.clock),
        failed = recent.new(MAX_FAILED, MAX_FAILED_TIME, stack.clock),
        state = options.operator and "searching" or "inactive", here = {},
        search = options.operator and { since = stack.clock(), retry = 2 } or nil,
        seen_messages = recent.new(MAX_SEEN), outbox = {}, next_message = math.random(0, 0x7FFFFFFF),
        started = stack.clock(),
    }, Phone)

    -- A cell may share this computer (a relay), so frames from phones come here too: they're ignored, as they don't
    -- come from our cell.
    self.frame_handler = stack:on_frame(common.FRAME, function(interface, src, body, signal)
        if interface.name == self.interface then self:radio(src, body, signal) end
    end, true)
    self.timer = stack:schedule(MEASURE_INTERVAL, function() self:measure() end)
    return self
end

--[[ Go into a state. The phone is in one at a time: `inactive`, `activating`, `searching`, `attaching`, `attached` or
`rejected`. Each has a table of what belongs to it (`here`), which is made on entering and dropped on leaving, so
nothing of an attach which is over can be read by the next; anything which waits (a timer) checks that the table is
still the phone's before it acts.

A search (`search`) lasts from losing service (or starting, or being activated) until the phone is attached again,
through every attach which doesn't work: it keeps when it started, how long to wait before trying again, and why the
last attach was refused, if it was.

The phone's `cell`, `via` (the network it uses the cell through) and `rejected` say what it's doing, for whoever looks:
nothing here decides by them.
]]
function Phone:enter(state, here)
    local old = self.state
    here = here or {}
    self.state, self.here = state, here
    if state == "searching" then
        self.search = self.search or { since = self.stack.clock(), retry = 2 }
    elseif state ~= "attaching" and state ~= "rejected" then
        self.search = nil
    end
    self.cell, self.via = here.cell, here.via
    self.rejected = self.search and self.search.rejected or nil
    if old == state then return end
    if state == "attached" then
        self:event("attached", { cell = here.cell, roaming = self:roaming() and here.via or nil })
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
    local failed = self.failed:get(id)
    return failed ~= nil and now - failed.time < math.min(FAILED_TIME * 2 ^ (failed.count - 1), MAX_FAILED_TIME)
end

-- Whether a network is ours, or one we treat as ours.
function Phone:home_class(network)
    return network == self.operator.network or self.equivalent[network] == true
end

--[[ Whether one way to use a cell is better than another: by what its network is to us (`tier`, which puts cells which
didn't answer lately last, and then `class`), then the stronger, then our own network before one we treat as home, and
otherwise the one first by network and cell.
]]
local function before(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    if a.class ~= b.class then return a.class < b.class end
    if a.signal ~= b.signal then return a.signal > b.signal end
    if a.own ~= b.own then return a.own end
    if a.network ~= b.network then return a.network < b.network end
    return a.id < b.id
end

--[[ The best way to use a cell we hear now, of those `fits` allows (any, without it): each cell, through each network
it serves which we may use. With `others`, through networks we don't know to carry us too (neither ours nor a
partner's), leaving out those which turned us away lately, unless we've been told to use one.

Each way is `{ id, network, signal, class, tier, own }`, and [`before`] says which is better. Attaching, going home and
being handed over each take the best of those they may use.
]]
function Phone:best(now, fits, others)
    local own = self.operator.network
    -- Each way in turn, in `choice`; the best so far is kept, and its table used for the next.
    local found, choice = nil, {}
    local function consider(id, network, signal, class, tier)
        choice.id, choice.network, choice.signal, choice.class, choice.tier = id, network, signal, class, tier
        choice.own = network == own
        if (not fits or fits(choice)) and (not found or before(choice, found)) then found, choice = choice, found or {} end
    end

    for id, cell in pairs(self.cells) do
        for name in pairs(cell.networks) do
            if self:usable(id, cell, name, now) then
                local class = self:home_class(name) and HOME or PARTNER
                consider(id, name, cell.signal, class, self:failed_lately(id, now) and FAILED or class)
            end
        end
    end

    -- Networks we don't know only come before cells which didn't answer lately, so they're only worth looking for when
    -- there's nothing better.
    if not others or (found and found.tier ~= FAILED) then return found end
    local chosen = self.selection
    for id, cell in pairs(self.heard) do
        if now - cell.heard <= SILENCE and cell.signal >= NO_SERVICE and id ~= self.stack.id then
            for name, entry in pairs(cell.networks) do
                if name ~= own and not self.partners[name] and (chosen == nil or name == chosen)
                    and (chosen ~= nil or not self.forbidden:get(name))
                    and now - entry.heard <= SILENCE and self:path_ok(entry.path) then
                    consider(id, name, cell.signal, OTHER, OTHER)
                end
            end
        end
    end
    return found
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
    if self.state == "attached" then self.here.home_since = nil end
    if not self.operator then return end
    -- If we're on a network we may no longer use, or attaching to one, look again.
    local state = self.state
    if (state == "attached" or state == "attaching") and network and self.via ~= network then
        if state == "attached" then self:event("lost", { cell = self.cell }) end
        self:enter("searching")
        self:attach()
    elseif state == "searching" or state == "rejected" then
        self:enter("searching")
        self:attach()
    end
end

-- What each state does with what comes from its cell (or says it does), by state, then by `op`. Each is given the
-- state's table.
local from_cell = { activating = {}, attaching = {}, attached = {} }

function Phone:radio(src, message, signal)
    if type(message) ~= "table" then return end
    local op = message.op

    if op == "sib" then
        -- A cell newer than we are may say things we can't read, and while there's nothing else, that's worth knowing.
        if common.is_newer(message.v) then self.newer_heard = self.stack.clock() end
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
                    network = name, signing = signing, now = epoch, sender = src, certificates = self.certificates,
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

    -- Everything else comes from the cell we're activating or attaching through, or attached to: or says it does. Until
    -- a message has been opened with a key only our cell has, it may be from anyone, and mustn't spoil anything.
    local handlers, here = from_cell[self.state], self.here
    local handle = handlers and handlers[op]
    if handle and src == here.cell then handle(self, here, message) end
end

function from_cell.attaching.attach_reply(self, here, message)
    if not here.handshake then return end
    local handshake = here.handshake:clone()
    local payload = handshake:read(message.handshake)
    local info = payload and codec.decode(payload)
    if type(info) ~= "table" then return end
    if common.is_newer(info.v) then self.newer_heard = self.stack.clock() end
    self.subscriber = { id = info.id, number = info.number }
    -- Other networks' phones reach ours at our network's number prefix followed by our number.
    if type(info.numbers) == "string" and #info.numbers <= 8 and info.numbers:find("^%d+$") and type(info.number) == "string" then
        self.subscriber.full = info.numbers .. info.number
    end
    self:set_partners(info.partners)
    local send = handshake:split()
    here.secret, here.handshake = handshake.ck, nil
    self:to_cell(here.cell, { op = "attach_complete", via = here.via, data = send:encrypt(codec.encode({ complete = true })) })
end

function from_cell.attaching.accept(self, here, message)
    if not here.secret then return end
    local sealer = common.new_sealer(self.crypto, common.cell_key(self.crypto, here.secret, here.cell), common.UPLINK, common.DOWNLINK)
    local value = sealer:open(message.sealed)
    if type(value) ~= "table" or type(value.address) ~= "number" or value.address % 1 ~= 0
        or value.address < 1 or value.address >= 0xFFFFFFFF then
        return
    end
    self:set_address(value.address)
    self.failed:remove(here.cell)
    -- What we keep while attached: the cell and the key we share with it; whether it still knows us (`last_heard`,
    -- `last_check`, `unanswered`, `fast_check`), and whether it knows we've arrived, after a handover (`confirming`);
    -- a cell to be handed over to (`candidate`); and how long our own network has been stronger (`home_since`).
    self:enter("attached", {
        cell = here.cell, via = here.via, secret = here.secret, sealer = sealer,
        last_heard = self.stack.clock(), last_check = 0, unanswered = 0, fast_check = false,
    })
    self:send_waiting()
end

function from_cell.attaching.reject(self, here, message)
    if here.secret or here.refusal then return end
    -- Anyone can send this, so the real answer still counts if it comes soon.
    here.refusal = type(message.reason) == "string" and message.reason:sub(1, 100) or "Rejected"
    self.stack:schedule(REJECT_GRACE, function()
        if self.here == here and not here.secret then self:give_up(here, here.refusal) end
    end)
end

function from_cell.attached.data(self, here, message)
    local value = here.sealer:open(message.sealed)
    if type(value) ~= "table" then return end
    self:heard_from_cell(here)
    local packet = type(value.p) == "string" and codec.decode(value.p)
    if type(packet) == "table" then
        self.stack:inject("cell", packet)
    elseif type(value.sms) == "table" and common.is_id(value.sms.id) and type(value.sms.from) == "string"
        and type(value.sms.text) == "string" then
        -- Say we have it, even if we've seen it before (our last acknowledgement may have been lost).
        local id = value.sms.id
        self:to_cell(here.cell, { op = "data", sealed = here.sealer:seal({ sms_ack = id }) })
        if not self.seen_messages:get(id) then
            self.seen_messages:add(id)
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
end

function from_cell.attached.handover(self, here, message)
    local value = here.sealer:open(message.sealed)
    local target = type(value) == "table" and value.target
    -- Within the network we're on, to a cell which serves it.
    if not common.is_id(target) or not self.cells[target] or target == here.cell
        or not self.cells[target].networks[here.via] then
        return
    end
    -- Move to the new cell, with the key we share with it, and say we're there. Our address stays the same.
    self:event("handover", { from = here.cell, to = target })
    here.cell, here.candidate, self.cell = target, nil, target
    here.sealer = common.new_sealer(self.crypto, common.cell_key(self.crypto, here.secret, target), common.UPLINK, common.DOWNLINK)
    -- The new cell may not hear us the first time, so we say so until it answers.
    self:heard_from_cell(here)
    here.confirming = { tries = 0, last = self.stack.clock() }
    self:to_cell(target, { op = "confirm", sealed = here.sealer:seal({ confirm = true }) })
    self.on_change(self)
end

function from_cell.attached.unknown(_, here)
    -- The cell says it doesn't know us (or someone says so for it): find out.
    if here.fast_check then return end
    here.fast_check, here.unanswered, here.last_check = true, 0, -math.huge
end

function from_cell.activating.activate_reply(self, here, message)
    local handshake = here.handshake:clone()
    if not handshake:read(message.handshake) then return end
    local finish = handshake:write(codec.encode({ v = common.VERSION }))
    if not finish then return end
    here.handshake, here.finished = handshake, true
    self:to_cell(here.cell, { op = "activate_finish", via = here.via, handshake = finish })
end

function from_cell.activating.activate_accept(self, here, message)
    if not here.finished then return end
    local _, receive = here.handshake:split()
    local plaintext = type(message.data) == "string" and receive:decrypt(message.data)
    local info = plaintext and codec.decode(plaintext)
    -- Only someone who knew the code could have sent something which decrypts, so these keys are the operator's.
    if type(info) ~= "table" then return end
    if type(info.network) ~= "string" or type(info.key) ~= "string" or #info.key ~= 32
        or type(info.signing) ~= "string" or #info.signing ~= 32 then
        return self:activation_failed("The network's answer was garbled")
    end
    self.operator = { network = info.network, key = info.key, signing = info.signing }
    self.subscriber = { id = info.id, number = info.number }
    self:event("activated", { network = info.network })
    self.on_activated(info)
    self.started = self.stack.clock()
    -- Which networks we may use (or treat as home), so we can use them at once: a network may have no cells.
    self:set_partners(info.partners)
    self:enter("searching")
    self:attach()
end

function from_cell.activating.reject(self, here, message)
    if here.finished or here.refusal then return end
    -- Another network's cell, whose core doesn't carry our network's phones: try the next. Anyone can send this, so
    -- the real answer still counts if it comes soon.
    here.refusal = type(message.reason) == "string" and message.reason:sub(1, 100) or "Rejected"
    self.stack:schedule(REJECT_GRACE, function()
        if self.here == here and not here.finished then
            here.activation.refusal = here.refusal
            self:try_activation(here.activation)
        end
    end)
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
    for network in pairs(partners) do self.forbidden:remove(network) end
    self.on_partners(partners, equivalent)
end

-- Something came from our cell which only it could have sent: it knows us.
function Phone:heard_from_cell(here)
    here.last_heard, here.unanswered, here.fast_check, here.confirming = self.stack.clock(), 0, false, nil
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

    self.activation_error = nil
    local activation = {
        network = network, tag = tag, key = common.activation_key(self.crypto, secret), candidates = candidates, next = 1,
    }
    if not self:try_activation(activation) then return nil, "The SIM can't be used" end
    return true
end

-- Ask the next cell to pass our activation on, or give up if none is left. Returns false if the SIM can't be used.
function Phone:try_activation(activation)
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
    -- What we keep while activating through one cell: the activation, the cell and the network we asked through, and
    -- the handshake; then whether we've finished it, and a refusal, which may not be the real answer.
    local here = { activation = activation, cell = candidate.id, via = candidate.network, handshake = handshake }
    self:enter("activating", here)
    self:to_cell(here.cell, {
        op = "activate", network = activation.network, via = here.via, tag = activation.tag, handshake = message,
    })
    self.stack:schedule(ATTACH_TIMEOUT * 2, function()
        if self.here == here then self:activation_failed("No answer: check the code") end
    end)
    return true
end

function Phone:activation_failed(reason)
    self.activation_error = reason
    self:event("activation_failed", { reason = reason })
    self:enter("inactive")
end

--[[- Whether a message could be sent: a number, and not too long a text.

@param to The number.
@param text The message.
@treturn[1] true If it could.
@treturn[2] nil If it couldn't.
@treturn[2] string Why not.
]]
local function check_message(to, text)
    if type(to) ~= "string" or #to < 1 or #to > 32 then return nil, "Numbers are up to 32 characters" end
    if type(text) ~= "string" or #text > 1000 then return nil, "Messages can be at most 1000 characters" end
    return true
end

--[[- Send a message to another phone, by its number. It's sent until the network says it has it, which then keeps
it until that phone is reachable. Without service, it waits until the phone has some: only tries while it has service
count towards giving up.

@tparam string to The number.
@tparam string text The message, up to 1000 characters.
@tparam[opt] number id The message's ID, for one which was waiting to be sent when the phone last stopped. The network
knows it again if it took it then, so it isn't delivered twice.
@treturn[1] true If it's being sent, or waits to be. `on_sent` is called once the network has it, or if it won't take
it.
@treturn[1] number The message's ID, which `on_sent` is called with.
@treturn[2] nil If it can't be sent.
@treturn[2] string Why not.
]]
function Phone:send_message(to, text, id)
    if not self.operator then return nil, "No SIM" end
    local ok, err = check_message(to, text)
    if not ok then return nil, err end
    if #self.outbox >= MAX_OUTBOX then return nil, "Too many messages are waiting to be sent" end

    if id ~= nil then
        if not common.is_id(id) then return nil, "Expected a message's ID" end
        for _, waiting in ipairs(self.outbox) do
            if waiting.id == id then return nil, "That message is being sent already" end
        end
        -- Messages the phone numbers itself come after it, so none has the same ID.
        if id > self.next_message then self.next_message = id end
    else
        self.next_message = self.next_message + 1
        id = self.next_message
    end
    local waiting = { id = id, to = to, text = text, tries = 0 }
    self.outbox[#self.outbox + 1] = waiting
    if self.state == "attached" then self:send_one(waiting) end
    return true, id
end

-- Send a message, while attached.
function Phone:send_one(waiting)
    local here = self.here
    waiting.tries, waiting.sent = waiting.tries + 1, self.stack.clock()
    self:to_cell(here.cell, { op = "data", sealed = here.sealer:seal({ sms = { id = waiting.id, to = waiting.to, text = waiting.text } }) })
end

-- Send the messages the network hasn't said it has, again, while attached: all of them once we have service back, or
-- those which haven't been sent yet or have waited a while. After enough tries, give up on one.
function Phone:send_waiting(only_old)
    local now = self.stack.clock()
    local function due(waiting) return not only_old or not waiting.sent or now - waiting.sent >= MESSAGE_RETRY end
    for i = #self.outbox, 1, -1 do
        local waiting = self.outbox[i]
        if due(waiting) and waiting.tries >= MESSAGE_TRIES then
            table.remove(self.outbox, i)
            self.on_sent(waiting.id, false, "The network didn't answer")
        end
    end
    for _, waiting in ipairs(self.outbox) do
        if due(waiting) then self:send_one(waiting) end
    end
end

-- Start attaching through the best cell: of our own network, else a partner's, else one of another network, which
-- may have an agreement with ours we don't know of yet. Cells which didn't answer lately come last.
function Phone:attach()
    local now, search = self.stack.clock(), self.search
    -- Other networks only once we've searched long enough to have heard every cell around, unless we were told to use
    -- one.
    local scanned = self.selection ~= nil or now - search.since >= SCAN_TIME
    local choice = self:best(now, nil, scanned)
    if not choice then return end
    -- Just started (or activated), we may not have heard our own network's cells yet, only a partner's. Don't settle
    -- for that, and stay there, until we've listened for long enough to hear every cell around.
    if choice.tier == PARTNER and now - self.started < SCAN_TIME then return end

    if choice.class == OTHER then
        -- We can't check its cell's part for that network until (and unless) our operator gives us the network's key,
        -- so go by what we heard.
        local heard, cell = self.heard[choice.id], self.cells[choice.id]
        if not cell then
            cell = {
                samples = { table.unpack(heard.samples) }, signal = heard.signal, heard = heard.heard, area = heard.area,
                networks = {},
            }
            self.cells[choice.id] = cell
        end
        local entry = heard.networks[choice.network]
        cell.networks[choice.network] = { heard = entry.heard, path = entry.path, unverified = true }
    end

    -- What we keep while attaching: the cell and the network we use it through, and the handshake; then the secret it
    -- gave us, and a refusal, which may not be the real answer.
    search.rejected = nil
    local here = { cell = choice.id, via = choice.network }
    here.handshake = noise.new {
        crypto = self.crypto, pattern = "IK", initiator = true, prologue = PROLOGUE .. self.operator.network,
        static = self.sim, remote_static = self.operator.key,
    }
    local message = here.handshake:write(codec.encode({ v = common.VERSION }))
    if not message then return self:give_up(here) end
    self:enter("attaching", here)
    self:to_cell(here.cell, { op = "attach", network = self.operator.network, via = here.via, handshake = message })

    self.stack:schedule(ATTACH_TIMEOUT, function()
        if self.here ~= here then return end
        -- A refusal which nothing else followed was the answer. Otherwise there was none: the cell may not hear us.
        local rejected = not here.secret and here.refusal or nil
        self:give_up(here, rejected, not rejected)
    end)
end

-- Attaching (`here`) didn't work, as it was refused or got no answer: try again later, less often each time. A network
-- we tried without knowing whether it would carry us is left alone for a while, so we try the others (or it again, once
-- its agreement may have changed). A cell which didn't answer is left alone for a while too, while there are others.
function Phone:give_up(here, rejected, unanswered)
    local search = self.search
    local cell = self.cells[here.cell]
    local entry = cell and cell.networks[here.via]
    if entry and entry.unverified then
        self.forbidden:add(here.via)
        cell.networks[here.via] = nil
        if next(cell.networks) == nil then self.cells[here.cell] = nil end
    elseif cell and unanswered then
        local failed = self.failed:get(here.cell) or { count = 0 }
        failed.count, failed.time = failed.count + 1, self.stack.clock()
        self.failed:add(here.cell, failed)
    end
    search.rejected = rejected
    self:enter(rejected and "rejected" or "searching")
    local delay = search.retry
    search.retry = math.min(search.retry * 2, MAX_RETRY)
    self.stack:schedule(delay, function()
        if self.search == search and (self.state == "searching" or self.state == "rejected") then
            self:enter("searching")
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
    local here = self.here
    local sealed = here.sealer:seal({ p = codec.encode(packet) })
    if sealed then self:to_cell(here.cell, { op = "data", sealed = sealed }) end
end

-- Compare our cell with the others, every second.
function Phone:measure()
    self.timer = self.stack:schedule(MEASURE_INTERVAL, function() self:measure() end)
    if self.state == "attached" then self:check(self.here) end
end

-- While attached (`here`): see that our cell is still there, and knows us; whether to go home; and whether another cell
-- is better.
function Phone:check(here)
    local now = self.stack.clock()
    local serving = self.cells[here.cell]
    local entry = serving and serving.networks[here.via]
    if not entry or now - entry.heard > SILENCE or serving.signal < NO_SERVICE then
        -- Our cell has gone (or stopped serving our network): attach again through another, keeping our address.
        self:event("lost", { cell = here.cell })
        self:enter("searching")
        if serving then
            serving.networks[here.via] = nil
            if next(serving.networks) == nil then self.cells[here.cell] = nil end
        end
        return self:attach()
    end

    -- A cell we've moved to may not have heard that we arrived: say so again, until it answers.
    local confirming = here.confirming
    if confirming and now - confirming.last >= 1 then
        if confirming.tries >= CONFIRM_TRIES then return self:forgotten(here) end
        confirming.tries, confirming.last = confirming.tries + 1, now
        self:to_cell(here.cell, { op = "confirm", sealed = here.sealer:seal({ confirm = true }) })
    end

    -- The cell may have forgotten us without going quiet (it restarted, or the core did). When nothing has come from
    -- it for a while, ask. If it doesn't answer several times running, attach again.
    local interval, misses = CHECK_INTERVAL, CHECK_MISSES
    if here.fast_check then interval, misses = FAST_INTERVAL, FAST_MISSES end
    if not confirming and now - here.last_heard >= interval and now - here.last_check >= interval then
        if here.unanswered >= misses then return self:forgotten(here) end
        here.unanswered, here.last_check = here.unanswered + 1, now
        self:to_cell(here.cell, { op = "data", sealed = here.sealer:seal({ ping = here.unanswered }) })
    end

    self:send_waiting(true)

    -- Roaming, and left to choose: go back to our own network (or one we treat as home) once its best cell has been
    -- stronger than ours for a while, or at once if ours serves it too (it's shared). We attach again, through its
    -- cell, rather than being handed over, and keep our address. On a network we treat as home, we stay until we lose
    -- it, as on our own.
    if not self:home_class(here.via) and not self.selection and not confirming then
        local home = self:best(now)
        if home and home.tier == HOME and (home.signal >= serving.signal + HYSTERESIS or home.id == here.cell) then
            here.home_since = here.home_since or now
            if now - here.home_since >= HOME_TIME then
                self:event("home", { from = here.cell })
                self:enter("searching")
                return self:attach()
            end
        else
            here.home_since = nil
        end
    end

    -- Handovers stay within the network we're on, to the best cell which is stronger enough than ours. One which didn't
    -- answer an attach lately comes after any other which will do.
    local target = self:best(now, function(choice)
        return choice.network == here.via and choice.id ~= here.cell and choice.signal >= serving.signal + HYSTERESIS
    end)
    if target then
        if here.candidate ~= target.id then
            here.candidate, here.candidate_since = target.id, now
        elseif now - here.candidate_since >= TIME_TO_TRIGGER and not here.reported then
            here.reported = target.id
            self:to_cell(here.cell, { op = "data", sealed = here.sealer:seal({ target = target.id }) })
            -- If the handover doesn't happen, ask again later.
            self.stack:schedule(TIME_TO_TRIGGER * 2, function() here.reported = nil end)
        end
    else
        here.candidate = nil
    end
end

-- Our cell (`here`'s) is there, but doesn't answer as a cell which knows us would: attach again, to it or another,
-- keeping our address.
function Phone:forgotten(here)
    self:event("lost", { cell = here.cell })
    self:enter("searching")
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
                    -- Heard lately enough to use.
                    fresh = age <= SILENCE,
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
        -- A cell or core newer than we are was heard lately: if we can't attach, that may be why.
        newer = self.newer_heard ~= nil and now - self.newer_heard <= FORGET,
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
    check_message = check_message,
}
