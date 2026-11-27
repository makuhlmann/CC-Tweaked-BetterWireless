// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Predicate;
import java.util.function.Supplier;

/**
 * The links we've traced, each until it expires.
 * <p>
 * A link is traced with whatever is known of the terrain along it, and terrain we know nothing of counts as open ground,
 * so a link traced before its terrain's heights arrive (or after they were forgotten) may seem far better than it is.
 * Such a path is only cached briefly, so the link is traced again once more is known. And once a link has been traced
 * with all of its terrain known, that path is kept in preference to one traced with some missing: otherwise a link over
 * a hill would come and go as the hill's heights are forgotten and fetched again.
 * <p>
 * This may be read on any thread. Links are only added on the server thread.
 *
 * @param <K> What links are told apart by.
 */
final class LinkCache<K> {
    /** How long a path traced with some of its terrain missing is used for, in ticks, before tracing the link again. */
    static final long GUESS_TICKS = 20;

    /**
     * How many ticks before a cached link expires a packet over it has it traced again, in the background (but never
     * more than a quarter of how long it's cached for).
     */
    static final long RENEW_TICKS = 20;

    /** The links, least recently used first. This must only be used while holding its lock. */
    private final Map<K, CachedLink> links;

    /**
     * Make an empty cache.
     *
     * @param capacity How many links to remember at most.
     */
    LinkCache(int capacity) {
        links = new LinkedHashMap<>(256, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<K, CachedLink> eldest) {
                return size() > capacity;
            }
        };
    }

    /**
     * A traced link, which is used until it expires.
     *
     * @param path     Its path.
     * @param traced   The tick it was traced on.
     * @param expires  The tick it expires on.
     * @param complete Whether all the terrain along it was known when it was traced.
     * @param renewing Whether it's being traced again already, as it was in use when it was about to expire.
     */
    record CachedLink(LinkPath path, long traced, long expires, boolean complete, AtomicBoolean renewing) {
        CachedLink(LinkPath path, long traced, long expires, boolean complete) {
            this(path, traced, expires, complete, new AtomicBoolean());
        }

        /**
         * Whether to trace the link again now, in the background, as it's in use and expires soon. Only says so once.
         * This may be called from any thread.
         *
         * @param now The current tick.
         * @return Whether to trace it again.
         */
        boolean dueForRenewal(long now) {
            var margin = Math.min(RENEW_TICKS, (expires - traced) / 4);
            return expires - now <= margin && renewing.compareAndSet(false, true);
        }
    }

    /**
     * Find a cached link whose path serves a link with some budget, at some frequency. This may be called from any
     * thread.
     * <p>
     * Links are only traced as far as what's waiting for them needs: a path traced for a weaker transmitter serves a
     * stronger one only if the link was within its budget. Otherwise, it's traced again, further.
     *
     * @param key          The link.
     * @param frequencyMHz The frequency it's needed at.
     * @param budget       How much loss the link can take, in dB.
     * @param now          The current tick.
     * @return The cached link, or {@code null} if it isn't cached, has expired, or wasn't traced far enough.
     */
    @Nullable
    CachedLink get(K key, double frequencyMHz, double budget, long now) {
        CachedLink cached;
        synchronized (links) {
            cached = links.get(key);
        }
        return cached != null && cached.expires() > now && cached.path().serves(frequencyMHz, budget) ? cached : null;
    }

    /**
     * Find a link's path, now that what's known of its terrain has arrived (or we've waited long enough for it), and
     * remember it.
     * <p>
     * With all of its terrain known, the link is traced. With some missing, the path it had when it was last traced with
     * everything known is used instead, if it serves everything waiting for it: that's still a better guess than
     * counting the missing terrain as open ground. Otherwise it's traced with what's known. Either way, it's only kept
     * for {@link #GUESS_TICKS}, so it's traced again soon.
     *
     * @param key      The link.
     * @param complete Whether all the terrain along it is known.
     * @param serves   Whether a path serves everything waiting for the link.
     * @param now      The current tick.
     * @param lifetime How long a path traced with all of its terrain known is used for, in ticks.
     * @param trace    Trace the link.
     * @return The path to use.
     */
    LinkPath settle(K key, boolean complete, Predicate<LinkPath> serves, long now, long lifetime, Supplier<LinkPath> trace) {
        if (!complete) {
            CachedLink previous;
            synchronized (links) {
                previous = links.get(key);
            }
            if (previous != null && previous.complete() && serves.test(previous.path())) {
                put(key, new CachedLink(previous.path(), now, now + Math.min(lifetime, GUESS_TICKS), true));
                return previous.path();
            }
        }

        var path = trace.get();
        put(key, new CachedLink(path, now, now + (complete ? lifetime : Math.min(lifetime, GUESS_TICKS)), complete));
        return path;
    }

    private void put(K key, CachedLink link) {
        synchronized (links) {
            links.put(key, link);
        }
    }
}
