-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.link", function()
    local link = require "cc.internal.net.link"
    local address = require "cc.net.address"
    local network = require "support.virtual_network"

    local function ip(text) return (address.parse(text)) end

    local KEY = link.derive(crypto, "correct horse battery staple")

    -- Computers on one link, each with a key (or none). The key is set before the address, as the net API does.
    local function setup(keys)
        local net = network()
        local stacks = {}
        for i, key in ipairs(keys) do
            local stack = net.stack(i)
            net.connect(stack, "top")
            if key ~= "none" then stack:set_link_key("top", key) end
            stack:set_address("top", ip("10.0.0." .. i), 24)
            stacks[i] = stack
        end
        net.run()
        return net, stacks
    end

    -- Whether a ping got an answer.
    local function answered(net, stack, dst)
        local result = net.ping(stack, ip(dst), nil, 3)
        return result ~= nil and result.error == nil
    end

    -- The sealed frames on the link which haven't been delivered yet.
    local function sealed_frames(net)
        local frames = {}
        for _, item in ipairs(net.queue) do
            if item.frame.type == "sealed" then frames[#frames + 1] = item end
        end
        return frames
    end

    it("lets computers with the same passphrase talk", function()
        local net, stacks = setup { KEY, KEY }
        local result = net.ping(stacks[1], ip("10.0.0.2"))
        expect(result and result.error):eq(nil)
        expect(link.derive(crypto, "correct horse battery staple")):eq(KEY)
    end)

    it("keeps out computers with another passphrase, or none", function()
        local net, stacks = setup { KEY, link.derive(crypto, "wrong"), "none" }
        expect(answered(net, stacks[1], "10.0.0.2")):eq(false)
        expect(answered(net, stacks[1], "10.0.0.3")):eq(false)
        expect(answered(net, stacks[3], "10.0.0.1")):eq(false)
        -- None of them even learnt where the others are.
        expect(next(stacks[2].interfaces.top.neighbours)):eq(nil)
        expect(next(stacks[3].interfaces.top.neighbours)):eq(nil)
        expect(stacks[1].interfaces.top.stats.dropped > 0):eq(true)
    end)

    it("hides what's sent", function()
        local net, stacks = setup { KEY, KEY }
        stacks[1]:echo(ip("10.0.0.2"), "the secret plans")
        for _, item in ipairs(net.queue) do
            expect(item.frame.type):eq("sealed")
            expect(textutils.serialise(item.frame):find("secret", 1, true)):eq(nil)
        end
    end)

    it("refuses replayed, changed and old frames", function()
        local net, stacks = setup { KEY, KEY }
        local _, b = stacks[1], stacks[2]
        net.ping(stacks[1], ip("10.0.0.2"))

        -- Capture a frame on its way.
        stacks[1]:echo(ip("10.0.0.2"))
        local captured = sealed_frames(net)[1]
        net.run()
        local received = b.interfaces.top.stats.frames_in

        local function resend(change)
            local frame = textutils.unserialise(textutils.serialise(captured.frame))
            if change then change(frame) end
            net.inject("top", captured.channel, frame)
            net.run()
        end

        resend()
        resend(function(frame) frame.dst = -1 end)
        resend(function(frame) frame.body.counter = frame.body.counter + 1 end)
        resend(function(frame) frame.body.data = frame.body.data:sub(1, -2) .. "x" end)
        resend(function(frame) frame.type = "ip" end)
        expect(b.interfaces.top.stats.frames_in):eq(received)

        -- Even once the receiver has forgotten the sender, an old frame is refused.
        net.advance(70)
        b.interfaces.top.link.peers = {}
        resend()
        expect(b.interfaces.top.stats.frames_in):eq(received)
    end)

    it("copes with frames arriving out of order", function()
        local net, stacks = setup { KEY, KEY }
        net.jitter.top = 0.5
        math.randomseed(9)
        local replies = 0
        for _ = 1, 20 do
            local result = net.ping(stacks[1], ip("10.0.0.2"))
            if result and not result.error then replies = replies + 1 end
        end
        expect(replies):eq(20)
    end)

    it("carries every datagram a socket takes", function()
        -- Frames are encoded before they're sealed, which not every value a modem can send survives, and radio
        -- messages have a size limit. Sockets refuse what wouldn't get through, so nothing is dropped here.
        local net, stacks = setup { KEY, KEY }
        local a, b = stacks[1], stacks[2]
        local server, client = b:udp_open(7000), a:udp_open()
        net.latency.top = 0.05

        local deepest = {}
        for _ = 2, 60 do deepest = { deepest } end
        local strings, numbers = {}, {}
        for i = 1, 4400 do strings[i] = "" end
        for i = 1, 3413 do numbers[i] = i / 3 end
        local values = { "text", 0 / 0, -math.huge, { [true] = 1, [0.5] = { "half" } }, deepest, strings, numbers, ("x"):rep(60 * 1024 - 2) }

        local largest = 0
        for i, value in ipairs(values) do
            expect({ a:udp_send(client, ip("10.0.0.2"), 7000, value) }):describe("Datagram " .. i):same { true }
            for _, item in ipairs(sealed_frames(net)) do largest = math.max(largest, #item.frame.body.data) end
            net.advance(1)
            local received = table.remove(server.queue, 1)
            expect(received):describe("Datagram " .. i):ne(nil)
            if value ~= value then
                expect(received.data ~= received.data):eq(true)
            elseif type(value) == "string" then
                expect(received.data == value):describe("Datagram " .. i):eq(true)
            else
                expect(received.data):describe("Datagram " .. i):same(value)
            end
        end
        expect(a.interfaces.top.stats.dropped):eq(0)
        -- Radio messages may be 64 KiB, as modems reckon it: the sealed bytes, and a little for the rest of the frame.
        expect(largest > 60 * 1024 and largest + 256 <= 64 * 1024):describe("The largest frame, " .. largest .. " bytes"):eq(true)

        local recursive = {}
        recursive.self = recursive
        expect({ a:udp_send(client, ip("10.0.0.2"), 7000, recursive) }):same { nil, "Can't send a table which contains itself" }
        expect({ a:udp_send(client, ip("10.0.0.2"), 7000, { { deepest } }) }):same { nil, "Can't send tables nested more than 60 deep" }
    end)

    it("sends and accepts nothing when it should be encrypted but can't be", function()
        local net, stacks = setup { false, KEY }
        expect(answered(net, stacks[1], "10.0.0.2")):eq(false)
        expect(net.frames.top):eq(1) -- Only computer 2's announcement.
    end)
end)
