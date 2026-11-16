-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Services: programs which run in the background, each in a coroutine of its own, with a log of what it prints in
place of a terminal. The [`service`] API keeps one set of them, which the computer's background process runs, so they
keep running while the shell is used for other things.

Each service is a command, run as the shell would run it, from the root directory. What it prints goes to its log: an
invisible window as wide as the computer's screen, which keeps the last 100 lines. A service gets every event except
Ctrl+T, which is for whatever the user is running, and the computer's own keyboard and mouse, which a service has none
of: a service which reads input mustn't take the user's.

To stop a service, it gets a `terminate` event, as Ctrl+T would send, so it can close what it has open (a server's
socket, say) and finish. One which hasn't finished three seconds later is stopped anyway.

Starting and stopping happen in the background process: asking for either only says what's wanted, and wakes it. So
a service may stop itself (or the one it runs inside, as a remote shell may), with nothing resumed while it runs.

Some services run elsewhere, such as a cellular network's cell and core, which run in the network stack's background
process. These are given as `builtins`, each with functions to say what it's doing, and to start and stop it.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the [`service`] API instead.

@local
]]

local files = require "cc.internal.net.files"

--- How many lines of what a service prints are kept.
local LOG_LINES = 100

--- How long a service has to finish once told to stop, in seconds, before it's stopped anyway.
local STOP_GRACE = 3

--- The longest name a service may have.
local MAX_NAME = 32

-- The path when no shell has been given, as for the first shell.
local DEFAULT_PATH = ".:/rom/programs:/rom/programs/http:/rom/programs/net"

-- Events a service never gets. Ctrl+T is for whatever the user is running, and a service has no keyboard, mouse or
-- screen of its own.
local NOT_FOR_SERVICES = {
    terminate = true, key = true, key_up = true, char = true, paste = true, term_resize = true,
    mouse_click = true, mouse_drag = true, mouse_scroll = true, mouse_up = true,
}

--[[- Whether something is a service's name: letters, digits, `_`, `-` and `.`, up to 32 of them.

@param name The name.
@treturn boolean Whether it's a name.
]]
local function is_name(name)
    return type(name) == "string" and #name >= 1 and #name <= MAX_NAME and not name:find("[^%w_%-%.]")
end

--[[- Check a command: a program's path, and its arguments, all strings. An argument may have spaces, but not a `"`, as
the shell can't pass one on.

@param command The command.
@treturn string|nil What's wrong with it, if anything.
]]
local function check_command(command)
    if type(command) ~= "table" or type(command[1]) ~= "string" or command[1] == "" then
        return "A service's command is a program, and its arguments"
    end
    for i, word in pairs(command) do
        if type(i) ~= "number" or i < 1 or i > #command or i % 1 ~= 0 or type(word) ~= "string" then
            return "A service's command is a list of words"
        end
        if word:find('"', 1, true) then return "A service's command can't have a \" in it" end
    end
    return nil
end

local function copy(command)
    local result = {}
    for i = 1, #command do result[i] = command[i] end
    return result
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- A command's words as the shell reads them: those with spaces (or none at all) in quotes.
local function quoted(command)
    local words = {}
    for i, word in ipairs(command) do words[i] = (word == "" or word:find("%s")) and ('"' .. word .. '"') or word end
    return words
end

--[[- A command as one line, as the shell would read it: words with spaces in quotes.

@tparam { string... } command The command.
@treturn string The line.
]]
local function command_line(command)
    return table.concat(quoted(command), " ")
end

local Manager = {}
Manager.__index = Manager

--[[- Make a set of services, with those saved in a file.

@tparam {
    file = string, builtins? = table, run_program? = function, queue_event? = function, clock? = function,
    epoch? = function, start_timer? = function, cancel_timer? = function, width? = number,
} options The file the services are kept in; services which run elsewhere (each with `name`, `description`, `info`,
`start` and `stop`); and how to run a program (given the parent shell, and the command's words), queue an event, tell
the time and set timers, and how wide a log is, when not as the computer does.
@treturn table The services.
]]
local function new(options)
    local self = setmetatable({
        file = options.file,
        builtins = {},
        builtin_order = {},
        services = {},
        run_program = options.run_program or function(parent, ...)
            os.run({ shell = parent }, "/rom/programs/shell.lua", ...)
        end,
        queue_event = options.queue_event or os.queueEvent,
        clock = options.clock or os.clock,
        epoch = options.epoch or function() return os.epoch("utc") end,
        start_timer = options.start_timer or os.startTimer,
        cancel_timer = options.cancel_timer or os.cancelTimer,
        width = options.width or term.native().getSize(),
    }, Manager)

    for _, builtin in ipairs(options.builtins or {}) do
        self.builtins[builtin.name] = builtin
        self.builtin_order[#self.builtin_order + 1] = builtin.name
    end

    -- What the file says, if it makes sense: anything may have written it.
    for name, saved in pairs(files.read_table(self.file)) do
        if is_name(name) and not self.builtins[name] and type(saved) == "table" and not check_command(saved.command) then
            self.services[name] = {
                name = name, command = copy(saved.command), enabled = saved.enabled ~= false, state = "stopped",
            }
        end
    end
    return self
end

-- The services, by name, so they're always run in the same order.
function Manager:sorted()
    local names = {}
    for name in pairs(self.services) do names[#names + 1] = name end
    table.sort(names)
    local result = {}
    for i, name in ipairs(names) do result[i] = self.services[name] end
    return result
end

function Manager:save()
    local saved = {}
    for name, record in pairs(self.services) do
        if record.want ~= "remove" then saved[name] = { command = record.command, enabled = record.enabled } end
    end
    files.write_table(self.file, saved)
end

-- Wake the background process, to do what's been asked. One wake at a time is enough.
function Manager:wake()
    if self.wake_queued then return end
    self.wake_queued = true
    self.queue_event("service")
end

-- Say a service's state changed, for anyone waiting on it.
function Manager:changed(record)
    self.queue_event("service", record.name, record.state)
end

-- Write a line into a service's log, in a colour of its own.
function Manager:note(record, text, colour)
    local previous = term.redirect(record.log)
    local old = term.getTextColour()
    if term.isColour() then term.setTextColour(colour or colours.lightGrey) end
    print(text)
    term.setTextColour(old)
    term.redirect(previous)
end

-- The shell a service's own shell takes its path, aliases and completion from. Its directory is always the root.
function Manager:parent()
    local base = self.shell
    return {
        dir = function() return "" end,
        path = function() return base and base.path() or DEFAULT_PATH end,
        aliases = function() return base and base.aliases() or {} end,
        getCompletionInfo = function() return base and base.getCompletionInfo() or {} end,
    }
end

-- Run a service until it next waits, with what it draws going to its own terminal.
function Manager:step(record, ...)
    local previous = term.redirect(record.term)
    self.current = record.name
    local ok, result = coroutine.resume(record.co, ...)
    self.current = nil
    record.term = term.redirect(previous)

    if not ok then self:note(record, tostring(result), colours.red) end
    if not ok or coroutine.status(record.co) == "dead" then
        record.co, record.filter = nil, nil
        -- One which was told to stop has stopped; one which wasn't has exited by itself.
        record.state = record.terminated and "stopped" or "exited"
        record.ended = self.epoch()
        self:changed(record)
    else
        record.filter = result
    end
end

function Manager:spawn(record)
    local log = window.create(term.native(), 1, 1, self.width, LOG_LINES, false)
    record.log, record.term = log, log
    record.terminated, record.deadline, record.ended = nil, nil, nil
    record.state, record.started, record.fresh = "running", self.epoch(), true

    local parent, words = self:parent(), quoted(record.command)
    local run_program = self.run_program
    record.co = coroutine.create(function() run_program(parent, table.unpack(words)) end)
    self:changed(record)
    self:step(record)
end

-- Do what's been asked of each service: stop it (telling it to first), start it, or both.
function Manager:process()
    for _, record in ipairs(self:sorted()) do
        local want = record.want
        if want == "stop" or want == "restart" or want == "remove" then
            if record.co and not record.terminated then
                record.terminated, record.deadline, record.state = true, self.clock() + STOP_GRACE, "stopping"
                self:changed(record)
                self:step(record, "terminate")
            end
            if record.co and self.clock() >= record.deadline then
                self:note(record, "Stopped, as it didn't finish when told to stop.", colours.red)
                record.co, record.filter, record.state, record.ended = nil, nil, "stopped", self.epoch()
                self:changed(record)
            end
            if not record.co then
                record.terminated, record.deadline = nil, nil
                if want == "remove" then
                    self.services[record.name] = nil
                    record.want, record.state = nil, "removed"
                    self:changed(record)
                elseif want == "restart" then
                    record.want = "start"
                else
                    record.want = nil
                    if record.state ~= "stopped" then
                        record.state = "stopped"
                        self:changed(record)
                    end
                end
            end
        end
        if record.want == "start" then
            record.want = nil
            if not record.co then self:spawn(record) end
        end
    end

    -- One timer, for the first service which might not stop by itself.
    local first
    for _, record in pairs(self.services) do
        if record.co and record.deadline and (not first or record.deadline < first) then first = record.deadline end
    end
    if first and not self.timer then
        self.timer = self.start_timer(math.max(0, first - self.clock()))
    elseif not first and self.timer then
        self.cancel_timer(self.timer)
        self.timer = nil
    end
end

--[[- Pass an event to the services. This is what the background process does with each event.

@tparam string event The event's name.
@param ... Its arguments.
]]
function Manager:resume(event, ...)
    if event == "service" and select("#", ...) == 0 then self.wake_queued = false end
    if event == "timer" and ... == self.timer then self.timer = nil end

    self:process()
    if not NOT_FOR_SERVICES[event] then
        for _, record in ipairs(self:sorted()) do
            -- Those which just started have already run, and this event came before they did.
            if record.co and not record.fresh and (record.filter == nil or record.filter == event) then
                self:step(record, event, ...)
            end
        end
    end
    -- Anything asked for meanwhile is done now, not at the next event; and services started now get the next one.
    self:process()
    for _, record in pairs(self.services) do record.fresh = nil end
end

--[[- Start the services which start with the computer. Only the first time counts.

@tparam table|nil shell The shell services' own shells take their path, aliases and completion from.
]]
function Manager:boot(shell)
    if self.booted then return end
    self.booted, self.shell = true, shell
    for _, record in pairs(self.services) do
        if record.enabled and not record.co then record.want = "start" end
    end
    self:wake()
end

-- What a builtin service says it's doing, or nil if it isn't set up here (or can't say).
function Manager:builtin_info(builtin)
    local ok, info = pcall(builtin.info)
    if not ok or type(info) ~= "table" then return nil end
    return {
        name = builtin.name, description = builtin.description, hint = builtin.hint, builtin = true,
        state = info.running and "running" or "stopped", enabled = info.enabled == true, detail = info.detail,
    }
end

-- What a service is doing, for list and status.
function Manager:record_info(record)
    return {
        name = record.name, command = command_line(record.command), enabled = record.enabled, state = record.state,
        started = record.started, ended = record.ended,
    }
end

--[[- List the services: those added here, and those which run elsewhere and are set up on this computer.

@treturn { table... } What each is doing, by name.
]]
function Manager:list()
    local result = {}
    for _, record in ipairs(self:sorted()) do result[#result + 1] = self:record_info(record) end
    for _, name in ipairs(self.builtin_order) do
        local info = self:builtin_info(self.builtins[name])
        if info then result[#result + 1] = info end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

--[[- Say what one service is doing, with the lines of its log.

@tparam string name The service.
@treturn table|nil What it's doing, or nil if there's no such service.
]]
function Manager:status(name)
    local record = self.services[name]
    if record then
        local info = self:record_info(record)
        local lines, log = {}, record.log
        if log then
            local _, last = log.getCursorPos()
            for y = 1, math.min(last, LOG_LINES) do lines[y] = log.getLine(y):gsub("%s+$", "") end
            while lines[1] and lines[#lines] == "" do lines[#lines] = nil end
        end
        info.log = lines
        return info
    end
    local builtin = self.builtins[name]
    return builtin and self:builtin_info(builtin) or nil
end

--[[- Whether a service has done what was asked of it.

@tparam string name The service.
@treturn boolean Whether nothing's left to do.
]]
function Manager:settled(name)
    local record = self.services[name]
    return not record or (record.want == nil and record.state ~= "stopping")
end

-- Find a service, or say there isn't one.
function Manager:find(name)
    if self.services[name] then return self.services[name] end
    return nil, ("There's no service called %s"):format(tostring(name))
end

--[[- Add a service, or change the command of one, and start it (or start it again, with the new command). It starts
with the computer from now on.

@tparam string name The service's name.
@tparam { string... } command The program, and its arguments.
@treturn boolean|nil Whether it was added.
@treturn string|nil Why not.
]]
function Manager:add(name, command)
    if not is_name(name) then return nil, "A service's name is up to 32 letters, digits, _, - and ." end
    if self.builtins[name] then return nil, ("%s is a service of its own, which can't be changed"):format(name) end
    local err = check_command(command)
    if err then return nil, err end
    if not fs.exists(command[1]) or fs.isDir(command[1]) then return nil, ("There's no program %s"):format(command[1]) end

    local record = self.services[name]
    if not record then
        record = { name = name, state = "stopped" }
        self.services[name] = record
    end
    local changed = record.command and not same(record.command, command)
    record.command, record.enabled = copy(command), true
    if record.co and changed then
        record.want = "restart"
    elseif not record.co or record.want == "stop" or record.want == "remove" then
        record.want = record.co and "restart" or "start"
    end
    self:save()
    self:wake()
    return true
end

--[[- Stop a service, and forget it.

@tparam string name The service.
@treturn boolean|nil Whether there was one.
@treturn string|nil Why not.
]]
function Manager:remove(name)
    if self.builtins[name] then return nil, ("%s can't be removed, only stopped"):format(name) end
    local record, err = self:find(name)
    if not record then return nil, err end
    record.want = "remove"
    self:save()
    self:wake()
    return true
end

--[[- Start a service, and have it start with the computer.

@tparam string name The service.
@treturn boolean|nil Whether there's such a service.
@treturn string|nil Why not.
]]
function Manager:start(name)
    local builtin = self.builtins[name]
    if builtin and self:builtin_info(builtin) then return builtin.start() end
    local record, err = self:find(name)
    if not record then return nil, err end
    record.enabled = true
    if not record.co then
        record.want = "start"
    elseif record.want == "stop" then
        record.want = "restart"
    end
    self:save()
    self:wake()
    return true
end

--[[- Stop a service, and have it not start with the computer.

@tparam string name The service.
@treturn boolean|nil Whether there's such a service.
@treturn string|nil Why not.
]]
function Manager:stop(name)
    local builtin = self.builtins[name]
    if builtin and self:builtin_info(builtin) then return builtin.stop() end
    local record, err = self:find(name)
    if not record then return nil, err end
    record.enabled = false
    if record.co or record.want == "start" or record.want == "restart" then record.want = "stop" end
    self:save()
    self:wake()
    return true
end

--[[- Stop a service if it's running, and start it again. It starts with the computer from now on.

@tparam string name The service.
@treturn boolean|nil Whether there's such a service.
@treturn string|nil Why not.
]]
function Manager:restart(name)
    local builtin = self.builtins[name]
    if builtin and self:builtin_info(builtin) then
        local ok, err = builtin.stop()
        if not ok then return nil, err end
        return builtin.start()
    end
    local record, err = self:find(name)
    if not record then return nil, err end
    record.enabled = true
    record.want = (record.co or record.want == "start" or record.want == "restart") and "restart" or "start"
    self:save()
    self:wake()
    return true
end

return { new = new, is_name = is_name, command_line = command_line }
