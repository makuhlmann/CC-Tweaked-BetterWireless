-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.remote_term", function()
    local remote_term = require "cc.internal.net.remote_term"

    local function draw(target)
        target.setTextColour(colours.red)
        target.setBackgroundColour(colours.blue)
        target.clear()
        target.setCursorPos(2, 2)
        target.write("Hello")
        target.write(42)
        target.blit("abc", "012", "fff")
        target.setCursorPos(1, 4)
        target.clearLine()
        target.write("Last line")
        target.scroll(1)
    end

    local function contents(window)
        local lines = {}
        local _, height = window.getSize()
        for y = 1, height do lines[y] = { window.getLine(y) } end
        return lines
    end

    it("draws on the client's terminal as the server drew it", function()
        local batches = {}
        local remote = remote_term.new({ width = 20, height = 5, colour = true }, function(batch) batches[#batches + 1] = batch end)
        draw(remote)
        remote.flush()
        expect(#batches):eq(1)

        local expected = window.create(term.current(), 1, 1, 20, 5, false)
        draw(expected)
        local client = window.create(term.current(), 1, 1, 20, 5, false)
        for _, batch in ipairs(batches) do remote_term.apply(client, batch) end

        expect(contents(client)):same(contents(expected))
        expect({ client.getCursorPos() }):same { expected.getCursorPos() }
    end)

    it("answers questions without asking the client", function()
        local remote = remote_term.new({ width = 30, height = 10, colour = false, x = 3, y = 4 }, function() end)
        expect({ remote.getSize() }):same { 30, 10 }
        expect({ remote.getCursorPos() }):same { 3, 4 }
        expect(remote.isColour()):eq(false)
        remote.write("abc")
        expect({ remote.getCursorPos() }):same { 6, 4 }
        remote.setTextColour(colours.lime)
        expect(remote.getTextColour()):eq(colours.lime)
        remote.setPaletteColour(colours.red, 0x123456)
        expect({ remote.getPaletteColour(colours.red) }):same { colours.unpackRGB(0x123456) }
        expect.error(remote.setTextColour, 3):eq("Invalid colour (got 3)")
        remote.resize(40, 12)
        expect({ remote.getSize() }):same { 40, 12 }
    end)

    it("ignores anything which isn't a drawing call", function()
        local client = window.create(term.current(), 1, 1, 10, 3, false)
        remote_term.apply(client, {
            { "write", "ok" }, { "getLine", 1 }, { "setCursorPos", "x", 1 }, { "redirect", {} }, "junk", { "write", {} },
            { "blit", "a", "0", "f" },
        })
        expect(client.getLine(1):sub(1, 3)):eq("oka")
        remote_term.apply(client, "not a batch")
    end)
end)
