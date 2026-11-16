// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.shared.config.Config;
import org.jspecify.annotations.Nullable;

import java.util.Map;

/**
 * A snapshot of the radio configuration.
 * <p>
 * A channel's number is its frequency in units of 100kHz: channel 1500 is 150MHz, and channel 24000 is 2.4GHz. Rednet's
 * messages and GPS's channel have frequencies of their own (see {@link #frequency(Packet)}).
 * <p>
 * Whether a receiver hears a packet depends on the power it was sent with ({@link #transmitPower(Packet)}), the loss
 * along the way, and how weak a signal the receiver can hear ({@link #sensitivity(PacketReceiver)}).
 *
 * @param environment        The propagation model parameters.
 * @param maxRange           The maximum distance a link may span, in blocks.
 * @param defaultPower       The power placed computers' wireless modems transmit with by default, in dBm.
 * @param maxPower           The most power any device may transmit with, in dBm.
 * @param rednetFrequency    The frequency of rednet's messages, in MHz.
 * @param rednetPowerOffset  How much less power rednet's messages are sent with than the modem's, in dB.
 * @param gpsFrequency       The frequency of GPS's channel, in MHz.
 * @param stormPenalty       How much noise thunderstorms add, in dB.
 * @param tickBudgetNanos    How long we may spend evaluating links each tick.
 * @param cacheTicks         How long evaluated links are remembered for.
 * @param moveTolerance      How far two radios may have moved since their link was traced, in blocks, for a packet
 *                           between them to be delivered with that path while the link is traced again; 0 for never.
 * @param crossCacheTicks    How long links evaluated for a packet from another dimension are remembered for.
 * @param dimensionHeights   The heights signals from other dimensions may appear at in each dimension, by its ID.
 * @param lookupTimeoutTicks How long to wait for terrain data before guessing.
 * @param useGenerator       Whether to ask the chunk generator about terrain we have no other data for.
 * @param useDistantHorizons Whether to read terrain from Distant Horizons.
 */
public record RadioSettings(
    RadioEnvironment environment,
    double maxRange,
    double defaultPower,
    double maxPower,
    double rednetFrequency,
    double rednetPowerOffset,
    double gpsFrequency,
    double stormPenalty,
    long tickBudgetNanos,
    int cacheTicks,
    int moveTolerance,
    int crossCacheTicks,
    Map<String, DimensionHeights> dimensionHeights,
    int lookupTimeoutTicks,
    boolean useGenerator,
    boolean useDistantHorizons
) {
    /**
     * The weakest signal a wireless modem on a placed computer can hear, in dBm. Weaker devices hear less (see
     * {@link #sensitivity(PacketReceiver)}).
     */
    public static final double SENSITIVITY = -100;

    /** GPS's channel. */
    public static final int GPS_CHANNEL = 65534;

    /**
     * Channels 65533-65535 belong to rednet and GPS. Rednet's messages are recognised by what they carry instead (see
     * {@link #frequency(Packet)}), so other messages on 65533 and 65535 are treated like rednet's.
     */
    private static final int FIRST_RESERVED_CHANNEL = 65533;

    public static RadioSettings fromConfig() {
        var environment = new RadioEnvironment(
            Config.radioMetresPerBlock,
            Config.radioMetresPerBlockVertical,
            Config.radioEarthRadius * 1000 * 4 / 3,
            Config.radioGroundReflection,
            Config.radioMinAntennaHeight,
            Config.radioMaterialLossScale,
            Config.radioBuiltLossScale,
            Config.radioReflections,
            Config.radioVoxelRadius,
            Config.radioProfileSamples,
            Config.radioCeilingUnknownFill
        );

        var maxPower = Math.max(Config.radioMaxTransmitPower, Math.max(Config.radioPocketMaxTransmitPower, Config.radioTurtleMaxTransmitPower));
        return new RadioSettings(
            environment,
            Config.radioMaxRange,
            Config.radioTransmitPower,
            maxPower,
            Config.radioRednetFrequency,
            Config.radioRednetPowerOffset,
            Config.radioGpsFrequency,
            Config.radioStormPenalty,
            Config.radioTickBudgetMicros * 1000L,
            Config.radioCacheTicks,
            Config.radioMoveTolerance,
            Config.radioEnderCacheTicks,
            Config.radioEnderYRanges,
            Config.radioLookupTimeoutTicks,
            Config.radioUseGenerator,
            Config.radioUseDistantHorizons
        );
    }

    /**
     * The frequency of a channel: its number in units of 100kHz, within the frequencies the model works at.
     *
     * @param channel The channel.
     * @return The frequency, in MHz.
     */
    public static double channelFrequency(int channel) {
        return Math.clamp(channel / 10.0, RadioMaterial.MIN_FREQUENCY, RadioMaterial.MAX_FREQUENCY);
    }

    /**
     * The frequency a packet is sent at.
     * <p>
     * Rednet's messages use {@link #rednetFrequency()}, whatever their channel. Rednet sends to a computer on a channel
     * derived from its ID, so going by channel would send rednet at a different frequency to every computer, and its
     * replies at a different frequency from the messages they answer. Other messages on rednet's channels (65533 and
     * 65535) use rednet's frequency too, and GPS's channel (65534) has {@link #gpsFrequency()}.
     * <p>
     * Everything else goes by channel ({@link #channelFrequency(int)}).
     *
     * @param packet The packet being sent.
     * @return The frequency, in MHz.
     */
    public double frequency(Packet packet) {
        var channel = packet.channel();
        if (isRednet(packet.payload())) return clampFrequency(rednetFrequency);
        if (channel == GPS_CHANNEL) return clampFrequency(gpsFrequency);
        if (channel >= FIRST_RESERVED_CHANNEL) return clampFrequency(rednetFrequency);
        return channelFrequency(channel);
    }

    private static double clampFrequency(double frequency) {
        return Math.clamp(frequency, RadioMaterial.MIN_FREQUENCY, RadioMaterial.MAX_FREQUENCY);
    }

    /**
     * The power a packet is sent with: its sender's, less {@link #rednetPowerOffset()} for rednet's messages.
     *
     * @param packet The packet being sent.
     * @return The power, in dBm. This is never more than {@link #maxPower()}.
     */
    public double transmitPower(Packet packet) {
        var power = packet.sender().getTransmitPower();
        if (Double.isNaN(power)) power = defaultPower;
        if (isRednet(packet.payload())) power += Math.min(0, rednetPowerOffset);
        return Math.min(power, maxPower);
    }

    /**
     * The weakest signal a receiver can hear.
     *
     * @param receiver The receiver.
     * @return The signal strength, in dBm.
     */
    public static double sensitivity(PacketReceiver receiver) {
        return SENSITIVITY - Math.min(0, receiver.getReceiveOffset());
    }

    /**
     * The largest link budget any link may have: that of the strongest transmitter and the best receiver. Links are
     * traced this far, so a traced link serves every device.
     *
     * @return The budget, in dB.
     */
    public double maxBudget() {
        return maxPower - SENSITIVITY;
    }

    /**
     * Whether a message is one of rednet's. Rednet wraps everything it sends (lookups, broadcasts and what repeaters
     * pass on included) in a table with a message ID and the recipient's ID. This is the check rednet's repeater makes.
     *
     * @param payload The message.
     * @return Whether it's rednet's.
     */
    static boolean isRednet(@Nullable Object payload) {
        return payload instanceof Map<?, ?> message && message.get("nMessageID") != null && message.get("nRecipient") instanceof Number;
    }

    /**
     * Whether a link between two particular devices could possibly work, even in perfect conditions.
     * <p>
     * This only looks at the distance, so is cheap: no link loses less than it would in free space. Links which pass
     * still need their terrain looked up and evaluated.
     *
     * @param distance     The distance between the two antennas, in blocks.
     * @param frequencyMHz The frequency the link uses, in MHz.
     * @param power        The power the packet is sent with, in dBm.
     * @param sensitivity  The weakest signal the receiver can hear, in dBm.
     * @return Whether the link is worth evaluating.
     */
    public boolean isPossible(double distance, double frequencyMHz, double power, double sensitivity) {
        return distance <= maxRange
            && RadioMath.freeSpaceLoss(distance * environment.metresPerBlock(), frequencyMHz) <= power - sensitivity;
    }
}
