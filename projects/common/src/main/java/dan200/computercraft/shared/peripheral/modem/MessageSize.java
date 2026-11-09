// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem;

import org.jspecify.annotations.Nullable;

import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Estimates how large a modem message is, without serialising it: string lengths, eight bytes per number, and a small
 * overhead per table entry. Tables which appear more than once are only counted once.
 */
public final class MessageSize {
    private static final int STRING_OVERHEAD = 2;
    private static final int NUMBER_SIZE = 8;
    private static final int TABLE_OVERHEAD = 2;
    private static final int ENTRY_OVERHEAD = 2;

    private final long limit;
    private final Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<>());
    private long size;

    private MessageSize(long limit) {
        this.limit = limit;
    }

    /**
     * Check whether a message is larger than a limit. This stops as soon as it is, so huge messages are cheap to reject.
     *
     * @param message The message, as passed to {@code modem.transmit}.
     * @param limit   The largest allowed size, in bytes.
     * @return Whether the message is larger than the limit.
     */
    public static boolean exceeds(@Nullable Object message, long limit) {
        return new MessageSize(limit).add(message);
    }

    private boolean add(@Nullable Object value) {
        switch (value) {
            case null -> size += 1;
            case Boolean ignored -> size += 1;
            case Number ignored -> size += NUMBER_SIZE;
            case String string -> size += string.length() + STRING_OVERHEAD;
            case byte[] bytes -> size += bytes.length + STRING_OVERHEAD;
            case ByteBuffer bytes -> size += bytes.remaining() + STRING_OVERHEAD;
            case Map<?, ?> table -> {
                if (!seen.add(table)) return false;
                size += TABLE_OVERHEAD;
                for (var entry : table.entrySet()) {
                    size += ENTRY_OVERHEAD;
                    if (size > limit || add(entry.getKey()) || add(entry.getValue())) return true;
                }
            }
            default -> size += NUMBER_SIZE;
        }
        return size > limit;
    }
}
