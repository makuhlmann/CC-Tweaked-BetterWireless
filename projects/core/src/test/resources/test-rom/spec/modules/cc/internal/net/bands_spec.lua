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

    it("gives callers copies", function()
        local band = bands.get("b1")
        band.downlink[1] = 0
        expect(bands.get("b1").downlink[1]):eq(21100)
    end)
end)
