// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executor;

/**
 * Heights of chunks in a single level which are not currently loaded.
 * <p>
 * This is filled from several places: chunks as they unload, and then {@linkplain HeightSource height sources} for
 * anything we've not seen. Lookups and insertions may happen on any thread.
 */
final class LevelHeights {
    private static final Logger LOG = LoggerFactory.getLogger(LevelHeights.class);

    /** The maximum number of chunks to remember. At ~1KiB a chunk, this is ~16MiB per level. */
    private static final int CAPACITY = 16384;

    /** How long to remember that we couldn't find a chunk, before trying again. */
    private static final long UNAVAILABLE_MILLIS = 60_000;

    /** How many chunks may be fetched at once. */
    private static final int MAX_FETCHING = 256;

    private final ServerLevel level;
    private final Map<Long, ChunkHeights> heights = new LinkedHashMap<>(256, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<Long, ChunkHeights> eldest) {
            return size() > CAPACITY;
        }
    };
    private final Set<Long> fetching = ConcurrentHashMap.newKeySet();

    LevelHeights(ServerLevel level) {
        this.level = level;
    }

    synchronized @Nullable ChunkHeights get(long chunk) {
        var heights = this.heights.get(chunk);
        if (heights != null && !heights.isAvailable() && System.currentTimeMillis() - heights.created() > UNAVAILABLE_MILLIS) {
            this.heights.remove(chunk);
            return null;
        }
        return heights;
    }

    synchronized void put(long chunk, ChunkHeights heights) {
        // Don't replace data we already have with a worse guess.
        var existing = this.heights.get(chunk);
        if (existing != null && existing.isAvailable() && existing.source().ordinal() < heights.source().ordinal()) return;
        this.heights.put(chunk, heights);
    }

    /**
     * Start fetching the heights of a chunk, if we're not already doing so.
     *
     * @param chunk   The chunk to fetch.
     * @param sources The sources to try, in order.
     * @param worker  An executor for slow work.
     */
    void request(long chunk, List<HeightSource> sources, Executor worker) {
        if (fetching.size() >= MAX_FETCHING || !fetching.add(chunk)) return;

        fetch(sources, 0, ChunkPos.getX(chunk), ChunkPos.getZ(chunk), worker).whenComplete((result, error) -> {
            if (error != null) LOG.warn("Failed to find heights for chunk {}", ChunkPos.unpack(chunk), error);
            put(chunk, result == null ? ChunkHeights.unavailable() : result);
            fetching.remove(chunk);
        });
    }

    private CompletableFuture<@Nullable ChunkHeights> fetch(List<HeightSource> sources, int index, int x, int z, Executor worker) {
        if (index >= sources.size()) return CompletableFuture.completedFuture(null);
        return sources.get(index).fetch(level, x, z, worker)
            .exceptionally(e -> {
                LOG.debug("Height source failed for chunk {}, {}", x, z, e);
                return null;
            })
            .thenCompose(result -> result != null ? CompletableFuture.completedFuture(result) : fetch(sources, index + 1, x, z, worker));
    }

    boolean isFetching(long chunk) {
        return fetching.contains(chunk);
    }
}
