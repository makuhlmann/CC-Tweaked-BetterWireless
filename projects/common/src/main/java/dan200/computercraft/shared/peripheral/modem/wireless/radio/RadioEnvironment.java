// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

/**
 * Global parameters for the propagation model.
 *
 * @param metresPerBlock         How many metres a block represents horizontally. Worlds generated at a reduced scale
 *                               (for instance, Tellus at 1:8) should increase this.
 * @param metresPerBlockVertical How many metres a block represents vertically.
 * @param effectiveEarthRadius   The effective radius of the earth in metres, used to bend terrain profiles. Usually
 *                               4/3 of the real radius. Zero for a flat world.
 * @param groundReflection       Whether to use the two-ray ground reflection model, rather than just free space loss.
 * @param minAntennaHeight       The minimum height of an antenna above the average terrain, in metres.
 * @param materialLossScale      A multiplier applied to all material attenuation.
 * @param voxelRadius            How far from each end of the link, in blocks, we look at individual blocks rather than
 *                               just heightmaps.
 * @param maxProfileSamples      The maximum number of points we sample along the terrain profile.
 */
public record RadioEnvironment(
    double metresPerBlock,
    double metresPerBlockVertical,
    double effectiveEarthRadius,
    boolean groundReflection,
    double minAntennaHeight,
    double materialLossScale,
    int voxelRadius,
    int maxProfileSamples
) {
    public static final RadioEnvironment DEFAULT = new RadioEnvironment(1, 1, 0, true, 2, 1, 64, 512);

    /**
     * The total path loss two antennas at the minimum height experience over flat, open ground. This is used to derive a
     * link budget from a configured range.
     *
     * @param rangeBlocks  The distance between the antennas, in blocks.
     * @param frequencyMHz The frequency, in MHz.
     * @return The path loss, in dB.
     */
    public double flatGroundLoss(double rangeBlocks, double frequencyMHz) {
        var distance = rangeBlocks * metresPerBlock;
        return groundReflection
            ? RadioMath.groundReflectionLoss(distance, frequencyMHz, minAntennaHeight, minAntennaHeight)
            : RadioMath.freeSpaceLoss(distance, frequencyMHz);
    }
}
