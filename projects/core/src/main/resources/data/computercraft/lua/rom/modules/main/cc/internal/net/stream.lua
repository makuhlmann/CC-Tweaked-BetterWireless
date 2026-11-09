-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- Byte streams over connections, for files and terminals.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use `net.stream` instead.

Connections carry whole messages, each at most about 60 KiB. A stream turns them into a sequence of bytes: what's
written is collected and sent in chunks of 16 KiB, and what arrives can be read in any amounts, much like a file.

@local
]]

local expect = require "cc.expect".expect

--- How many bytes to send in each message.
local CHUNK = 16 * 1024

--[[- Make a stream from a connection.

@tparam table connection The connection, with methods `send(value)`, which waits until the message is queued and
returns `true` or `nil` and an error; `receive()`, which waits for the next message, returning `nil` once the other side
has closed or `nil` and an error; and `close()`.
@treturn table The stream, with `read`, `readLine`, `readAll`, `write`, `writeLine`, `flush` and `close` methods.
]]
local function wrap(connection)
    local stream = {}

    -- Bytes written but not sent yet.
    local out, out_size = {}, 0
    -- The message being read, and how far into it we are.
    local buffer, position, ended = "", 1, false

    local function send(data)
        local ok, err = connection:send(data)
        if not ok then error(err or "Connection closed", 3) end
    end

    -- Make sure there's something left in the buffer. Returns false at the end of the stream.
    local function fill()
        while position > #buffer do
            if ended then return false end
            local value, err = connection:receive()
            if value == nil then
                if err then error(err, 3) end
                ended = true
                return false
            end
            if type(value) ~= "string" then error("Expected text in the stream, got a " .. type(value), 3) end
            buffer, position = value, 1
        end
        return true
    end

    --- Write some text. It's sent in chunks as it builds up: use [`flush`] to send what's left.
    --
    -- @tparam string|number text The text.
    function stream.write(text)
        expect(1, text, "string", "number")
        text = tostring(text)
        out[#out + 1] = text
        out_size = out_size + #text
        if out_size < CHUNK then return end

        local data = table.concat(out)
        local i = 1
        while #data - i + 1 >= CHUNK do
            send(data:sub(i, i + CHUNK - 1))
            i = i + CHUNK
        end
        local rest = data:sub(i)
        out, out_size = { rest }, #rest
    end

    --- Write some text, then a new line.
    --
    -- @tparam string|number text The text.
    function stream.writeLine(text)
        expect(1, text, "string", "number")
        stream.write(tostring(text) .. "\n")
    end

    --- Send everything written so far.
    function stream.flush()
        if out_size == 0 then return end
        local data = table.concat(out)
        out, out_size = {}, 0
        send(data)
    end

    --[[- Read some bytes, waiting until there are that many or the stream ends.

    @tparam[opt=1] number count How many bytes to read.
    @treturn string|nil The bytes, which may be fewer at the end of the stream, or `nil` if it has ended.
    ]]
    function stream.read(count)
        expect(1, count, "number", "nil")
        count = count or 1
        if count < 1 or not fill() then return nil end

        local parts, needed = {}, count
        while needed > 0 and fill() do
            local take = math.min(#buffer - position + 1, needed)
            parts[#parts + 1] = buffer:sub(position, position + take - 1)
            position, needed = position + take, needed - take
        end
        return table.concat(parts)
    end

    --[[- Read a line.

    @tparam[opt=false] boolean trailing Whether to keep the new line at the end.
    @treturn string|nil The line, or `nil` if the stream has ended.
    ]]
    function stream.readLine(trailing)
        if not fill() then return nil end

        local parts = {}
        while fill() do
            local newline = buffer:find("\n", position, true)
            if newline then
                parts[#parts + 1] = buffer:sub(position, trailing and newline or newline - 1)
                position = newline + 1
                return table.concat(parts)
            end
            parts[#parts + 1] = buffer:sub(position)
            position = #buffer + 1
        end
        return table.concat(parts)
    end

    --- Read everything until the stream ends.
    --
    -- @treturn string|nil Everything, or `nil` if the stream had already ended.
    function stream.readAll()
        if not fill() then return nil end

        local parts = {}
        while fill() do
            parts[#parts + 1] = buffer:sub(position)
            position = #buffer + 1
        end
        return table.concat(parts)
    end

    --- Send what's left, and close the connection. Reading still works until the other side closes.
    function stream.close()
        stream.flush()
        connection:close()
    end

    return stream
end

return {
    wrap = wrap,
    CHUNK = CHUNK,
}
