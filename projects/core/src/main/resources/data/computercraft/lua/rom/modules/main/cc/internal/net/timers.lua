-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Timers for the network stack, kept in a heap by when they're due (and then the order they were set), so the next
is found at once, however many there are: each connection has a timer or two, and a busy computer has many.

A cancelled timer stays in the heap until it comes up, and is passed by then. If cancelled ones come to outnumber the
others, the heap is made again without them.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

@local
]]

local Timers = {}
Timers.__index = Timers

--- Make an empty set of timers.
--
-- @treturn table The timers.
local function new()
    return setmetatable({ heap = {}, live = 0, set = 0 }, Timers)
end

local function before(a, b)
    return a.time < b.time or (a.time == b.time and a.order < b.order)
end

local function up(heap, i)
    local item = heap[i]
    while i > 1 do
        local parent = math.floor(i / 2)
        if not before(item, heap[parent]) then break end
        heap[i] = heap[parent]
        i = parent
    end
    heap[i] = item
end

local function down(heap, i)
    local n, item = #heap, heap[i]
    while true do
        local child = i * 2
        if child > n then break end
        if child < n and before(heap[child + 1], heap[child]) then child = child + 1 end
        if not before(heap[child], item) then break end
        heap[i] = heap[child]
        i = child
    end
    heap[i] = item
end

local function pop(heap)
    local n = #heap
    local top, last = heap[1], heap[n]
    -- Not `heap[1], heap[n] = heap[n], nil`: with one timer left, the order those are assigned in matters.
    heap[n] = nil
    if n > 1 then
        heap[1] = last
        down(heap, 1)
    end
    return top
end

-- Make the heap again, without the timers which were cancelled.
local function rebuild(self)
    local heap = {}
    for _, timer in ipairs(self.heap) do
        if not timer.cancelled then heap[#heap + 1] = timer end
    end
    for i = math.floor(#heap / 2), 1, -1 do down(heap, i) end
    self.heap = heap
end

--- Add a timer.
--
-- @tparam number time When it's due.
-- @tparam function fn What to run then.
-- @treturn table The timer, to cancel it with.
function Timers:add(time, fn)
    self.set = self.set + 1
    local timer = { time = time, fn = fn, order = self.set }
    local heap = self.heap
    heap[#heap + 1] = timer
    up(heap, #heap)
    self.live = self.live + 1
    return timer
end

--- Cancel a timer, unless it has run already.
--
-- @tparam table timer The timer.
function Timers:cancel(timer)
    if timer.cancelled or timer.ran then return end
    timer.cancelled = true
    self.live = self.live - 1
    if #self.heap > 2 * self.live + 64 then rebuild(self) end
end

--- Get the timer due next, without taking it.
--
-- @treturn table|nil The timer, with its `time`, or `nil` if there's none.
function Timers:peek()
    local heap = self.heap
    while heap[1] and heap[1].cancelled do pop(heap) end
    return heap[1]
end

--- How many timers have been set so far: [`Timers:pop_due`] can leave those set after a point for later.
--
-- @treturn number How many.
function Timers:last_set()
    return self.set
end

--- Take the next timer which is due, if one is.
--
-- @tparam number now The time.
-- @tparam[opt] number last Only timers set up to this point (see [`Timers:last_set`]).
-- @treturn table|nil The timer, which is now taken (its `fn` is for the caller to run), or `nil`.
function Timers:pop_due(now, last)
    local top = self:peek()
    if not top or top.time > now or (last and top.order > last) then return nil end
    pop(self.heap)
    top.ran = true
    self.live = self.live - 1
    return top
end

--- Count the timers waiting to run.
--
-- @treturn number How many.
function Timers:count()
    return self.live
end

return {
    new = new,
}
