-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell: a tower which phones attach through, relaying between them and the core.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `celld` program instead.

A cell broadcasts signed system information every second, relays phones' attach handshakes to the core, and carries
their packets: sealed with the key it shares with each phone over the radio, and sealed tunnels to the gateway behind
it. When a phone reports a stronger cell, it asks the core to hand the phone over.

@local
]]

local common = require "cc.internal.net.cell.common"

-- How long to keep a handed-over phone's confirmation which came before the core's word, in seconds, and how many.
local EARLY_CONFIRM_TIME, MAX_EARLY_CONFIRMS = 5, 16

-- How often to tell a computer that we don't know it as a phone, in seconds, and how many computers to keep track of.
local UNKNOWN_INTERVAL, MAX_UNKNOWN = 1, 64

local is_id = common.is_id

local Tower = {}
Tower.__index = Tower

--[[- Start a cell.

@tparam {
    stack = table, crypto = table, interface = string, network = string, area? = number,
    certificate = string, sign = function(data:string):string, epoch = function():number,
    core = number, tunnel_key = string, control = function(message:table), can_serve? = function():boolean,
} options The stack; the `crypto` API; the interface phones are on (a low band wireless one); the network's name and
this cell's tracking area; the cell's certificate from the operator, and a way to sign with its key; the time, as
`os.epoch("utc")` gives; the core's address, and the key for the tunnel to it; a way to send the core control
messages; and whether the cell can serve phones now. A relay can't while its own phone has no service, and stops
broadcasting, so its phones move to another cell.
@treturn table The cell.
]]
local function new(options)
    local stack = options.stack
    local self = setmetatable({
        stack = stack, crypto = options.crypto, interface = options.interface, network = options.network,
        area = options.area or 0, certificate = options.certificate, sign = options.sign, epoch = options.epoch,
        core = options.core, control_send = options.control, id = stack.id,
        can_serve = options.can_serve or function() return true end,
        tunnel = common.new_sealer(options.crypto, options.tunnel_key, common.UPLINK, common.DOWNLINK),
        phones = {}, by_teid = {}, path = {}, early_confirms = {}, unknown = {}, unknown_count = 0,
    }, Tower)

    self.frame_handler = stack:on_frame(common.FRAME, function(interface, src, body, _, dst)
        if interface.name == self.interface and dst == self.id then self:radio(src, body) end
    end, true)
    -- Tunnels carry phones' packets whole, so need more room than programs' datagrams.
    self.socket = assert(stack:udp_open(common.CELL_TUNNEL_PORT, function(data) self:downlink(data) end, common.TUNNEL_LIMITS))
    self:beacon()
    return self
end

-- Broadcast system information, every second, while we can serve phones.
function Tower:beacon()
    self.beacon_timer = self.stack:schedule(common.SIB_INTERVAL, function() self:beacon() end)
    -- A relay too many relays from the core can't carry the biggest packets, so doesn't serve.
    if #self.path > common.MAX_PATH or not self.can_serve() then return end
    local load = 0
    for _ in pairs(self.phones) do load = load + 1 end
    self.stack:send_frame(self.interface, -1, common.FRAME, common.make_sib {
        network = self.network, cell = self.id, area = self.area, load = math.min(1, load / 32), time = self.epoch(),
        path = self.path, certificate = self.certificate, sign = self.sign,
    })
end

function Tower:to_phone(phone, message)
    self.stack:send_frame(self.interface, phone, common.FRAME, message)
end

-- A frame from a phone.
function Tower:radio(phone, message)
    if type(message) ~= "table" then return end
    local op = message.op
    if op == "attach" and common.is_network(message.network) and type(message.handshake) == "string" then
        -- A phone of another network may be roaming: the core knows whether we carry that network's phones.
        self.control_send({
            op = "attach", phone = phone, handshake = message.handshake,
            network = message.network ~= self.network and message.network or nil,
        })
    elseif op == "activate" and message.network == self.network and type(message.tag) == "string"
        and type(message.handshake) == "string" then
        self.control_send({ op = "activate", phone = phone, tag = message.tag, handshake = message.handshake })
    elseif op == "activate_finish" and type(message.handshake) == "string" then
        self.control_send({ op = "activate_finish", phone = phone, handshake = message.handshake })
    elseif op == "attach_complete" and type(message.data) == "string" then
        self.control_send({ op = "attach_complete", phone = phone, data = message.data })
    elseif op == "data" then
        local context = self.phones[phone]
        -- A phone we've forgotten (we restarted, or the core did) would wait a long time for an answer. Tell it, so
        -- it can check, and attach again. Anyone can send such a frame, so not too often.
        if not context then return self:say_unknown(phone) end
        local value = context.active and context.sealer:open(message.sealed)
        if type(value) ~= "table" then return end
        if type(value.p) == "string" then
            -- Up the tunnel to the gateway.
            local sealed = self.tunnel:seal({ teid = context.teid, packet = value.p })
            if sealed then
                local ok, err = self.stack:udp_send(self.socket, self.core, common.TUNNEL_PORT, sealed)
                if not ok then self.stack.log("Cell couldn't tunnel a phone's packet: " .. tostring(err)) end
            end
        elseif type(value.sms) == "table" then
            self.control_send({ op = "sms", teid = context.teid, id = value.sms.id, to = value.sms.to, text = value.sms.text })
        elseif value.sms_ack ~= nil then
            self.control_send({ op = "sms_ack", teid = context.teid, id = value.sms_ack })
        elseif value.ping ~= nil then
            -- The phone is checking we still know it.
            self:to_phone(phone, { op = "data", sealed = context.sealer:seal({ pong = true }) })
        elseif is_id(value.target) and value.target ~= self.id
            and (not context.handing_over or self.stack.clock() - context.handing_over > 5) then
            -- The phone hears another cell better. If the handover doesn't happen, it may ask again later.
            context.handing_over = self.stack.clock()
            self.control_send({ op = "handover", teid = context.teid, target = value.target })
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

-- A phone handed over to us says it's here: tell the core to send its packets our way, and tell the phone we heard.
-- It says so until we answer, as either frame may be lost.
function Tower:confirm(phone, sealed)
    local context = self.phones[phone]
    if not context then return end
    local value = context.sealer:open(sealed)
    if type(value) ~= "table" or value.confirm ~= true then return end
    if not context.active then
        context.active = true
        self.control_send({ op = "path_switch", teid = context.teid })
    end
    self:to_phone(phone, { op = "data", sealed = context.sealer:seal({ confirmed = true }) })
end

--[[- Handle a control message from the core.

@param message The message.
]]
function Tower:control(message)
    if type(message) ~= "table" then return end
    local op = message.op
    if op == "attach_reply" and is_id(message.phone) then
        self:to_phone(message.phone, { op = "attach_reply", handshake = message.handshake })
    elseif op == "reject" and is_id(message.phone) then
        self:to_phone(message.phone, { op = "reject", reason = message.reason })
    elseif (op == "activate_reply" or op == "activate_accept") and is_id(message.phone) then
        self:to_phone(message.phone, { op = op, handshake = message.handshake, data = message.data })
    elseif op == "sms" and is_id(message.teid) then
        local context = self.by_teid[message.teid]
        if context and context.active then
            local sms = { id = message.id, from = message.from, text = message.text }
            local sealed = context.sealer:seal({ sms = sms })
            if sealed then self:to_phone(context.phone, { op = "data", sealed = sealed }) end
        end
    elseif op == "sms_sent" and is_id(message.teid) then
        -- The core has a message the phone sent (or won't take it).
        local context = self.by_teid[message.teid]
        if context and context.active then
            local sealed = context.sealer:seal({ sms_sent = { id = message.id, ok = message.ok, error = message.error } })
            if sealed then self:to_phone(context.phone, { op = "data", sealed = sealed }) end
        end
    elseif op == "context" and is_id(message.phone) and is_id(message.teid)
        and type(message.key) == "string" and #message.key == 32 then
        local old = self.phones[message.phone]
        if old then self.by_teid[old.teid] = nil end
        local context = {
            phone = message.phone, teid = message.teid, active = not message.handover,
            sealer = common.new_sealer(self.crypto, message.key, common.DOWNLINK, common.UPLINK),
        }
        self.phones[message.phone] = context
        self.by_teid[message.teid] = context
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
        local context = self.by_teid[message.teid]
        if context then
            self:to_phone(context.phone, { op = "handover", sealed = context.sealer:seal({ target = message.target }) })
        end
    elseif op == "path" and common.is_path(message.path) then
        -- The relays our backhaul goes through, which phones on them mustn't use us.
        self.path = message.path
    elseif op == "release" and is_id(message.teid) then
        local context = self.by_teid[message.teid]
        if context then
            self.by_teid[message.teid] = nil
            if self.phones[context.phone] == context then self.phones[context.phone] = nil end
        end
    end
end

-- A packet for a phone, down the tunnel from the gateway.
function Tower:downlink(data)
    -- Only the core has the tunnel's key, and the sealer refuses replays, so where it came from doesn't matter. (It
    -- isn't always the address we reached the core at: a relay's tunnel comes from the core's gateway address.)
    local inner = self.tunnel:open(data)
    local context = type(inner) == "table" and self.by_teid[inner.teid]
    if not context or not context.active or type(inner.packet) ~= "string" then return end
    local sealed = context.sealer:seal({ p = inner.packet })
    if sealed then self:to_phone(context.phone, { op = "data", sealed = sealed }) end
end

--- Stop the cell.
function Tower:stop()
    self.stack:cancel(self.beacon_timer)
    self.stack:udp_close(self.socket)
    self.stack:off_frame(common.FRAME, self.frame_handler)
end

return {
    new = new,
}
