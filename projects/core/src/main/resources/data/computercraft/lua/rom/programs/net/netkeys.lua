-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

local certificate = require "cc.internal.net.certificate"

local TRUSTED = "/.net/trust"
local CERTIFICATE = "/.net/certificate"
local DAY = 24 * 60 * 60 * 1000

local args = { ... }

local function usage()
    local name = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(name)
    print(name .. " hosts")
    print(name .. " forget <name>")
    print(name .. " export <file>")
    print(name .. " authority [file]")
    print(name .. " trust <key|file> [label]")
    print(name .. " untrust <key|label>")
    print(name .. " sign <name> <key|file> [days] [file]")
    print(name .. " install <file>")
end

if not crypto or not enclave then
    printError("netkeys needs the crypto and enclave APIs, which are turned off on this server")
    return
end

local function to_hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function from_hex(text)
    if type(text) ~= "string" or #text ~= 64 or text:find("[^%x]") then return nil end
    return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function read_file(path, binary)
    local file = fs.open(shell.resolve(path), binary and "rb" or "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    return contents
end

local function write_file(path, contents, binary)
    local file, err = fs.open(shell.resolve(path), binary and "wb" or "w")
    if not file then error(err, 0) end
    file.write(contents)
    file.close()
end

-- A key given as 64 hexadecimal digits, or a file holding them.
local function read_key(text)
    local key = from_hex(text:lower())
    if key then return key end
    local contents = read_file(text)
    key = contents and from_hex(contents:match("^%s*(%x+)%s*$") or "")
    if not key then error("Expected a key of 64 hexadecimal digits, or a file with one in", 0) end
    return key
end

local function read_table(path)
    local contents = read_file(path)
    local value = contents and textutils.unserialise(contents)
    return type(value) == "table" and value or {}
end

-- This computer's certificate authority key, made the first time it's needed.
local function authority()
    return enclave.publicKey("net.authority") or enclave.generate("net.authority", "ed25519")
end

local command = args[1]
if command == nil then
    local key = net.getIdentity()
    print("This computer's key, which other computers see when it connects to them:")
    print(key)
    print("Fingerprint: " .. net.fingerprint(key))
    local cert = certificate.decode(read_file(CERTIFICATE, true))
    if cert then print(("It has a certificate for %s, until %s."):format(cert.name, os.date("%Y-%m-%d", cert.expires / 1000))) end
elseif command == "hosts" and #args == 1 then
    local any = false
    for name, key in pairs(net.knownHosts()) do
        print(("%-20s %s"):format(name, net.fingerprint(key)))
        any = true
    end
    if not any then print("No computers known yet.") end
elseif command == "forget" and #args == 2 then
    print(net.forgetHost(args[2]) and ("Forgot the key for " .. args[2]) or ("No key known for " .. args[2]))
elseif command == "export" and #args == 2 then
    write_file(args[2], net.getIdentity() .. "\n")
    print("Wrote this computer's key to " .. args[2] .. ". Send it to an authority to get a certificate.")
elseif command == "authority" and #args <= 2 then
    local key = to_hex(authority())
    if args[2] then
        write_file(args[2], key .. "\n")
        print("Wrote this computer's authority key to " .. args[2] .. ". Computers which trust it accept its certificates.")
    else
        print("This computer's authority key, for computers to trust:")
        print(key)
    end
elseif command == "trust" and (#args == 2 or #args == 3) then
    local key = to_hex(read_key(args[2]))
    local trusted = read_table(TRUSTED)
    trusted[key] = args[3] or "added by hand"
    write_file(TRUSTED, textutils.serialise(trusted))
    print("Trusting certificates from " .. net.fingerprint(key))
elseif command == "untrust" and #args == 2 then
    local trusted, removed = read_table(TRUSTED), 0
    for key, label in pairs(trusted) do
        if key == args[2]:lower() or label == args[2] then
            trusted[key] = nil
            removed = removed + 1
        end
    end
    write_file(TRUSTED, textutils.serialise(trusted))
    print(removed > 0 and "Removed." or "No such authority.")
elseif command == "sign" and #args >= 3 and #args <= 5 then
    local name, key = args[2]:lower(), read_key(args[3])
    local days = tonumber(args[4] or 365)
    if not days or days <= 0 then
        usage()
        return
    end
    local cert = certificate.issue {
        name = name, key = key, expires = os.epoch("utc") + days * DAY, issuer = authority(),
        sign = function(data) return enclave.sign("net.authority", data) end,
    }
    local output = args[5] or (name .. ".cert")
    write_file(output, certificate.encode(cert), true)
    print(("Wrote a certificate for %s to %s, valid for %d days."):format(name, output, days))
elseif command == "install" and #args == 2 then
    local cert = certificate.decode(read_file(args[2], true))
    if not cert then
        printError(args[2] .. " isn't a certificate.")
        return
    end
    if to_hex(cert.key) ~= net.getIdentity() then
        printError("That certificate is for another computer's key.")
        return
    end
    -- Replacing one, say when renewing it.
    fs.delete(CERTIFICATE)
    fs.copy(shell.resolve(args[2]), CERTIFICATE)
    print(("Installed the certificate for %s. Secure servers started from now on offer it."):format(cert.name))
else
    usage()
end
