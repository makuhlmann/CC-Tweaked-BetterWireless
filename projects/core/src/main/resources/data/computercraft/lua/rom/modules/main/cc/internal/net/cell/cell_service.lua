-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell of a cellular network, run in the network stack's background process. It connects to the network's core,
waits for the core to allow it if it must, and then runs the cell. When it loses the core, it connects again, less often
each time.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `celld` program instead.

@local
]]

local tasks = require "cc.internal.net.tasks"

-- How long the core has to answer, and how long to wait to be allowed, in seconds. The core gives up waiting first.
local HELLO_TIMEOUT = 15
local WAIT_TIMEOUT = 11 * 60

--- How long to wait before connecting again, at first, in seconds. It doubles each time.
local FIRST_DELAY = 2

--- The longest to wait before connecting again, in seconds.
local MAX_DELAY = 60

local Service = {}
Service.__index = Service

--[[- Start a cell.

@tparam {
    core = string, area? = number, id = number, identity = string, fingerprint = function(key:string):string,
    signing = string, connect = function(core:string):table,
    start_tower = function(welcome:table, control:function):table,
    sleep = function(seconds:number), wake = function(),
} options The core's name or address; the cell's tracking area; this computer's ID and its key (as hexadecimal
digits), and a way to get a key's fingerprint; the cell's own Ed25519 key, as hexadecimal digits, which the core
certifies; a way to connect securely to the core's control port; a way to start the cell itself, given what the core
said (`network`, `certificate`, `tunnel_key`, `core` and `area`) and a function to send the core control messages;
a way to wait; and a way to wake tasks waiting for something to change.
@treturn table The service. Pass it every event with `resume`.
]]
local function new(options)
    local self = setmetatable({ options = options, state = "connecting" }, Service)
    self.tasks = tasks.new(function(err) self.error = tostring(err) end)
    self.tasks:spawn(function() self:run() end)
    return self
end

function Service:set(state, err)
    self.state, self.error = state, err
end

function Service:run()
    local delay = FIRST_DELAY
    while not self.stopped do
        self:set("connecting")
        local connected, connection, err = pcall(self.options.connect, self.options.core)
        if not connected then connection, err = nil, tostring(connection) end
        if connection then
            self.connection = connection
            local ok, reason = pcall(self.serve, self, connection)
            self.connection = nil
            connection:abort()
            if self.served then delay, self.served = FIRST_DELAY, false end
            if not ok then reason = tostring(reason) end
            if self.state ~= "refused" then self:set("lost", reason or "The core closed the connection") end
        else
            self:set("lost", err)
        end
        if self.stopped then return end
        self.retry = delay
        self.options.sleep(delay)
        delay = math.min(delay * 2, MAX_DELAY)
    end
end

function Service:serve(connection)
    local options = self.options
    connection:send({ role = "cell", id = options.id, signing = options.signing, area = options.area or 0 })
    local reply, err = connection:receive(HELLO_TIMEOUT)
    if type(reply) == "table" and reply.waiting then
        self:set("waiting")
        reply, err = connection:receive(WAIT_TIMEOUT)
    end
    if type(reply) == "table" and type(reply.error) == "string" then
        self:set("refused", reply.error)
        return
    end
    if type(reply) ~= "table" or type(reply.network) ~= "string" or type(reply.certificate) ~= "string"
        or type(reply.tunnel_key) ~= "string" then
        return err or "The core didn't answer"
    end

    -- The cell sends control messages from inside the network stack, where nothing may wait: queue them.
    local outbox, done = {}, false
    local tower = options.start_tower({
        network = reply.network, certificate = reply.certificate, tunnel_key = reply.tunnel_key,
        core = connection:getPeer(), area = options.area or 0,
    }, function(message)
        outbox[#outbox + 1] = message
        options.wake()
    end)
    self.tower, self.network, self.served = tower, reply.network, true
    self:set("serving")

    self.tasks:spawn(function()
        while not done do
            local message = table.remove(outbox, 1)
            if message then
                if not connection:send(message) then done = true end
            else
                coroutine.yield()
            end
        end
    end)

    local reason
    local ok, failure = pcall(function()
        while not done do
            local message, receive_err = connection:receive()
            if message == nil then
                reason = receive_err or "The core closed the connection"
                break
            end
            tower:control(message)
        end
    end)
    done = true
    self.tower = nil
    tower:stop()
    if not ok then error(failure, 0) end
    return reason
end

--[[- Describe the cell.

@treturn table Its `state`: `"connecting"`, `"waiting"` (for the core to allow it), `"serving"`, `"lost"` (it couldn't
reach the core, or lost it, and tries again in `retry` seconds) or `"refused"`; `error`, saying why; the `core`; the
`network` it serves; its `area`; and its `id` and `fingerprint`, for allowing it on the core.
]]
function Service:info()
    local options = self.options
    return {
        state = self.state, error = self.error, retry = self.retry, core = options.core, network = self.network,
        area = options.area or 0, id = options.id, fingerprint = options.fingerprint(options.identity),
    }
end

--[[- Pass an event to the service's tasks.

@tparam string|nil event The event's name.
@param ... Its arguments.
]]
function Service:resume(...)
    self.tasks:resume(...)
end

--- Stop the cell. Its phones lose service.
function Service:stop()
    if self.stopped then return end
    self.stopped = true
    self.tasks:stop()
    if self.tower then
        self.tower:stop()
        self.tower = nil
    end
    if self.connection then self.connection:abort() end
end

return {
    new = new,
    FIRST_DELAY = FIRST_DELAY,
    MAX_DELAY = MAX_DELAY,
}
