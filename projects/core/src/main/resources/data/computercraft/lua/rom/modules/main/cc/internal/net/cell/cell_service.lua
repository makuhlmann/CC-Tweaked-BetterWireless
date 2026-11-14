-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell of a cellular network, run in the network stack's background process. It connects to the network's core,
waits for the core to allow it if it must, and then runs the cell. When it loses the core, it connects again, less often
each time.

A cell may serve several networks, connecting to each one's core (operators sharing a cell site): each connection is
kept on its own, and the cell serves each network while its core is there. Cores may be added and removed while it
runs, and what it says about itself changed, without disturbing the networks it serves.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `celld` program instead.

@local
]]

local tasks = require "cc.internal.net.tasks"
local bands = require "cc.internal.net.bands"
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
    core? = string, cores? = { string... }, area? = number, band? = string, interval? = number,
    pos? = { number, number, number }, service? = string, id = number,
    identity = string, fingerprint = function(key:string):string, signing = string, connect = function(core:string):table,
    start_tower = function(welcome:table, control:function):table,
    sleep = function(seconds:number), wake = function(),
} options The core's name or address, or the names or addresses of several (for a cell which serves several
networks); the cell's tracking area; the cellular band it should be on, if it matters; how often it sends system
information, if not as its core says; where it says it is, and `"sms"` if it only carries messages; this computer's ID
and its key (as hexadecimal digits), and a way to get a key's fingerprint; the cell's own Ed25519 key, as hexadecimal
digits, which each core certifies; a way to connect securely to a core's control port; a way to have the cell serve a
network, given what its core said (`network`, `certificate`, `tunnel_key`, `core`, `area`, the `carrier` and `ul`
channel the cell is on, the `interval`, whether it was set for this cell (`fixed_interval`) and what the core said
(`core_interval`), the network's `carriers`, and the cell's `pos` and `service`) and a function to send that core
control messages, which returns something to give the core's messages to (`control`), to stop serving the network with
(`stop`), and the cell's radio (`tower`, which `configure` changes); a way to wait; and a way to wake tasks waiting for
something to change. A cell is on one carrier, whichever network it serves: the first core it reaches picks it, and it
tells the others.
@treturn table The service. Pass it every event with `resume`.
]]
local function new(options)
    local self = setmetatable({ options = options, links = {} }, Service)
    self.tasks = tasks.new(function(err) self.error = tostring(err) end)
    for _, core in ipairs(options.cores or { options.core }) do self:add_core(core) end
    return self
end

--[[- Serve another core's network too, connecting to it now. The networks the cell serves already carry on as they
were.

@tparam string core The core's name or address.
@treturn boolean Whether it was added: false if the cell connects to it already.
]]
function Service:add_core(core)
    for _, link in ipairs(self.links) do
        if link.core == core then return false end
    end
    local link = { core = core, state = "connecting" }
    self.links[#self.links + 1] = link
    if not self.stopped then self.tasks:spawn(function() self:run(link) end) end
    return true
end

--[[- Stop serving a core's network, and stop connecting to it. Its phones here lose service, and find another cell;
the other networks' carry on. Removing the last network the cell serves takes it off the air.

@tparam string core The core's name or address, as it was added.
@treturn boolean Whether it was removed: false if the cell doesn't connect to it.
]]
function Service:remove_core(core)
    for i, link in ipairs(self.links) do
        if link.core == core then
            table.remove(self.links, i)
            link.removed = true
            if link.handle then
                link.handle:stop()
                link.handle = nil
            end
            if link.connection then link.connection:abort() end
            return true
        end
    end
    return false
end

-- Keep a core connected: connect, serve its network, and connect again once it's lost, less often each time.
function Service:run(link)
    local delay = FIRST_DELAY
    while not self.stopped and not link.removed do
        link.state, link.error = "connecting", nil
        local connected, connection, err = pcall(self.options.connect, link.core)
        if not connected then connection, err = nil, tostring(connection) end
        -- Removed while connecting: there's nothing to serve.
        if connection and (self.stopped or link.removed) then
            connection:abort()
            return
        end
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
        if self.stopped or link.removed then return end
        link.retry = delay
        self.options.sleep(delay)
        delay = math.min(delay * 2, MAX_DELAY)
    end
end

-- The carrier the cell is on, and its uplink channel there, if it serves a network now. Every network it serves is
-- served on the same one.
function Service:radio()
    for _, other in ipairs(self.links) do
        local tower = other.handle and other.handle.tower
        if tower and not tower.stopped then return tower.carrier, tower.ul end
    end
end

function Service:serve(link, connection)
    local options = self.options
    local carrier, ul = self:radio()
    connection:send({
        role = "cell", v = common.VERSION, id = options.id, signing = options.signing, area = options.area or 0,
        band = options.band, carrier = carrier, ul = ul,
    })
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
        or type(reply.tunnel_key) ~= "string" or #reply.tunnel_key ~= 32 or not common.is_id(reply.carrier)
        or not bands.carrier(reply.carrier) or not common.is_uplink(reply.ul) or bands.carrier_of(reply.ul) ~= reply.carrier
        or not common.is_interval(reply.interval) or not common.is_carriers(reply.carriers) then
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
    local send, stop_sending = self.tasks:sender(connection, options.wake)
    -- On the carrier we're on already, if we serve another network. (That core picked it, and this one was told.)
    carrier, ul = self:radio()
    local interval = common.is_interval(options.interval) and options.interval or nil
    local handle = options.start_tower({
        network = reply.network, certificate = reply.certificate, tunnel_key = reply.tunnel_key,
        core = connection:getPeer(), area = options.area or 0,
        carrier = carrier or reply.carrier, ul = ul or reply.ul, interval = interval or reply.interval,
        fixed_interval = interval ~= nil, core_interval = reply.interval, carriers = reply.carriers,
        pos = options.pos, service = options.service,
    }, send)
    link.handle, link.network, link.served, link.state = handle, reply.network, true, "serving"
    link.carriers = reply.carriers

    local reason
    local ok, failure = pcall(function()
        while true do
            local message, receive_err = connection:receive()
            if message == nil then
                reason = receive_err or "The core closed the connection"
                break
            end
            -- The network's carriers, which its administrator may change: a band the cell is asked to go on must be
            -- one of them.
            if type(message) == "table" and message.op == "carriers" and common.is_carriers(message.carriers)
                and message.carriers[1] then
                link.carriers = message.carriers
            end
            handle:control(message)
        end
    end)
    stop_sending()
    link.handle, link.carriers = nil, nil
    handle:stop()
    if not ok then error(failure, 0) end
    return reason
end

--[[- Change the cell's settings. What it says about itself (where it is, whether it only carries messages, and how
often it sends system information) changes on the air at once, and its phones keep their service. The band and area are
only said to a core when the cell connects to it.

@tparam {
    area? = number, band? = string, interval? = number, pos? = { number, number, number }, service? = string,
} settings Every setting, as `new` takes them: one which is missing is unset.
]]
function Service:configure(settings)
    local options = self.options
    options.area, options.band, options.interval = settings.area, settings.band, settings.interval
    options.pos, options.service = settings.pos, settings.service
    local done = {}
    for _, link in ipairs(self.links) do
        local tower = link.handle and link.handle.tower
        if tower and not done[tower] then
            done[tower] = true
            tower:configure { interval = options.interval, pos = options.pos, service = options.service }
        end
    end
end

--[[- The bands the networks the cell serves have carriers in, as their cores said.

@treturn { [string] = true }|nil Each band, by name, or `nil` if the cell serves no network now.
]]
function Service:bands()
    local result
    for _, link in ipairs(self.links) do
        if link.handle and link.carriers then
            result = result or {}
            for _, carrier in ipairs(link.carriers) do
                local _, band = bands.carrier_of(carrier)
                if band then result[band] = true end
            end
        end
    end
    return result
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
    local carrier, ul = self:radio()
    return {
        state = best.state, error = best.error, retry = best.retry, core = best.core, network = best.network,
        area = options.area or 0, id = options.id, fingerprint = options.fingerprint(options.identity), links = links,
        carrier = carrier and bands.carrier_name(carrier), ul = ul, band = options.band,
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
