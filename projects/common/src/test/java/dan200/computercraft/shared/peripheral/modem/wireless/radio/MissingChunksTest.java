// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import it.unimi.dsi.fastutil.longs.LongArrayList;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.phys.Vec3;
import org.junit.jupiter.api.Test;

import java.util.stream.LongStream;

import static org.junit.jupiter.api.Assertions.*;

class MissingChunksTest {
    /**
     * A height cache, which fetches as many chunks at once as it may. It counts how often it's asked about chunks, as
     * a tick spends its time doing that.
     */
    private static final class Cache {
        final LongOpenHashSet known = new LongOpenHashSet();
        final LongOpenHashSet fetching = new LongOpenHashSet();
        final LongArrayList fetched = new LongArrayList();
        int capacity;
        int lookups;

        Cache(int capacity) {
            this.capacity = capacity;
        }

        boolean isKnown(long chunk) {
            lookups++;
            return known.contains(chunk);
        }

        boolean request(long chunk) {
            lookups++;
            if (fetching.contains(chunk)) return true;
            if (fetching.size() >= capacity) return false;
            fetching.add(chunk);
            fetched.add(chunk);
            return true;
        }

        // A chunk arrives.
        void arrive(long chunk) {
            known.add(chunk);
            fetching.remove(chunk);
        }

        boolean update(MissingChunks missing) {
            lookups = 0;
            return missing.update(this::isKnown, this::request);
        }
    }

    private static long[] range(int from, int to) {
        return LongStream.range(from, to).toArray();
    }

    @Test
    void knownChunksAreNotFetched() {
        var cache = new Cache(10);
        cache.known.addAll(LongArrayList.wrap(range(0, 5)));

        var missing = MissingChunks.of(range(0, 5));
        assertTrue(cache.update(missing));
        assertTrue(missing.isComplete());
        assertEquals(LongArrayList.of(), cache.fetched);
    }

    @Test
    void asksForChunksInOrderAsTheCacheHasRoom() {
        var cache = new Cache(4);
        var missing = MissingChunks.of(range(0, 10));

        assertFalse(cache.update(missing));
        assertEquals(LongArrayList.wrap(range(0, 4)), cache.fetched);

        // Two arrive, which makes room for two more.
        cache.arrive(0);
        cache.arrive(1);
        assertFalse(cache.update(missing));
        assertEquals(LongArrayList.wrap(range(0, 6)), cache.fetched);

        for (var chunk = 2; chunk < 10; chunk++) {
            assertFalse(missing.isComplete());
            cache.arrive(chunk);
            cache.update(missing);
        }
        assertTrue(missing.isComplete());
        assertEquals(LongArrayList.wrap(range(0, 10)), cache.fetched);
    }

    @Test
    void chunksWhichArriveOutOfOrderCount() {
        var cache = new Cache(100);
        var missing = MissingChunks.of(range(0, 10));
        assertFalse(cache.update(missing));

        for (var chunk = 9; chunk > 0; chunk--) cache.arrive(chunk);
        assertFalse(cache.update(missing));

        cache.arrive(0);
        assertTrue(cache.update(missing));
    }

    @Test
    void waitingLooksAtFewChunks() {
        // A long link, whose chunks the cache has room for: once asked for, each tick looks at the first chunk only.
        var cache = new Cache(10_000);
        var missing = MissingChunks.of(range(0, 5000));
        assertFalse(cache.update(missing));
        for (var i = 0; i < 20; i++) {
            assertFalse(cache.update(missing));
            assertTrue(cache.lookups <= 2, "Looked at " + cache.lookups + " chunks");
        }

        // And one the cache is too full for: each tick also tries the next chunk to ask for.
        cache = new Cache(256);
        missing = MissingChunks.of(range(0, 5000));
        assertFalse(cache.update(missing));
        for (var i = 0; i < 20; i++) {
            assertFalse(cache.update(missing));
            assertTrue(cache.lookups <= 4, "Looked at " + cache.lookups + " chunks");
        }
    }

    @Test
    void asksAgainForAChunkWhichWasForgotten() {
        var cache = new Cache(100);
        var missing = MissingChunks.of(range(0, 3));
        assertFalse(cache.update(missing));

        // Chunk 0 arrives, but is forgotten before we look.
        cache.arrive(0);
        cache.known.remove(0);
        cache.arrive(1);
        cache.arrive(2);

        assertFalse(cache.update(missing));
        assertEquals(LongArrayList.of(0, 1, 2, 0), cache.fetched);

        cache.arrive(0);
        assertTrue(cache.update(missing));
    }

    // A short link, whose samples fall in every chunk it crosses, so the columns near the ends add nothing.
    @Test
    void chunksBetweenTwoPointsAreInOrder() {
        var from = new Vec3(8, 64, 8);
        var to = new Vec3(8 + 16 * 40, 64, 8 + 16 * 40);
        var cache = new Cache(10_000);
        cache.update(MissingChunks.between(from, to, RadioEnvironment.DEFAULT));

        var chunks = cache.fetched;
        assertEquals(ChunkPos.pack(0, 0), chunks.getLong(0));
        assertTrue(chunks.contains(ChunkPos.pack(40, 40)));
        assertEquals(chunks.size(), new LongOpenHashSet(chunks).size(), "Chunks are repeated");

        // Along a diagonal, X and Z never go backwards.
        for (var i = 1; i < chunks.size(); i++) {
            var last = chunks.getLong(i - 1);
            var chunk = chunks.getLong(i);
            assertTrue(ChunkPos.getX(chunk) >= ChunkPos.getX(last) && ChunkPos.getZ(chunk) >= ChunkPos.getZ(last), "Went backwards at " + i);
        }
    }
}
