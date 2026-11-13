// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.api.network.PacketSender;
import dan200.computercraft.shared.config.Config;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

public class RadioSettingsTest {
    @Test
    public void weakerDevicesNeedToBeCloser() {
        var settings = RadioSettings.fromConfig();
        var band = settings.lowBand();
        var pockets = Config.radioPocketTransmitOffset + Config.radioPocketReceiveOffset;

        // Placed computers can reach each other over 10,000 blocks of open ground, if their antennas are high enough.
        // Two pocket computers can't, whatever is in the way, so the link isn't worth looking up the terrain for.
        assertTrue(settings.isPossible(10_000, band, 0));
        assertFalse(settings.isPossible(10_000, band, pockets));
        assertTrue(settings.isPossible(5_000, band, pockets));
    }

    @Test
    public void rednetUsesTheHighBand() {
        var settings = RadioSettings.fromConfig();
        var high = settings.highBand();
        var low = settings.lowBand();

        // Sent to computer 5 (on channel 5), broadcast, and passed on by a repeater.
        assertEquals(high, settings.band(packet(5, rednet(5))));
        assertEquals(high, settings.band(packet(65535, rednet(65535))));
        assertEquals(high, settings.band(packet(65533, rednet(2000))));

        // GPS keeps the low band: both the ping, and the host's reply of its position.
        assertEquals(low, settings.band(packet(65534, "PING")));
        assertEquals(low, settings.band(packet(65534, Map.of(1.0, 120.0, 2.0, 70.0, 3.0, -40.0))));
        // As do other messages on rednet's channels.
        assertEquals(low, settings.band(packet(65535, Map.of("message", "hello"))));

        // Everything else goes by channel.
        assertEquals(low, settings.band(packet(5, "hello")));
        assertEquals(high, settings.band(packet(2000, "hello")));
        assertEquals(high, settings.band(packet(2000, null)));
    }

    // A message as rednet wraps it.
    private static Map<Object, Object> rednet(int recipient) {
        return Map.of("nMessageID", 1234567.0, "nRecipient", (double) recipient, "nSender", 1.0, "message", "hello", "sProtocol", "chat");
    }

    private static Packet packet(int channel, @Nullable Object payload) {
        return new Packet(channel, channel, payload, new Sender(0));
    }

    @Test
    public void offsetAddsBothEnds() {
        assertEquals(-17, RadioSettings.offset(new Sender(-10), new Receiver(-7)));
        // Nothing is stronger than a placed computer.
        assertEquals(0, RadioSettings.offset(new Sender(5), new Receiver(3)));
    }

    private static final class Sender implements PacketSender {
        private final double offset;

        Sender(double offset) {
            this.offset = offset;
        }

        @Override
        public Level getLevel() {
            throw new UnsupportedOperationException();
        }

        @Override
        public Vec3 getPosition() {
            throw new UnsupportedOperationException();
        }

        @Override
        public String getSenderID() {
            return "test";
        }

        @Override
        public double getTransmitOffset() {
            return offset;
        }
    }

    private static final class Receiver implements PacketReceiver {
        private final double offset;

        Receiver(double offset) {
            this.offset = offset;
        }

        @Override
        public Level getLevel() {
            throw new UnsupportedOperationException();
        }

        @Override
        public Vec3 getPosition() {
            throw new UnsupportedOperationException();
        }

        @Override
        public double getRange() {
            return 0;
        }

        @Override
        public double getReceiveOffset() {
            return offset;
        }

        @Override
        public boolean isInterdimensional() {
            return false;
        }

        @Override
        public void receiveSameDimension(Packet packet, double distance) {
        }

        @Override
        public void receiveDifferentDimension(Packet packet) {
        }
    }
}
