// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.api.network.PacketSender;
import dan200.computercraft.shared.config.Config;

import java.util.Map;

/**
 * A snapshot of the radio configuration.
 *
 * @param environment         The propagation model parameters.
 * @param lowBand             The band used by most channels.
 * @param highBand            The band used by high channels.
 * @param highBandFirstChannel The first channel which uses the high band.
 * @param maxRange            The maximum distance a link may span, in blocks.
 * @param stormPenalty        How much noise thunderstorms add, in dB.
 * @param tickBudgetNanos     How long we may spend evaluating links each tick.
 * @param cacheTicks          How long evaluated links are remembered for.
 * @param crossCacheTicks     How long links evaluated for a packet from another dimension are remembered for.
 * @param dimensionHeights    The heights signals from other dimensions may appear at in each dimension, by its ID.
 * @param lookupTimeoutTicks  How long to wait for terrain data before guessing.
 * @param useGenerator        Whether to ask the chunk generator about terrain we have no other data for.
 * @param useDistantHorizons  Whether to read terrain from Distant Horizons.
 */
public record RadioSettings(
    RadioEnvironment environment,
    RadioBand lowBand,
    RadioBand highBand,
    int highBandFirstChannel,
    double maxRange,
    double stormPenalty,
    long tickBudgetNanos,
    int cacheTicks,
    int crossCacheTicks,
    Map<String, DimensionHeights> dimensionHeights,
    int lookupTimeoutTicks,
    boolean useGenerator,
    boolean useDistantHorizons
) {
    /** Rednet and GPS use these channels, and should keep long range regardless of band settings. */
    private static final int FIRST_RESERVED_CHANNEL = 65533;

    public static RadioSettings fromConfig() {
        var environment = new RadioEnvironment(
            Config.radioMetresPerBlock,
            Config.radioMetresPerBlockVertical,
            Config.radioEarthRadius * 1000 * 4 / 3,
            Config.radioGroundReflection,
            Config.radioMinAntennaHeight,
            Config.radioMaterialLossScale,
            Config.radioVoxelRadius,
            Config.radioProfileSamples,
            Config.radioCeilingUnknownFill
        );

        var lowBudget = environment.flatGroundLoss(Config.radioReferenceRange, Config.radioLowBandFrequency);
        return new RadioSettings(
            environment,
            new RadioBand(0, Config.radioLowBandFrequency, lowBudget),
            new RadioBand(1, Config.radioHighBandFrequency, lowBudget + Config.radioHighBandBudgetOffset),
            Config.radioHighBandFirstChannel,
            Config.radioMaxRange,
            Config.radioStormPenalty,
            Config.radioTickBudgetMicros * 1000L,
            Config.radioCacheTicks,
            Config.radioEnderCacheTicks,
            Config.radioEnderYRanges,
            Config.radioLookupTimeoutTicks,
            Config.radioUseGenerator,
            Config.radioUseDistantHorizons
        );
    }

    public RadioBand band(int channel) {
        return channel >= highBandFirstChannel && channel < FIRST_RESERVED_CHANNEL ? highBand : lowBand;
    }

    /**
     * Whether a link between two particular devices could possibly work, even in perfect conditions.
     * <p>
     * This only looks at the distance, so is cheap: no link loses less than it would in free space. Links which pass
     * still need their terrain looked up and evaluated, so this should account for everything it can, including how
     * weak the devices are.
     *
     * @param distance The distance between the two antennas, in blocks.
     * @param band     The band the link uses.
     * @param offset   How much weaker the two devices are than the strongest, in dB: see
     *                 {@link #offset(PacketSender, PacketReceiver)}.
     * @return Whether the link is worth evaluating.
     */
    public boolean isPossible(double distance, RadioBand band, double offset) {
        return distance <= maxRange
            && RadioMath.freeSpaceLoss(distance * environment.metresPerBlock(), band.frequencyMHz()) <= band.linkBudget() + Math.min(0, offset);
    }

    /**
     * How much weaker two devices are than the strongest (a wireless modem on a placed computer at each end), and so
     * how much less loss a link between them can take.
     *
     * @param sender   The device which sends.
     * @param receiver The device which receives.
     * @return The sum of the sender's transmit offset and the receiver's receive offset, in dB. Positive offsets
     * count as zero, so this is zero or negative.
     */
    public static double offset(PacketSender sender, PacketReceiver receiver) {
        return Math.min(0, sender.getTransmitOffset()) + Math.min(0, receiver.getReceiveOffset());
    }
}
