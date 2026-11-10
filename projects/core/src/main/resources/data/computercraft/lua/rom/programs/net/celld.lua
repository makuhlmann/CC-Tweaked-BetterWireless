-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local CONTROL_PORT = 2123

local args = { ... }
if #args < 1 or #args > 2 then
    print("Usage: " .. (arg[0] or fs.getName(shell.getRunningProgram())) .. " <core> [area]")
    return
end
if not crypto or not enclave then
    printError("Cells need the crypto and enclave APIs, which are turned off on this server")
    return
end

local core, area = args[1], tonumber(args[2] or 0)

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

-- Cells must keep running when nobody is nearby.
pcall(os.setKeepLoaded, true)

-- The cell's own signing key, which the core certifies.
local signing = enclave.publicKey("cell.tower") or enclave.generate("cell.tower", "ed25519")
print(("Cell #%d. This computer's key is %s: allow it on the core with 'cellcore allow'."):format(os.getComputerID(), net.getIdentity()))

-- Run the cell over one connection to the core, until it breaks.
local function serve(connection)
    connection:send({ hello = 1, id = os.getComputerID(), signing = to_hex(signing), area = area })
    local welcome, err = connection:receive(15)
    if type(welcome) ~= "table" or type(welcome.network) ~= "string" then
        return "The core didn't accept this cell: " .. tostring(welcome and welcome.error or err or "no answer")
    end

    -- The cell's messages for the core are queued, and sent from here, as the cell runs inside the network stack.
    local outbox = {}
    local cell = net.cell.startCell {
        network = welcome.network, area = area, certificate = welcome.certificate, tunnel_key = welcome.tunnel_key,
        core = connection:getPeer(),
        sign = function(data) return enclave.sign("cell.tower", data) end,
        control = function(message)
            outbox[#outbox + 1] = message
            os.queueEvent("celld_outbox")
        end,
    }
    print(("Serving %s. Press Ctrl+T to stop."):format(welcome.network))

    local reason
    local ok, result = pcall(parallel.waitForAny,
        function()
            while true do
                while outbox[1] do
                    local sent, send_err = connection:send(table.remove(outbox, 1))
                    if not sent then
                        reason = send_err
                        return
                    end
                end
                os.pullEvent("celld_outbox")
            end
        end,
        function()
            while true do
                local message, receive_err = connection:receive()
                if message == nil then
                    reason = receive_err or "The core closed the connection"
                    return
                end
                cell:control(message)
            end
        end
    )
    cell:stop()
    if not ok then error(result, 0) end
    return reason
end

local delay = 2
while true do
    local connection, err = net.secure.connect(core, CONTROL_PORT)
    if connection then
        delay = 2
        local ok, reason = pcall(serve, connection)
        connection:abort()
        if not ok then
            if reason == "Terminated" then return end
            printError(reason)
        else
            printError(reason)
        end
    else
        printError(("Cannot reach the core %s: %s"):format(core, err))
    end
    -- Try again, less often each time.
    sleep(delay)
    delay = math.min(delay * 2, 60)
end
