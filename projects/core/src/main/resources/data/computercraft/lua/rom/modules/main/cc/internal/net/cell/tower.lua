-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell: a tower which phones attach through, relaying between them and the core.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `celld` program instead.

A cell broadcasts signed system information every second, relays phones' attach handshakes to the core, and carries
their packets: sealed with the key it shares with each phone over the radio, and sealed tunnels to the gateway behind
it. When a phone reports a stronger cell, it asks the core to hand the phone over.

One cell may serve several networks, each with its own core, as operators who share a cell site do (like LTE's
multi-operator core networks). Its system information names each network, with the certificate that network's
operator gave the cell. A phone says which of them it chose; the cell takes it to that network's core, and carries its
packets through that core's tunnel. A network whose core is lost is no longer named, and its phones move on, while the
cell carries on serving the others.

@local
]]

local common = require "cc.internal.net.cell.common"

-- How long to keep a handed-over phone's confirmation which came before the core's word, in seconds, and how many.
local EARLY_CONFIRM_TIME, MAX_EARLY_CONFIRMS = 5, 16

-- How often to tell a computer that we don't know it as a phone, in seconds, and how many computers to keep track of.
local UNKNOWN_INTERVAL, MAX_UNKNOWN = 1, 64

-- How many phones to remember the network of, which they last asked to attach through.
local MAX_ASKED = 256

local is_id = common.is_id

local Tower = {}
Tower.__index = Tower

-- A network the cell serves: what its core sends goes to `control`, and `stop` stops serving it.
local Link = {}
Link.__index = Link

--[[- Start a cell.

@tparam {
    stack = table, crypto = table, interface = string, area? = number, sign = function(data:string):string,
    epoch = function():number, can_serve? = function(core:number):boolean,
    network? = string, certificate? = string, core? = number, tunnel_key? = string, control? = function(message:table),
} options The stack; the `crypto` API; the interface phones are on (a low band wireless one); this cell's tracking
area; a way to sign with the cell's key; the time, as `os.epoch("utc")` gives; and whether the cell can serve a
network's phones now, given the address of its core (a relay can't while its own phone has no service, and stops naming
that network, so its phones move to another cell). It may also be given the first network to serve, as `add_network`
takes it.
@treturn table The cell.
]]
local function new(options)
    local stack = options.stack
    local self = setmetatable({
        stack = stack, crypto = options.crypto, interface = options.interface, area = options.area or 0,
        sign = options.sign, epoch = options.epoch, id = stack.id,
        can_serve = options.can_serve or function() return true end,
        links = {}, phones = {}, early_confirms = {}, unknown = {}, unknown_count = 0, asked = {}, asked_count = 0,
    }, Tower)

    self.frame_handler = stack:on_frame(common.FRAME, function(interface, src, body, _, dst)
        if interface.name == self.interface and dst == self.id then self:radio(src, body) end
    end, true)
    -- Tunnels carry phones' packets whole, so need more room than programs' datagrams.
    self.socket = assert(stack:udp_open(common.CELL_TUNNEL_PORT, function(data) self:downlink(data) end, common.TUNNEL_LIMITS))
    if options.network then self:add_network(options.network, options) end
    self:beacon()
    return self
end

-- Stop serving a network: its phones here lose service, and find another cell.
local function drop(tower, link)
    tower.links[link.network] = nil
    for phone, context in pairs(tower.phones) do
        if context.link == link then tower.phones[phone] = nil end
    end
    for phone, asked in pairs(tower.asked) do
        if asked == link then
            tower.asked[phone] = nil
            tower.asked_count = tower.asked_count - 1
        end
    end
end

--[[- Serve a network: name it in our system information, and take its phones to its core.

@tparam string network The network's name.
@tparam {
    certificate = string, core = number, tunnel_key = string, control = function(message:table),
} options The cell's certificate from the network's operator; the address of its core, and the key for the tunnel to
it; and a way to send that core control messages.
@treturn table The network's link: give it what the core sends (`link:control(message)`), and stop serving the network
with `link:stop()`. Stopping the last network the cell serves stops the cell.
]]
function Tower:add_network(network, options)
    local old = self.links[network]
    if old then drop(self, old) end
    local link = setmetatable({
        tower = self, network = network, certificate = options.certificate, core = options.core,
        control_send = options.control, path = {}, by_teid = {},
        tunnel = common.new_sealer(self.crypto, options.tunnel_key, common.UPLINK, common.DOWNLINK),
    }, Link)
    self.links[network] = link
    return link
end

--- Handle a control message from this network's core.
--
-- @param message The message.
function Link:control(message)
    self.tower:control(message, self)
end

--- Stop serving this network. Its phones here lose service, and find another cell.
function Link:stop()
    local tower = self.tower
    if tower.links[self.network] ~= self then return end
    drop(tower, self)
    if next(tower.links) == nil then tower:stop() end
end

-- The network a phone chose here, by name: or, if it names none, our only one. A phone which names a network we don't
-- serve (one we stopped serving a moment ago, say) isn't taken to another, as its own network's core couldn't answer.
function Tower:link_for(network)
    if network ~= nil then return self.links[network] end
    local only, count = nil, 0
    for _, other in pairs(self.links) do only, count = other, count + 1 end
    if count == 1 then return only end
    return nil
end

-- Broadcast system information, every second, naming the networks we can serve phones of now.
function Tower:beacon()
    self.beacon_timer = self.stack:schedule(common.SIB_INTERVAL, function() self:beacon() end)
    local names = {}
    for name in pairs(self.links) do names[#names + 1] = name end
    table.sort(names)
    local networks = {}
    for _, name in ipairs(names) do
        local link = self.links[name]
        -- A relay too many relays from the core can't carry the biggest packets, so doesn't serve.
        if #link.path <= common.MAX_PATH and self.can_serve(link.core) and #networks < common.MAX_SIB_NETWORKS then
            networks[#networks + 1] = { network = name, certificate = link.certificate, path = link.path }
        end
    end
    if not networks[1] then return end
    local load = 0
    for _ in pairs(self.phones) do load = load + 1 end
    self.stack:send_frame(self.interface, -1, common.FRAME, common.make_sib {
        cell = self.id, area = self.area, load = math.min(1, load / 32), time = self.epoch(), networks = networks,
        sign = self.sign,
    })
end

function Tower:to_phone(phone, message)
    self.stack:send_frame(self.interface, phone, common.FRAME, message)
end

-- A frame from a phone.
function Tower:radio(phone, message)
    if type(message) ~= "table" then return end
    local op = message.op
    if (op == "attach" or op == "activate") and common.is_network(message.network) and type(message.handshake) == "string"
        and (op == "attach" or type(message.tag) == "string") then
        -- The phone names its own network, and the one it chose here (`via`): a phone of another network may be
        -- roaming, or activating through ours, and that network's core knows whether it carries the phone's.
        local link = self:link_for(message.via or message.network)
        if not link then return end
        if op == "attach" then self:ask(phone, link) end
        link.control_send({
            op = op, phone = phone, handshake = message.handshake, tag = op == "activate" and message.tag or nil,
            network = message.network ~= link.network and message.network or nil,
        })
    elseif op == "attach_complete" and type(message.data) == "string" then
        local link = self:link_for(message.via)
        if link then link.control_send({ op = "attach_complete", phone = phone, data = message.data }) end
    elseif op == "activate_finish" and type(message.handshake) == "string" then
        local link = self:link_for(message.via)
        if link then link.control_send({ op = "activate_finish", phone = phone, handshake = message.handshake }) end
    elseif op == "data" then
        local context = self.phones[phone]
        -- A phone we've forgotten (we restarted, or the core did) would wait a long time for an answer. Tell it, so
        -- it can check, and attach again. Anyone can send such a frame, so not too often.
        if not context then return self:say_unknown(phone) end
        local value = context.active and context.sealer:open(message.sealed)
        if type(value) ~= "table" then return end
        local link = context.link
        if type(value.p) == "string" then
            -- Up the tunnel to the gateway.
            local sealed = link.tunnel:seal({ teid = context.teid, packet = value.p })
            if sealed then
                local ok, err = self.stack:udp_send(self.socket, link.core, common.TUNNEL_PORT, sealed)
                if not ok then self.stack.log("Cell couldn't tunnel a phone's packet: " .. tostring(err)) end
            end
        elseif type(value.sms) == "table" then
            link.control_send({ op = "sms", teid = context.teid, id = value.sms.id, to = value.sms.to, text = value.sms.text })
        elseif value.sms_ack ~= nil then
            link.control_send({ op = "sms_ack", teid = context.teid, id = value.sms_ack })
        elseif value.ping ~= nil then
            -- The phone is checking we still know it.
            self:to_phone(phone, { op = "data", sealed = context.sealer:seal({ pong = true }) })
        elseif is_id(value.target) and value.target ~= self.id
            and (not context.handing_over or self.stack.clock() - context.handing_over > 5) then
            -- The phone hears another cell better. If the handover doesn't happen, it may ask again later.
            context.handing_over = self.stack.clock()
            link.control_send({ op = "handover", teid = context.teid, target = value.target })
        end
    elseif op == "confirm" and type(message.sealed) == "table" then
        -- A phone handed over to us. The core's word about it comes over the backhaul, which may be slower than the
        -- phone over the air (through a relay's own phone, say), so keep the phone's confirmation until it does.
        if self.phones[phone] then return self:confirm(phone, message.sealed) end
        local count = 0
        for id, early in pairs(self.early_confirms) do
            if self.stack.clock() - early.time > EARLY_CONFIRM_TIME then self.early_confirms[id] = nil else count = count + 1 end
        end
        if self.early_confirms[phone] or count < MAX_EARLY_CONFIRMS then
            self.early_confirms[phone] = { sealed = message.sealed, time = self.stack.clock() }
        end
    end
end

-- Remember which network a phone asked to attach through. A cell which serves several networks only lets a network's
-- core take over a phone from another's when the phone asked for that network.
function Tower:ask(phone, link)
    if self.asked[phone] == nil then
        -- Anyone can send an attach, as from any phone. Forgetting only costs a phone moving between two networks
        -- here another try.
        if self.asked_count >= MAX_ASKED then self.asked, self.asked_count = {}, 0 end
        self.asked_count = self.asked_count + 1
    end
    self.asked[phone] = link
end

-- Tell a computer which thinks it's one of our phones that we don't know it.
function Tower:say_unknown(phone)
    local now = self.stack.clock()
    local last = self.unknown[phone]
    if last and now - last < UNKNOWN_INTERVAL then return end
    if not last then
        if self.unknown_count >= MAX_UNKNOWN then self.unknown, self.unknown_count = {}, 0 end
        self.unknown_count = self.unknown_count + 1
    end
    self.unknown[phone] = now
    self:to_phone(phone, { op = "unknown" })
end

-- A phone handed over to us says it's here: tell its core to send its packets our way, and tell the phone we heard.
-- It says so until we answer, as either frame may be lost.
function Tower:confirm(phone, sealed)
    local context = self.phones[phone]
    if not context then return end
    local value = context.sealer:open(sealed)
    if type(value) ~= "table" or value.confirm ~= true then return end
    if not context.active then
        context.active = true
        context.link.control_send({ op = "path_switch", teid = context.teid })
    end
    self:to_phone(phone, { op = "data", sealed = context.sealer:seal({ confirmed = true }) })
end

-- Forget a phone's context.
local function forget(tower, context)
    if context.link.by_teid[context.teid] == context then context.link.by_teid[context.teid] = nil end
    if tower.phones[context.phone] == context then tower.phones[context.phone] = nil end
end

--[[- Handle a control message from a core.

@param message The message.
@tparam[opt] table link The link of the network whose core sent it: see [`Tower:add_network`]. A cell which serves one
network needn't say.
]]
function Tower:control(message, link)
    link = link or self:link_for(nil)
    if type(message) ~= "table" or not link or self.links[link.network] ~= link then return end
    local op = message.op
    if op == "attach_reply" and is_id(message.phone) then
        self:to_phone(message.phone, { op = "attach_reply", handshake = message.handshake })
    elseif op == "reject" and is_id(message.phone) then
        self:to_phone(message.phone, { op = "reject", reason = message.reason })
    elseif (op == "activate_reply" or op == "activate_accept") and is_id(message.phone) then
        self:to_phone(message.phone, { op = op, handshake = message.handshake, data = message.data })
    elseif op == "sms" and is_id(message.teid) then
        local context = link.by_teid[message.teid]
        if context and context.active then
            local sms = { id = message.id, from = message.from, text = message.text }
            local sealed = context.sealer:seal({ sms = sms })
            if sealed then self:to_phone(context.phone, { op = "data", sealed = sealed }) end
        end
    elseif op == "sms_sent" and is_id(message.teid) then
        -- The core has a message the phone sent (or won't take it).
        local context = link.by_teid[message.teid]
        if context and context.active then
            local sealed = context.sealer:seal({ sms_sent = { id = message.id, ok = message.ok, error = message.error } })
            if sealed then self:to_phone(context.phone, { op = "data", sealed = sealed }) end
        end
    elseif op == "context" and is_id(message.phone) and is_id(message.teid)
        and type(message.key) == "string" and #message.key == 32 then
        -- A phone is attached (or handed over) through one network at a time. One network's core doesn't get to take
        -- a phone which is here through another, unless the phone asked to attach through it.
        local old = self.phones[message.phone]
        if old and old.link ~= link and self.asked[message.phone] ~= link then return end
        if old then forget(self, old) end
        local context = {
            phone = message.phone, teid = message.teid, link = link, active = not message.handover,
            sealer = common.new_sealer(self.crypto, message.key, common.DOWNLINK, common.UPLINK),
        }
        self.phones[message.phone] = context
        link.by_teid[message.teid] = context
        if context.active then
            local sealed = context.sealer:seal({ address = message.address })
            if sealed then self:to_phone(message.phone, { op = "accept", sealed = sealed }) end
        end
        -- The phone may have arrived already.
        local early = self.early_confirms[message.phone]
        self.early_confirms[message.phone] = nil
        if early and not context.active and self.stack.clock() - early.time <= EARLY_CONFIRM_TIME then
            self:confirm(message.phone, early.sealed)
        end
    elseif op == "handover_go" and is_id(message.teid) and is_id(message.target) then
        local context = link.by_teid[message.teid]
        if context then
            self:to_phone(context.phone, { op = "handover", sealed = context.sealer:seal({ target = message.target }) })
        end
    elseif op == "path" and common.is_path(message.path) then
        -- The relays our backhaul to this network's core goes through, which phones on them mustn't use us.
        link.path = message.path
    elseif op == "release" and is_id(message.teid) then
        local context = link.by_teid[message.teid]
        if context then forget(self, context) end
    end
end

-- A packet for a phone, down a tunnel from a gateway.
function Tower:downlink(data)
    -- Only a core has its tunnel's key, and the sealer refuses replays, so where it came from doesn't matter. (It
    -- isn't always the address we reached the core at: a relay's tunnel comes from the core's gateway address.) Each
    -- network's tunnel has its own key: the one which opens it says whose it is.
    for _, link in pairs(self.links) do
        local inner = link.tunnel:open(data)
        if inner ~= nil then
            local context = type(inner) == "table" and link.by_teid[inner.teid]
            if not context or not context.active or type(inner.packet) ~= "string" then return end
            local sealed = context.sealer:seal({ p = inner.packet })
            if sealed then self:to_phone(context.phone, { op = "data", sealed = sealed }) end
            return
        end
    end
end

--- Stop the cell, for every network it serves.
function Tower:stop()
    if self.stopped then return end
    self.stopped = true
    self.stack:cancel(self.beacon_timer)
    self.stack:udp_close(self.socket)
    self.stack:off_frame(common.FRAME, self.frame_handler)
    self.links, self.phones, self.asked, self.asked_count = {}, {}, {}, 0
end

return {
    new = new,
}
