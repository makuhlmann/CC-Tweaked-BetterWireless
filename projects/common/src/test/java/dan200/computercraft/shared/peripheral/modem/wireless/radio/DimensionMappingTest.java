// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.world.phys.Vec3;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

public class DimensionMappingTest {
    private static final DimensionHeights NETHER = new DimensionHeights(0, 128);
    private static final DimensionHeights OVERWORLD = new DimensionHeights(-64, 320);

    @Test
    public void scalesHorizontally() {
        // From the Overworld into the Nether, and back.
        var there = DimensionMapping.map(new Vec3(800.5, 70, -1600.5), 1 / 8.0, NETHER);
        assertEquals(new Vec3(100.0625, 70, -200.0625), there);
        assertEquals(new Vec3(800.5, 70, -1600.5), DimensionMapping.map(there, 8, OVERWORLD));
    }

    @Test
    public void keepsHeightsWithinTheRange() {
        // A modem high up in a tall world appears on the Nether's roof, and one deep down on its floor.
        assertEquals(128, DimensionMapping.map(new Vec3(0, 2031, 0), 1 / 8.0, NETHER).y);
        assertEquals(0, DimensionMapping.map(new Vec3(0, -60, 0), 1 / 8.0, NETHER).y);
        assertEquals(127.5, DimensionMapping.map(new Vec3(0, 127.5, 0), 1 / 8.0, NETHER).y);
        // The other way, heights are as they were.
        assertEquals(128, DimensionMapping.map(new Vec3(0, 128, 0), 8, OVERWORLD).y);
    }

    @Test
    public void bothWaysAreTheSameLink() {
        // A modem in the Overworld and one in the Nether. Whichever sends, the same two links are evaluated: one in
        // each dimension, between one modem and where the other's signal appears.
        var overworld = new Vec3(820, 90, 400);
        var nether = new Vec3(100, 60, 50);
        var inNether = DimensionMapping.map(overworld, 1 / 8.0, NETHER);
        var inOverworld = DimensionMapping.map(nether, 8, OVERWORLD);

        assertEquals(2.5, inNether.subtract(nether).horizontalDistance(), 1e-9);
        assertEquals(20, inOverworld.subtract(overworld).horizontalDistance(), 1e-9);
        // The link through the Nether is an eighth as long.
        assertEquals(inOverworld.subtract(overworld).horizontalDistance() / 8, inNether.subtract(nether).horizontalDistance(), 1e-9);
    }

    @Test
    public void readsHeightRanges() {
        assertEquals(
            Map.of("minecraft:the_nether", new DimensionHeights(0, 128), "minecraft:the_end", new DimensionHeights(0, 128)),
            DimensionHeights.DEFAULTS
        );

        var ranges = DimensionHeights.parse(List.of(
            "minecraft:overworld=-64..320", " the_nether = 4 .. 123 ", "mod:deep_dark=-2032..-1000",
            // None of these can be read, so they're skipped.
            "", "nonsense", "minecraft:the_end", "minecraft:the_end=5", "minecraft:the_end=9..1", "=1..2",
            "minecraft:the_end=a..b", "minecraft:the_end=1...2"
        ));
        assertEquals(Map.of(
            "minecraft:overworld", new DimensionHeights(-64, 320),
            "minecraft:the_nether", new DimensionHeights(4, 123),
            "mod:deep_dark", new DimensionHeights(-2032, -1000)
        ), ranges);

        assertTrue(DimensionHeights.isValid("minecraft:the_end=0..128"));
        assertFalse(DimensionHeights.isValid("minecraft:the_end=128..0"));
        assertFalse(DimensionHeights.isValid(5));
    }
}
