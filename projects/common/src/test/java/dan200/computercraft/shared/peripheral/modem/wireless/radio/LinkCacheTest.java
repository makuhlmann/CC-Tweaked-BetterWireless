// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.junit.jupiter.api.Test;

import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;

class LinkCacheTest {
    private static final double FREQUENCY = 942.5, BUDGET = 123;
    private static final long LIFETIME = 100;
    private static final String LINK = "cell to phone";

    /**
     * Flat ground at 64, with a hill in the middle of the link.
     *
     * @param hillKnown Whether we know the hill's heights.
     */
    private record Terrain(boolean hillKnown) implements TerrainView {
        private boolean hill(int x) {
            return x >= 400 && x < 416;
        }

        @Override
        public int groundHeight(int x, int z) {
            if (hill(x)) return hillKnown ? 200 : UNKNOWN;
            return 64;
        }

        @Override
        public int surfaceHeight(int x, int z) {
            return groundHeight(x, z);
        }

        @Override
        public BlockRadioInfo block(int x, int y, int z) {
            var ground = groundHeight(x, z);
            return ground != UNKNOWN && y < ground ? BlockRadioInfo.full(RadioMaterial.GROUND) : BlockRadioInfo.AIR;
        }
    }

    private static Supplier<LinkPath> trace(boolean hillKnown) {
        return () -> PropagationModel.trace(0.5, 70, 0.5, 800.5, 66, 0.5, BUDGET, RadioEnvironment.DEFAULT, new Terrain(hillKnown));
    }

    private static double loss(LinkPath path) {
        return path.evaluate(FREQUENCY).loss();
    }

    @Test
    void hillShowsOnlyWhenItsHeightsAreKnown() {
        // What the rest relies on: missing terrain counts as open ground.
        assertTrue(loss(trace(true).get()) > loss(trace(false).get()) + 20);
    }

    @Test
    void keepsAPathTracedWithEverythingKnownOverOneWithTerrainMissing() {
        var cache = new LinkCache<String>(16);
        var known = cache.settle(LINK, true, p -> true, 0, LIFETIME, trace(true));
        assertSame(known, cache.get(LINK, FREQUENCY, BUDGET, 50).path());

        // Later the hill's heights are forgotten, and don't come back in time: the link keeps its hill.
        var path = cache.settle(LINK, false, p -> true, 200, LIFETIME, () -> fail("Traced with the hill missing"));
        assertSame(known, path);
        // Only for a moment, as it's traced again soon.
        assertNotNull(cache.get(LINK, FREQUENCY, BUDGET, 200 + LinkCache.GUESS_TICKS - 1));
        assertNull(cache.get(LINK, FREQUENCY, BUDGET, 200 + LinkCache.GUESS_TICKS));

        // And again, if the heights are still missing.
        assertSame(known, cache.settle(LINK, false, p -> true, 300, LIFETIME, trace(false)));
    }

    @Test
    void tracesWithWhatsKnownWhenItsNeverBeenTracedWithEverything() {
        var cache = new LinkCache<String>(16);
        var guess = cache.settle(LINK, false, p -> true, 0, LIFETIME, trace(false));
        assertEquals(loss(trace(false).get()), loss(guess), 1e-9);
        assertNull(cache.get(LINK, FREQUENCY, BUDGET, LinkCache.GUESS_TICKS));

        // A guess doesn't stand in for the link's terrain later either.
        var again = cache.settle(LINK, false, p -> true, 100, LIFETIME, trace(false));
        assertNotSame(guess, again);

        // Once everything is known, the link has its hill, for the usual time.
        var known = cache.settle(LINK, true, p -> true, 200, LIFETIME, trace(true));
        assertTrue(loss(known) > loss(guess) + 20);
        assertSame(known, cache.get(LINK, FREQUENCY, BUDGET, 200 + LIFETIME - 1).path());
    }

    @Test
    void tracesAgainIfTheKnownPathDoesntServeWhatsWaiting() {
        var cache = new LinkCache<String>(16);
        var known = cache.settle(LINK, true, p -> true, 0, LIFETIME, trace(true));
        var guess = cache.settle(LINK, false, p -> p != known, 200, LIFETIME, trace(false));
        assertNotSame(known, guess);
    }

    @Test
    void renewsALinkInUseOnceInItsLastTicks() {
        var cache = new LinkCache<String>(16);
        cache.settle(LINK, true, p -> true, 0, LIFETIME, trace(true));

        var early = cache.get(LINK, FREQUENCY, BUDGET, LIFETIME - LinkCache.RENEW_TICKS - 1);
        assertNotNull(early);
        assertFalse(early.dueForRenewal(LIFETIME - LinkCache.RENEW_TICKS - 1));

        var late = cache.get(LINK, FREQUENCY, BUDGET, LIFETIME - LinkCache.RENEW_TICKS);
        assertNotNull(late);
        assertTrue(late.dueForRenewal(LIFETIME - LinkCache.RENEW_TICKS));
        // Only once.
        assertFalse(late.dueForRenewal(LIFETIME - 1));

        // A guess, cached briefly, is renewed in the last quarter of its time.
        cache.settle(LINK, false, p -> false, 200, LIFETIME, trace(false));
        var guess = cache.get(LINK, FREQUENCY, BUDGET, 200);
        assertNotNull(guess);
        assertFalse(guess.dueForRenewal(200 + LinkCache.GUESS_TICKS * 3 / 4 - 1));
        assertTrue(guess.dueForRenewal(200 + LinkCache.GUESS_TICKS * 3 / 4));
    }

    @Test
    void forgetsTheLeastRecentlyUsedLinks() {
        var cache = new LinkCache<Integer>(2);
        for (var i = 0; i < 3; i++) cache.settle(i, true, p -> true, 0, LIFETIME, trace(true));
        assertNull(cache.get(0, FREQUENCY, BUDGET, 1));
        assertNotNull(cache.get(1, FREQUENCY, BUDGET, 1));
        assertNotNull(cache.get(2, FREQUENCY, BUDGET, 1));
    }
}
