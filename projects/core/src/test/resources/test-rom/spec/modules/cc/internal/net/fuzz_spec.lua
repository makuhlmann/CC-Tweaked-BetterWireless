-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

--[[ Misbehaving computers: every field of every message the network stack reads, filled with values it doesn't
expect. Nothing may escape as an error, leave the stack in a state which breaks later, or stop it working. ]]

describe("The network stack, given bad messages,", function()
    local Stack = require "cc.internal.net.stack"
    local rip = require "cc.internal.net.rip"
    local tcp = require "cc.internal.net.tcp"
    local dhcp = require "cc.internal.net.dhcp"
    local dns = require "cc.internal.net.dns"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    local NIL = {}
    local recursive = {}
    recursive.self = recursive
    local BAD = {
        { "nil", NIL }, { "NaN", 0 / 0 }, { "inf", math.huge }, { "-inf", -math.huge }, { "1e18", 1e18 },
        { "-1", -1 }, { "0.5", 0.5 }, { "2^32", 2 ^ 32 }, { "a string", "x" }, { "a table", {} }, { "true", true },
        { "a recursive table", recursive },
    }

    -- A copy of a table with one field replaced.
    local function with(template, key, value)
        local result = {}
        for k, v in pairs(template) do result[k] = v end
        if value == NIL then result[key] = nil else result[key] = value end
        return result
    end

    -- Every variant of a template with one field made bad.
    local function variants(name, template, fields, wrap)
        local result = {}
        for _, field in ipairs(fields) do
            for _, bad in ipairs(BAD) do
                result[#result + 1] = { name = ("%s with %s = %s"):format(name, field, bad[1]), value = wrap(with(template, field, bad[2])) }
            end
        end
        return result
    end

    local function is_integer(value, min, max)
        return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
    end
    local function is_address(value) return is_integer(value, 0, 0xFFFFFFFF) end

    -- Check nothing has been left in a state which breaks later.
    local function check_sane(stack)
        local deadline = stack:next_deadline()
        if deadline ~= nil and not (deadline == deadline and deadline < math.huge) then
            error("Deadline is " .. tostring(deadline), 0)
        end
        for _, route in ipairs(stack.routes) do
            if not is_address(route.network) or not is_integer(route.prefix, 0, 32) or not is_integer(route.metric, 0, Stack.INFINITY)
                or (route.gateway ~= nil and not is_address(route.gateway)) then
                error(("Bad route %s/%s via %s, metric %s"):format(
                    tostring(route.network), tostring(route.prefix), tostring(route.gateway), tostring(route.metric)
                ), 0)
            end
        end
        for name, interface in pairs(stack.interfaces) do
            if interface.address ~= nil and (not is_address(interface.address) or not is_integer(interface.prefix, 1, 32)) then
                error(("Bad address %s/%s on %s"):format(tostring(interface.address), tostring(interface.prefix), name), 0)
            end
            for addr, neighbour in pairs(interface.neighbours) do
                if not is_address(addr) or type(neighbour.id) ~= "number" then error("Bad neighbour " .. tostring(addr), 0) end
            end
        end
    end

    --[[ The computer under attack is a router, running RIP and answering mDNS:

        peer 2 (10.0.0.2) -- top -- (10.0.0.1) target 1 (10.1.0.1) -- b -- (10.1.0.2) far 3

    Bad messages come from computer 9, which says it's 10.0.0.9.
    ]]
    local function yield()
        os.queueEvent("fuzz_yield")
        os.pullEvent("fuzz_yield")
    end

    -- A network which gives up quickly when something loops.
    local function small_network()
        local net = network()
        net.step_limit = 2000
        return net
    end

    local function target_network()
        local net = small_network()
        local target = net.stack(1)
        net.connect(target, "top", "10.0.0.1/24")
        net.connect(target, "b", "10.1.0.1/24")
        target.forwarding = true
        rip.start(target)
        dns.respond(target, { hostname = function() return "target" end, services = { chat = 1234 } })
        tcp.listen(target, 22)

        local peer = net.stack(2)
        net.connect(peer, "top", "10.0.0.2/24")
        peer:add_route { network = 0, prefix = 0, gateway = ip("10.0.0.1"), source = "static" }
        local far = net.stack(3)
        net.connect(far, "b", "10.1.0.2/24")
        far:add_route { network = 0, prefix = 0, gateway = ip("10.1.0.1"), source = "static" }
        net.advance(5)
        return net, target, peer
    end

    -- Open a connection from the peer to the target, and check a message gets across.
    local function check_connection(net, target, peer)
        local client = tcp.connect(peer, ip("10.0.0.1"), 22)
        net.advance(1)
        local server = target.tcp.listeners[22]:accept()
        if not server then error("Couldn't connect: " .. tostring(client.error or client.state), 0) end
        client:send("hello")
        net.advance(1)
        local ok, value = server:take()
        if not ok or value ~= "hello" then error("Message didn't arrive: " .. tostring(value), 0) end
        return client, server
    end

    local function check_healthy(net, target, peer)
        check_sane(target)
        net.advance(2)
        for _, dst in ipairs { "10.0.0.1", "10.1.0.2" } do
            local result = net.ping(peer, ip(dst))
            if not result or result.error then error("Ping to " .. dst .. " failed: " .. tostring(result and result.error), 0) end
        end
        check_connection(net, target, peer)
        check_sane(target)
    end

    -- Send each case's frame at the target, and collect everything which goes wrong.
    local function attack(cases, options)
        options = options or {}
        local failures = {}
        for _, case in ipairs(cases) do
            local net, target, peer = target_network()
            local ok, err = pcall(function()
                local channel = options.broadcast and target.interfaces.top.broadcast or target.interfaces.top.unicast
                net.inject("top", channel, case.value ~= NIL and case.value or nil)
                net.advance(3)
                check_healthy(net, target, peer)
            end)
            if not ok then failures[#failures + 1] = case.name .. ": " .. tostring(err) end
            yield()
        end
        expect(failures):same {}
    end

    local function frame(body, kind, dst) return { net = 1, src = 9, dst = dst or 1, type = kind or "ip", body = body } end

    local ECHO = { type = "echo", id = 1, seq = 1, data = "hello" }
    local function packet(body, proto, dst)
        return { v = 1, src = ip("10.0.0.9"), dst = dst or ip("10.0.0.1"), ttl = 32, proto = proto or "icmp", id = 1, body = body }
    end

    it("frames", function()
        local cases = {}
        for _, bad in ipairs(BAD) do cases[#cases + 1] = { name = "frame = " .. bad[1], value = bad[2] } end
        for _, case in ipairs(variants("frame", frame(packet(ECHO)), { "net", "src", "dst", "type", "body" }, function(x) return x end)) do
            cases[#cases + 1] = case
        end
        attack(cases)
    end)

    it("neighbour discovery", function()
        local cases = {}
        for _, op in ipairs { "who", "is" } do
            local body = { op = op, addr = ip(op == "who" and "10.0.0.1" or "10.0.0.9"), from = ip("10.0.0.9") }
            for _, case in ipairs(variants("nd " .. op, body, { "op", "addr", "from" }, function(x) return frame(x, "nd", -1) end)) do
                cases[#cases + 1] = case
            end
        end
        attack(cases, { broadcast = true })
    end)

    it("packet headers", function()
        local fields = { "v", "src", "dst", "ttl", "proto", "id", "body" }
        local cases = variants("packet", packet(ECHO), fields, frame)
        -- And packets to be forwarded.
        for _, case in ipairs(variants("forwarded packet", packet(ECHO, "icmp", ip("10.1.0.2")), fields, frame)) do
            cases[#cases + 1] = case
        end
        attack(cases)
    end)

    it("ICMP", function()
        local cases = variants("echo", ECHO, { "id", "seq", "data" }, function(x) return frame(packet(x)) end)
        local function add(list) for _, case in ipairs(list) do cases[#cases + 1] = case end end
        add(variants("echo reply", { type = "echo_reply", id = 1, seq = 1 }, { "id", "seq" }, function(x) return frame(packet(x)) end))

        local orig = { src = ip("10.0.0.1"), dst = ip("10.0.0.9"), proto = "udp", id = 1, sp = 520, dp = 520, echo = 1 }
        for _, kind in ipairs { "unreachable", "time_exceeded" } do
            local message = { type = kind, code = "port", orig = orig }
            add(variants(kind, message, { "type", "code", "orig" }, function(x) return frame(packet(x)) end))
            add(variants(kind .. " about", orig, { "src", "dst", "proto", "id", "sp", "dp", "echo" }, function(x)
                return frame(packet(with(message, "orig", x)))
            end))
        end
        attack(cases)
    end)

    it("datagrams", function()
        local cases = {}
        for _, port in ipairs { rip.PORT, dns.MDNS_PORT, dhcp.CLIENT_PORT, 9999 } do
            for _, case in ipairs(variants("datagram to " .. port, { sp = 1, dp = port, data = "x" }, { "sp", "dp", "data" }, function(x)
                return frame(packet(x, "udp"))
            end)) do
                cases[#cases + 1] = case
            end
        end
        attack(cases)
    end)

    it("routing updates", function()
        local function update(message) return frame(packet({ sp = rip.PORT, dp = rip.PORT, data = message }, "udp")) end
        local entry = { network = ip("10.5.0.0"), prefix = 16, metric = 1 }
        local cases = variants("update", { version = 1, routes = { entry } }, { "version", "routes", "mac" }, update)
        for _, case in ipairs(variants("route", entry, { "network", "prefix", "metric" }, function(x)
            return update { version = 1, routes = { x } }
        end)) do
            cases[#cases + 1] = case
        end
        for _, bad in ipairs(BAD) do
            if bad[2] ~= NIL then cases[#cases + 1] = { name = "route = " .. bad[1], value = update { version = 1, routes = { bad[2] } } } end
        end
        attack(cases)
    end)

    it("connection segments to a listening port", function()
        local cases = {}
        for _, flags in ipairs { "S", "A", "SA", "FA", "R" } do
            local segment = { sp = 1234, dp = 22, flags = flags, seq = 1000, ack = 5, win = 16, sack = { 7 }, data = "x" }
            for _, case in ipairs(variants("segment " .. flags, segment, { "sp", "dp", "flags", "seq", "ack", "win", "sack", "data" }, function(x)
                return frame(packet(x, "tcp"))
            end)) do
                cases[#cases + 1] = case
            end
        end
        attack(cases)
    end)

    it("connection segments in an open connection", function()
        local failures = {}
        for _, flags in ipairs { "A", "FA", "KA", "R", "SA" } do
            for _, field in ipairs { "seq", "ack", "win", "sack", "data", "flags" } do
                for _, bad in ipairs(BAD) do
                    local name = ("segment %s with %s = %s"):format(flags, field, bad[1])
                    local net, target, peer = target_network()
                    local ok, err = pcall(function()
                        local client, server = check_connection(net, target, peer)
                        -- A segment from the client's own computer, with one field made bad. Resets and opens use the
                        -- right sequence number. Others don't: a forged message or close with exactly the next sequence
                        -- number is accepted, as with TCP, and only encryption can stop that.
                        local exact = flags == "R" or flags == "SA"
                        local segment = {
                            sp = client.local_port, dp = 22, flags = flags, seq = client.snd_nxt + (exact and 0 or 100),
                            ack = client.rcv_nxt, win = 16, sack = { client.rcv_nxt + 1 }, data = flags == "A" and "forged" or nil,
                        }
                        segment = with(segment, field, bad[2])
                        net.inject("top", target.interfaces.top.unicast, {
                            net = 1, src = 2, dst = 1, type = "ip",
                            body = { v = 1, src = ip("10.0.0.2"), dst = ip("10.0.0.1"), ttl = 32, proto = "tcp", id = 1, body = segment },
                        })
                        net.advance(2)
                        check_sane(target)

                        -- The connection either still works, or has failed cleanly.
                        if server.state ~= "closed" then
                            while server:take() do end
                            client:send("still there?")
                            net.advance(2)
                            local got_one, value = server:take()
                            if server.state ~= "closed" and not (got_one and value == "still there?") then
                                error("Connection stopped working: " .. tostring(value), 0)
                            end
                        elseif not server.error then
                            error("Connection closed without a reason", 0)
                        end
                        check_healthy(net, target, peer)
                    end)
                    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
                    yield()
                end
            end
        end
        expect(failures):same {}
    end)

    it("mDNS questions", function()
        local question = { id = 1, name = "target.local", type = "A" }
        local cases = variants("question", question, { "id", "name", "type" }, function(x)
            return frame(packet({ sp = 1, dp = dns.MDNS_PORT, data = x }, "udp", address.BROADCAST), "ip", -1)
        end)
        attack(cases, { broadcast = true })
    end)

    local function dhcp_replies(op)
        local failures = {}
        local template = {
            server = ip("10.0.0.2"), address = ip("10.0.0.50"), prefix = 24, lease = 600, dns = { ip("10.0.0.2") },
            domain = "home", gateway = ip("10.0.0.2"),
        }
        do
            for _, field in ipairs { "op", "xid", "client", "server", "address", "prefix", "lease", "dns", "domain", "gateway" } do
                for _, bad in ipairs(BAD) do
                    local name = ("%s with %s = %s"):format(op, field, bad[1])
                    local net = small_network()
                    local client = net.stack(1)
                    net.connect(client, "top")
                    local server = net.stack(2)
                    net.connect(server, "top", "10.0.0.2/24")
                    local socket
                    socket = server:udp_open(dhcp.SERVER_PORT, function(message)
                        local reply = with(template, "xid", message.xid)
                        reply.client = message.client
                        reply.op = message.op == "discover" and "offer" or "ack"
                        if reply.op == op then reply = with(reply, field, bad[2]) end
                        server:udp_send(socket, address.BROADCAST, dhcp.CLIENT_PORT, reply, "top")
                    end)

                    local ok, err = pcall(function()
                        dhcp.start(client, "top", {})
                        net.advance(60)
                        check_sane(client)
                        if net.frames.top > 100 then error(net.frames.top .. " frames in a minute", 0) end
                        local interface = client.interfaces.top
                        if interface.address and interface.prefix < 31 and (interface.address == address.network(interface.address, interface.prefix)
                            or interface.address == address.broadcast(interface.address, interface.prefix)) then
                            error("Took the address " .. address.format(interface.address, interface.prefix), 0)
                        end
                    end)
                    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
                    yield()
                end
            end
        end
        expect(failures):same {}
    end

    it("DHCP offers", function() dhcp_replies("offer") end)
    it("DHCP acks", function() dhcp_replies("ack") end)

    it("DHCP requests, at the server", function()
        local failures = {}
        local template = { op = "discover", xid = 1, client = 5, hostname = "x", requested = ip("10.0.0.120"), server = ip("10.0.0.2"), address = ip("10.0.0.100") }
        for _, op in ipairs { "discover", "request", "release" } do
            for _, case in ipairs(variants(op, with(template, "op", op), { "op", "xid", "client", "hostname", "requested", "server", "address" }, function(x) return x end)) do
                local server = dhcp.server {
                    address = ip("10.0.0.2"), prefix = 24, first = ip("10.0.0.100"), last = ip("10.0.0.199"), lease = 600,
                    clock = function() return 0 end,
                }
                local ok, err = pcall(function()
                    server:handle(case.value)
                    -- The server still works.
                    local reply = server:handle { op = "discover", xid = 2, client = 6 }
                    if not reply or not is_address(reply.address) then error("No offer afterwards", 0) end
                    for client, lease in pairs(server.leases) do
                        if not is_integer(client, -math.huge, math.huge) or not is_address(lease.address) then error("Bad lease", 0) end
                    end
                end)
                if not ok then failures[#failures + 1] = case.name .. ": " .. tostring(err) end
            end
        end
        expect(failures):same {}
    end)

    it("DNS answers", function()
        local failures = {}
        local record = { name = "x.home", type = "A", value = ip("10.0.0.7"), ttl = 60 }
        local answer = { code = "ok", records = { record } }
        local cases = variants("answer", answer, { "code", "records" }, function(x) return x end)
        for _, case in ipairs(variants("record", record, { "name", "type", "value", "ttl" }, function(x) return with(answer, "records", { x }) end)) do
            cases[#cases + 1] = case
        end
        for _, bad in ipairs(BAD) do
            if bad[2] ~= NIL then cases[#cases + 1] = { name = "record = " .. bad[1], value = with(answer, "records", { bad[2] }) } end
        end

        for _, case in ipairs(cases) do
            local net = network()
            local client = net.add(1, "10.0.0.1/24")
            local server = net.add(2, "10.0.0.2/24")
            local socket
            socket = server:udp_open(53, function(question, from, port)
                local reply = with(case.value, "id", question.id)
                server:udp_send(socket, from, port, reply)
            end)
            local cache = {}
            local ok, err = pcall(function()
                local addr = net.await(function(callback)
                    dns.resolve(client, "x.home", { servers = { ip("10.0.0.2") }, hostname = "me", cache = cache }, callback)
                end)
                if addr ~= nil and not is_address(addr) then error("Resolved to " .. tostring(addr), 0) end
                for name, entry in pairs(cache) do
                    if not is_address(entry.address) or entry.expires ~= entry.expires then error("Cached " .. name .. " badly", 0) end
                end
                check_sane(client)
            end)
            if not ok then failures[#failures + 1] = case.name .. ": " .. tostring(err) end
        end
        expect(failures):same {}
    end)
end)
