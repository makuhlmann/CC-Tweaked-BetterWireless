-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("Cellular services", function()
    local codec = require "cc.net.codec"
    local noise = require "cc.internal.net.noise"
    local certificate = require "cc.internal.net.certificate"
    local common = require "cc.internal.net.cell.common"
    local cell_core = require "cc.internal.net.cell.core"
    local core_service = require "cc.internal.net.cell.core_service"
    local cell_service = require "cc.internal.net.cell.cell_service"
    local tasks = require "cc.internal.net.tasks"
    local network = require "support.virtual_network"

    local DIR = "/.cell-spec"

    local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
    local function unhex(text) return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)) end
    local function copy(value) return codec.decode(codec.encode(value)) end
    local function new_key() return hex(crypto.random(32)) end
    local function fingerprint(key) return hex(crypto.sha256(unhex(key))):sub(1, 20):gsub("(....)", "%1 "):sub(1, -2) end

    local function read_table(path)
        local file = fs.open(path, "r")
        if not file then return {} end
        local value = textutils.unserialise(file.readAll())
        file.close()
        return value
    end

    local function write_table(path, value)
        local file = fs.open(path, "w")
        file.write(textutils.serialise(value))
        file.close()
    end

    local function yield()
        os.queueEvent("cell_service_yield")
        os.pullEvent("cell_service_yield")
    end

    --[[ Two ends of a connection, which wait (by yielding) as the net API's do. Each end's peer is the other side. ]]
    local function pipe(clock, a, b)
        local shared, inboxes, closed = {}, { {}, {} }, {}
        local function side(me, other, peer)
            return {
                send = function(_, value)
                    if shared.aborted or closed[me] then return nil, "Connection closed" end
                    table.insert(inboxes[other], copy(value))
                    return true
                end,
                receive = function(_, timeout)
                    local deadline = timeout and clock() + timeout
                    while true do
                        if inboxes[me][1] then return table.remove(inboxes[me], 1) end
                        if shared.aborted then return nil, "Connection reset" end
                        if closed[other] then return nil end
                        if deadline and clock() >= deadline then return nil, "Timed out" end
                        coroutine.yield()
                    end
                end,
                close = function() closed[me] = true end,
                abort = function() shared.aborted = true end,
                getPeerKey = function() return peer.key end,
                getPeer = function() return peer.address, 2123 end,
                is_gone = function() return shared.aborted or closed[me] or closed[other] end,
            }
        end
        return side(1, 2, b), side(2, 1, a)
    end

    -- Run functions alongside services, letting time pass, until the functions have finished.
    local function run(net, services, functions, limit, step)
        step = step or 0.1
        local threads = {}
        for i, fn in ipairs(functions) do threads[i] = coroutine.create(fn) end
        local elapsed, turns = 0, 0
        while true do
            for _, service in ipairs(services) do service:resume() end
            local alive = false
            for _, thread in ipairs(threads) do
                if coroutine.status(thread) ~= "dead" then
                    local ok, err = coroutine.resume(thread)
                    if not ok then error(err, 0) end
                    if coroutine.status(thread) ~= "dead" then alive = true end
                end
            end
            if not alive then return end
            net.advance(step)
            elapsed = elapsed + step
            if elapsed > (limit or 120) then error("Still running", 0) end
            turns = turns + 1
            if turns % 50 == 0 then yield() end
        end
    end

    -- Wait (in a function given to run) until something is true.
    local function wait_until(test)
        while not test() do coroutine.yield() end
    end

    local function hello(connection, role, id, extra)
        local message = { role = role, id = id }
        for k, v in pairs(extra or {}) do message[k] = v end
        assert(connection:send(message))
        return connection:receive(15)
    end

    local function ask(connection, request)
        assert(connection:send(request))
        return connection:receive(15)
    end

    --[[ A core for ACME, on computer 50, whose files are in DIR. Another network's core, for roaming, is made by giving
    its name, its computer's ID and the end of its address, where its files are, and the network to join. ]]
    local function setup(files, other)
        other = other or {}
        local dir, name, id = other.dir or DIR, other.network or "ACME", other.id or 50
        local own_address = "10.0.0." .. (other.host or 1)
        fs.delete(dir)
        write_table(fs.combine(dir, "config"), { network = name, prefix = other.prefix or "10.64.0.0/16", number_prefix = other.numbers })
        for file, value in pairs(files or {}) do write_table(fs.combine(dir, file), value) end

        local net = other.net or network()
        local stack = net.stack(id)
        net.connect(stack, "backhaul", own_address .. "/24")
        stack.forwarding = true
        local now = function() return 1.7e12 + net.time * 1000 end
        local operator_private = crypto.generateKeyPair("x25519")
        local operator = {
            public = noise.public_key(crypto, operator_private),
            exchange = function(public) return crypto.exchange(operator_private, public) end,
        }
        local signing_private, signing_public = crypto.generateKeyPair("ed25519")
        local env = { net = net, stack = stack, identity = new_key(), signing = signing_public, now = now, dir = dir }

        env.listener = { queue = {} }
        function env.listener.accept(self)
            while true do
                if self.queue[1] then return table.remove(self.queue, 1) end
                if self.closed then return nil, "Listener is closed" end
                coroutine.yield()
            end
        end
        function env.listener.close(self) self.closed = true end

        env.options = {
            dir = dir, identity = env.identity, fingerprint = fingerprint, id = id,
            -- Waiting, as tasks do: until enough time has passed on the network.
            sleep = function(seconds)
                local deadline = net.time + seconds
                while net.time < deadline do coroutine.yield() end
            end,
            listen = function()
                if env.listening then return nil, "Port 2123 is in use" end
                env.listening, env.listener.closed = true, false
                return env.listener
            end,
            start_core = function(options)
                return cell_core.new {
                    stack = stack, crypto = crypto, network = options.network, prefix = options.prefix, operator = operator,
                    signing = signing_public, subscribers = options.subscribers, codes = options.codes,
                    secret = crypto.random(32), epoch = now, on_event = options.on_event, number_prefix = options.number_prefix,
                }
            end,
            signing = signing_public, sign = function(data) return crypto.sign(signing_private, data) end,
            clock = function() return net.time end, epoch = now, wake = function() end,
        }
        env.service = assert(core_service.new(env.options))

        -- Connect to the core, as a computer with this key.
        function env.connect(key, addr)
            local client, server = pipe(function() return net.time end,
                { key = key, address = addr or "10.0.0.9" }, { key = env.identity, address = own_address })
            table.insert(env.listener.queue, server)
            return client
        end

        -- Connect as the core's own computer, to manage it.
        function env.admin()
            local admin = env.connect(env.identity, "127.0.0.1")
            expect(hello(admin, "admin", id)):same { ok = true, network = name }
            return admin
        end
        return env
    end

    describe("tasks", function()
        it("runs tasks side by side, each waiting for its own events", function()
            local seen = {}
            local set = tasks.new()
            set:spawn(function(name)
                while true do
                    local _, value = coroutine.yield("a")
                    seen[#seen + 1] = name .. value
                end
            end, "first ")
            set:spawn(function()
                local event, value = coroutine.yield()
                seen[#seen + 1] = event .. " " .. value
            end)
            set:resume("b", "one")
            set:resume("a", "two")
            set:resume("terminate")
            set:resume("a", "three")
            expect(seen):same { "b one", "first two", "first three" }
            expect(set:count()):eq(1)

            set:stop()
            set:resume("a", "four")
            expect(#seen):eq(3)
        end)

        it("reports tasks which fail, and carries on", function()
            local errors = {}
            local set = tasks.new(function(err) errors[#errors + 1] = err end)
            local ran = 0
            set:spawn(function() coroutine.yield() error("Broken", 0) end)
            set:spawn(function() while true do coroutine.yield() ran = ran + 1 end end)
            set:resume()
            set:resume()
            expect(errors):same { "Broken" }
            expect(ran):eq(2)
            expect(set:count()):eq(1)
        end)
    end)

    describe("the core", function()
        it("lets its own computer manage it", function()
            local env = setup()
            run(env.net, { env.service }, { function()
                local admin = env.admin()
                local status = ask(admin, { op = "status" })
                expect(status.network):eq("ACME")
                expect(status.prefix):eq("10.64.0.0/16")
                expect(#status.cells):eq(0)
                expect(#status.waiting):eq(0)
                expect(ask(admin, { op = "launch" })):same { error = "Unknown request launch" }
                admin:close()
            end, })
        end)

        it("keeps cells waiting until they're allowed, then certifies them", function()
            local env = setup()
            local cell_key = new_key()
            local _, tower_public = crypto.generateKeyPair("ed25519")
            local welcome
            run(env.net, { env.service }, {
                function()
                    local cell = env.connect(cell_key, "10.0.0.11")
                    local reply = hello(cell, "cell", 11, { signing = hex(tower_public), area = 2 })
                    expect(reply):same { waiting = true, fingerprint = fingerprint(cell_key) }
                    welcome = cell:receive(60)
                end,
                function()
                    local admin = env.admin()
                    local status
                    repeat
                        status = ask(admin, { op = "status" })
                        coroutine.yield()
                    until #status.waiting == 1
                    local waiting = status.waiting[1]
                    expect({ waiting.key, waiting.id, waiting.role, waiting.fingerprint })
                        :same { cell_key, 11, "cell", fingerprint(cell_key) }

                    expect(ask(admin, { op = "allow", key = cell_key })):same {
                        role = "cell", id = 11, label = "cell #11", fingerprint = fingerprint(cell_key),
                    }
                    wait_until(function() return welcome end)
                    status = ask(admin, { op = "status" })
                    expect(#status.waiting):eq(0)
                    expect(status.cells[1].id):eq(11)
                    expect(status.cells[1].address):eq("10.0.0.11")
                    expect(status.cells[1].area):eq(2)
                    admin:close()
                end,
            })

            expect(welcome.network):eq("ACME")
            expect(welcome.tunnel_key):type("string")
            local cert = certificate.decode(welcome.certificate)
            expect(certificate.verify(crypto, cert, {
                name = common.cell_name("ACME", 11), key = tower_public, now = env.now(), trusted = { [env.signing] = true },
            })):eq(true)
            expect(env.service.core.towers[11]):ne(nil)
            -- It's remembered, so it's let straight in next time.
            expect(read_table(fs.combine(DIR, "cells"))[cell_key]):same { label = "cell #11", role = "cell", id = 11 }
        end)

        it("passes control messages between the core and its cells, and forgets cells which go", function()
            local env = setup()
            local cell_key = new_key()
            local _, tower_public = crypto.generateKeyPair("ed25519")
            env.service.allowed[cell_key] = { label = "tower", role = "cell" }
            run(env.net, { env.service }, { function()
                local cell = env.connect(cell_key, "10.0.0.11")
                local welcome = hello(cell, "cell", 11, { signing = hex(tower_public) })
                expect(welcome.network):eq("ACME")
                -- The cell learns the relays its backhaul goes through: none.
                expect(cell:receive(5)):same { op = "path", path = {} }
                -- The core's messages come down the connection, and the cell's go up it.
                env.service.core:send(11, { op = "release", teid = 5 })
                expect(cell:receive(5)):same { op = "release", teid = 5 }
                assert(cell:send({ op = "attach", phone = 70, handshake = "not a handshake" }))
                coroutine.yield()

                cell:close()
                wait_until(function() return env.service.cells[11] == nil end)
                expect(env.service.core.towers[11]):eq(nil)
            end, })
            -- Its ID is remembered with its key.
            expect(env.service.allowed[cell_key].id):eq(11)
        end)

        it("refuses computers it has denied, and drops their connections", function()
            local env = setup()
            local cell_key = new_key()
            local _, tower_public = crypto.generateKeyPair("ed25519")
            env.service.allowed[cell_key] = { label = "tower", role = "cell" }
            run(env.net, { env.service }, { function()
                local cell = env.connect(cell_key)
                expect(hello(cell, "cell", 11, { signing = hex(tower_public) }).network):eq("ACME")

                local admin = env.admin()
                expect(ask(admin, { op = "deny", key = cell_key })):same { id = 11 }
                expect(ask(admin, { op = "deny", key = env.identity })):same { error = "The core's own computer is always allowed" }
                wait_until(function() return cell.is_gone() end)
                wait_until(function() return env.service.core.towers[11] == nil end)

                cell = env.connect(cell_key)
                expect(hello(cell, "cell", 11, { signing = hex(tower_public) })):same { error = "The core has refused this computer." }

                -- Until it's allowed again.
                expect(ask(admin, { op = "allow", key = cell_key }).role):eq("cell")
                cell = env.connect(cell_key)
                expect(hello(cell, "cell", 11, { signing = hex(tower_public) }).network):eq("ACME")
                admin:close()
            end, })
        end)

        it("lets computers in for what they were allowed, and nothing else", function()
            local env = setup()
            local cell_key, admin_key = new_key(), new_key()
            env.service.allowed[cell_key] = { label = "tower", role = "cell" }
            run(env.net, { env.service }, {
                function()
                    expect(hello(env.connect(cell_key), "admin", 11)):same {
                        error = "This computer may be a cell, but not manage the network.",
                    }
                    expect(hello(env.connect(new_key()), "boss", 12)):eq(nil)

                    -- A computer which wants to manage the network waits too.
                    local remote = env.connect(admin_key)
                    expect(hello(remote, "admin", 15).waiting):eq(true)
                    expect(remote:receive(60)):same { ok = true, network = "ACME" }
                    expect(ask(remote, { op = "status" }).network):eq("ACME")
                    remote:close()

                    expect(hello(env.connect(admin_key), "cell", 15, { signing = hex(crypto.random(32)) })):same {
                        error = "This computer may manage the network, but not be a cell.",
                    }
                end,
                function()
                    local admin = env.admin()
                    wait_until(function() return env.service.waiting[admin_key] end)
                    expect(ask(admin, { op = "allow", key = admin_key, label = "laptop" })):same {
                        role = "admin", id = 15, label = "laptop", fingerprint = fingerprint(admin_key),
                    }
                    admin:close()
                end,
            })
        end)

        it("only keeps so many computers waiting, for so long", function()
            local env = setup()
            local replies, last = {}, nil
            local functions = {}
            for i = 1, core_service.MAX_WAITING do
                functions[i] = function()
                    local connection = env.connect(new_key())
                    expect(hello(connection, "cell", 100 + i, { signing = hex(crypto.random(32)) }).waiting):eq(true)
                    replies[i] = connection:receive(core_service.WAIT_TIMEOUT + 60)
                end
            end
            functions[#functions + 1] = function()
                wait_until(function()
                    local count = 0
                    for _ in pairs(env.service.waiting) do count = count + 1 end
                    return count == core_service.MAX_WAITING
                end)
                last = hello(env.connect(new_key()), "cell", 99, { signing = hex(crypto.random(32)) })
            end
            run(env.net, { env.service }, functions, core_service.WAIT_TIMEOUT + 120, 5)

            expect(last):same { error = "Too many computers are waiting for the core to allow them. Try again later." }
            for i = 1, core_service.MAX_WAITING do
                expect(replies[i]):same { error = "Nobody allowed this computer in time. Try again." }
            end
            expect(next(env.service.waiting)):eq(nil)
        end)

        it("forgets computers which stop waiting, or connect again", function()
            local env = setup()
            local key = new_key()
            run(env.net, { env.service }, { function()
                local first = env.connect(key)
                expect(hello(first, "cell", 11, { signing = hex(crypto.random(32)) }).waiting):eq(true)
                local second = env.connect(key)
                expect(hello(second, "cell", 11, { signing = hex(crypto.random(32)) }).waiting):eq(true)
                wait_until(function() return first.is_gone() end)
                expect(env.service.waiting[key].connection):ne(nil)

                second:abort()
                wait_until(function() return env.service.waiting[key] == nil end)
            end, })
        end)

        it("makes activation codes, and removes subscribers", function()
            local env = setup()
            local sim = new_key()
            env.service.subscribers[sim] = { id = "ACME-1", number = "100" }
            run(env.net, { env.service }, { function()
                local admin = env.admin()
                local code = ask(admin, { op = "add", id = "ACME-2", number = "200" }).code
                expect(common.parse_code(code)):ne(nil)
                expect(ask(admin, { op = "add", id = "ACME-3", number = "100" })):same {
                    error = "ACME-1 already has the number 100",
                }
                expect(ask(admin, { op = "add", id = "ACME 3", number = "300" })):same {
                    error = "IDs and numbers are up to 32 letters, digits, and . - _ or +",
                }
                expect(ask(admin, { op = "status" }).codes):eq(1)

                local subscribers = ask(admin, { op = "status" }).subscribers
                expect(#subscribers):eq(1)
                expect({ subscribers[1].id, subscribers[1].number, subscribers[1].fingerprint })
                    :same { "ACME-1", "100", fingerprint(sim) }

                expect(ask(admin, { op = "remove", subscriber = "100" })):same { removed = 1, codes = 0 }
                expect(ask(admin, { op = "remove", subscriber = "ACME-2" })):same { removed = 0, codes = 1 }
                expect(ask(admin, { op = "remove", subscriber = "ACME-1" })):same { error = "There's no subscriber ACME-1" }
                admin:close()
            end, })
            expect(env.service.subscribers[sim]):eq(nil)
            expect(read_table(fs.combine(DIR, "subscribers"))):same {}
            expect(read_table(fs.combine(DIR, "codes"))):same {}
        end)

        it("bars subscribers, and keeps them from roaming", function()
            local sim = new_key()
            local env = setup({ subscribers = { [sim] = { id = "ACME-1", number = "1" } } })
            local detached = {}
            env.service.core.detach = function(_, which) detached[#detached + 1] = which end
            run(env.net, { env.service }, { function()
                local admin = env.admin()
                expect(ask(admin, { op = "set", subscriber = "ACME-1", barred = true })):same {
                    id = "ACME-1", number = "1", barred = true, roaming = true,
                }
                expect(detached):same { sim }
                expect(read_table(fs.combine(DIR, "subscribers"))[sim]):same { id = "ACME-1", number = "1", barred = true }
                local listed = ask(admin, { op = "status" }).subscribers[1]
                expect({ listed.barred, listed.may_roam }):same { true, true }

                -- By number too. Roaming is allowed unless it's forbidden.
                expect(ask(admin, { op = "set", subscriber = "1", barred = false, roaming = false })):same {
                    id = "ACME-1", number = "1", barred = false, roaming = false,
                }
                expect(read_table(fs.combine(DIR, "subscribers"))[sim]):same { id = "ACME-1", number = "1", roaming = false }
                expect(ask(admin, { op = "status" }).subscribers[1].may_roam):eq(false)
                expect(ask(admin, { op = "set", subscriber = "1", roaming = true }).roaming):eq(true)
                expect(read_table(fs.combine(DIR, "subscribers"))[sim]):same { id = "ACME-1", number = "1" }

                expect(ask(admin, { op = "set", subscriber = "ACME-9", barred = true })):same { error = "There's no subscriber ACME-9" }
                expect(ask(admin, { op = "set", subscriber = "1", barred = "yes" }).error):ne(nil)
                admin:close()
            end, })
            -- The core refuses a barred subscriber's phone.
            expect(env.service.core.subscribers[sim].barred):eq(nil)
        end)

        it("stops, or starts afresh, when an administrator asks, after answering", function()
            local env = setup()
            local asked = {}
            run(env.net, { env.service }, { function()
                local admin = env.admin()
                -- Not every core can be: only one whose computer says how.
                expect(ask(admin, { op = "stop" })):same { error = "This core can't be stopped from here" }
                expect(ask(admin, { op = "restart" })):same { error = "This core can't be started again from here" }

                env.options.stop = function() asked[#asked + 1] = "stop" end
                env.options.restart = function() asked[#asked + 1] = "restart" end
                expect(ask(admin, { op = "restart" })):same { restarting = true }
                wait_until(function() return #asked == 1 end)
                admin = env.admin()
                expect(ask(admin, { op = "stop" })):same { stopping = true }
                wait_until(function() return #asked == 2 end)
            end, })
            expect(asked):same { "restart", "stop" }
        end)

        it("keeps a log", function()
            local env = setup()
            for i = 1, core_service.LOG_SIZE + 10 do env.service:log("Line " .. i) end
            run(env.net, { env.service }, { function()
                local admin = env.admin()
                local reply = ask(admin, { op = "log" })
                expect(#reply.lines):eq(core_service.LOG_SIZE)
                expect(reply.lines[#reply.lines].text):eq("Line " .. (core_service.LOG_SIZE + 10))
                expect(reply.last):eq(core_service.LOG_SIZE + 11)

                ask(admin, { op = "add", id = "ACME-2", number = "200" })
                reply = ask(admin, { op = "log", after = reply.last })
                expect(#reply.lines):eq(1)
                expect(reply.lines[1].text):eq("Made an activation code for ACME-2, number 200")
                admin:close()
            end, })
        end)

        it("reads cells allowed by older versions", function()
            local cell_key = new_key()
            local env = setup { cells = { [cell_key] = "tower-3" } }
            run(env.net, { env.service }, { function()
                local reply = hello(env.connect(cell_key), "cell", 11, { signing = hex(crypto.random(32)) })
                expect(reply.network):eq("ACME")
            end, })
        end)

        it("can be stopped and started again", function()
            local env = setup()
            local cell_key = new_key()
            env.service.allowed[cell_key] = { label = "tower", role = "cell" }
            local cell
            run(env.net, { env.service }, { function()
                cell = env.connect(cell_key)
                expect(hello(cell, "cell", 11, { signing = hex(crypto.random(32)) }).network):eq("ACME")
            end, })

            env.service:stop()
            expect(cell.is_gone()):eq(true)
            expect(env.listener.closed):eq(true)
            expect(env.stack.interfaces.cellular):eq(nil)

            env.listening = false
            env.service = assert(core_service.new(env.options))
            expect(env.stack.interfaces.cellular):ne(nil)
            run(env.net, { env.service }, { function()
                expect(hello(env.connect(cell_key), "cell", 11, { signing = hex(crypto.random(32)) }).network):eq("ACME")
            end, })
        end)

        local recursive = {}
        recursive.self = recursive
        local NIL = {}
        local BAD = {
            NIL, 0 / 0, math.huge, -math.huge, 1e18, -1, 0.5, 2 ^ 32, "x", {}, true, ("y"):rep(5000), { 1, { 2 } },
        }
        local function with(template, key, value)
            local result = {}
            for k, v in pairs(template) do result[k] = v end
            if value == NIL then result[key] = nil else result[key] = value end
            return result
        end
        local function errors_logged(env)
            local found = {}
            for _, line in ipairs(env.service.lines) do
                if line.text:find("^Error") then found[#found + 1] = line.text end
            end
            return found
        end

        it("answers requests with something unexpected in them, and carries on", function()
            local env = setup()
            run(env.net, { env.service }, { function()
                local admin = env.admin()
                local template = {
                    key = new_key(), label = "label", role = "admin", id = "ACME-1", number = "1", subscriber = "ACME-1", after = 0,
                    network = "BETA", core = "10.0.0.2",
                }
                local asked = 0
                for _, op in ipairs { "status", "allow", "deny", "add", "remove", "log", "carry", "uncarry", "nonsense" } do
                    for field in pairs(template) do
                        for _, bad in ipairs(BAD) do
                            local request = with(template, field, bad)
                            request.op = op
                            expect(type(ask(admin, request))):describe(op .. " with a bad " .. field):eq("table")
                            asked = asked + 1
                        end
                    end
                end
                for _, bad in ipairs(BAD) do
                    if bad ~= NIL and type(bad) ~= "table" then
                        expect(ask(admin, { op = bad }).error):describe("A bad request"):ne(nil)
                    end
                end
                expect(asked > 500):eq(true)

                -- It still works, and nothing went wrong inside.
                expect(ask(admin, { op = "status" }).network):eq("ACME")
                expect(ask(admin, { op = "add", id = "ACME-2", number = "2" }).code):type("string")
                expect(errors_logged(env)):same {}
                admin:close()
            end, }, 600)
        end)

        it("turns away computers which introduce themselves oddly", function()
            local env = setup()
            local cell_key, admin_key, partner_key = new_key(), new_key(), new_key()
            local _, tower_public = crypto.generateKeyPair("ed25519")
            env.service.allowed[cell_key] = { label = "tower", role = "cell" }
            env.service.allowed[admin_key] = { label = "boss", role = "admin" }
            env.service.allowed[partner_key] = { label = "BETA", role = "roam" }
            run(env.net, { env.service }, { function()
                for _, role in ipairs { "cell", "roam" } do
                    local template = { role = role, id = 11, signing = hex(tower_public), area = 1, network = "BETA" }
                    for field in pairs(template) do
                        for _, bad in ipairs(BAD) do
                            for _, key in ipairs { cell_key, admin_key, partner_key, new_key() } do
                                local connection = env.connect(key, "10.0.0.11")
                                assert(connection:send(with(template, field, bad)))
                                connection:receive(2)
                                connection:abort()
                            end
                        end
                    end
                end
                -- And computers which say something else entirely, or nothing.
                for _, bad in ipairs(BAD) do
                    local connection = env.connect(cell_key, "10.0.0.11")
                    if bad ~= NIL then assert(connection:send(bad)) end
                    coroutine.yield()
                    connection:abort()
                end

                expect(errors_logged(env)):same {}
                -- Only cells with whole numbers for IDs got in, and none is left.
                wait_until(function() return next(env.service.cells) == nil end)
                expect(next(env.service.core.towers)):eq(nil)
                local admin = env.admin()
                expect(#ask(admin, { op = "status" }).cells):eq(0)
                admin:close()
            end, }, 900)
        end)

        describe("messages between networks", function()
            local function two_cores(acme_numbers, beta_numbers)
                local acme = setup(nil, { numbers = acme_numbers })
                local beta = setup(nil, {
                    dir = DIR .. "-beta", network = "BETA", id = 51, host = 2, prefix = "10.65.0.0/16", net = acme.net,
                    numbers = beta_numbers,
                })
                -- BETA's core reaches ACME's as itself.
                beta.options.connect = function() return acme.connect(beta.identity, "10.0.0.2") end
                return acme, beta
            end

            it("are exchanged with another network's core, once it allows it", function()
                local acme, beta = two_cores("555", "666")
                run(acme.net, { acme.service, beta.service }, { function()
                    local acme_admin, beta_admin = acme.admin(), beta.admin()
                    expect(ask(beta_admin, { op = "peer", network = "ACME", core = "10.0.0.1" })):same {
                        network = "ACME", core = "10.0.0.1", id = 51, fingerprint = fingerprint(beta.identity),
                    }

                    -- ACME's administrator sees who is asking, and allows it.
                    local status
                    repeat
                        status = ask(acme_admin, { op = "status" })
                        coroutine.yield()
                    until #status.waiting == 1
                    expect({ status.waiting[1].role, status.waiting[1].network }):same { "peer", "BETA" }
                    expect(ask(acme_admin, { op = "allow", key = beta.identity })):same {
                        role = "peer", id = 51, label = "BETA", network = "BETA", fingerprint = fingerprint(beta.identity),
                    }
                    wait_until(function() return beta.service.peering.ACME.state == "serving" end)

                    -- Each core knows the other's number prefix.
                    expect(acme.service.core.peers.BETA.prefix):eq("666")
                    expect(beta.service.core.peers.ACME.prefix):eq("555")
                    status = ask(acme_admin, { op = "status" })
                    expect({ status.number_prefix, status.peers }):same {
                        "555", { { network = "BETA", id = 51, connected = true, prefix = "666", waiting = 0 } },
                    }
                    expect(ask(beta_admin, { op = "status" }).peers):same {
                        { network = "ACME", core = "10.0.0.1", state = "serving", connected = true, prefix = "555", waiting = 0 },
                    }
                    expect(read_table(fs.combine(beta.dir, "peers"))):same { ACME = { core = "10.0.0.1", prefix = "555" } }
                    expect(read_table(fs.combine(acme.dir, "cells"))[beta.identity].prefix):eq("666")

                    -- What the cores say to each other passes over the connection, both ways.
                    local at_acme, at_beta = {}, {}
                    local acme_control, beta_control = acme.service.core.peer_control, beta.service.core.peer_control
                    acme.service.core.peer_control = function(core, from, message, send)
                        at_acme[#at_acme + 1] = { from, message }
                        return acme_control(core, from, message, send)
                    end
                    beta.service.core.peer_control = function(core, from, message, send)
                        at_beta[#at_beta + 1] = { from, message }
                        return beta_control(core, from, message, send)
                    end
                    acme.service.core.peers.BETA.links[1]({ op = "sms_reply", id = 1, ok = true })
                    beta.service.core.peers.ACME.links[1]({ op = "sms_reply", id = 2, ok = true })
                    wait_until(function() return #at_acme > 0 and #at_beta > 0 end)
                    expect(at_beta):same { { "ACME", { op = "sms_reply", id = 1, ok = true } } }
                    expect(at_acme):same { { "BETA", { op = "sms_reply", id = 2, ok = true } } }

                    -- The same core may carry ACME's phones too: it's allowed for that apart.
                    ask(beta_admin, { op = "carry", network = "ACME", core = "10.0.0.1" })
                    repeat
                        status = ask(acme_admin, { op = "status" })
                        coroutine.yield()
                    until #status.waiting == 1
                    expect(status.waiting[1].role):eq("roam")
                    expect(ask(acme_admin, { op = "allow", key = beta.identity })):same {
                        role = "roam", id = 51, label = "BETA", network = "BETA", fingerprint = fingerprint(beta.identity),
                    }
                    wait_until(function() return beta.service.carrying.ACME.state == "serving" end)
                    expect(read_table(fs.combine(acme.dir, "cells"))[beta.identity]):same {
                        label = "BETA", role = "peer", id = 51, network = "BETA", signing = hex(beta.signing), roles = { roam = true },
                        prefix = "666",
                    }
                    expect(acme.service.core.partner_keys):same { BETA = { signing = beta.signing } }
                    expect(beta.service.peering.ACME.state):eq("serving")

                    -- With a new number prefix, BETA's core connects again, and hears it.
                    expect(ask(acme_admin, { op = "numbers", prefix = "556" })):same { prefix = "556" }
                    wait_until(function()
                        return beta.service.core.peers.ACME.prefix == "556" and beta.service.peering.ACME.state == "serving"
                    end)
                    expect(read_table(fs.combine(acme.dir, "config")).number_prefix):eq("556")
                    expect(acme.service.core.number_prefix):eq("556")
                    expect(ask(acme_admin, { op = "numbers", prefix = "666" }).error):eq("BETA has the number prefix 666")
                    expect(ask(acme_admin, { op = "numbers", prefix = "12a" }).error):eq("Number prefixes are 1 to 8 digits")

                    -- Either side can end it: BETA stops connecting.
                    expect(ask(beta_admin, { op = "unpeer", network = "ACME" })):same { network = "ACME" }
                    wait_until(function() return acme.service.peer_links.BETA == nil end)
                    expect(read_table(fs.combine(beta.dir, "peers"))):same {}
                    expect(ask(beta_admin, { op = "unpeer", network = "ACME" }).error)
                        :eq("This network doesn't connect to the core of ACME")
                    -- Carrying ACME's phones goes on.
                    expect(beta.service.carrying.ACME.state):eq("serving")
                    expect(errors_logged(acme)):same {}
                    acme_admin:close()
                    beta_admin:close()
                end, }, 600)
            end)

            it("are kept for a peer which hasn't connected since its core started", function()
                local acme, beta = two_cores("555", "666")
                run(acme.net, { acme.service, beta.service }, { function()
                    local acme_admin, beta_admin = acme.admin(), beta.admin()
                    ask(beta_admin, { op = "peer", network = "ACME", core = "10.0.0.1" })
                    repeat coroutine.yield() until #ask(acme_admin, { op = "status" }).waiting == 1
                    ask(acme_admin, { op = "allow", key = beta.identity })
                    wait_until(function() return beta.service.peering.ACME.state == "serving" end)
                    acme_admin:close()
                    beta_admin:close()
                end, })

                -- Both cores start again. Before they connect, each knows the other's prefix: messages for it wait.
                acme.service:stop()
                beta.service:stop()
                acme.listening, beta.listening = false, false
                acme.service = assert(core_service.new(acme.options))
                beta.options.connect = function() return nil, "No route to host" end
                beta.service = assert(core_service.new(beta.options))
                expect({ acme.service.core.peers.BETA.prefix, #acme.service.core.peers.BETA.links }):same { "666", 0 }
                expect({ beta.service.core.peers.ACME.prefix, #beta.service.core.peers.ACME.links }):same { "555", 0 }
                expect(acme.service.core:find_number("6660042")):eq("BETA")

                -- Ending it forgets the prefix: its numbers can't be reached.
                run(acme.net, { acme.service, beta.service }, { function()
                    local beta_admin = beta.admin()
                    expect(ask(beta_admin, { op = "unpeer", network = "ACME" })):same { network = "ACME" }
                    beta_admin:close()
                end, })
                expect(beta.service.core.peers.ACME):eq(nil)
                expect(beta.service.core:find_number("5550042")):eq(false)
            end)

            it("need both networks to have number prefixes, and different ones", function()
                local acme, beta = two_cores(nil, "666")
                acme.service.allowed[beta.identity] = { label = "BETA", role = "peer" }
                run(acme.net, { acme.service, beta.service }, { function()
                    local acme_admin, beta_admin = acme.admin(), beta.admin()
                    expect(ask(acme_admin, { op = "peer", network = "BETA", core = "10.0.0.2" }).error)
                        :eq("Set this network's number prefix first, with 'cellcore numbers'")

                    ask(beta_admin, { op = "peer", network = "ACME", core = "10.0.0.1" })
                    wait_until(function() return beta.service.peering.ACME.error == "ACME has no number prefix yet." end)
                    ask(acme_admin, { op = "numbers", prefix = "666" })
                    wait_until(function() return beta.service.peering.ACME.error == "ACME has the number prefix 666 too." end)
                    ask(acme_admin, { op = "numbers", prefix = "555" })
                    wait_until(function() return beta.service.peering.ACME.state == "serving" end)
                    expect(acme.service.core.peers.BETA.prefix):eq("666")
                    acme_admin:close()
                    beta_admin:close()
                end, }, 600)
            end)
        end)

        describe("roaming", function()
            local function two_cores(allowed)
                local acme = setup(allowed and { cells = allowed })
                local beta = setup(nil, { dir = DIR .. "-beta", network = "BETA", id = 51, host = 2, prefix = "10.65.0.0/16", net = acme.net })
                -- BETA's core reaches ACME's as itself.
                beta.options.connect = function() return acme.connect(beta.identity, "10.0.0.2") end
                return acme, beta
            end

            it("carries another network's phones, once that network's core allows it", function()
                local acme, beta = two_cores()
                run(acme.net, { acme.service, beta.service }, { function()
                    local acme_admin, beta_admin = acme.admin(), beta.admin()
                    expect(ask(beta_admin, { op = "carry", network = "ACME", core = "10.0.0.1" })):same {
                        network = "ACME", core = "10.0.0.1", id = 51, fingerprint = fingerprint(beta.identity),
                    }

                    -- ACME's administrator sees who is asking, and allows it.
                    local status
                    repeat
                        status = ask(acme_admin, { op = "status" })
                        coroutine.yield()
                    until #status.waiting == 1
                    local waiting = status.waiting[1]
                    expect({ waiting.key, waiting.id, waiting.role, waiting.network }):same { beta.identity, 51, "roam", "BETA" }
                    expect(ask(beta_admin, { op = "status" }).carrying):same {
                        { network = "ACME", core = "10.0.0.1", state = "waiting", phones = 0 },
                    }
                    expect(ask(acme_admin, { op = "allow", key = beta.identity })):same {
                        role = "roam", id = 51, label = "BETA", network = "BETA", fingerprint = fingerprint(beta.identity),
                    }
                    wait_until(function() return beta.service.carrying.ACME.state == "serving" end)

                    -- To ACME's core, BETA's is a cell, and its phones are told they may use BETA's cells.
                    expect(acme.service.core.towers[51].partner):eq("BETA")
                    expect(acme.service.core.partner_keys):same { BETA = { signing = beta.signing } }
                    expect(beta.service.core.partners.ACME):ne(nil)
                    expect(ask(acme_admin, { op = "status" }).partners):same { {
                        network = "BETA", id = 51, key = beta.identity, fingerprint = fingerprint(beta.identity), phones = 0,
                        connected = true, address = "10.0.0.2", home = false,
                    }, }
                    expect(ask(beta_admin, { op = "status" }).carrying[1].state):eq("serving")
                    expect(read_table(fs.combine(acme.dir, "cells"))[beta.identity]):same {
                        label = "BETA", role = "roam", id = 51, network = "BETA", signing = hex(beta.signing),
                    }
                    expect(read_table(fs.combine(beta.dir, "roaming"))):same { ACME = { core = "10.0.0.1" } }

                    -- ACME's phones may treat BETA as home, and roam on it again.
                    expect(ask(acme_admin, { op = "partner", network = "BETA", home = true })):same { network = "BETA", home = true }
                    expect(acme.service.core.partner_keys):same { BETA = { signing = beta.signing, home = true } }
                    expect(read_table(fs.combine(acme.dir, "cells"))[beta.identity].home):eq(true)
                    expect(ask(acme_admin, { op = "status" }).partners[1].home):eq(true)
                    expect(ask(acme_admin, { op = "partner", network = "GAMMA", home = true }).error)
                        :eq("GAMMA doesn't carry this network's phones")
                    expect(ask(acme_admin, { op = "partner", network = "BETA", home = "yes" }).error)
                        :eq("Expected home to be true or false")
                    expect(ask(acme_admin, { op = "partner", network = "BETA", home = false })):same { network = "BETA", home = false }
                    expect(acme.service.core.partner_keys):same { BETA = { signing = beta.signing } }

                    -- What the cores say to each other passes over the connection, both ways.
                    local at_home, at_partner = {}, {}
                    local control, partner_control = acme.service.core.control, beta.service.core.partner_control
                    acme.service.core.control = function(core, id, message)
                        at_home[#at_home + 1] = { id, message }
                        return control(core, id, message)
                    end
                    beta.service.core.partner_control = function(core, from, message)
                        at_partner[#at_partner + 1] = { from, message }
                        return partner_control(core, from, message)
                    end
                    beta.service.core.partners.ACME.send({ op = "sms_ack", teid = 5, id = 1 })
                    acme.service.core:send(51, { op = "release", teid = 5 })
                    wait_until(function() return #at_home > 0 and #at_partner > 0 end)
                    expect(at_home):same { { 51, { op = "sms_ack", teid = 5, id = 1 } } }
                    expect(at_partner[#at_partner]):same { "ACME", { op = "release", teid = 5 } }

                    -- It connects again when it loses ACME's core.
                    acme.service.partners.BETA.connection:abort()
                    wait_until(function() return beta.service.carrying.ACME.state == "lost" end)
                    expect(beta.service.core.partners.ACME):eq(nil)
                    wait_until(function() return beta.service.carrying.ACME.state == "serving" end)
                    expect(acme.service.core.towers[51].partner):eq("BETA")

                    -- Either side can end it. ACME refuses BETA: its phones are no longer told of BETA's cells.
                    expect(ask(acme_admin, { op = "deny", key = beta.identity })):same { id = 51 }
                    wait_until(function() return beta.service.carrying.ACME.state == "refused" end)
                    expect(beta.service.carrying.ACME.error):eq("The core has refused this computer.")
                    expect(acme.service.core.partner_keys):same {}
                    expect(acme.service.core.towers[51]):eq(nil)
                    expect(ask(acme_admin, { op = "status" }).partners):same {}

                    expect(ask(beta_admin, { op = "uncarry", network = "ACME" })):same { network = "ACME" }
                    expect(ask(beta_admin, { op = "uncarry", network = "ACME" }).error):eq("This network doesn't carry the phones of ACME")
                    expect(ask(beta_admin, { op = "status" }).carrying):same {}
                    expect(read_table(fs.combine(beta.dir, "roaming"))):same {}
                    acme_admin:close()
                    beta_admin:close()
                end, }, 300)
            end)

            it("is set up again when the cores start", function()
                local acme, beta = two_cores()
                acme.service.allowed[beta.identity] = { label = "BETA", role = "roam" }
                run(acme.net, { acme.service, beta.service }, { function()
                    local beta_admin = beta.admin()
                    ask(beta_admin, { op = "carry", network = "ACME", core = "10.0.0.1" })
                    wait_until(function() return beta.service.carrying.ACME.state == "serving" end)
                    beta_admin:close()
                end, })

                -- ACME's core starts again: it tells phones of BETA before BETA's core has connected.
                acme.service:stop()
                beta.service:stop()
                acme.listening, beta.listening = false, false
                acme.service = assert(core_service.new(acme.options))
                expect(acme.service.core.partner_keys):same { BETA = { signing = beta.signing } }
                -- And BETA's connects to ACME's by itself.
                beta.service = assert(core_service.new(beta.options))
                run(acme.net, { acme.service, beta.service }, { function()
                    wait_until(function() return beta.service.carrying.ACME.state == "serving" end)
                    expect(acme.service.core.towers[51].partner):eq("BETA")
                end, })
            end)

            it("only takes a partner as the network it was allowed as", function()
                local key, other_key = new_key(), new_key()
                local acme = setup({ cells = {
                    [key] = { label = "BETA", role = "roam", network = "BETA", id = 51 },
                    [other_key] = { label = "tower", role = "cell" },
                }, })
                local signing = hex(crypto.random(32))
                run(acme.net, { acme.service }, { function()
                    local function try(with_key, role, name)
                        return hello(acme.connect(with_key, "10.0.0.2"), role, 51, { network = name, signing = signing })
                    end
                    expect(try(key, "roam", "GAMMA")):same { error = "This computer was allowed as the core of BETA, not of GAMMA." }
                    expect(try(key, "roam", "ACME")):same { error = "That's this network's own name." }
                    expect(try(key, "cell", "BETA")):same { error = "This computer may carry the network's phones, but not be a cell." }
                    expect(try(other_key, "roam", "BETA")):same { error = "This computer may be a cell, but not carry the network's phones." }
                    expect(try(key, "roam", "BETA").network):eq("ACME")

                    -- Another computer can't be allowed as a network which has a core already.
                    local third = new_key()
                    acme.service.allowed[third] = { label = "BETA too", role = "roam" }
                    expect(try(third, "roam", "BETA")):same { error = "Another computer is the core of BETA." }
                end, })
            end)

            it("says when the core it connects to isn't the network's", function()
                local acme, beta = two_cores()
                acme.service.allowed[beta.identity] = { label = "BETA", role = "roam" }
                run(acme.net, { acme.service, beta.service }, { function()
                    local beta_admin = beta.admin()
                    ask(beta_admin, { op = "carry", network = "GAMMA", core = "10.0.0.1" })
                    wait_until(function() return beta.service.carrying.GAMMA.state == "refused" end)
                    expect(beta.service.carrying.GAMMA.error):eq("That's the core of ACME, not of GAMMA")
                    expect(beta.service.core.partners.GAMMA):eq(nil)

                    expect(ask(beta_admin, { op = "carry", network = "BETA", core = "10.0.0.1" })):same { error = "That's this network" }
                    expect(ask(beta_admin, { op = "carry", network = "no spaces", core = "10.0.0.1" }).error):ne(nil)
                    expect(ask(beta_admin, { op = "carry", network = "ACME", core = "" }).error):ne(nil)
                    beta_admin:close()
                end, })
            end)
        end)

        it("needs setting up first", function()
            local env = setup()
            fs.delete(fs.combine(DIR, "config"))
            env.service:stop()
            env.listening = false
            expect({ core_service.new(env.options) }):same { nil, "Set the network up first, with 'cellcore setup'." }
        end)
    end)

    describe("a cell", function()
        local function cell_setup(cores)
            local net = network()
            local key, core_key = new_key(), new_key()
            local _, signing = crypto.generateKeyPair("ed25519")
            local env = { net = net, connections = {}, towers = {}, key = key }
            env.service = cell_service.new {
                core = not cores and "core.acme" or nil, cores = cores,
                area = 3, id = 11, identity = key, fingerprint = fingerprint, signing = hex(signing),
                connect = function(core)
                    if env.unreachable then return nil, "No route to host" end
                    local mine, theirs = pipe(function() return net.time end,
                        { key = key, address = "10.0.0.11" }, { key = core_key, address = "10.0.0.1" })
                    env.connections[#env.connections + 1] = theirs
                    env.core_name = core
                    return mine
                end,
                start_tower = function(welcome, control)
                    local tower = { welcome = welcome, send = control, messages = {} }
                    function tower.control(_, message) tower.messages[#tower.messages + 1] = message end
                    function tower.stop() tower.stopped = true end
                    env.towers[#env.towers + 1] = tower
                    return tower
                end,
                sleep = function(seconds)
                    local done = net.time + seconds
                    while net.time < done do coroutine.yield() end
                end,
                wake = function() end,
            }
            env.signing = hex(signing)
            return env
        end

        it("waits to be allowed, serves, and connects again when it loses the core", function()
            local env = cell_setup()
            run(env.net, { env.service }, { function()
                local core = env.connections[1]
                expect(env.core_name):eq("core.acme")
                expect(core:receive(5)):same { role = "cell", id = 11, signing = env.signing, area = 3 }
                expect(env.service:info().state):eq("connecting")

                core:send({ waiting = true, fingerprint = fingerprint(env.key) })
                wait_until(function() return env.service:info().state == "waiting" end)
                expect(env.service:info()):same {
                    state = "waiting", core = "core.acme", area = 3, id = 11, fingerprint = fingerprint(env.key),
                    links = { { core = "core.acme", state = "waiting" } },
                }

                core:send({ network = "ACME", certificate = "certificate", tunnel_key = "key" })
                wait_until(function() return env.service:info().state == "serving" end)
                expect(env.service:info().network):eq("ACME")
                local tower = env.towers[1]
                expect(tower.welcome):same {
                    network = "ACME", certificate = "certificate", tunnel_key = "key", core = "10.0.0.1", area = 3,
                }

                -- Control messages go both ways.
                core:send({ op = "context", phone = 70 })
                wait_until(function() return tower.messages[1] end)
                expect(tower.messages[1]):same { op = "context", phone = 70 }
                tower.send({ op = "attach", phone = 70 })
                expect(core:receive(5)):same { op = "attach", phone = 70 }

                -- Losing the core stops the cell, until it connects again.
                core:abort()
                wait_until(function() return env.service:info().state == "lost" end)
                expect(tower.stopped):eq(true)
                expect(env.service:info().error):eq("Connection reset")
                wait_until(function() return env.connections[2] end)
                expect(env.connections[2]:receive(5).role):eq("cell")
            end, })
        end)

        it("serves several networks, through each one's core, and the others while it loses one", function()
            local env = cell_setup({ "core.acme", "core.beta" })
            run(env.net, { env.service }, { function()
                wait_until(function() return env.connections[2] end)
                local acme, beta = env.connections[1], env.connections[2]
                expect(acme:receive(5).role):eq("cell")
                expect(beta:receive(5).role):eq("cell")
                acme:send({ network = "ACME", certificate = "a", tunnel_key = "ka" })
                beta:send({ network = "BETA", certificate = "b", tunnel_key = "kb" })
                wait_until(function() return env.service:info().links[1].state == "serving" and env.service:info().links[2].state == "serving" end)
                expect(env.service:info().links):same {
                    { core = "core.acme", state = "serving", network = "ACME" },
                    { core = "core.beta", state = "serving", network = "BETA" },
                }
                expect({ env.towers[1].welcome.network, env.towers[2].welcome.network }):same { "ACME", "BETA" }

                -- Each core's messages go to its own network's part of the cell, and back.
                beta:send({ op = "path", path = { 7 } })
                wait_until(function() return env.towers[2].messages[1] end)
                expect(env.towers[1].messages):same {}
                env.towers[1].send({ op = "attach", phone = 70 })
                expect(acme:receive(5)):same { op = "attach", phone = 70 }

                -- Losing one core stops serving its network only.
                beta:abort()
                wait_until(function() return env.service:info().links[2].state == "lost" end)
                expect({ env.towers[1].stopped, env.towers[2].stopped }):same { nil, true }
                expect({ env.service:info().state, env.service:info().network }):same { "serving", "ACME" }

                -- Another core of a network it serves already is one too many.
                wait_until(function() return env.connections[3] end)
                env.connections[3]:receive(5)
                env.connections[3]:send({ network = "ACME", certificate = "c", tunnel_key = "kc" })
                wait_until(function() return env.service:info().links[2].state == "refused" end)
                expect(env.service:info().links[2].error):eq("This cell serves ACME through the core core.acme already")
                expect(#env.towers):eq(2)
            end, }, 300)
        end)

        it("tries again, less often each time, while it can't reach the core or is refused", function()
            local env = cell_setup()
            local times = {}
            run(env.net, { env.service }, { function()
                for i = 1, 3 do
                    wait_until(function() return env.connections[i] end)
                    times[i] = env.net.time
                    local core = env.connections[i]
                    core:receive(5)
                    core:send({ error = "The core has refused this computer." })
                    core:close()
                    wait_until(function() return env.service:info().state == "refused" end)
                    expect(env.service:info().error):eq("The core has refused this computer.")
                end
                env.unreachable = true
                wait_until(function() return env.service:info().error == "No route to host" end)
                expect(env.service:info().state):eq("lost")
            end, }, 300)
            -- Two seconds, then four.
            expect(math.floor(times[2] - times[1] + 0.5)):eq(2)
            expect(math.floor(times[3] - times[2] + 0.5)):eq(4)
        end)

        it("stops when told", function()
            local env = cell_setup()
            local core
            run(env.net, { env.service }, { function()
                core = env.connections[1]
                core:receive(5)
                core:send({ network = "ACME", certificate = "certificate", tunnel_key = "key" })
                wait_until(function() return env.service:info().state == "serving" end)
            end, })
            env.service:stop()
            expect(env.towers[1].stopped):eq(true)
            expect(core.is_gone()):eq(true)
            run(env.net, { env.service }, { function()
                local done = env.net.time + 30
                wait_until(function() return env.net.time >= done end)
            end, })
            expect(#env.connections):eq(1)
        end)
    end)
end)
