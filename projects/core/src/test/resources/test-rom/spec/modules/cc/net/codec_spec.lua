-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.net.codec", function()
    local codec = require "cc.net.codec"

    it("reads back what it writes", function()
        local values = {
            false, true, 0, -1.5, 2 ^ 53, math.huge, -math.huge, "", "text\0with\255bytes",
            {}, { 1, 2, 3 }, { a = { b = { c = "deep" } }, [1] = false, [2.5] = "half", [true] = "yes" },
        }
        for _, value in ipairs(values) do expect(codec.decode(codec.encode(value))):same(value) end
        expect(codec.decode(codec.encode(nil))):eq(nil)
        local nan = codec.decode(codec.encode(0 / 0))
        expect(nan ~= nan):eq(true)
    end)

    it("writes the same table the same way, however it was built", function()
        local a, b = {}, {}
        for i = 1, 50 do a["k" .. i], a[i] = i, -i end
        for i = 50, 1, -1 do b[i], b["k" .. i] = -i, i end
        expect(codec.encode(a)):eq(codec.encode(b))
        expect(codec.encode(-0)):eq(codec.encode(0))
        expect(codec.encode({ [false] = 1, [true] = 2, x = 3, [1] = 4 })):eq(codec.encode({ [1] = 4, x = 3, [true] = 2, [false] = 1 }))
    end)

    it("refuses what it can't write", function()
        local recursive = {}
        recursive.self = recursive
        expect.error(codec.encode, print):eq("Can't encode a function")
        expect.error(codec.encode, { [{}] = 1 }):eq("Can't encode a table with a table as a key")
        expect.error(codec.encode, recursive):eq("Can't encode a table which contains itself")
        local deep = {}
        for _ = 1, 100 do deep = { deep } end
        expect.error(codec.encode, deep):eq("Tables are nested too deeply")

        -- The same table twice is fine, as long as it doesn't contain itself.
        local shared = { 1 }
        expect(codec.decode(codec.encode({ shared, shared }))):same { { 1 }, { 1 } }
    end)

    it("rejects bytes it didn't write", function()
        local good = codec.encode({ name = "bank", list = { 1, 2 } })
        for i = 1, #good - 1 do
            expect({ codec.decode(good:sub(1, i)) }):same { nil, "Invalid data" }
        end
        expect({ codec.decode(good .. "\0") }):same { nil, "Invalid data" }
        expect({ codec.decode("\9") }):same { nil, "Invalid data" }
        -- A table claiming more entries than it could hold, a duplicate key, a NaN key and a table key.
        expect({ codec.decode("\6\255\255\255\255") }):same { nil, "Invalid data" }
        expect({ codec.decode("\6\2\0\0\0\1\2\1\2") }):same { nil, "Invalid data" }
        expect({ codec.decode("\6\1\0\0\0\4\2") }):same { nil, "Invalid data" }
        expect({ codec.decode("\6\1\0\0\0\6\0\0\0\0\2") }):same { nil, "Invalid data" }
        -- Too deeply nested.
        expect({ codec.decode(("\6\1\0\0\0\1"):rep(100) .. "\2") }):same { nil, "Invalid data" }

        -- Random bytes never break it.
        math.randomseed(1)
        for _ = 1, 2000 do
            local bytes = {}
            for i = 1, math.random(1, 24) do bytes[i] = string.char(math.random(0, 6)) end
            codec.decode(table.concat(bytes))
        end
    end)
end)
