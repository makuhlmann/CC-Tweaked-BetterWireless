-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- What a computer trusts when it connects securely: the authorities whose certificates it accepts (`/.net/trust`),
the keys it has seen for other computers (`/.net/known_hosts`), and its own certificate (`/.net/certificate`), which
its secure servers offer.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `net` API and the `netkeys` program.

@local
]]

local files = require "cc.internal.net.files"

local to_hex, from_hex = files.hex.encode, files.hex.decode
local read_table, write_table = files.read_table, files.write_table
local TRUSTED, KNOWN_HOSTS, CERTIFICATE = files.TRUSTED, files.KNOWN_HOSTS, files.CERTIFICATE

-- Whether text could be a key: 64 hexadecimal digits.
local function is_key(text) return type(text) == "string" and #text == 64 and from_hex(text) ~= nil end

--- The authorities trusted to issue certificates.
--
-- @treturn { [string] = string } Each one's key, as hexadecimal digits, and what it's called.
local function trusted()
    local result = {}
    for key, label in pairs(read_table(TRUSTED)) do
        if is_key(key) then result[key:lower()] = tostring(label) end
    end
    return result
end

--- Trust an authority to issue certificates.
--
-- @tparam string key Its key, as hexadecimal digits.
-- @tparam string label What it's called.
local function trust(key, label)
    local list = read_table(TRUSTED)
    list[key:lower()] = label
    write_table(TRUSTED, list)
end

--- Stop trusting an authority.
--
-- @tparam string which Its key, as hexadecimal digits, or what it's called.
-- @treturn number How many authorities were trusted no longer.
local function untrust(which)
    local list, removed = read_table(TRUSTED), 0
    for key, label in pairs(list) do
        if key == which:lower() or label == which then
            list[key] = nil
            removed = removed + 1
        end
    end
    write_table(TRUSTED, list)
    return removed
end

--[[- The keys seen for other computers when connecting to them.

@treturn { [string] = string } Each name, and its key as hexadecimal digits. Entries which aren't a name and a key (in
a file which was changed by hand, say) are left out.
]]
local function known_hosts()
    local result = {}
    for name, key in pairs(read_table(KNOWN_HOSTS)) do
        if type(name) == "string" and is_key(key) then result[name] = key:lower() end
    end
    return result
end

--- The key seen for a name, if any.
--
-- @tparam string name The name.
-- @treturn string|nil The key.
local function known_key(name)
    local key = read_table(KNOWN_HOSTS)[name]
    return is_key(key) and from_hex(key) or nil
end

--[[- Check a computer's key against the one seen for its name, the first time remembering it.

@tparam string name The name.
@tparam string key The key the computer has now.
@treturn[1] string `"new"` (it's remembered now) or `"known"` (it's the same).
@treturn[2] nil If it has changed.
]]
local function check_host(name, key)
    local hosts = read_table(KNOWN_HOSTS)
    local known = hosts[name]
    if known == nil then
        hosts[name] = to_hex(key)
        write_table(KNOWN_HOSTS, hosts)
        return "new"
    end
    if known ~= to_hex(key) then return nil end
    return "known"
end

--- Forget the key seen for a name.
--
-- @tparam string name The name.
-- @treturn boolean Whether a key was forgotten.
local function forget_host(name)
    local hosts = read_table(KNOWN_HOSTS)
    if hosts[name] == nil then return false end
    hosts[name] = nil
    write_table(KNOWN_HOSTS, hosts)
    return true
end

--- This computer's certificate, as its secure servers offer it, if it has one.
--
-- @treturn string|nil The certificate.
local function certificate()
    local file = fs.open(CERTIFICATE, "rb")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    return contents
end

--- Make a certificate in a file this computer's, in place of any it had.
--
-- @tparam string path The file.
local function install_certificate(path)
    fs.delete(CERTIFICATE)
    fs.copy(path, CERTIFICATE)
end

return {
    trusted = trusted,
    trust = trust,
    untrust = untrust,
    known_hosts = known_hosts,
    known_key = known_key,
    check_host = check_host,
    forget_host = forget_host,
    certificate = certificate,
    install_certificate = install_certificate,
}
