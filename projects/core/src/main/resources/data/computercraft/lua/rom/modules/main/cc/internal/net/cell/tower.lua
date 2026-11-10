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

local Tower = {}
Tower.__index = Tower

--[[- Start a cell.

@tparam {
    stack = table, crypto = table, interface = string, network = string, area? = number,
    certificate = string, sign = function(data:string):string, epoch = function():number,
    core = number, tunnel_key = string, control = function(message:table),
} options The stack; the `crypto` API; the interface phones are on (a low band wireless one); the network's name and
this cell's tracking area; the cell's certificate from the operator, and a way to sign with its key; the time, as
`os.epoch("utc")` gives; the core's address, and the key for the tunnel to it; and a way to send the core control
messages.
@treturn table The cell.
]]
local function new(options)
    local stack = options.stack
    local self = setmetatable({
        stack = stack, crypto = options.crypto, interface = options.interface, network = options.network,
        area = options.area or 0, certificate = options.certificate, sign = options.sign, epoch = options.epoch,
        core = options.core, control_send = options.control, id = stack.id,
        tunnel = common.new_sealer(options.crypto, options.tunnel_key, common.UPLINK, common.DOWNLINK),
        phones = {}, by_teid = {},
    }, Tower)

    stack:on_frame(common.FRAME, function(interface, src, body, _, dst)
        if interface.name == self.interface and dst == self.id then self:radio(src, body) end
    end, true)
    self.socket = assert(stack:udp_open(common.CELL_TUNNEL_PORT, function(data, from) self:downlink(data, from) end))
    self:beacon()
    return self
end

-- Broadcast system information, every second.
function Tower:beacon()
    local load = 0
    for _ in pairs(self.phones) do load = load + 1 end
    self.stack:send_frame(self.interface, -1, common.FRAME, common.make_sib {
        network = self.network, cell = self.id, area = self.area, load = math.min(1, load / 32), time = self.epoch(),
        certificate = self.certificate, sign = self.sign,
    })
    self.beacon_timer = self.stack:schedule(common.SIB_INTERVAL, function() self:beacon() end)
end

function Tower:to_phone(phone, message)
    self.stack:send_frame(self.interface, phone, common.FRAME, message)
end

-- A frame from a phone.
function Tower:radio(phone, message)
    if type(message) ~= "table" then return end
    local op = message.op
    if op == "attach" and message.network == self.network and type(message.handshake) == "string" then
        self.control_send({ op = "attach", phone = phone, handshake = message.handshake })
    elseif op == "activate" and message.network == self.network and type(message.tag) == "string"
        and type(message.handshake) == "string" then
        self.control_send({ op = "activate", phone = phone, tag = message.tag, handshake = message.handshake })
    elseif op == "activate_finish" and type(message.handshake) == "string" then
        self.control_send({ op = "activate_finish", phone = phone, handshake = message.handshake })
    elseif op == "attach_complete" and type(message.data) == "string" then
        self.control_send({ op = "attach_complete", phone = phone, data = message.data })
    elseif op == "data" then
        local context = self.phones[phone]
        local value = context and context.active and context.sealer:open(message.sealed)
        if type(value) ~= "table" then return end
        if type(value.p) == "string" then
            -- Up the tunnel to the gateway.
            local sealed = self.tunnel:seal({ teid = context.teid, packet = value.p })
            if sealed then self.stack:udp_send(self.socket, self.core, common.TUNNEL_PORT, sealed) end
        elseif type(value.sms) == "table" then
            self.control_send({ op = "sms", teid = context.teid, to = value.sms.to, text = value.sms.text })
        elseif value.sms_ack ~= nil then
            self.control_send({ op = "sms_ack", teid = context.teid, id = value.sms_ack })
        elseif type(value.target) == "number" and value.target ~= self.id
            and (not context.handing_over or self.stack.clock() - context.handing_over > 5) then
            -- The phone hears another cell better. If the handover doesn't happen, it may ask again later.
            context.handing_over = self.stack.clock()
            self.control_send({ op = "handover", teid = context.teid, target = value.target })
        end
    elseif op == "confirm" then
        -- A phone handed over to us.
        local context = self.phones[phone]
        if not context or context.active then return end
        local value = context.sealer:open(message.sealed)
        if type(value) == "table" and value.confirm == true then
            context.active = true
            self.control_send({ op = "path_switch", teid = context.teid })
        end
    end
end

--[[- Handle a control message from the core.

@param message The message.
]]
function Tower:control(message)
    if type(message) ~= "table" then return end
    local op = message.op
    if op == "attach_reply" and type(message.phone) == "number" then
        self:to_phone(message.phone, { op = "attach_reply", handshake = message.handshake })
    elseif op == "reject" and type(message.phone) == "number" then
        self:to_phone(message.phone, { op = "reject", reason = message.reason })
    elseif (op == "activate_reply" or op == "activate_accept") and type(message.phone) == "number" then
        self:to_phone(message.phone, { op = op, handshake = message.handshake, data = message.data })
    elseif op == "sms" and type(message.teid) == "number" then
        local context = self.by_teid[message.teid]
        if context and context.active then
            local sms = { id = message.id, from = message.from, text = message.text }
            self:to_phone(context.phone, { op = "data", sealed = context.sealer:seal({ sms = sms }) })
        end
    elseif op == "context" and type(message.phone) == "number" and type(message.teid) == "number"
        and type(message.key) == "string" then
        local old = self.phones[message.phone]
        if old then self.by_teid[old.teid] = nil end
        local context = {
            phone = message.phone, teid = message.teid, active = not message.handover,
            sealer = common.new_sealer(self.crypto, message.key, common.DOWNLINK, common.UPLINK),
        }
        self.phones[message.phone] = context
        self.by_teid[message.teid] = context
        if context.active then
            self:to_phone(message.phone, { op = "accept", sealed = context.sealer:seal({ address = message.address }) })
        end
    elseif op == "handover_go" and type(message.teid) == "number" then
        local context = self.by_teid[message.teid]
        if context then
            self:to_phone(context.phone, { op = "handover", sealed = context.sealer:seal({ target = message.target }) })
        end
    elseif op == "release" and type(message.teid) == "number" then
        local context = self.by_teid[message.teid]
        if context then
            self.by_teid[message.teid] = nil
            if self.phones[context.phone] == context then self.phones[context.phone] = nil end
        end
    end
end

-- A packet for a phone, down the tunnel from the gateway.
function Tower:downlink(data, from)
    if from ~= self.core then return end
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
    self.stack:on_frame(common.FRAME, nil)
end

return {
    new = new,
}
