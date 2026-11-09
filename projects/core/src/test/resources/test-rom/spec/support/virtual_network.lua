-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A virtual network for testing the network stack: links between computers, and a clock which only moves when told
to.

Each link is a modem shared by every computer on it, and the interface on it is named after the link. Most tests only
need one link, "top", which [`add`] puts computers on.
]]

local Stack = require "cc.internal.net.stack"
local address = require "cc.net.address"

-- Modems hand each receiver its own copy of a message.
local function copy(value) return textutils.unserialise(textutils.serialise(value)) end

return function()
    local self = { time = 0, queue = {}, stacks = {}, errors = {}, signals = {} }

    --- Add a computer with no interfaces.
    --
    -- @tparam number id The computer's ID.
    -- @treturn table Its network stack.
    function self.stack(id)
        local stack
        stack = Stack.new {
            id = id,
            clock = function() return self.time end,
            transmit = function(link, channel, _, frame)
                table.insert(self.queue, { sender = stack, link = link, channel = channel, frame = copy(frame) })
            end,
            wake = function() end,
            log = function(err) table.insert(self.errors, err) end,
        }
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

    --- Deliver frames until nobody sends anything more.
    function self.run()
        local count = 0
        while #self.queue > 0 do
            local item = table.remove(self.queue, 1)
            for _, stack in ipairs(self.stacks) do
                if stack ~= item.sender and stack.by_modem[item.link] then
                    stack:receive(item.link, item.channel, copy(item.frame), self.signals[item.link])
                end
            end

            count = count + 1
            if count > 1000 then error("Network never went quiet", 2) end
        end
    end

    --- Let time pass, running any timers which are due, and delivering what they send.
    function self.advance(seconds)
        self.run()
        local target = self.time + seconds
        while true do
            local next
            for _, stack in ipairs(self.stacks) do
                local deadline = stack:next_deadline()
                if deadline and (not next or deadline < next) then next = deadline end
            end
            if not next or next > target then break end

            self.time = math.max(self.time, next)
            for _, stack in ipairs(self.stacks) do stack:tick() end
            self.run()
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
            self.advance(0.5)
            waited = waited + 0.5
        end
        local result = stack:echo_result(id)
        stack:forget_echo(id)
        return result.done and result or nil
    end

    return self
end
