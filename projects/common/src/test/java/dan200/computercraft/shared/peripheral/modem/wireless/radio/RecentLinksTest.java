// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class RecentLinksTest {
    private static final Object LEVEL = new Object();
    private static final Object OTHER_LEVEL = new Object();
    private static final Object CELL = new Object();
    private static final Object PHONE = new Object();
    private static final Vec3 CELL_AT = new Vec3(0.5, 100, 0.5);
    private static final Vec3 PHONE_AT = new Vec3(800.5, 65.6, 0.5);
    private static final double FREQUENCY = 806, BUDGET = 123, TOLERANCE = 16;
    private static final long MAX_AGE = 200;

    /** Flat ground, open sky: a link which closes easily, traced for {@link #BUDGET}. */
    private static final TerrainView FLAT = new TerrainView() {
        @Override
        public int groundHeight(int x, int z) {
            return 64;
        }

        @Override
        public int surfaceHeight(int x, int z) {
            return 64;
        }

        @Override
        public BlockRadioInfo block(int x, int y, int z) {
            return y < 64 ? BlockRadioInfo.full(RadioMaterial.GROUND) : BlockRadioInfo.AIR;
        }
    };

    private static LinkPath path(double budget) {
        return PropagationModel.trace(
            CELL_AT.x, CELL_AT.y, CELL_AT.z, PHONE_AT.x, PHONE_AT.y, PHONE_AT.z, budget, RadioEnvironment.DEFAULT, FLAT
        );
    }

    private static @Nullable LinkPath find(RecentLinks recent, Object sender, Vec3 from, Object receiver, Vec3 to, long tick) {
        return recent.find(LEVEL, sender, from, receiver, to, tick, TOLERANCE, MAX_AGE, FREQUENCY, BUDGET);
    }

    @Test
    void reusesAPathForRadiosWhichMovedALittle() {
        var recent = new RecentLinks(16);
        var path = path(BUDGET);
        recent.record(LEVEL, CELL, CELL_AT, PHONE, PHONE_AT, path, 100);

        // The phone walked a few blocks: either way round, as the reply goes the other way.
        var moved = PHONE_AT.add(5, 0, -3);
        assertSame(path, find(recent, CELL, CELL_AT, PHONE, moved, 110));
        assertSame(path, find(recent, PHONE, moved, CELL, CELL_AT, 110));
        // Right up to the tolerance, and right up to the age.
        assertSame(path, find(recent, PHONE, PHONE_AT.add(TOLERANCE, 0, 0), CELL, CELL_AT, 100 + MAX_AGE));
    }

    @Test
    void waitsForRadiosWhichMovedFurther() {
        var recent = new RecentLinks(16);
        recent.record(LEVEL, CELL, CELL_AT, PHONE, PHONE_AT, path(BUDGET), 100);

        assertNull(find(recent, PHONE, PHONE_AT.add(TOLERANCE + 1, 0, 0), CELL, CELL_AT, 110));
        // Each end counts on its own: the cell can't have moved either.
        assertNull(find(recent, PHONE, PHONE_AT, CELL, CELL_AT.add(0, 0, 17), 110));
        // The positions belong to the radios, not to which end sent: swapped, the phone is 800 blocks off.
        assertNull(find(recent, CELL, PHONE_AT, PHONE, CELL_AT, 110));
    }

    @Test
    void waitsForPathsWhichAreTooOldOrElsewhere() {
        var recent = new RecentLinks(16);
        recent.record(LEVEL, CELL, CELL_AT, PHONE, PHONE_AT, path(BUDGET), 100);

        assertNull(find(recent, PHONE, PHONE_AT, CELL, CELL_AT, 100 + MAX_AGE + 1));
        assertNull(recent.find(OTHER_LEVEL, PHONE, PHONE_AT, CELL, CELL_AT, 110, TOLERANCE, MAX_AGE, FREQUENCY, BUDGET));
        // Another phone, at the same place, has its own link.
        assertNull(find(recent, new Object(), PHONE_AT, CELL, CELL_AT, 110));
    }

    @Test
    void onlyUsesAPathTracedFarEnough() {
        var recent = new RecentLinks(16);
        // Traced for a budget so small that walking stopped before this link was done.
        var shallow = path(20);
        assertFalse(shallow.serves(FREQUENCY, BUDGET));
        recent.record(LEVEL, CELL, CELL_AT, PHONE, PHONE_AT, shallow, 100);
        assertNull(find(recent, PHONE, PHONE_AT, CELL, CELL_AT, 110));
    }

    @Test
    void keepsOneRefreshForEachPair() {
        var recent = new RecentLinks(16);
        var first = new Object();
        var second = new Object();

        assertNull(recent.refreshing(PHONE, CELL, first));
        // The same trace again isn't a replacement.
        assertNull(recent.refreshing(CELL, PHONE, first));
        // A newer one replaces it, either way round.
        assertSame(first, recent.refreshing(CELL, PHONE, second));

        // The older one finishing changes nothing: the newer one still waits.
        recent.refreshed(PHONE, CELL, first);
        assertSame(second, recent.refreshing(PHONE, CELL, new Object()));
    }

    @Test
    void forgetsOldPathsAndTheLeastUsed() {
        var recent = new RecentLinks(2);
        var path = path(BUDGET);
        var other = new Object();
        recent.record(LEVEL, CELL, CELL_AT, PHONE, PHONE_AT, path, 100);
        recent.record(LEVEL, CELL, CELL_AT, other, PHONE_AT, path, 300);

        recent.purge(200);
        assertEquals(1, recent.size());
        assertNull(find(recent, PHONE, PHONE_AT, CELL, CELL_AT, 300));
        assertSame(path, find(recent, other, PHONE_AT, CELL, CELL_AT, 300));

        // No more than it may hold, the least used going first.
        recent.record(LEVEL, CELL, CELL_AT, new Object(), PHONE_AT, path, 300);
        recent.record(LEVEL, CELL, CELL_AT, new Object(), PHONE_AT, path, 300);
        assertEquals(2, recent.size());
        assertNull(find(recent, other, PHONE_AT, CELL, CELL_AT, 300));
    }
}
