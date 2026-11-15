-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A cell of a cellular network, run in the network stack's background process. It connects to the network's core,
waits for the core to allow it if it must, and then runs the cell. When it loses the core, it connects again, less often
each time.

A cell may serve several networks, connecting to each one's core (operators sharing a cell site): each connection is
kept on its own, and the cell serves each network while its core is there. Cores may be added and removed while it
runs, and what it says about itself changed, without disturbing the networks it serves.

The computer may run several cells, each on a carrier of its own (a cell site with several bands, say): it tells its
cores which bands or carriers it wants, and the first core it reaches puts a cell on each. They share the connection to
each core, whose messages say which cell they're about, and every network the computer serves is on every one of its
cells that network's core knows of.

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

-- What the computer wants its cells on: a list of bands and carriers, or `nil` for one cell on any carrier.
local function wanted(band)
    if type(band) == "string" then band = { band } end
    return common.is_wants(band) and band or nil
end

-- Stop serving a core's network on each of the computer's cells.
local function stop_cells(link)
    local cells = link.cells
    link.cells, link.handle = nil, nil
    for _, cell in ipairs(cells or {}) do cell.handle:stop() end
end

--[[- Start a cell.

@tparam {
    core? = string, cores? = { string... }, area? = number, band? = string|{ string... }, interval? = number,
    pos? = { number, number, number }, service? = string, id = number,
    identity = string, fingerprint = function(key:string):string, signing = string, connect = function(core:string):table,
    start_tower = function(welcome:table, control:function):table,
    sleep = function(seconds:number), wake = function(),
} options The core's name or address, or the names or addresses of several (for a cell which serves several
networks); the cell's tracking area; the cellular band it should be on, if it matters, or a list of bands and carriers
(`"b20"`, `"b3/2"`) for a cell on each; how often it sends system
information, if not as its core says; where it says it is, and `"sms"` if it only carries messages; this computer's ID
and its key (as hexadecimal digits), and a way to get a key's fingerprint; the cell's own Ed25519 key, as hexadecimal
digits, which each core certifies; a way to connect securely to a core's control port; a way to have the cell serve a
network, given what its core said (the cell's `id`, `network`, `certificate`, `tunnel_key`, `core`, `area`, the `carrier`
and `ul` channel the cell is on, the `interval`, whether it was set for this cell (`fixed_interval`) and what the core said
(`core_interval`), the network's `carriers`, and the cell's `pos` and `service`) and a function to send that core
control messages, which returns something to give the core's messages to (`control`), to stop serving the network with
(`stop`), and the cell's radio (`tower`, which `configure` changes); a way to wait; and a way to wake tasks waiting for
something to change. A cell is on one carrier, whichever network it serves: the first core it reaches picks it, and it
tells the others. With several cells, the way to serve a network is used once for each.
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
            stop_cells(link)
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
        if link.again then
            -- We hung up ourselves, to tell this core of the computer's new cells: connect again at once.
            link.again = nil
        else
            link.retry = delay
            self.options.sleep(delay)
            delay = math.min(delay * 2, MAX_DELAY)
        end
    end
end

--[[- The cells the computer runs now, for any network: each on a carrier of its own. Every network the computer serves
is served on them.

@treturn { { id = number, carrier = number, ul = number }... } Each cell's ID, its carrier (by its beacon channel) and
its uplink channel there: the computer's first cell, which has the computer's ID, first.
]]
function Service:radio()
    local cells, seen = {}, {}
    for _, link in ipairs(self.links) do
        for _, cell in ipairs(link.cells or {}) do
            local tower = cell.handle.tower
            if tower and not tower.stopped and not seen[cell.id] then
                seen[cell.id] = true
                cells[#cells + 1] = { id = cell.id, carrier = tower.carrier, ul = tower.ul }
            end
        end
    end
    table.sort(cells, function(a, b) return a.id < b.id end)
    return cells
end

--[[- Read the cells a core gave the computer, in its answer: one, from a core which knows of no more.

@tparam table reply The core's answer.
@treturn { { id = number, carrier = number, ul = number, certificate = string, tunnel_key = string }... }|nil The
cells, or `nil` if they can't be used.
]]
function Service:read_cells(reply)
    local id = self.options.id
    local function usable(cell)
        return type(cell) == "table" and type(cell.certificate) == "string" and #cell.certificate <= MAX_CERTIFICATE
            and type(cell.tunnel_key) == "string" and #cell.tunnel_key == 32 and common.is_id(cell.carrier)
            and bands.carrier(cell.carrier) ~= nil and common.is_uplink(cell.ul) and bands.carrier_of(cell.ul) == cell.carrier
    end
    if not usable(reply) then return nil end
    local first = {
        id = id, carrier = reply.carrier, ul = reply.ul, certificate = reply.certificate, tunnel_key = reply.tunnel_key,
    }
    if reply.cells == nil then return { first } end
    if type(reply.cells) ~= "table" or #reply.cells < 1 or #reply.cells > common.MAX_CARRIERS then return nil end

    local cells, seen = {}, {}
    for i = 1, #reply.cells do
        local cell = reply.cells[i]
        -- Each cell's ID is the one its carrier gives it, and the first is the computer's.
        if not usable(cell) or seen[cell.carrier]
            or cell.id ~= (i == 1 and id or common.carrier_cell(id, cell.carrier)) then
            return nil
        end
        seen[cell.carrier] = true
        cells[i] = {
            id = cell.id, carrier = cell.carrier, ul = cell.ul, certificate = cell.certificate, tunnel_key = cell.tunnel_key,
        }
    end
    return cells
end

--[[- Choose which of the cells a core gave the computer to serve its network on: those the computer runs already (on
the channels they're on, whatever this core says), and new ones which answer what the computer wants and has no cell
for yet.

@tparam { table... } given The cells the core gave, as [`Service:read_cells`] read them.
@treturn { table... } The cells to serve the network on.
@treturn boolean Whether any of them is new.
]]
function Service:choose_cells(given)
    local running = self:radio()
    local by_id, carriers = {}, {}
    for i, cell in ipairs(running) do by_id[cell.id], carriers[i] = cell, cell.carrier end
    local wants = wanted(self.options.band)

    -- Whether to start a cell the computer doesn't run yet. Its first goes where the core says, as it always did. A
    -- further one must answer something the computer wants, which the cells before it don't.
    local function may_start(cell)
        if not carriers[1] then return cell.id == self.options.id end
        if not wants or #carriers >= common.MAX_CARRIERS then return false end
        for _, carrier in ipairs(carriers) do
            if carrier == cell.carrier then return false end
        end
        local answered, rest = common.match_wants(wants, carriers), {}
        for i, want in ipairs(wants) do
            if not answered[i] then rest[#rest + 1] = want end
        end
        return next((common.match_wants(rest, { cell.carrier }))) ~= nil
    end

    local chosen, new = {}, false
    for _, cell in ipairs(given) do
        local now = by_id[cell.id]
        if now then
            cell.carrier, cell.ul = now.carrier or cell.carrier, now.ul or cell.ul
            chosen[#chosen + 1] = cell
        elseif may_start(cell) then
            carriers[#carriers + 1] = cell.carrier
            chosen[#chosen + 1], new = cell, true
        end
    end
    return chosen, new
end

function Service:serve(link, connection)
    local options = self.options
    local running, wants = self:radio(), wanted(options.band)
    -- What the computer wants: one band, as a cell always said it, or more (several, or a carrier by name), which a
    -- core which knows of them goes by instead. And the cells it runs already: the first, as a cell always said it.
    local hello = {
        role = "cell", v = common.VERSION, id = options.id, signing = options.signing, area = options.area or 0,
        band = wants and wants[1]:match("^[^/]+"), carrier = running[1] and running[1].carrier, ul = running[1] and running[1].ul,
    }
    if wants and (wants[2] or common.want_carrier(wants[1])) then hello.bands = wants end
    if running[2] then
        hello.cells = {}
        for i, cell in ipairs(running) do hello.cells[i] = { carrier = cell.carrier, ul = cell.ul } end
    end
    connection:send(hello)
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
    local given = common.is_network(reply.network) and common.is_interval(reply.interval)
        and common.is_carriers(reply.carriers) and self:read_cells(reply)
    if not given then
        link.state, link.error = "refused", "The core's answer can't be used"
        return
    end
    -- One core for each network.
    for _, other in ipairs(self.links) do
        if other ~= link and other.cells and other.network == reply.network then
            link.state, link.error = "refused", ("This cell serves %s through the core %s already"):format(reply.network, other.core)
            return
        end
    end

    -- On the carriers we're on already, if we serve another network. (That core picked them, and this one was told.)
    local chosen, new = self:choose_cells(given)
    if not chosen[1] then
        link.state, link.error = "refused", "The core's answer can't be used"
        return
    end
    -- The cell sends control messages from inside the network stack, where nothing may wait: queue them.
    local send, stop_sending = self.tasks:sender(connection, options.wake)
    local interval = common.is_interval(options.interval) and options.interval or nil
    local cells, handles = {}, {}
    link.cells = cells
    local started, start_error = pcall(function()
        for i, cell in ipairs(chosen) do
            -- Messages about the computer's further cells say which. Its first cell's needn't: a core which knows of
            -- one cell knows of that one.
            local id, to_core = cell.id, send
            if id ~= options.id then
                to_core = function(message)
                    message.at = id
                    return send(message)
                end
            end
            local handle = options.start_tower({
                id = id, network = reply.network, certificate = cell.certificate, tunnel_key = cell.tunnel_key,
                core = connection:getPeer(), area = options.area or 0,
                carrier = cell.carrier, ul = cell.ul, interval = interval or reply.interval,
                fixed_interval = interval ~= nil, core_interval = reply.interval, carriers = reply.carriers,
                pos = options.pos, service = options.service,
            }, to_core)
            cells[i] = { id = id, handle = handle }
            handles[id] = handle
        end
    end)
    if not started then
        stop_sending()
        stop_cells(link)
        error(start_error, 0)
    end
    link.handle, link.network, link.served, link.state = cells[1].handle, reply.network, true, "serving"
    link.carriers = reply.carriers
    -- What the core has no carrier for, to show; and whether it knows a computer may run several cells.
    link.unplaced = type(reply.unplaced) == "table" and common.is_wants(reply.unplaced) and reply.unplaced or nil
    link.many = reply.cells ~= nil
    -- The computer has cells this core's network alone is on now. The other cores' networks belong on them too: those
    -- cores hear of them when the computer connects again, which it does at once.
    if new and #cells > 1 then
        for _, other in ipairs(self.links) do
            if other ~= link and other.cells and other.many and #other.cells < #self:radio() and other.connection then
                other.again = true
                other.connection:abort()
            end
        end
    end

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
            -- Which of the computer's cells it's about: the first, unless it says.
            local at = type(message) == "table" and message.at
            if at == nil then at = options.id end
            local handle = handles[at]
            if handle then handle:control(message) end
        end
    end)
    stop_sending()
    link.carriers, link.unplaced = nil, nil
    stop_cells(link)
    if not ok then error(failure, 0) end
    return reason
end

--[[- Change the cell's settings. What it says about itself (where it is, whether it only carries messages, and how
often it sends system information) changes on the air at once, and its phones keep their service. The band and area are
only said to a core when the cell connects to it.

@tparam {
    area? = number, band? = string|{ string... }, interval? = number, pos? = { number, number, number },
    service? = string,
} settings Every setting, as `new` takes them: one which is missing is unset.
]]
function Service:configure(settings)
    local options = self.options
    options.area, options.band, options.interval = settings.area, settings.band, settings.interval
    options.pos, options.service = settings.pos, settings.service
    local done = {}
    for _, link in ipairs(self.links) do
        for _, cell in ipairs(link.cells or {}) do
            local tower = cell.handle.tower
            if tower and not done[tower] then
                done[tower] = true
                tower:configure { interval = options.interval, pos = options.pos, service = options.service }
            end
        end
    end
end

--[[- The bands the networks the cell serves have carriers in, as their cores said.

@treturn { [string] = true }|nil Each band, by name, or `nil` if the cell serves no network now.
]]
function Service:bands()
    local result
    for _, link in ipairs(self.links) do
        if link.cells and link.carriers then
            result = result or {}
            for _, carrier in ipairs(link.carriers) do
                local _, band = bands.carrier_of(carrier)
                if band then result[band] = true end
            end
        end
    end
    return result
end

--[[- What of a list of bands and carriers no network the cell serves could give it: a band none has a carrier in (or
enough carriers, for a band which comes several times), or a carrier none uses.

@tparam { string... } wants The bands and carriers, as `new` takes them.
@treturn string|nil The first which no network has, or `nil` if each has one (or the cell serves no network now, so
there's no telling).
]]
function Service:unplaceable(wants)
    local serving, placed = false, {}
    for _, link in ipairs(self.links) do
        if link.cells and link.carriers then
            serving = true
            for i in pairs(common.match_wants(wants, link.carriers)) do placed[i] = true end
        end
    end
    if not serving then return nil end
    for i, want in ipairs(wants) do
        if not placed[i] then return want end
    end
    return nil
end

--[[- Describe the cell.

@treturn table Its `state`: `"connecting"`, `"waiting"` (for the core to allow it), `"serving"`, `"lost"` (it couldn't
reach the core, or lost it, and tries again in `retry` seconds) or `"refused"`; `error`, saying why; the `core`; the
`network` it serves; its `area`; its `id` and `fingerprint`, for allowing it on the core; and `links`, the same for each
core (`core`, `state`, `error`, `retry` and `network`), for a cell which serves several networks. The cell's own
`state` (and `core`, `network`, `error` and `retry`) is the best of its cores': serving if it serves any network.
While it serves one, `carrier` and `ul` say where its first cell is, and `cells` where each is (`id`, `carrier` and
`ul`); a core's `unplaced` lists what the cell wants which that core's network has no carrier for.
]]
function Service:info()
    local options = self.options
    local links, best = {}, nil
    for i, link in ipairs(self.links) do
        links[i] = {
            core = link.core, state = link.state, error = link.error, retry = link.retry, network = link.network,
            newer = link.newer, unplaced = link.cells and link.unplaced or nil,
        }
        if not best or STATE_ORDER[link.state] < STATE_ORDER[best.state] then best = link end
    end
    best = best or {}
    local cells = self:radio()
    for _, cell in ipairs(cells) do cell.carrier = cell.carrier and bands.carrier_name(cell.carrier) end
    return {
        state = best.state, error = best.error, retry = best.retry, core = best.core, network = best.network,
        area = options.area or 0, id = options.id, fingerprint = options.fingerprint(options.identity), links = links,
        carrier = cells[1] and cells[1].carrier, ul = cells[1] and cells[1].ul, band = options.band,
        cells = cells[1] and cells or nil,
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
        stop_cells(link)
        if link.connection then link.connection:abort() end
    end
end

return {
    new = new,
    FIRST_DELAY = FIRST_DELAY,
    MAX_DELAY = MAX_DELAY,
}
