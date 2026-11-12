-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[- A network's agreements with other networks: one for each, kept in the file `networks` with the core's others.

> [!DANGER]
> This is an internal module and SHOULD NOT be used in your own code. Use the `cellcore` program instead.

An agreement says who the other network's core is, and what the two networks do for each other:

 - `key`, `id` and `label`: the other core's key (once it's been allowed, or met), its computer's ID, and a name for it.
 - `signing`: the key its operator certifies its cells with, which our phones check them by.
 - `prefix`: its number prefix, as it last said.
 - `core`: where to reach its core. With one, our core connects to it; without, it waits for the other to connect.
 - `carry`: whether we carry its phones at our cells.
 - `roam`: whether our phones may use its cells, if it carries them: `"partner"` (they're roaming there), `"home"`
   (they treat it as home, as for national roaming), or `false`.
 - `messages`: whether our phones and its exchange messages. Both networks must want it.

Older versions kept these in three places: the computers allowed in (`cells`, with the roles `roam` and `peer`), the
networks whose phones we carry (`roaming`) and those we connected to for messages (`peers`). [`read`] makes agreements
from those once, when there's no `networks` yet, and leaves them as they are.

@local
]]

local common = require "cc.internal.net.cell.common"
local files = require "cc.internal.net.files"

local is_key = files.hex.is_key

local ROAM = { partner = true, home = true }

--- Whether text could be where another core is: a name or an address.
--
-- @param text The text, which may be anything.
-- @treturn boolean Whether it could be.
local function is_core(text)
    return type(text) == "string" and #text >= 1 and #text <= 64 and not text:find("[^%w%.%-_:]")
end

--- Make an agreement from what's in a file (or a request), keeping only what could be right.
--
-- @param entry The agreement, which may be anything.
-- @treturn table|nil The agreement, or `nil` if it isn't one.
local function clean(entry)
    if type(entry) ~= "table" then return nil end
    return {
        key = is_key(entry.key) and entry.key:lower() or nil,
        id = common.is_id(entry.id) and entry.id < 2 ^ 31 and entry.id or nil,
        label = type(entry.label) == "string" and entry.label ~= "" and entry.label:sub(1, 32) or nil,
        signing = is_key(entry.signing) and entry.signing:lower() or nil,
        prefix = common.is_number_prefix(entry.prefix) and entry.prefix or nil,
        core = is_core(entry.core) and entry.core or nil,
        carry = entry.carry == true,
        roam = ROAM[entry.roam] and entry.roam or false,
        messages = entry.messages == true,
    }
end

--- An agreement which does nothing yet.
--
-- @treturn table The agreement.
local function empty()
    return { carry = false, roam = false, messages = false }
end

--[[- Make agreements from the files older versions kept, in a core's folder.

@tparam string dir The core's folder.
@tparam string own This network's name: nothing is agreed with it.
@treturn { [string] = table } The agreements, by network.
]]
local function migrate(dir, own)
    local result = {}
    local function get(network)
        local agreement = result[network]
        if not agreement then
            agreement = empty()
            result[network] = agreement
        end
        return agreement
    end

    -- Other networks' cores which were allowed in: to carry our phones (`roam`), and to exchange messages (`peer`),
    -- one of which may have been kept as a second role.
    for key, entry in pairs(files.read_table(fs.combine(dir, "cells"))) do
        if is_key(key) and type(entry) == "table" and (entry.role == "roam" or entry.role == "peer")
            and common.is_network(entry.network) and entry.network ~= own then
            local roles = { [entry.role] = true }
            if type(entry.roles) == "table" then
                for role, has in pairs(entry.roles) do
                    if has == true then roles[role] = true end
                end
            end
            local agreement = get(entry.network)
            agreement.key = key:lower()
            agreement.id = common.is_id(tonumber(entry.id)) and tonumber(entry.id) or agreement.id
            agreement.label = type(entry.label) == "string" and entry.label ~= "" and entry.label or agreement.label
            if roles.roam then
                agreement.roam = entry.home == true and "home" or "partner"
                agreement.signing = is_key(entry.signing) and entry.signing:lower() or agreement.signing
            end
            if roles.peer then agreement.messages = true end
            if common.is_number_prefix(entry.prefix) then agreement.prefix = entry.prefix end
        end
    end

    -- Networks whose phones we carried, through their cores.
    for network, entry in pairs(files.read_table(fs.combine(dir, "roaming"))) do
        if common.is_network(network) and network ~= own and type(entry) == "table" and is_core(entry.core) then
            local agreement = get(network)
            agreement.carry = true
            agreement.core = agreement.core or entry.core
        end
    end

    -- Networks whose cores we connected to, to exchange messages.
    for network, entry in pairs(files.read_table(fs.combine(dir, "peers"))) do
        if common.is_network(network) and network ~= own and type(entry) == "table" and is_core(entry.core) then
            local agreement = get(network)
            agreement.messages = true
            agreement.core = agreement.core or entry.core
            if common.is_number_prefix(entry.prefix) then agreement.prefix = agreement.prefix or entry.prefix end
        end
    end
    return result
end

--[[- Read a core's agreements, from its file `networks`: or, if there's none yet, from the files older versions kept.

@tparam string dir The core's folder.
@tparam string own This network's name.
@treturn { [string] = table } The agreements, by network.
@treturn boolean Whether they were made from older versions' files (and so should be written).
]]
local function read(dir, own)
    local path = fs.combine(dir, "networks")
    if not fs.exists(path) then return migrate(dir, own), true end
    local result = {}
    for network, entry in pairs(files.read_table(path)) do
        local agreement = common.is_network(network) and network ~= own and clean(entry)
        if agreement then result[network] = agreement end
    end
    return result, false
end

--- Write a core's agreements to its file `networks`.
--
-- @tparam string dir The core's folder.
-- @tparam { [string] = table } agreements The agreements, by network.
local function write(dir, agreements)
    files.write_table(fs.combine(dir, "networks"), agreements)
end

return {
    is_core = is_core,
    clean = clean,
    empty = empty,
    migrate = migrate,
    read = read,
    write = write,
}
