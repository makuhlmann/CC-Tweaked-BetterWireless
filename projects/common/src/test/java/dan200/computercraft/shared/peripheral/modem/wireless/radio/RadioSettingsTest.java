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
    private static final RadioEnvironment ENV = RadioEnvironment.DEFAULT;

    @Test
    public void channelsAreFrequencies() {
        // Each channel is 100kHz.
        assertEquals(150, RadioSettings.channelFrequency(1500), 1e-9);
        assertEquals(2400, RadioSettings.channelFrequency(24000), 1e-9);
        assertEquals(2110.5, RadioSettings.channelFrequency(21105), 1e-9);
        // Within the frequencies the model works at.
        assertEquals(RadioMaterial.MIN_FREQUENCY, RadioSettings.channelFrequency(5), 1e-9);
        assertEquals(RadioMaterial.MIN_FREQUENCY, RadioSettings.channelFrequency(0), 1e-9);
    }

    @Test
    public void rednetAndGpsHaveTheirOwnFrequencies() {
        var settings = RadioSettings.fromConfig();
        var rednet = Config.radioRednetFrequency;
        var gps = Config.radioGpsFrequency;

        // Sent to computer 5 (on channel 5), broadcast, and passed on by a repeater.
        assertEquals(rednet, settings.frequency(packet(5, rednet(5))));
        assertEquals(rednet, settings.frequency(packet(65535, rednet(65535))));
        assertEquals(rednet, settings.frequency(packet(65533, rednet(2000))));

        // GPS: both the ping, and the host's reply of its position.
        assertEquals(gps, settings.frequency(packet(65534, "PING")));
        assertEquals(gps, settings.frequency(packet(65534, Map.of(1.0, 120.0, 2.0, 70.0, 3.0, -40.0))));
        // Other messages on rednet's channels are taken for rednet's.
        assertEquals(rednet, settings.frequency(packet(65535, Map.of("message", "hello"))));

        // Everything else goes by channel.
        assertEquals(150, settings.frequency(packet(1500, "hello")), 1e-9);
        assertEquals(2400, settings.frequency(packet(24000, null)), 1e-9);
    }

    @Test
    public void rednetIsSentWithLessPower() {
        var settings = RadioSettings.fromConfig();
        var sender = new Sender(10);
        assertEquals(10, settings.transmitPower(new Packet(5, 5, "hello", sender)), 1e-9);
        assertEquals(10 + Config.radioRednetPowerOffset, settings.transmitPower(new Packet(5, 5, rednet(5), sender)), 1e-9);
    }

    @Test
    public void powerIsCapped() {
        var settings = RadioSettings.fromConfig();
        // A sender which says nothing uses the default, and none may be stronger than the strongest device allowed.
        assertEquals(Config.radioTransmitPower, settings.transmitPower(packet(1500, "hello")), 1e-9);
        assertEquals(settings.maxPower(), settings.transmitPower(new Packet(1500, 1500, "hello", new Sender(1000))), 1e-9);
        assertEquals(settings.maxPower() - RadioSettings.SENSITIVITY, settings.maxBudget(), 1e-9);
    }

    @Test
    public void weakerReceiversHearLess() {
        assertEquals(RadioSettings.SENSITIVITY, RadioSettings.sensitivity(new Receiver(0)), 1e-9);
        assertEquals(RadioSettings.SENSITIVITY + 7, RadioSettings.sensitivity(new Receiver(-7)), 1e-9);
        // Nothing hears better than a placed computer.
        assertEquals(RadioSettings.SENSITIVITY, RadioSettings.sensitivity(new Receiver(5)), 1e-9);
    }

    @Test
    public void defaultsKeepTheReferenceRanges() {
        // Placed computers' modems on flat, open ground reach 1024 blocks by default, whatever the frequency, as the
        // two-ray model's loss doesn't depend on it that far out.
        var budget = Config.radioTransmitPower - RadioSettings.SENSITIVITY;
        assertEquals(ENV.flatGroundLoss(1024, 150), budget, 0.1);
        assertEquals(ENV.flatGroundLoss(1024, 2400), budget, 0.1);

        // Rednet keeps its short range: about 260 blocks.
        var rednet = budget + Config.radioRednetPowerOffset;
        assertEquals(ENV.flatGroundLoss(261, Config.radioRednetFrequency), rednet, 0.2);
    }

    @Test
    public void weakerDevicesNeedToBeCloser() {
        var settings = RadioSettings.fromConfig();
        var pocketPower = Config.radioPocketTransmitPower;
        var pocketSensitivity = RadioSettings.SENSITIVITY - Config.radioPocketReceiveOffset;

        // Placed computers can reach each other over 10,000 blocks of open ground, if their antennas are high enough.
        // Two pocket computers can't, whatever is in the way, so the link isn't worth looking up the terrain for.
        assertTrue(settings.isPossible(10_000, 150, Config.radioTransmitPower, RadioSettings.SENSITIVITY));
        assertFalse(settings.isPossible(10_000, 150, pocketPower, pocketSensitivity));
        assertTrue(settings.isPossible(5_000, 150, pocketPower, pocketSensitivity));
        // Higher frequencies lose more in free space.
        assertFalse(settings.isPossible(5_000, 2400, pocketPower, pocketSensitivity));
    }

    // A message as rednet wraps it.
    private static Map<Object, Object> rednet(int recipient) {
        return Map.of("nMessageID", 1234567.0, "nRecipient", (double) recipient, "nSender", 1.0, "message", "hello", "sProtocol", "chat");
    }

    private static Packet packet(int channel, @Nullable Object payload) {
        return new Packet(channel, channel, payload, new Sender(Double.NaN));
    }

    private static final class Sender implements PacketSender {
        private final double power;

        Sender(double power) {
            this.power = power;
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
        public double getTransmitPower() {
            return power;
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
