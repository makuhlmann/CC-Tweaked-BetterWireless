-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.message", function()
    local message = require "cc.internal.net.message"

    it("refuses what can't be sent", function()
        local recursive = {}
        recursive.self = recursive
        expect({ message.check(nil) }):same { nil, "Can't send nil" }
        expect({ message.check(print) }):same { nil, "Can't send a function" }
        expect({ message.check({ fn = print }) }):same { nil, "Can't send a function" }
        expect({ message.check(("x"):rep(message.MAX_MESSAGE)) }):same { nil, "Message too large" }
        expect(message.check(("x"):rep(message.MAX_MESSAGE - 2))):eq(true)

        -- Modems can send these, but encrypted links can't, so they might never be delivered.
        expect({ message.check(recursive) }):same { nil, "Can't send a table which contains itself" }
        expect({ message.check({ { { recursive } } }) }):same { nil, "Can't send a table which contains itself" }
        expect({ message.check({ [{}] = true }) }):same { nil, "Can't send a table with a table as a key" }
        expect({ message.check({ [print] = true }) }):same { nil, "Can't send a table with a function as a key" }

        -- A table may appear more than once, as long as it isn't inside itself.
        local shared = { "shared" }
        expect(message.check({ shared, shared, { shared } })):eq(true)
        -- But appearing often enough is too large, however it was built: this would be a thousand million tables.
        local doubling = {}
        for _ = 1, 30 do doubling = { doubling, doubling } end
        expect({ message.check(doubling) }):same { nil, "Message too large" }

        local function nested(depth)
            local value = {}
            for _ = 2, depth do value = { value } end
            return value
        end
        expect(message.check(nested(message.MAX_DEPTH))):eq(true)
        expect({ message.check(nested(message.MAX_DEPTH + 1)) }):same { nil, "Can't send tables nested more than 60 deep" }
        expect({ message.check(nested(100000)) }):same { nil, "Can't send tables nested more than 60 deep" }

        -- Some values take more room encoded than modems reckon, such as empty strings.
        local strings = {}
        for i = 1, 4400 do strings[i] = "" end
        expect(message.check(strings)):eq(true)
        for i = 4401, 4500 do strings[i] = "" end
        expect({ message.check(strings) }):same { nil, "Message too large" }
    end)

    it("accepts exactly the kinds of value the codec can encode", function()
        local codec = require "cc.net.codec"
        local recursive, shared = {}, {}
        recursive[1] = { { recursive } }
        local values = {
            true, false, 0, -1.5, 0 / 0, math.huge, "", "text", {}, { 1, 2, 3 }, { a = { b = { c = {} } } },
            { [true] = 1, [false] = 2, [1.5] = 3, [""] = 4 }, { shared, shared },
            print, { print }, { [print] = 1 }, { [{}] = 1 }, { { [{}] = 1 } }, recursive, { recursive },
            coroutine.create(print), { x = coroutine.create(print) },
        }
        for i, value in ipairs(values) do
            expect(message.check(value) == true):describe("Value " .. i):eq((pcall(codec.encode, value)))
        end
    end)
end)
