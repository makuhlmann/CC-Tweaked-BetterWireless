-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Things remembered for a while: until there are too many, when the oldest are forgotten first, and (if they have a
lifetime) until they're too old.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code.

What others send can make us remember things (messages seen, phones heard from, networks which turned us away), so
anything we keep for them must have a limit. This is that limit, in one place.

@local
]]

local Recent = {}
Recent.__index = Recent

--[[- Make a store of things remembered for a while.

@tparam number max How many to remember at most. Adding one more forgets the oldest.
@tparam[opt] number lifetime How long to remember each, in seconds, from when it was last added.
@tparam[opt] function():number clock The time, in seconds. Needed with a lifetime.
@treturn table The store.
]]
local function new(max, lifetime, clock)
    if lifetime and not clock then error("A lifetime needs a clock", 2) end
    return setmetatable({
        max = max, lifetime = lifetime, clock = clock,
        -- Each entry, by key: { value, time, seq }. Keys in the order they were added, by seq, from first to last;
        -- slots whose entry was added again or removed since are skipped.
        entries = {}, order = {}, first = 1, last = 0, size = 0,
    }, Recent)
end

-- Forget the oldest entry.
local function drop_oldest(self)
    while self.first <= self.last do
        local seq = self.first
        local key = self.order[seq]
        self.order[seq], self.first = nil, seq + 1
        local entry = self.entries[key]
        if entry and entry.seq == seq then
            self.entries[key], self.size = nil, self.size - 1
            return
        end
    end
end

-- Forget entries which are too old. They're the oldest, so the first in order.
local function expire(self)
    if not self.lifetime then return end
    local now = self.clock()
    while self.first <= self.last do
        local seq = self.first
        local key = self.order[seq]
        local entry = key ~= nil and self.entries[key]
        if entry and entry.seq == seq then
            if now - entry.time < self.lifetime then return end
            self.entries[key], self.size = nil, self.size - 1
        end
        self.order[seq], self.first = nil, seq + 1
    end
end

-- Number the entries afresh, without the slots in the order which are skipped: something added again and again
-- leaves one behind each time.
local function compact(self)
    local live = {}
    for seq = self.first, self.last do
        local key = self.order[seq]
        local entry = key ~= nil and self.entries[key]
        if entry and entry.seq == seq then live[#live + 1] = key end
    end
    self.order, self.first, self.last = {}, 1, #live
    for seq, key in ipairs(live) do
        self.order[seq] = key
        self.entries[key].seq = seq
    end
end

--- Remember something, or remember it afresh: it's the newest now.
--
-- @param key What to remember it by.
-- @param[opt=true] value What to remember.
function Recent:add(key, value)
    if value == nil then value = true end
    local old = self.entries[key]
    if not old then self.size = self.size + 1 end
    self.last = self.last + 1
    self.order[self.last] = key
    self.entries[key] = { value = value, time = self.clock and self.clock() or 0, seq = self.last }
    while self.size > self.max do drop_oldest(self) end
    if self.last - self.first + 1 > 2 * self.max + 16 then compact(self) end
end

--- Get what's remembered by a key, if it's still remembered.
--
-- @param key The key.
-- @return The value, or `nil`.
function Recent:get(key)
    local entry = self.entries[key]
    if not entry then return nil end
    if self.lifetime and self.clock() - entry.time >= self.lifetime then
        expire(self)
        return nil
    end
    return entry.value
end

--- Forget something.
--
-- @param key The key.
-- @treturn boolean Whether it was remembered.
function Recent:remove(key)
    if not self.entries[key] then return false end
    -- Its slot in the order is skipped when it comes up.
    self.entries[key], self.size = nil, self.size - 1
    return true
end

--- Count what's still remembered.
--
-- @treturn number How many.
function Recent:count()
    expire(self)
    return self.size
end

--- Go through what's still remembered, in no particular order. Removing what's been given is fine.
--
-- @treturn function An iterator, giving each key and value.
function Recent:each()
    expire(self)
    local entries, key = self.entries, nil
    return function()
        local entry
        key, entry = next(entries, key)
        if key == nil then return nil end
        return key, entry.value
    end
end

return {
    new = new,
}
