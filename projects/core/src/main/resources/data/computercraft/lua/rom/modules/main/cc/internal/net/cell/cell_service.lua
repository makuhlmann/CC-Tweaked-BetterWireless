-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell of a cellular network, run in the network stack's background process. It connects to the network's core,
waits for the core to allow it if it must, and then runs the cell. When it loses the core, it connects again, less often
each time.

A cell may serve several networks, connecting to each one's core (operators sharing a cell site): each connection is
kept on its own, and the cell serves each network while its core is there.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `celld` program instead.

@local
]]

local tasks = require "cc.internal.net.tasks"
local common = require "cc.internal.net.cell.common"

-- How long the core has to answer, and how long to wait to be allowed, in seconds. The core gives up waiting first.
local HELLO_TIMEOUT = 15
local WAIT_TIMEOUT = 11 * 60

--- How long to wait before connecting again, at first, in seconds. It doubles each time.
local FIRST_DELAY = 2

--- The longest to wait before connecting again, in seconds.
local MAX_DELAY = 60

-- The longest certificate a core may give the cell, in bytes. It's broadcast every second, along with those of the
-- other networks the cell serves, so one which is far too long would keep all of them off the air.
local MAX_CERTIFICATE = 1024

-- Which state of a core's to show for the cell as a whole: the best one.
local STATE_ORDER = { serving = 1, waiting = 2, connecting = 3, lost = 4, refused = 5 }

local Service = {}
Service.__index = Service

--[[- Start a cell.

@tparam {
    core? = string, cores? = { string... }, area? = number, id = number, identity = string,
    fingerprint = function(key:string):string, signing = string, connect = function(core:string):table,
    start_tower = function(welcome:table, control:function):table,
    sleep = function(seconds:number), wake = function(),
} options The core's name or address, or the names or addresses of several (for a cell which serves several
networks); the cell's tracking area; this computer's ID and its key (as hexadecimal digits), and a way to get a key's
fingerprint; the cell's own Ed25519 key, as hexadecimal digits, which each core certifies; a way to connect securely
to a core's control port; a way to have the cell serve a network, given what its core said (`network`, `certificate`,
`tunnel_key`, `core` and `area`) and a function to send that core control messages, which returns something to give
the core's messages to (`control`) and to stop serving the network with (`stop`); a way to wait; and a way to wake
tasks waiting for something to change.
@treturn table The service. Pass it every event with `resume`.
]]
local function new(options)
    local self = setmetatable({ options = options, links = {} }, Service)
    self.tasks = tasks.new(function(err) self.error = tostring(err) end)
    for i, core in ipairs(options.cores or { options.core }) do
        local link = { core = core, state = "connecting" }
        self.links[i] = link
        self.tasks:spawn(function() self:run(link) end)
    end
    return self
end

-- Keep a core connected: connect, serve its network, and connect again once it's lost, less often each time.
function Service:run(link)
    local delay = FIRST_DELAY
    while not self.stopped do
        link.state, link.error = "connecting", nil
        local connected, connection, err = pcall(self.options.connect, link.core)
        if not connected then connection, err = nil, tostring(connection) end
        if connection then
            link.connection = connection
            local ok, reason = pcall(self.serve, self, link, connection)
            link.connection = nil
            connection:abort()
            if link.served then delay, link.served = FIRST_DELAY, false end
            if not ok then reason = tostring(reason) end
            if link.state ~= "refused" then link.state, link.error = "lost", reason or "The core closed the connection" end
        else
            link.state, link.error = "lost", err
        end
        if self.stopped then return end
        link.retry = delay
        self.options.sleep(delay)
        delay = math.min(delay * 2, MAX_DELAY)
    end
end

function Service:serve(link, connection)
    local options = self.options
    connection:send({ role = "cell", v = common.VERSION, id = options.id, signing = options.signing, area = options.area or 0 })
    local reply, err = connection:receive(HELLO_TIMEOUT)
    if type(reply) == "table" and reply.waiting then
        link.state = "waiting"
        reply, err = connection:receive(WAIT_TIMEOUT)
    end
    if type(reply) == "table" and type(reply.error) == "string" then
        link.state, link.error = "refused", reply.error
        return
    end
    if type(reply) ~= "table" then return err or "The core didn't answer" end
    -- A core newer than we are: shown in the cell's status, in case they don't work together.
    link.newer = common.is_newer(reply.v) and reply.v or nil
    -- What the core says is broadcast, and used as a key. A cell may serve other networks too, which a core that
    -- says something unfit mustn't spoil.
    if not common.is_network(reply.network) or type(reply.certificate) ~= "string" or #reply.certificate > MAX_CERTIFICATE
        or type(reply.tunnel_key) ~= "string" or #reply.tunnel_key ~= 32 then
        link.state, link.error = "refused", "The core's answer can't be used"
        return
    end
    -- One core for each network.
    for _, other in ipairs(self.links) do
        if other ~= link and other.handle and other.network == reply.network then
            link.state, link.error = "refused", ("This cell serves %s through the core %s already"):format(reply.network, other.core)
            return
        end
    end

    -- The cell sends control messages from inside the network stack, where nothing may wait: queue them.
    local outbox, done = {}, false
    local handle = options.start_tower({
        network = reply.network, certificate = reply.certificate, tunnel_key = reply.tunnel_key,
        core = connection:getPeer(), area = options.area or 0,
    }, function(message)
        outbox[#outbox + 1] = message
        options.wake()
    end)
    link.handle, link.network, link.served, link.state = handle, reply.network, true, "serving"

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
            handle:control(message)
        end
    end)
    done = true
    link.handle = nil
    handle:stop()
    if not ok then error(failure, 0) end
    return reason
end

--[[- Describe the cell.

@treturn table Its `state`: `"connecting"`, `"waiting"` (for the core to allow it), `"serving"`, `"lost"` (it couldn't
reach the core, or lost it, and tries again in `retry` seconds) or `"refused"`; `error`, saying why; the `core`; the
`network` it serves; its `area`; its `id` and `fingerprint`, for allowing it on the core; and `links`, the same for each
core (`core`, `state`, `error`, `retry` and `network`), for a cell which serves several networks. The cell's own
`state` (and `core`, `network`, `error` and `retry`) is the best of its cores': serving if it serves any network.
]]
function Service:info()
    local options = self.options
    local links, best = {}, nil
    for i, link in ipairs(self.links) do
        links[i] = {
            core = link.core, state = link.state, error = link.error, retry = link.retry, network = link.network,
            newer = link.newer,
        }
        if not best or STATE_ORDER[link.state] < STATE_ORDER[best.state] then best = link end
    end
    best = best or {}
    return {
        state = best.state, error = best.error, retry = best.retry, core = best.core, network = best.network,
        area = options.area or 0, id = options.id, fingerprint = options.fingerprint(options.identity), links = links,
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
    for _, link in ipairs(self.links) do
        if link.handle then
            link.handle:stop()
            link.handle = nil
        end
        if link.connection then link.connection:abort() end
    end
end

return {
    new = new,
    FIRST_DELAY = FIRST_DELAY,
    MAX_DELAY = MAX_DELAY,
}
