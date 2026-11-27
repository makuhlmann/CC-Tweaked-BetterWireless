// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import it.unimi.dsi.fastutil.longs.Long2ObjectLinkedOpenHashMap;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;

/**
 * Heights of chunks in a single level which are not currently loaded.
 * <p>
 * This is filled from several places: chunks as they unload, and then {@linkplain HeightSource height sources} for
 * anything we've not seen. Lookups and insertions may happen on any thread.
 * <p>
 * Chunks are kept by their packed {@link ChunkPos}. Don't key a {@link java.util.HashMap} with those: a boxed
 * {@link Long}'s hash is its chunk's {@code x ^ z}, which is the same for every chunk on a diagonal, and for many
 * chunks in any square, so a full cache ends up in a few hundred buckets. fastutil's maps mix the bits first.
 */
final class LevelHeights {
    private static final Logger LOG = LoggerFactory.getLogger(LevelHeights.class);

    /** The maximum number of chunks to remember. At ~1KiB a chunk, this is ~16MiB per level. */
    static final int CAPACITY = 16384;

    /** How long to remember that we couldn't find a chunk, before trying again. */
    private static final long UNAVAILABLE_MILLIS = 60_000;

    /** How many chunks may be fetched at once. */
    static final int MAX_FETCHING = 256;

    private final ServerLevel level;

    /** The heights we know, least recently used first. Guarded by {@code this}. */
    private final Long2ObjectLinkedOpenHashMap<ChunkHeights> heights = new Long2ObjectLinkedOpenHashMap<>(256);

    /** The chunks we're fetching. Guarded by {@code this}. */
    private final LongOpenHashSet fetching = new LongOpenHashSet();

    LevelHeights(ServerLevel level) {
        this.level = level;
    }

    synchronized @Nullable ChunkHeights get(long chunk) {
        var heights = this.heights.getAndMoveToLast(chunk);
        if (heights != null && !heights.isAvailable() && System.currentTimeMillis() - heights.created() > UNAVAILABLE_MILLIS) {
            this.heights.remove(chunk);
            return null;
        }
        return heights;
    }

    synchronized void put(long chunk, ChunkHeights heights) {
        // Don't replace data we already have with a worse guess.
        var existing = this.heights.getAndMoveToLast(chunk);
        if (existing != null && existing.isAvailable() && existing.source().ordinal() < heights.source().ordinal()) return;
        this.heights.putAndMoveToLast(chunk, heights);
        while (this.heights.size() > CAPACITY) this.heights.removeFirst();
    }

    /**
     * Start fetching the heights of a chunk, if we're not already doing so.
     *
     * @param chunk   The chunk to fetch.
     * @param sources The sources to try, in order.
     * @param worker  An executor for slow work.
     * @return Whether the chunk is being fetched: {@code false} if we're already fetching as many chunks as we may, so
     * should ask again later.
     */
    boolean request(long chunk, List<HeightSource> sources, Executor worker) {
        synchronized (this) {
            if (fetching.contains(chunk)) return true;
            if (fetching.size() >= MAX_FETCHING) return false;
            fetching.add(chunk);
        }

        fetch(sources, 0, ChunkPos.getX(chunk), ChunkPos.getZ(chunk), worker).whenComplete((result, error) -> {
            if (error != null) LOG.warn("Failed to find heights for chunk {}", ChunkPos.unpack(chunk), error);
            fetched(chunk, result == null ? ChunkHeights.unavailable() : result);
        });
        return true;
    }

    /**
     * Remember a chunk we fetched. It's never both unknown and not being fetched, until it's forgotten.
     *
     * @param chunk   The chunk.
     * @param heights Its heights.
     */
    private synchronized void fetched(long chunk, ChunkHeights heights) {
        put(chunk, heights);
        fetching.remove(chunk);
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
}
