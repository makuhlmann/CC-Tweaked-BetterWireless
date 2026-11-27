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

    /** How long to remember that we couldn't find a chunk, before trying again. */
    private static final long UNAVAILABLE_MILLIS = 60_000;

    /**
     * Forgetting a chunk we found out about less than this long ago means the links in use cross more chunks than we
     * remember, in milliseconds: they'd keep forgetting each other's terrain, and fetching it again.
     */
    static final long CHURN_MILLIS = 60_000;

    /** How often to say so, at most, in milliseconds. */
    private static final long CHURN_WARNING_MILLIS = 10 * 60_000;

    /** How many chunks may be fetched at once. */
    static final int MAX_FETCHING = 256;

    private final ServerLevel level;
    private final Runnable onFetched;

    /** The maximum number of chunks to remember. At ~1KiB a chunk, 262,144 are ~256MiB. Guarded by {@code this}. */
    private int capacity;

    /**
     * How many chunks were forgotten soon after we found out about them, and how many of those we've warned about.
     * Guarded by {@code this}.
     */
    private long churned, churnWarned;
    private long lastChurnWarning = Long.MIN_VALUE;

    /** The heights we know, least recently used first. Guarded by {@code this}. */
    private final Long2ObjectLinkedOpenHashMap<ChunkHeights> heights = new Long2ObjectLinkedOpenHashMap<>(256);

    /** The chunks we're fetching. Guarded by {@code this}. */
    private final LongOpenHashSet fetching = new LongOpenHashSet();

    /**
     * Make an empty set of heights.
     *
     * @param level     The level. It's only passed to height sources, and named in warnings.
     * @param capacity  The maximum number of chunks to remember.
     * @param onFetched Called, on any thread, each time a chunk we fetched arrives.
     */
    LevelHeights(ServerLevel level, int capacity, Runnable onFetched) {
        this.level = level;
        this.capacity = capacity;
        this.onFetched = onFetched;
    }

    /**
     * Change how many chunks we remember at most, forgetting the least recently used if there are more.
     *
     * @param capacity The maximum number of chunks to remember.
     */
    synchronized void setCapacity(int capacity) {
        this.capacity = capacity;
        trim();
    }

    /**
     * How many chunks were forgotten soon after we found out about them: a sign the links in use cross more chunks than
     * we may remember.
     *
     * @return The number of chunks.
     */
    synchronized long churned() {
        return churned;
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
        trim();
    }

    /**
     * Forget the least recently used chunks while we have more than we may. If some of them were found out about only
     * a moment ago, the links in use need more chunks than we may remember: say so, now and then, as their terrain then
     * goes missing over and over, and they're traced as if there were nothing there.
     */
    private synchronized void trim() {
        if (heights.size() <= capacity) return;
        var now = System.currentTimeMillis();
        while (heights.size() > capacity) {
            if (now - heights.removeFirst().created() < CHURN_MILLIS) churned++;
        }

        if (churned > churnWarned && now - lastChurnWarning >= CHURN_WARNING_MILLIS) {
            lastChurnWarning = now;
            // (No level in tests.)
            @SuppressWarnings("ConstantValue") var name = level == null ? "a level" : level.dimension().toString();
            LOG.warn(
                "Radio links in {} cross more chunks than the {} whose terrain heights are remembered (height_cache_chunks): " +
                    "{} chunks were forgotten within a minute of being looked up, so links are traced with terrain missing. " +
                    "Raise height_cache_chunks in the server config.",
                name, capacity, churned - churnWarned
            );
            churnWarned = churned;
        }
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
            onFetched.run();
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
