-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.bands", function()
    local bands = require "cc.internal.net.bands"

    local function ranges(band)
        if band.channels then return { band.channels } end
        return { band.uplink, band.downlink }
    end

    it("has bands within the channels there are, which don't overlap", function()
        local seen = {}
        for _, band in ipairs(bands.list()) do
            for _, range in ipairs(ranges(band)) do
                expect(range[1] >= 0 and range[1] < range[2] and range[2] < 65533):eq(true)
                for _, other in ipairs(seen) do
                    expect(range[2] < other[1] or range[1] > other[2]):describe(band.name .. " overlaps another band"):eq(true)
                end
                seen[#seen + 1] = range
            end
            -- A paired band's uplink and downlink are the same width.
            if band.uplink then expect(band.uplink[2] - band.uplink[1]):eq(band.downlink[2] - band.downlink[1]) end
        end
    end)

    it("knows LTE's bands", function()
        -- Band 1 (2100MHz): uplink 1920-1980MHz, downlink 2110-2170MHz.
        expect(bands.get("b1")):same { name = "b1", label = "2100", uplink = { 19200, 19800 }, downlink = { 21100, 21700 } }
        -- In band 20, the uplink is above the downlink.
        local b20 = bands.get("b20")
        expect(b20.uplink[1] > b20.downlink[2]):eq(true)
        expect(bands.get("nothing")):eq(nil)
        expect(bands.frequency(21100)):eq(2110)

        local names = {}
        for _, band in ipairs(bands.cellular()) do names[#names + 1] = band.name end
        expect(names):same { "b31", "b28", "b20", "b8", "b3", "b1", "b7" }
    end)

    it("says which band and part of it a channel is in", function()
        expect({ bands.of(21150) }):same { "b1", "downlink" }
        expect({ bands.of(19500) }):same { "b1", "uplink" }
        expect({ bands.of(1500) }):same { "low", "both" }
        expect({ bands.of(24100) }):same { "high", "both" }
        expect({ bands.of(5) }):same {}
    end)

    it("pairs downlink channels with uplink ones", function()
        expect(bands.uplink_of("b1", 21100)):eq(19200)
        expect(bands.uplink_of("b1", 21700)):eq(19800)
        expect(bands.uplink_of("b20", 8000)):eq(8410)
        expect(bands.uplink_of("b1", 19500)):eq(nil)
        expect(bands.uplink_of("low", 1500)):eq(nil)
    end)

    it("puts beacon channels in the middle of each 5MHz of a downlink", function()
        expect(bands.raster("b31")):same { 4650 }
        expect(bands.raster("b20")):same { 7935, 7985, 8035, 8085, 8135, 8185 }
        expect(bands.raster("low")):same {}

        -- Few enough that a phone can listen to all of them at once.
        local all, seen = bands.beacon_channels(), {}
        expect(#all):eq(61)
        expect(#all <= 128):eq(true)
        for _, channel in ipairs(all) do
            expect(seen[channel]):eq(nil)
            seen[channel] = true
            local _, part = bands.of(channel)
            expect(part):eq("downlink")
        end
    end)

    it("names carriers, and finds the carrier a channel is in", function()
        expect(bands.carrier_name(7935)):eq("b20/1")
        expect(bands.carrier_name(7936)):eq(nil)
        expect(bands.parse_carrier("b20/2")):eq(7985)
        expect(bands.parse_carrier("B3")):eq(18075)
        expect(bands.parse_carrier("b20/7")):eq(nil)
        expect(bands.parse_carrier("low")):eq(nil)
        expect(bands.parse_carrier(5)):eq(nil)

        -- Downlink and uplink channels both belong to their carrier.
        expect({ bands.carrier_of(7950) }):same { 7935, "b20" }
        expect({ bands.carrier_of(8330) }):same { 7935, "b20" }
        expect({ bands.carrier_of(8380) }):same { 7985, "b20" }
        expect(bands.carrier(7935)):same { downlink = { 7910, 7959 }, uplink = { 8320, 8369 }, band = "b20" }
        expect(bands.carrier(7936)):eq(nil)
        -- Channels of the stack's own bands, and band 31's last, which isn't a whole block, are in none.
        expect(bands.carrier_of(1500)):eq(nil)
        expect(bands.carrier_of(4675)):eq(nil)
        expect(bands.carrier_of("7935")):eq(nil)

        -- Every beacon channel is its own carrier's.
        for _, channel in ipairs(bands.beacon_channels()) do
            expect(bands.carrier_of(channel)):eq(channel)
            expect(bands.parse_carrier(bands.carrier_name(channel))):eq(channel)
        end
    end)

    it("says which channels a link of its own can use", function()
        for _, channel in ipairs { 300, 1450, 1360, 24000, 65532 } do
            expect({ bands.check_link_channel(channel) }):same { true }
        end

        local range = "A channel is a whole number from 300 to 65532 (30MHz to 6553.2MHz)"
        for _, channel in ipairs { 299, 65533, 65535, 1450.5, -1, 0 / 0, math.huge, "1450" } do
            expect({ bands.check_link_channel(channel) }):same { nil, range }
        end

        -- Not in the cellular bands, uplinks or downlinks, which phones and cells on the same modem need.
        expect({ bands.check_link_channel(7935) }):same {
            nil, "Channel 7935 (793.5MHz) is in cellular band b20 (800MHz), which phones and cells need",
        }
        expect({ bands.check_link_channel(19200) }):same {
            nil, "Channel 19200 (1920MHz) is in cellular band b1 (2100MHz), which phones and cells need",
        }
        for _, band in ipairs(bands.cellular()) do
            for _, range in ipairs { band.uplink, band.downlink } do
                expect(bands.check_link_channel(range[1])):eq(nil)
                expect(bands.check_link_channel(range[2])):eq(nil)
            end
        end
    end)

    it("gives callers copies", function()
        local band = bands.get("b1")
        band.downlink[1] = 0
        expect(bands.get("b1").downlink[1]):eq(21100)
    end)
end)
