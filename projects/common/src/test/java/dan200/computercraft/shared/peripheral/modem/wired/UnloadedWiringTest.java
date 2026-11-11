// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wired;

import dan200.computercraft.impl.network.wired.DormantWiring;
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

    @Test
    public void ignoresMissingAndBrokenFiles(@TempDir Path dir) throws IOException {
        assertEquals(Map.of(), UnloadedWiring.read(dir.resolve("missing.dat")));

        var broken = dir.resolve("broken.dat");
        Files.writeString(broken, "not a wiring file");
        assertEquals(Map.of(), UnloadedWiring.read(broken));
    }
}
