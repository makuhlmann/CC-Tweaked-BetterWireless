// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class QueuedSendersTest {
    /**
     * A sender which equals any other with the same name, as peripherals may.
     *
     * @param name Its name.
     */
    private record Modem(String name) {
    }

    @Test
    void countsEachSendersPackets() {
        var senders = new QueuedSenders();
        var modem = new Modem("left");
        assertFalse(senders.contains(modem));

        senders.add(modem);
        senders.add(modem);
        senders.remove(modem);
        assertTrue(senders.contains(modem), "One packet is still queued");

        senders.remove(modem);
        assertFalse(senders.contains(modem));

        // A sender with nothing queued stays that way.
        senders.remove(modem);
        senders.add(modem);
        assertTrue(senders.contains(modem));
    }

    @Test
    void tellsSendersApartByIdentity() {
        var senders = new QueuedSenders();
        var modem = new Modem("left");
        var other = new Modem("left");
        assertEquals(modem, other);

        senders.add(modem);
        assertTrue(senders.contains(modem));
        assertFalse(senders.contains(other), "An equal modem is still another modem");

        senders.remove(other);
        assertTrue(senders.contains(modem));
    }
}
