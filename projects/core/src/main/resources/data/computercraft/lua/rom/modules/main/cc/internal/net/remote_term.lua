-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A terminal on another computer, for remote shells.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `rsh` program instead.

[`new`] makes a terminal object (like `term.current()`) which programs on the server draw on. It keeps its own copy of
the cursor, colours and palette, to answer questions without asking the client, and collects drawing calls into
batches, which [`apply`] draws on the client's terminal. A batch is sent once it's about 32 KiB, well within what one
message may hold, so a program which draws a lot without yielding doesn't make a batch which can't be sent.

@local
]]

local expect = require "cc.expect".expect

-- The drawing calls a client will make, and the types of their arguments.
local OPERATIONS = {
    write = { "string" },
    blit = { "string", "string", "string" },
    clear = {},
    clearLine = {},
    scroll = { "number" },
    setCursorPos = { "number", "number" },
    setCursorBlink = { "boolean" },
    setTextColour = { "number" },
    setBackgroundColour = { "number" },
    setPaletteColour = { "number", "number", "number", "number" },
}

-- A batch is sent once it holds about this many bytes, as the network's estimate of a message's size would have it.
-- One message may hold about 60 KiB.
local BATCH_SIZE = 32 * 1024
-- Text longer than this is drawn in pieces, so that no one call is too big for a batch.
local MAX_TEXT = 8 * 1024

-- How big a drawing call is once encoded, counted as `cc.internal.net.message` counts it: its place in the batch, the
-- table, and each value with its index.
local function size_of(operation)
    local size = 9 + 5
    for i = 1, #operation do
        local value = operation[i]
        local kind = type(value)
        size = size + 9 + (kind == "string" and #value + 5 or kind == "number" and 9 or 1)
    end
    return size
end

local function is_colour(colour)
    return type(colour) == "number" and colour >= 1 and colour <= 32768 and colour % 1 == 0 and bit32.band(colour, colour - 1) == 0
end

--[[- Make a remote terminal.

@tparam {
    width = number, height = number, colour = boolean, x? = number, y? = number,
    text? = number, background? = number,
} options The client's terminal: its size, whether it shows colours, and where its cursor is and what colours are set
when the session starts.
@tparam function(operations:table) send Sends a batch of drawing calls to the client. It's called while drawing, once
a batch is full, so it shouldn't wait.
@treturn table The terminal, with every method `term` has, and `flush` (send what's been drawn) and `resize`.
]]
local function new(options, send)
    local width, height = options.width, options.height
    local x, y, blink = options.x or 1, options.y or 1, false
    local text, background = options.text or colours.white, options.background or colours.black
    local palette = {}
    for i = 0, 15 do palette[2 ^ i] = { term.nativePaletteColour(2 ^ i) } end
    local batch, batch_size = {}, 0

    local function add(...)
        local operation = { ... }
        local size = size_of(operation)
        if batch_size + size > BATCH_SIZE and #batch > 0 then
            local full = batch
            batch, batch_size = {}, 0
            send(full)
        end
        batch[#batch + 1] = operation
        batch_size = batch_size + size
    end

    local remote = {}

    function remote.write(value)
        value = tostring(value)
        for i = 1, #value, MAX_TEXT do add("write", value:sub(i, i + MAX_TEXT - 1)) end
        x = x + #value
    end

    function remote.blit(value, fg, bg)
        expect(1, value, "string")
        expect(2, fg, "string")
        expect(3, bg, "string")
        if #fg ~= #value or #bg ~= #value then error("Arguments must be the same length", 2) end
        for i = 1, #value, MAX_TEXT do
            local last = i + MAX_TEXT - 1
            add("blit", value:sub(i, last), fg:sub(i, last), bg:sub(i, last))
        end
        x = x + #value
    end

    function remote.clear() add("clear") end
    function remote.clearLine() add("clearLine") end

    function remote.scroll(lines)
        expect(1, lines, "number")
        add("scroll", lines)
    end

    function remote.setCursorPos(new_x, new_y)
        expect(1, new_x, "number")
        expect(2, new_y, "number")
        x, y = math.floor(new_x), math.floor(new_y)
        add("setCursorPos", x, y)
    end

    function remote.getCursorPos() return x, y end

    function remote.setCursorBlink(value)
        expect(1, value, "boolean")
        blink = value
        add("setCursorBlink", value)
    end

    function remote.getCursorBlink() return blink end
    function remote.getSize() return width, height end
    function remote.isColour() return options.colour end
    remote.isColor = remote.isColour

    function remote.setTextColour(colour)
        if not is_colour(colour) then error("Invalid colour (got " .. tostring(colour) .. ")", 2) end
        text = colour
        add("setTextColour", colour)
    end
    remote.setTextColor = remote.setTextColour

    function remote.setBackgroundColour(colour)
        if not is_colour(colour) then error("Invalid colour (got " .. tostring(colour) .. ")", 2) end
        background = colour
        add("setBackgroundColour", colour)
    end
    remote.setBackgroundColor = remote.setBackgroundColour

    function remote.getTextColour() return text end
    remote.getTextColor = remote.getTextColour
    function remote.getBackgroundColour() return background end
    remote.getBackgroundColor = remote.getBackgroundColour

    function remote.setPaletteColour(colour, r, g, b)
        if not is_colour(colour) then error("Invalid colour (got " .. tostring(colour) .. ")", 2) end
        if type(r) == "number" and g == nil then r, g, b = colours.unpackRGB(r) end
        expect(2, r, "number")
        expect(3, g, "number")
        expect(4, b, "number")
        palette[colour] = { r, g, b }
        add("setPaletteColour", colour, r, g, b)
    end
    remote.setPaletteColor = remote.setPaletteColour

    function remote.getPaletteColour(colour)
        if not is_colour(colour) then error("Invalid colour (got " .. tostring(colour) .. ")", 2) end
        return table.unpack(palette[colour])
    end
    remote.getPaletteColor = remote.getPaletteColour

    --- Send what's been drawn since last time.
    function remote.flush()
        if #batch == 0 then return end
        local operations = batch
        batch, batch_size = {}, 0
        send(operations)
    end

    --- The client's terminal changed size.
    function remote.resize(new_width, new_height)
        width, height = new_width, new_height
    end

    return remote
end

--[[- Draw a batch of drawing calls from a server. Anything which isn't a drawing call, or has the wrong arguments, is
skipped.

@tparam table target The terminal to draw on.
@param operations The batch.
]]
local function apply(target, operations)
    if type(operations) ~= "table" then return end
    for _, operation in ipairs(operations) do
        local kinds = type(operation) == "table" and OPERATIONS[operation[1]]
        if kinds then
            local good = true
            for i, kind in ipairs(kinds) do
                if type(operation[i + 1]) ~= kind then good = false end
            end
            if good then pcall(target[operation[1]], table.unpack(operation, 2, #kinds + 1)) end
        end
    end
end

return {
    --- The port remote shells are served on.
    PORT = 22,
    new = new,
    apply = apply,
}
