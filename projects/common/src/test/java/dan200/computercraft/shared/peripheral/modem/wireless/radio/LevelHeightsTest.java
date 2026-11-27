// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;

import static org.junit.jupiter.api.Assertions.*;

class LevelHeightsTest {
    private static ChunkHeights heights(ChunkHeights.Source source) {
        return new ChunkHeights(new short[256], new short[256], source, System.currentTimeMillis());
    }

    /** A source which answers when we say. */
    private static final class Pending implements HeightSource {
        final Long2ObjectOpenHashMap<CompletableFuture<@Nullable ChunkHeights>> fetching = new Long2ObjectOpenHashMap<>();
        int calls;

        @Override
        public CompletableFuture<@Nullable ChunkHeights> fetch(ServerLevel level, int chunkX, int chunkZ, Executor worker) {
            calls++;
            var future = new CompletableFuture<@Nullable ChunkHeights>();
            fetching.put(ChunkPos.pack(chunkX, chunkZ), future);
            return future;
        }
    }

    private static LevelHeights newHeights() {
        // The level is only passed to sources, which ignore it here.
        return new LevelHeights(null, () -> {
        });
    }

    @Test
    void forgetsTheLeastRecentlyUsed() {
        var cache = newHeights();
        // Chunks along a diagonal, whose boxed keys all have the same hash.
        for (var i = 0; i < LevelHeights.CAPACITY; i++) cache.put(ChunkPos.pack(i, i), heights(ChunkHeights.Source.DISK));

        // Reading the oldest makes it the newest, so the next oldest is forgotten instead.
        assertNotNull(cache.get(ChunkPos.pack(0, 0)));
        cache.put(ChunkPos.pack(-1, -1), heights(ChunkHeights.Source.DISK));

        assertNotNull(cache.get(ChunkPos.pack(0, 0)));
        assertNull(cache.get(ChunkPos.pack(1, 1)));
        assertNotNull(cache.get(ChunkPos.pack(2, 2)));
        assertNotNull(cache.get(ChunkPos.pack(-1, -1)));
    }

    @Test
    void keepsBetterHeights() {
        var cache = newHeights();
        var chunk = ChunkPos.pack(3, -7);
        var disk = heights(ChunkHeights.Source.DISK);
        cache.put(chunk, disk);
        cache.put(chunk, heights(ChunkHeights.Source.GENERATOR));
        assertSame(disk, cache.get(chunk));

        var loaded = heights(ChunkHeights.Source.CHUNK);
        cache.put(chunk, loaded);
        assertSame(loaded, cache.get(chunk));
    }

    @Test
    void fetchesSoManyAtOnce() {
        var cache = newHeights();
        var source = new Pending();
        List<HeightSource> sources = List.of(source);

        for (var i = 0; i < LevelHeights.MAX_FETCHING; i++) assertTrue(cache.request(ChunkPos.pack(i, 0), sources, Runnable::run));
        assertEquals(LevelHeights.MAX_FETCHING, source.calls);

        // Full: new chunks wait, but chunks being fetched are still being fetched, and aren't fetched twice.
        var next = ChunkPos.pack(-1, 0);
        assertFalse(cache.request(next, sources, Runnable::run));
        assertTrue(cache.request(ChunkPos.pack(0, 0), sources, Runnable::run));
        assertEquals(LevelHeights.MAX_FETCHING, source.calls);

        // One arrives, so it's known, and there's room for another.
        var found = heights(ChunkHeights.Source.DISK);
        source.fetching.get(ChunkPos.pack(0, 0)).complete(found);
        assertSame(found, cache.get(ChunkPos.pack(0, 0)));
        assertTrue(cache.request(next, sources, Runnable::run));

        // One isn't found, which is remembered too.
        source.fetching.get(ChunkPos.pack(1, 0)).complete(null);
        var missing = cache.get(ChunkPos.pack(1, 0));
        assertNotNull(missing);
        assertFalse(missing.isAvailable());
    }
}
