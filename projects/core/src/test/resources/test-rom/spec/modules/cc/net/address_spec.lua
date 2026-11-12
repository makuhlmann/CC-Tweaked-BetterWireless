-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.net.address", function()
    local address = require "cc.net.address"

    describe("parse", function()
        it("parses addresses", function()
            expect({ address.parse("10.0.0.1") }):same { 167772161 }
            expect({ address.parse("255.255.255.255") }):same { 0xFFFFFFFF }
            expect({ address.parse("192.168.1.20/24") }):same { 3232235796, 24 }
            expect({ address.parse("0.0.0.0/0") }):same { 0, 0 }
        end)

        it("rejects invalid addresses", function()
            expect({ address.parse("10.0.0") }):same { nil, "Invalid address '10.0.0'" }
            expect({ address.parse("10.0.0.256") }):same { nil, "Invalid address '10.0.0.256'" }
            expect({ address.parse("10.0.0.1/33") }):same { nil, "Invalid prefix length in '10.0.0.1/33'" }
            expect({ address.parse("10.0.0.1/x") }):same { nil, "Invalid prefix length in '10.0.0.1/x'" }
        end)
    end)

    it("formats addresses", function()
        expect(address.format(167772161)):eq("10.0.0.1")
        expect(address.format(0xFFFFFFFF)):eq("255.255.255.255")
        expect(address.format(3232235796, 24)):eq("192.168.1.20/24")
    end)

    it("computes masks", function()
        expect(address.mask(0)):eq(0)
        expect(address.mask(24)):eq(0xFFFFFF00)
        expect(address.mask(32)):eq(0xFFFFFFFF)
    end)

    it("finds networks and broadcast addresses", function()
        local addr = address.parse("10.4.0.17")
        expect(address.format(address.network(addr, 24))):eq("10.4.0.0")
        expect(address.format(address.broadcast(addr, 24))):eq("10.4.0.255")
        expect(address.format(address.network(addr, 8))):eq("10.0.0.0")
        expect(address.format(address.broadcast(addr, 8))):eq("10.255.255.255")
    end)

    it("checks whether networks contain addresses", function()
        local net = address.parse("10.4.0.0")
        expect(address.contains(net, 24, address.parse("10.4.0.200"))):eq(true)
        expect(address.contains(net, 24, address.parse("10.4.1.1"))):eq(false)
        expect(address.contains(net, 16, address.parse("10.4.1.1"))):eq(true)
        expect(address.contains(net, 0, address.parse("192.168.0.1"))):eq(true)
    end)

    it("recognises loopback addresses", function()
        expect(address.is_loopback(address.parse("127.0.0.1"))):eq(true)
        expect(address.is_loopback(address.parse("10.0.0.1"))):eq(false)
    end)

    it("checks whether an address can be a computer's", function()
        local function check(text, prefix) return { address.check_host(address.parse(text), prefix) } end
        expect(check("10.0.0.5", 24)):same { true }
        expect(check("10.0.0.0", 31)):same { true }
        expect(check("10.0.0.255", 32)):same { true }
        expect(check("169.254.3.4", 16)):same { true }
        expect(check("10.0.0.0", 24)):same { false, "10.0.0.0/24 is the address of the network itself, or its broadcast address" }
        expect(check("10.0.0.255", 24)):same { false, "10.0.0.255/24 is the address of the network itself, or its broadcast address" }
        for _, text in ipairs { "0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255" } do
            expect(check(text, 8)):same { false, text .. " can't be a computer's address" }
        end
    end)
end)
