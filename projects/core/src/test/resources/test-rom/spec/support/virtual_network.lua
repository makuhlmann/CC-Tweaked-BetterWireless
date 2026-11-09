-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A virtual network for testing the network stack: one link, which every stack's interface "top" is on, and a clock
which only moves when told to.
]]

local Stack = require "cc.internal.net.stack"
local address = require "cc.net.address"

-- Modems hand each receiver its own copy of a message.
local function copy(value) return textutils.unserialise(textutils.serialise(value)) end

return function()
    local self = { time = 0, queue = {}, stacks = {}, errors = {} }

    --- Add a computer to the link.
    --
    -- @tparam number id The computer's ID.
    -- @tparam[opt] string addr Its address and prefix length, such as "10.0.0.1/24".
    -- @treturn table Its network stack.
    function self.add(id, addr)
        local stack
        stack = Stack.new {
            id = id,
            clock = function() return self.time end,
            transmit = function(_, channel, _, frame)
                table.insert(self.queue, { sender = stack, channel = channel, frame = copy(frame) })
            end,
            wake = function() end,
            log = function(err) table.insert(self.errors, err) end,
        }
        stack:add_interface("top", "top", "wired", "high")
        if addr then
            local parsed, prefix = address.parse(addr)
            stack:set_address("top", parsed, prefix)
        end
        table.insert(self.stacks, stack)
        return stack
    end

    --- Deliver frames until nobody sends anything more.
    function self.run()
        local count = 0
        while #self.queue > 0 do
            local item = table.remove(self.queue, 1)
            for _, stack in ipairs(self.stacks) do
                if stack ~= item.sender then stack:receive("top", item.channel, copy(item.frame)) end
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

    return self
end
