-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A virtual network for testing the network stack: links between computers, and a clock which only moves when told
to.

Each link is a modem shared by every computer on it, and the interface on it is named after the link. Most tests only
need one link, "top", which [`add`] puts computers on.

Links can be slow (`latency[link]`, in seconds), vary in speed so frames arrive out of order (`jitter[link]`, up to
that many seconds more), lose frames (`loss[link]`, from 0 to 1) and deliver frames twice (`duplicate[link]`, from 0 to
1). The network counts frames sent on each link (`frames[link]`) and events each computer queues
(`wakes[stack][event]`), to measure floods.

Who hears a frame can depend on where computers are: `reach(link, sender, receiver)`, if set, gives the signal strength
a receiver hears a sender with, or `false` if it can't hear it at all. [`virtual_link`] joins two computers with
virtual interfaces instead of a modem.
]]

local Stack = require "cc.internal.net.stack"
local tcp = require "cc.internal.net.tcp"
local address = require "cc.net.address"

-- Modems hand each receiver its own copy of a message, as tables (even ones which contain themselves), strings, numbers
-- and booleans. Anything else becomes nil.
local function copy(value, seen)
    local kind = type(value)
    if kind ~= "table" then
        if kind == "function" or kind == "thread" or kind == "userdata" then return nil end
        return value
    end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for k, v in pairs(value) do
        k = copy(k, seen)
        if k ~= nil then result[k] = copy(v, seen) end
    end
    return result
end

return function()
    local self = {
        time = 0, queue = {}, stacks = {}, errors = {}, signals = {},
        latency = {}, jitter = {}, loss = {}, duplicate = {}, frames = {}, wakes = {},
        -- How many frames run() delivers, and how many steps advance() takes, before deciding something is looping.
        frame_limit = 1000, step_limit = 20000,
    }

    -- The queue is kept in order of arrival time.
    local function send(sender, link, channel, frame)
        self.frames[link] = (self.frames[link] or 0) + 1
        local copies = self.duplicate[link] and math.random() < self.duplicate[link] and 2 or 1
        for _ = 1, copies do
            local delay = (self.latency[link] or 0) + (self.jitter[link] and math.random() * self.jitter[link] or 0)
            local item = { sender = sender, link = link, channel = channel, frame = copy(frame), at = self.time + delay }
            local queue, position = self.queue, #self.queue + 1
            while position > 1 and queue[position - 1].at > item.at do position = position - 1 end
            table.insert(queue, position, item)
        end
    end

    local function yield()
        os.queueEvent("network_yield")
        os.pullEvent("network_yield")
    end

    --- Add a computer with no interfaces.
    --
    -- @tparam number id The computer's ID.
    -- @treturn table Its network stack.
    function self.stack(id)
        local stack, wakes = nil, {}
        stack = Stack.new {
            id = id,
            clock = function() return self.time end,
            epoch = function() return 1.7e12 + self.time * 1000 end,
            crypto = crypto,
            transmit = function(link, channel, _, frame) send(stack, link, channel, frame) end,
            wake = function(event) wakes[event] = (wakes[event] or 0) + 1 end,
            log = function(err) table.insert(self.errors, err) end,
        }
        -- Every computer takes connections, as with the net API.
        tcp.attach(stack)
        self.wakes[stack] = wakes
        table.insert(self.stacks, stack)
        return stack
    end

    --- Connect a computer to a link.
    --
    -- @tparam table stack The computer's network stack.
    -- @tparam string link The link's name, which is also the interface's.
    -- @tparam[opt] string addr Its address and prefix length on the link, such as "10.0.0.1/24".
    -- @tparam[opt="wired"] string kind The kind of interface. Wireless links deliver with the signal in `signals[link]`.
    function self.connect(stack, link, addr, kind)
        stack:add_interface(link, link, kind or "wired", "high")
        if addr then
            local parsed, prefix = address.parse(addr)
            stack:set_address(link, parsed, prefix)
        end
    end

    --- Take a computer off the network, as if it was broken.
    --
    -- @tparam table stack The computer's network stack.
    function self.remove(stack)
        for i, other in ipairs(self.stacks) do
            if other == stack then table.remove(self.stacks, i) end
        end
    end

    --- Add a computer to the link "top".
    --
    -- @tparam number id The computer's ID.
    -- @tparam[opt] string addr Its address and prefix length, such as "10.0.0.1/24".
    -- @treturn table Its network stack.
    function self.add(id, addr)
        local stack = self.stack(id)
        self.connect(stack, "top", addr)
        return stack
    end

    --[[- Join two computers with virtual interfaces (see `Stack:add_virtual_interface`), each named `name`. Packets
    sent on one are delivered to the other, through the same queue as frames.

    @tparam table a One computer's network stack.
    @tparam table b The other's.
    @tparam string name The interfaces' name.
    @tparam[opt] string a_address `a`'s address and prefix length.
    @tparam[opt] string b_address `b`'s.
    ]]
    function self.virtual_link(a, b, name, a_address, b_address)
        for _, pair in ipairs { { a, b, a_address }, { b, a, b_address } } do
            local from, to, addr = pair[1], pair[2], pair[3]
            from:add_virtual_interface(name, "virtual", function(packet)
                self.frames[name] = (self.frames[name] or 0) + 1
                local delay = self.latency[name] or 0
                local item = { sender = from, inject = to, name = name, frame = copy(packet), at = self.time + delay }
                local position = #self.queue + 1
                while position > 1 and self.queue[position - 1].at > item.at do position = position - 1 end
                table.insert(self.queue, position, item)
            end)
            if addr then
                local parsed, prefix = address.parse(addr)
                from:set_address(name, parsed, prefix)
            end
        end
    end

    --- Put a frame on a link from outside the network stack, as a misbehaving computer might.
    --
    -- @tparam string link The link.
    -- @tparam number channel The channel to send on.
    -- @param frame The frame, which may be anything.
    function self.inject(link, channel, frame)
        send(nil, link, channel, frame)
    end

    --- Deliver frames which have arrived, until nobody sends anything more.
    function self.run()
        local count = 0
        while self.queue[1] and self.queue[1].at <= self.time do
            local item = table.remove(self.queue, 1)

            if item.inject then
                -- A packet on a virtual link, unless the computer on the other end has gone.
                for _, stack in ipairs(self.stacks) do
                    if stack == item.inject then stack:inject(item.name, item.frame) end
                end
            elseif not (self.loss[item.link] and math.random() < self.loss[item.link]) then
                local receivers = {}
                local signals = {}
                for _, stack in ipairs(self.stacks) do
                    if stack ~= item.sender and stack.by_modem[item.link] then
                        -- Who hears what may depend on where they are.
                        local signal = self.signals[item.link]
                        if self.reach then signal = self.reach(item.link, item.sender, stack) end
                        if signal ~= false then
                            receivers[#receivers + 1] = stack
                            signals[#receivers] = signal
                        end
                    end
                end
                -- Each receiver gets its own copy, but a lone receiver can have the one made when it was sent.
                for i, stack in ipairs(receivers) do
                    local frame = #receivers == 1 and item.frame or copy(item.frame)
                    stack:receive(item.link, item.channel, frame, signals[i])
                end
            end

            count = count + 1
            if count > self.frame_limit then error("Network never went quiet", 2) end
            -- Big networks take a while to simulate, and computers which don't yield are stopped.
            if count % 100 == 0 then yield() end
        end
    end

    --- Let time pass, running any timers which are due, and delivering what they send.
    function self.advance(seconds)
        self.run()
        local target, steps, deadlines = self.time + seconds, 0, {}
        while true do
            local next = self.queue[1] and self.queue[1].at
            for i, stack in ipairs(self.stacks) do
                local deadline = stack:next_deadline()
                deadlines[i] = deadline
                if deadline and (not next or deadline < next) then next = deadline end
            end
            if not next or next > target then break end

            self.time = math.max(self.time, next)
            -- Only computers with something due need a tick. Copy the list, as a timer may remove a computer.
            local due = {}
            for i, stack in ipairs(self.stacks) do
                if deadlines[i] and deadlines[i] <= self.time then due[#due + 1] = stack end
            end
            for _, stack in ipairs(due) do stack:tick() end
            self.run()

            steps = steps + 1
            if steps > self.step_limit then error(("Timers never settled (at %.2f seconds)"):format(self.time), 2) end
            if steps % 100 == 0 then yield() end
        end
        self.time = target
    end

    --- Wait for something which finishes by calling a callback, letting up to `limit` seconds pass.
    --
    -- @tparam function(callback:function) start Starts the work.
    -- @tparam[opt=10] number limit The most time to let pass.
    -- @return Whatever the callback was called with.
    function self.await(start, limit)
        local results
        start(function(...) results = table.pack(...) end)
        local waited = 0
        while not results and waited < (limit or 10) do
            self.advance(0.5)
            waited = waited + 0.5
        end
        if not results then error("Callback was never called", 2) end
        return table.unpack(results, 1, results.n)
    end

    --- Send an echo request and wait for the answer, letting up to `limit` seconds pass.
    --
    -- @tparam table stack The computer sending it.
    -- @tparam number dst Where to send it.
    -- @tparam[opt] number ttl Its time to live.
    -- @tparam[opt=5] number limit The most time to let pass.
    -- @treturn table|nil The result (see `Stack:echo_result`), or `nil` if nothing came back.
    -- @treturn string|nil Why it couldn't be sent.
    function self.ping(stack, dst, ttl, limit)
        local id, err = stack:echo(dst, nil, ttl)
        if not id then return nil, err end
        self.run()
        local waited = 0
        while not stack:echo_result(id).done and waited < (limit or 5) do
            self.advance(0.25)
            waited = waited + 0.25
        end
        local result = stack:echo_result(id)
        stack:forget_echo(id)
        return result.done and result or nil
    end

    --- Count the frames sent on every link.
    --
    -- @treturn number The number of frames.
    function self.total_frames()
        local total = 0
        for _, count in pairs(self.frames) do total = total + count end
        return total
    end

    return self
end
