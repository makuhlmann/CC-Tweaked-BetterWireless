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
import org.junit.jupiter.api.Test;

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
