// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

import java.util.concurrent.ConcurrentHashMap;

/**
 * The senders which have packets queued for the server thread, and how many. While a sender has any, its next packets
 * are queued too, rather than delivered at once, so that a sender's packets arrive in the order it sent them.
 * <p>
 * Senders are told apart by identity, as modems are the same object while they exist. They're held strongly while
 * they have packets queued. This may be used from any thread.
 */
final class QueuedSenders {
    private final ConcurrentHashMap<Key, Integer> counts = new ConcurrentHashMap<>();

    private record Key(Object sender) {
        @Override
        public boolean equals(@Nullable Object other) {
            return other instanceof Key key && key.sender == sender;
        }

        @Override
        public int hashCode() {
            return System.identityHashCode(sender);
        }
    }

    /**
     * Say a sender has queued another packet.
     *
     * @param sender The sender.
     */
    void add(Object sender) {
        counts.merge(new Key(sender), 1, Integer::sum);
    }

    /**
     * Say one of a sender's queued packets has been delivered (or dropped).
     *
     * @param sender The sender.
     */
    void remove(Object sender) {
        counts.computeIfPresent(new Key(sender), (key, count) -> count <= 1 ? null : count - 1);
    }

    /**
     * Check whether a sender has packets queued.
     *
     * @param sender The sender.
     * @return Whether it has any.
     */
    boolean contains(Object sender) {
        return counts.containsKey(new Key(sender));
    }
}
