// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.shared.config.Config;

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
            Config.radioProfileSamples
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
            Config.radioLookupTimeoutTicks,
            Config.radioUseGenerator,
            Config.radioUseDistantHorizons
        );
    }

    public RadioBand band(int channel) {
        return channel >= highBandFirstChannel && channel < FIRST_RESERVED_CHANNEL ? highBand : lowBand;
    }

    /**
     * Whether a link could possibly work, even in perfect conditions.
     *
     * @param distance The distance between the two antennas, in blocks.
     * @param band     The band the link uses.
     * @return Whether the link is worth evaluating.
     */
    public boolean isPossible(double distance, RadioBand band) {
        return distance <= maxRange && RadioMath.freeSpaceLoss(distance * environment.metresPerBlock(), band.frequencyMHz()) <= band.linkBudget();
    }
}
