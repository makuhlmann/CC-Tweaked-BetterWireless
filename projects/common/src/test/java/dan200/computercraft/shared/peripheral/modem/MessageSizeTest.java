// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

public class MessageSizeTest {
    @Test
    public void countsStrings() {
        assertFalse(MessageSize.exceeds("x".repeat(100), 200));
        assertTrue(MessageSize.exceeds("x".repeat(300), 200));
    }

    @Test
    public void countsNestedTables() {
        var message = Map.of("a", "x".repeat(90), "b", Map.of("c", "y".repeat(90)));
        assertFalse(MessageSize.exceeds(message, 250));
        assertTrue(MessageSize.exceeds(message, 150));
    }

    @Test
    public void countsNumbers() {
        var message = new HashMap<Object, Object>();
        for (var i = 1; i <= 30; i++) message.put((double) i, (double) i);
        // Each entry is a key, a value and some overhead: about 18 bytes.
        assertTrue(MessageSize.exceeds(message, 500));
        assertFalse(MessageSize.exceeds(message, 600));
    }

    @Test
    public void countsSharedTablesOnce() {
        var shared = Map.of("data", "x".repeat(100));
        var message = new HashMap<Object, Object>();
        for (var i = 0; i < 10; i++) message.put("copy" + i, shared);
        assertFalse(MessageSize.exceeds(message, 300));

        var cycle = new HashMap<Object, Object>();
        cycle.put("self", cycle);
        assertFalse(MessageSize.exceeds(cycle, 100));
    }
}
