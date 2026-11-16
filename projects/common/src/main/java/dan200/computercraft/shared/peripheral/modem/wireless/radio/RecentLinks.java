// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The last path traced between each pair of radios, so that a packet between two radios which have moved a little
 * since needn't wait for the link to be traced again where they are now.
 * <p>
 * Links are remembered by the blocks their ends are in, so every block a phone moves into is a link which hasn't been
 * traced. On a long link that takes a while: the terrain's heights may have to be looked up, and the server only
 * traces so many links each tick. Instead, the path traced between the same two radios a moment ago is used at once
 * (if neither has moved further than some tolerance since, and it isn't too old), while the link where they are now is
 * traced in the background. Each pair has at most one such trace waiting: a newer one replaces it, so a radio which
 * keeps moving only has its latest position traced.
 * <p>
 * Radios are told apart by identity: a modem is the same object while it exists. They're held strongly, so entries are
 * {@linkplain #purge(long) purged} once they're too old to be used.
 */
final class RecentLinks {
    private final int capacity;
    private final Map<Pair, Recent> entries;
    private final Map<Pair, Object> refreshing = new LinkedHashMap<>();

    /**
     * Make an empty set of recent links.
     *
     * @param capacity How many pairs of radios to remember at most.
     */
    RecentLinks(int capacity) {
        this.capacity = capacity;
        entries = new LinkedHashMap<>(256, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<Pair, Recent> eldest) {
                return size() > RecentLinks.this.capacity;
            }
        };
    }

    /**
     * Two radios, either way round.
     *
     * @param a One radio.
     * @param b The other.
     */
    private record Pair(Object a, Object b) {
        @Override
        public boolean equals(@Nullable Object other) {
            return other instanceof Pair pair && ((a == pair.a && b == pair.b) || (a == pair.b && b == pair.a));
        }

        @Override
        public int hashCode() {
            return System.identityHashCode(a) ^ System.identityHashCode(b);
        }
    }

    /**
     * The last path traced between two radios, and where each was.
     *
     * @param level  The level they were in.
     * @param a      One radio.
     * @param aPos   Where its antenna was.
     * @param b      The other radio.
     * @param bPos   Where its antenna was.
     * @param path   The path traced between them.
     * @param traced When it was traced, in ticks.
     */
    private record Recent(Object level, Object a, Vec3 aPos, Object b, Vec3 bPos, LinkPath path, long traced) {
    }

    /**
     * Remember a path traced between two radios.
     *
     * @param level    The level they're in.
     * @param sender   One radio.
     * @param from     Where its antenna is.
     * @param receiver The other radio.
     * @param to       Where its antenna is.
     * @param path     The path traced between them.
     * @param tick     The current tick.
     */
    void record(Object level, Object sender, Vec3 from, Object receiver, Vec3 to, LinkPath path, long tick) {
        entries.put(new Pair(sender, receiver), new Recent(level, sender, from, receiver, to, path, tick));
    }

    /**
     * Find a path to use now for two radios, from the last traced between them.
     *
     * @param level     The level they're in.
     * @param sender    The radio sending.
     * @param from      Where its antenna is now.
     * @param receiver  The radio receiving.
     * @param to        Where its antenna is now.
     * @param tick      The current tick.
     * @param tolerance How far each may have moved since, in blocks.
     * @param maxAge    How long ago the path may have been traced, in ticks.
     * @param frequency The frequency the packet is sent at, in MHz.
     * @param budget    The link's budget, in dB, which the path must serve (see {@link LinkPath#serves}).
     * @return The path, or {@code null} if there's none to use.
     */
    @Nullable
    LinkPath find(
        Object level, Object sender, Vec3 from, Object receiver, Vec3 to, long tick, double tolerance, long maxAge,
        double frequency, double budget
    ) {
        var entry = entries.get(new Pair(sender, receiver));
        if (entry == null || entry.level != level || tick - entry.traced > maxAge) return null;

        // The entry may have the two radios the other way round: this is the reply.
        var senderWas = entry.a == sender ? entry.aPos : entry.bPos;
        var receiverWas = entry.a == sender ? entry.bPos : entry.aPos;
        var limit = tolerance * tolerance;
        if (from.distanceToSqr(senderWas) > limit || to.distanceToSqr(receiverWas) > limit) return null;
        return entry.path.serves(frequency, budget) ? entry.path : null;
    }

    /**
     * Say which trace is waiting to refresh the link between two radios, replacing any before it.
     *
     * @param sender   One radio.
     * @param receiver The other.
     * @param refresh  The trace now waiting.
     * @return The trace which was waiting before, if it's another one: it may be dropped, if nothing else needs it.
     */
    @Nullable
    Object refreshing(Object sender, Object receiver, Object refresh) {
        var previous = refreshing.put(new Pair(sender, receiver), refresh);
        return previous == refresh ? null : previous;
    }

    /**
     * Say a trace is done, so it no longer waits to refresh the link between two radios.
     *
     * @param sender   One radio.
     * @param receiver The other.
     * @param refresh  The trace which is done.
     */
    void refreshed(Object sender, Object receiver, Object refresh) {
        refreshing.remove(new Pair(sender, receiver), refresh);
    }

    /**
     * Forget paths traced before some tick, so radios which no longer exist aren't held.
     *
     * @param before The first tick of the paths to keep.
     */
    void purge(long before) {
        entries.values().removeIf(entry -> entry.traced < before);
    }

    /**
     * Count the pairs of radios remembered.
     *
     * @return How many.
     */
    int size() {
        return entries.size();
    }
}
