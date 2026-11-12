-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Tasks which run side by side, each in a coroutine which waits for events as programs do. The network stack's
background process runs services this way, such as a cellular network's core, so they keep running while the shell is
used for other things.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local Tasks = {}
Tasks.__index = Tasks

--[[- Make an empty set of tasks.

@tparam[opt] function(err:string) on_error Called when a task fails. The task ends, and the others carry on.
@treturn table The tasks.
]]
local function new(on_error)
    return setmetatable({ list = {}, on_error = on_error or function(err) error(err, 0) end }, Tasks)
end

local function step(self, task, ...)
    local ok, filter = coroutine.resume(task.co, ...)
    if not ok then
        self.on_error(filter)
    else
        task.filter = filter
    end
end

--[[- Start a task. It runs until it first waits, before this returns.

@tparam function fn The task.
@param ... Its arguments.
]]
function Tasks:spawn(fn, ...)
    if self.stopped then return end
    local task = { co = coroutine.create(fn) }
    self.list[#self.list + 1] = task
    step(self, task, ...)
end

--[[- Pass an event to every task waiting for it. Tasks never see `terminate`: that's for whatever the user is running.

@tparam string|nil event The event's name. With `nil`, only tasks waiting for any event run.
@param ... The event's arguments.
]]
function Tasks:resume(event, ...)
    if event == "terminate" or self.stopped then return end
    local list = self.list
    -- Tasks started now have already run, so only resume those there were before.
    for i = 1, #list do
        local task = list[i]
        if self.stopped then return end
        if coroutine.status(task.co) == "suspended" and (task.filter == nil or task.filter == event) then
            step(self, task, event, ...)
        end
    end

    local alive = {}
    for _, task in ipairs(self.list) do
        if coroutine.status(task.co) ~= "dead" then alive[#alive + 1] = task end
    end
    self.list = alive
end

--[[- Send messages over a connection from a task of its own. A connection's `send` waits while the other side has no
room, and the code which sends (the network stack's, say) mustn't wait: so it queues them here instead.

@tparam table connection The connection.
@tparam function() wake Wakes the tasks, once there's something to send.
@treturn function(message:any) Queue a message. Once a send has failed, or sending has stopped, nothing more is sent.
@treturn function() Stop sending, once done with the connection.
]]
function Tasks:sender(connection, wake)
    local outbox, done = {}, false
    self:spawn(function()
        while not done do
            local message = table.remove(outbox, 1)
            if message ~= nil then
                if not connection:send(message) then done = true end
            else
                coroutine.yield()
            end
        end
    end)
    return function(message)
        if done then return end
        outbox[#outbox + 1] = message
        wake()
    end, function() done = true end
end

--- Stop every task. They don't run again, so anything they hold must be cleaned up by whoever stops them.
function Tasks:stop()
    self.stopped = true
    self.list = {}
end

--- Count the tasks still running. Only tests use this.
--
-- @treturn number How many.
function Tasks:count()
    local count = 0
    for _, task in ipairs(self.list) do
        if coroutine.status(task.co) ~= "dead" then count = count + 1 end
    end
    return count
end

return { new = new }
