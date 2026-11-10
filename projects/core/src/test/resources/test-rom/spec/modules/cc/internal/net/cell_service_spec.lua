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

    --[[ A core for ACME, on computer 50, whose files are in DIR. ]]
    local function setup(files)
        fs.delete(DIR)
        write_table(fs.combine(DIR, "config"), { network = "ACME", prefix = "10.64.0.0/16" })
        for name, value in pairs(files or {}) do write_table(fs.combine(DIR, name), value) end

        local net = network()
        local stack = net.stack(50)
        net.connect(stack, "backhaul", "10.0.0.1/24")
        stack.forwarding = true
        local now = function() return 1.7e12 + net.time * 1000 end
        local operator_private = crypto.generateKeyPair("x25519")
        local operator = {
            public = noise.public_key(crypto, operator_private),
            exchange = function(public) return crypto.exchange(operator_private, public) end,
        }
        local signing_private, signing_public = crypto.generateKeyPair("ed25519")
        local env = { net = net, stack = stack, identity = new_key(), signing = signing_public, now = now }

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
            dir = DIR, identity = env.identity, fingerprint = fingerprint,
            listen = function()
                if env.listening then return nil, "Port 2123 is in use" end
                env.listening, env.listener.closed = true, false
                return env.listener
            end,
            start_core = function(options)
                return cell_core.new {
                    stack = stack, crypto = crypto, network = options.network, prefix = options.prefix, operator = operator,
                    signing = signing_public, subscribers = options.subscribers, codes = options.codes,
                    secret = crypto.random(32), epoch = now, on_event = options.on_event,
                }
            end,
            signing = signing_public, sign = function(data) return crypto.sign(signing_private, data) end,
            clock = function() return net.time end, epoch = now, wake = function() end,
        }
        env.service = assert(core_service.new(env.options))

        -- Connect to the core, as a computer with this key.
        function env.connect(key, addr)
            local client, server = pipe(function() return net.time end,
                { key = key, address = addr or "10.0.0.9" }, { key = env.identity, address = "10.0.0.1" })
            table.insert(env.listener.queue, server)
            return client
        end

        -- Connect as the core's own computer, to manage it.
        function env.admin()
            local admin = env.connect(env.identity, "127.0.0.1")
            expect(hello(admin, "admin", 50)):same { ok = true, network = "ACME" }
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

        it("needs setting up first", function()
            local env = setup()
            fs.delete(fs.combine(DIR, "config"))
            env.service:stop()
            env.listening = false
            expect({ core_service.new(env.options) }):same { nil, "Set the network up first, with 'cellcore setup'." }
        end)
    end)

    describe("a cell", function()
        local function cell_setup()
            local net = network()
            local key, core_key = new_key(), new_key()
            local _, signing = crypto.generateKeyPair("ed25519")
            local env = { net = net, connections = {}, towers = {}, key = key }
            env.service = cell_service.new {
                core = "core.acme", area = 3, id = 11, identity = key, fingerprint = fingerprint, signing = hex(signing),
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
