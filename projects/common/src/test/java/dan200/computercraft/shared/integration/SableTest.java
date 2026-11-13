// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.integration;

import dev.ryanhcode.sable.companion.SableCompanion;
import net.minecraft.world.phys.Vec3;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Checks that {@link Sable} finds Sable Companion's {@code projectOutOfSubLevel}, using the stand-in
 * {@link SableCompanion} in the test sources.
 */
public class SableTest {
    @Test
    public void mapsPlotPositionsToTheWorld() {
        var project = Sable.find();
        assertNotNull(project, "projectOutOfSubLevel was not found");

        // A modem in the plot is moved to where its object is, and one in the world stays put.
        assertEquals(new Vec3(1008.5, 128.5, -1991.5), Sable.project(project, null, new Vec3(8.5, 64.5, 8.5)));
        var outside = new Vec3(85473, 135, -563334);
        assertSame(outside, Sable.project(project, null, outside));
    }

    @Test
    public void positionsStayPutWithoutSable() {
        // The tests' platform has no mods installed, so nothing is looked up.
        var position = new Vec3(8.5, 64.5, 8.5);
        assertSame(position, Sable.toWorld(null, position));
    }
}
