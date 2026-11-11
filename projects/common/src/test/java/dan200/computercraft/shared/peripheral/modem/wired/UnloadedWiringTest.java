// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wired;

import dan200.computercraft.impl.network.wired.DormantWiring;
import it.unimi.dsi.fastutil.longs.LongLinkedOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

public class UnloadedWiringTest {
    @Test
    public void savesAndReadsWiring(@TempDir Path dir) {
        var file = dir.resolve("computercraft").resolve("wiring.dat");
        var overworld = List.of(
            new DormantWiring.Ports(12345L, new long[]{ 1L, -2L }, new byte[]{ 4, 8 }),
            new DormantWiring.Ports(-7L, new long[]{ Long.MAX_VALUE }, new byte[]{ 48 })
        );
        UnloadedWiring.write(file, Map.of("minecraft:overworld", overworld, "minecraft:the_nether", List.of()));

        var read = UnloadedWiring.read(file);
        assertEquals(2, read.size());
        assertEquals(List.of(), read.get("minecraft:the_nether"));
        var pieces = read.get("minecraft:overworld");
        assertEquals(2, pieces.size());
        for (var i = 0; i < 2; i++) {
            assertEquals(overworld.get(i).chunk(), pieces.get(i).chunk());
            assertArrayEquals(overworld.get(i).positions(), pieces.get(i).positions());
            assertArrayEquals(overworld.get(i).sides(), pieces.get(i).sides());
        }
        assertFalse(Files.exists(file.resolveSibling("wiring.dat.new")));
    }

    /**
     * Joining a chunk which has loaded may load others (a block looking at its neighbour waits for a chunk still loading,
     * and the server loads others meanwhile), which adds them to the chunks loading while we go through them. That once
     * spoilt the set, and crashed the server when the next chunk loaded.
     */
    @Test
    public void drainsChunksWhichLoadOthers() {
        LongSet loading = new LongLinkedOpenHashSet();
        for (long pos = 0; pos < 150; pos++) loading.add(pos);

        // Each chunk loads two more as it joins, enough for the set to grow, and every third isn't ready yet.
        UnloadedWiring.drain(loading, pos -> {
            if (pos < 150) {
                loading.add(1000 + pos);
                loading.add(2000 + pos);
            }
            return pos % 3 != 0;
        });

        LongSet expected = new LongOpenHashSet();
        for (long pos = 0; pos < 150; pos++) {
            if (pos % 3 == 0) expected.add(pos);
            expected.add(1000 + pos);
            expected.add(2000 + pos);
        }
        assertEquals(expected, loading);

        // The set still works.
        for (long pos = 5000; pos < 6000; pos++) loading.add(pos);
        for (long pos = 5000; pos < 6000; pos++) assertTrue(loading.remove(pos));
        assertEquals(expected, loading);
    }

    @Test
    public void ignoresMissingAndBrokenFiles(@TempDir Path dir) throws IOException {
        assertEquals(Map.of(), UnloadedWiring.read(dir.resolve("missing.dat")));

        var broken = dir.resolve("broken.dat");
        Files.writeString(broken, "not a wiring file");
        assertEquals(Map.of(), UnloadedWiring.read(broken));
    }
}
