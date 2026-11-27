// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import it.unimi.dsi.fastutil.longs.LongArrayList;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.phys.Vec3;

import java.util.function.LongPredicate;

/**
 * The chunks a link crosses, which it waits to know the heights of before it's traced.
 * <p>
 * A link may cross thousands of chunks, and wait several seconds for them, so rather than look at every chunk each
 * tick, we walk along them in order: past the chunks we know, and then asking for the ones we don't, as far as the
 * height cache will let us. Chunks arrive in roughly the order they're asked for, so while we wait, each tick looks at
 * only the first chunk we don't know, and where we stopped asking. Each chunk is looked at a few times at most.
 */
final class MissingChunks {
    private final long[] chunks;

    /** All chunks before this one were known when we looked. */
    private int known;

    /** All chunks before this one, and after {@link #known}, have been asked for. */
    private int requested;

    private MissingChunks(long[] chunks) {
        this.chunks = chunks;
    }

    /**
     * Find the chunks a link crosses, as the terrain profile samples them.
     *
     * @param from The position of one end.
     * @param to   The position of the other.
     * @param env  The environment, which says how many samples the profile has.
     * @return The chunks the profile's samples fall in, in order from {@code from}, and then any more near each end
     * (on a long link, samples are chunks apart, but every column near the ends is looked at).
     */
    static MissingChunks between(Vec3 from, Vec3 to, RadioEnvironment env) {
        var seen = new LongOpenHashSet();
        var chunks = new LongArrayList();
        PropagationModel.forEachProfileColumn(from.x, from.z, to.x, to.z, env, (i, x, z) -> {
            var chunk = ChunkPos.pack(x >> 4, z >> 4);
            if (seen.add(chunk)) chunks.add(chunk);
        });
        return of(chunks.toLongArray());
    }

    /**
     * Wait for some chunks.
     *
     * @param chunks The chunks, in the order they should be asked for, without repeats.
     * @return The chunks.
     */
    static MissingChunks of(long... chunks) {
        return new MissingChunks(chunks);
    }

    /**
     * Look at the chunks again, asking for those we don't know.
     *
     * @param isKnown Whether we know the heights of a chunk.
     * @param request Start fetching a chunk, if it isn't being already. This returns {@code false} if it can't be
     *                fetched yet, so should be asked for again later.
     * @return Whether every chunk is known.
     */
    boolean update(LongPredicate isKnown, LongPredicate request) {
        while (known < chunks.length && isKnown.test(chunks[known])) known++;
        if (known == chunks.length) return true;

        // The first chunk we don't know about was asked for before, and is usually still being fetched. It may have
        // been forgotten since it arrived, though (the cache is full, or it couldn't be found a while ago), so ask
        // again. If that can't be fetched yet, nor can anything else.
        if (known < requested) {
            if (!request.test(chunks[known])) return false;
        } else {
            requested = known;
        }

        while (requested < chunks.length) {
            var chunk = chunks[requested];
            if (!isKnown.test(chunk) && !request.test(chunk)) break;
            requested++;
        }
        return false;
    }

    /**
     * Whether every chunk was known, when we last {@linkplain #update looked}.
     *
     * @return Whether every chunk is known.
     */
    boolean isComplete() {
        return known == chunks.length;
    }
}
