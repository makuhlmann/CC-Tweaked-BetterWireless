-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What the network stack's specs have in common: addresses and keys written out, the odd values to feed what's being
tested, and ways to let time pass on a virtual network (`support.virtual_network`) while things wait for each other.
]]

local address = require "cc.net.address"
local codec = require "cc.net.codec"
local yield = require "support.yield"

local helpers = { yield = yield }

--- An address, from text such as "10.0.0.1".
function helpers.ip(text) return (address.parse(text)) end

--- Bytes as hexadecimal digits, and back.
function helpers.hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
function helpers.unhex(text) return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)) end

--- A copy of a value, as a message has it once it has been sent.
function helpers.copy(value) return codec.decode(codec.encode(value)) end

--- How many entries a table has.
function helpers.count(list)
    local total = 0
    for _ in pairs(list) do total = total + 1 end
    return total
end

--- Stands for nil among odd values, which a table can't hold.
helpers.NIL = {}

--- A copy of a table with one field replaced (or taken away, with `NIL`).
function helpers.with(template, key, value)
    local result = {}
    for k, v in pairs(template) do result[k] = v end
    if value == helpers.NIL then result[key] = nil else result[key] = value end
    return result
end

--- A table which contains itself, which can't be sent.
helpers.RECURSIVE = {}
helpers.RECURSIVE.self = helpers.RECURSIVE

--[[- Values which a field mustn't be taken to be, each with a name to say which it was: the wrong kind of value, a number
which isn't a whole one, or is too big or too small, a table which contains itself, and a string which is far too long.

@param ... More, as `{ name, value }`.
@treturn { { string, any }... } The values.
]]
function helpers.bad_values(...)
    local values = {
        { "nil", helpers.NIL }, { "NaN", 0 / 0 }, { "inf", math.huge }, { "-inf", -math.huge }, { "1e18", 1e18 },
        { "-1", -1 }, { "0.5", 0.5 }, { "2^32", 2 ^ 32 }, { "a string", "x" }, { "a table", {} }, { "true", true },
        { "a recursive table", helpers.RECURSIVE }, { "a long string", ("y"):rep(5000) },
    }
    for _, value in ipairs({ ... }) do values[#values + 1] = value end
    return values
end

--- Whether a computer on a virtual network gets an answer from the server, at 10.0.0.60.
function helpers.reaches_server(net, stack)
    local result = net.ping(stack, helpers.ip("10.0.0.60"), nil, 1)
    return result ~= nil and result.error == nil
end

--- Let time pass on a virtual network, a little at a time, until something is true, or fail once `limit` seconds have.
function helpers.wait_until(net, test, limit, what)
    local deadline = net.time + (limit or 30)
    while net.time < deadline do
        if test() then return end
        net.advance(0.1)
        yield()
    end
    error(("%s didn't happen within %d seconds"):format(what or "Something", limit or 30), 2)
end

--[[- Run functions side by side, letting time pass on a virtual network, until they've all finished. They wait by
yielding.

@treturn { table... } What each returned, packed.
@treturn number How many seconds passed.
]]
function helpers.run(net, functions, limit)
    local threads, results = {}, {}
    for i, fn in ipairs(functions) do
        threads[i] = coroutine.create(function() results[i] = table.pack(fn()) end)
    end
    local elapsed = 0
    while true do
        local alive = false
        for _, thread in ipairs(threads) do
            if coroutine.status(thread) ~= "dead" then
                local ok, err = coroutine.resume(thread)
                if not ok then error(err, 0) end
                if coroutine.status(thread) ~= "dead" then alive = true end
            end
        end
        if not alive then return results, elapsed end
        net.advance(0.05)
        elapsed = elapsed + 0.05
        if elapsed > (limit or 300) then error(("Still running after %d seconds"):format(elapsed), 0) end
    end
end

--- A TCP connection whose `send` and `receive` wait (by yielding), as the net API's do.
function helpers.blocking(net, connection)
    return {
        connection = connection,
        send = function(_, value)
            while true do
                local ok, err = connection:send(value)
                if ok then return true end
                if err ~= "Full" then return nil, err end
                coroutine.yield()
            end
        end,
        receive = function(_, timeout)
            local started = net.time
            while true do
                local ok, value = connection:take()
                if ok then return value end
                if value == "closed" then return nil end
                if value then return nil, value end
                if timeout and net.time - started >= timeout then return nil, "Timed out" end
                coroutine.yield()
            end
        end,
        close = function() connection:close() end,
        abort = function() connection:abort() end,
    }
end

--- Send everything a computer doesn't know a better way for to a router.
function helpers.default_route(stack, gateway)
    stack:add_route { network = 0, prefix = 0, gateway = helpers.ip(gateway), source = "static" }
end

--- A router on a virtual network, on each of `links` (a link, an address and a kind, as `connect` takes them).
function helpers.router(net, id, links)
    local stack = net.stack(id)
    for _, link in ipairs(links) do net.connect(stack, link[1], link[2], link[3]) end
    stack.forwarding = true
    return stack
end

return helpers
