// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

/**
 * Pure radio propagation formulas. Nothing in here touches Minecraft, so it can be used from any thread and is easy to
 * unit test.
 * <p>
 * All distances and heights are in metres, frequencies in MHz and losses in dB.
 */
public final class RadioMath {
    public static final double SPEED_OF_LIGHT = 299_792_458.0;

    /**
     * Below this Fresnel parameter, an obstacle does not contribute any diffraction loss (ITU-R P.526).
     */
    public static final double KNIFE_EDGE_THRESHOLD = -0.78;

    private RadioMath() {
    }

    /**
     * The strength of a signal at a receiver, in dBm.
     * <p>
     * Links are evaluated for the strongest transmitter and receiver, so their losses can be shared between devices.
     * Weaker devices' offsets are then added. Offsets above zero are ignored, as nothing beyond what the strongest
     * device reaches is evaluated.
     *
     * @param transmitPower  The power of a placed computer's modem, in dBm.
     * @param loss           The path loss, in dB.
     * @param transmitOffset How much weaker the sender transmits, in dB.
     * @param receiveOffset  How much worse the receiver receives, in dB.
     * @return The signal strength, in dBm.
     */
    public static double receivedSignal(double transmitPower, double loss, double transmitOffset, double receiveOffset) {
        return transmitPower - loss + Math.min(0, transmitOffset) + Math.min(0, receiveOffset);
    }

    /**
     * The wavelength of a signal.
     *
     * @param frequencyMHz The frequency in MHz.
     * @return The wavelength in metres.
     */
    public static double wavelength(double frequencyMHz) {
        return SPEED_OF_LIGHT / (frequencyMHz * 1e6);
    }

    /**
     * Free-space path loss (Friis), using isotropic antennas.
     *
     * @param distance     The distance between the antennas, in metres. Clamped to at least 1m.
     * @param frequencyMHz The frequency, in MHz.
     * @return The path loss in dB.
     */
    public static double freeSpaceLoss(double distance, double frequencyMHz) {
        return 20 * Math.log10(Math.max(distance, 1)) + 20 * Math.log10(frequencyMHz) - 27.55;
    }

    /**
     * Two-ray ("plane earth") path loss. Beyond the crossover distance {@code 4π h1 h2 / λ}, the ground-reflected ray
     * cancels out the direct ray and loss grows with the fourth power of distance rather than the square. This is what
     * makes antenna height matter so much in practice.
     *
     * @param distance     The distance between the antennas, in metres.
     * @param frequencyMHz The frequency, in MHz.
     * @param height1      The height of the first antenna above the reflecting ground, in metres.
     * @param height2      The height of the second antenna above the reflecting ground, in metres.
     * @return The path loss in dB. This is never less than {@link #freeSpaceLoss(double, double)}.
     */
    public static double groundReflectionLoss(double distance, double frequencyMHz, double height1, double height2) {
        var freeSpace = freeSpaceLoss(distance, frequencyMHz);
        var planeEarth = 40 * Math.log10(Math.max(distance, 1)) - 20 * Math.log10(height1 * height2);
        return Math.max(freeSpace, planeEarth);
    }

    /**
     * The Fresnel-Kirchhoff diffraction parameter ν for an obstacle.
     *
     * @param height     The height of the obstacle's tip above the line of sight, in metres. Negative if the line of
     *                   sight clears the obstacle.
     * @param distance1  The distance from the first terminal to the obstacle, in metres.
     * @param distance2  The distance from the obstacle to the second terminal, in metres.
     * @param wavelength The wavelength, in metres.
     * @return The diffraction parameter.
     */
    public static double fresnelParameter(double height, double distance1, double distance2, double wavelength) {
        return height * Math.sqrt(2 / wavelength * (distance1 + distance2) / (distance1 * distance2));
    }

    /**
     * Loss due to a single knife edge, using the approximation from ITU-R P.526 (equation 31).
     *
     * @param v The diffraction parameter, see {@link #fresnelParameter(double, double, double, double)}.
     * @return The diffraction loss in dB.
     */
    public static double knifeEdgeLoss(double v) {
        if (v <= KNIFE_EDGE_THRESHOLD) return 0;
        var t = v - 0.1;
        return 6.9 + 20 * Math.log10(Math.sqrt(t * t + 1) + t);
    }

    /**
     * The extra height of the earth's bulge at a point along a path, used to correct terrain profiles on a curved world.
     *
     * @param distance1     Distance from the first terminal, in metres.
     * @param distance2     Distance to the second terminal, in metres.
     * @param effectiveRadius The effective earth radius in metres (usually 4/3 of the real radius, to account for
     *                        atmospheric refraction). Zero or less means a flat world.
     * @return The bulge height in metres.
     */
    public static double earthBulge(double distance1, double distance2, double effectiveRadius) {
        return effectiveRadius <= 0 ? 0 : distance1 * distance2 / (2 * effectiveRadius);
    }

    /**
     * Diffraction loss over a terrain profile, using the Deygout method. We find the obstacle with the largest
     * diffraction parameter, then recursively look for the dominant obstacle on each side of it.
     *
     * @param distance   The distance of each profile point from the transmitter, in metres. Must be increasing.
     * @param height     The height of each profile point, in metres. This should already include any earth bulge.
     * @param from       The index of the first terminal in the profile.
     * @param to         The index of the second terminal in the profile.
     * @param fromHeight The height of the first terminal (antenna, or obstacle tip), in metres.
     * @param toHeight   The height of the second terminal, in metres.
     * @param wavelength The wavelength, in metres.
     * @param depth      The maximum recursion depth. A depth of 1 gives the classic three-edge Deygout construction.
     * @return The diffraction loss in dB.
     * @see #deygoutEdges(double[], double[], int, int, double, double, int)
     */
    public static double deygoutLoss(double[] distance, double[] height, int from, int to, double fromHeight, double toHeight, double wavelength, int depth) {
        var edge = deygoutEdges(distance, height, from, to, fromHeight, toHeight, depth);
        return edge == null ? 0 : edge.loss(wavelength);
    }

    /**
     * The obstacles the Deygout method finds along a terrain profile, at any frequency.
     * <p>
     * An obstacle's diffraction parameter is proportional to {@code 1/√λ}, so the obstacle with the largest one is the
     * same at every frequency, as are those either side of it. Only whether each counts (whether its parameter is
     * above {@link #KNIFE_EDGE_THRESHOLD}) and how much it costs depend on the frequency. So the obstacles can be found
     * once, and the loss worked out for each frequency with {@link DiffractionEdge#loss(double)}.
     *
     * @param distance   The distance of each profile point from the transmitter, in metres. Must be increasing.
     * @param height     The height of each profile point, in metres. This should already include any earth bulge.
     * @param from       The index of the first terminal in the profile.
     * @param to         The index of the second terminal in the profile.
     * @param fromHeight The height of the first terminal (antenna, or obstacle tip), in metres.
     * @param toHeight   The height of the second terminal, in metres.
     * @param depth      The maximum recursion depth. A depth of 1 gives the classic three-edge Deygout construction.
     * @return The main obstacle, with those either side of it, or {@code null} if there's none.
     */
    public static @Nullable DiffractionEdge deygoutEdges(double[] distance, double[] height, int from, int to, double fromHeight, double toHeight, int depth) {
        if (to - from < 2) return null;

        var x0 = distance[from];
        var length = distance[to] - x0;
        if (length <= 0) return null;

        var best = Double.NEGATIVE_INFINITY;
        var bestIndex = -1;
        for (var i = from + 1; i < to; i++) {
            var d1 = distance[i] - x0;
            var d2 = distance[to] - distance[i];
            if (d1 <= 0 || d2 <= 0) continue;

            var lineOfSight = fromHeight + (toHeight - fromHeight) * (d1 / length);
            var steepness = fresnelParameter(height[i] - lineOfSight, d1, d2, 1);
            if (steepness > best) {
                best = steepness;
                bestIndex = i;
            }
        }

        if (bestIndex < 0) return null;
        if (depth <= 0) return new DiffractionEdge(best, null, null);

        var tip = height[bestIndex];
        return new DiffractionEdge(
            best,
            deygoutEdges(distance, height, from, bestIndex, fromHeight, tip, depth - 1),
            deygoutEdges(distance, height, bestIndex, to, tip, toHeight, depth - 1)
        );
    }

    /**
     * An obstacle found by the Deygout method, with the obstacles found either side of it.
     *
     * @param steepness The obstacle's diffraction parameter for a wavelength of one metre. At other wavelengths, the
     *                  parameter is this divided by {@code √λ}.
     * @param left      The main obstacle between the first terminal and this one, if any.
     * @param right     The main obstacle between this one and the second terminal, if any.
     */
    public record DiffractionEdge(double steepness, @Nullable DiffractionEdge left, @Nullable DiffractionEdge right) {
        /**
         * The diffraction loss of this obstacle and those either side of it.
         *
         * @param wavelength The wavelength, in metres.
         * @return The diffraction loss in dB.
         */
        public double loss(double wavelength) {
            var v = steepness / Math.sqrt(wavelength);
            if (v <= KNIFE_EDGE_THRESHOLD) return 0;

            var loss = knifeEdgeLoss(v);
            if (left != null) loss += left.loss(wavelength);
            if (right != null) loss += right.loss(wavelength);
            return loss;
        }
    }

    /**
     * Specific attenuation of a plane wave in a homogeneous, non-magnetic lossy medium.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @param permittivity The real part of the relative permittivity (ε').
     * @param lossFactor   The imaginary part of the relative permittivity (ε''), including conductivity.
     * @return The attenuation in dB per metre.
     */
    public static double dielectricAttenuation(double frequencyMHz, double permittivity, double lossFactor) {
        // The propagation constant is jω√(με), so attenuation is (ω/c)·|Im √(ε' - jε'')|.
        var magnitude = Math.hypot(permittivity, lossFactor);
        var imaginary = Math.sqrt(Math.max(0, (magnitude - permittivity) / 2));
        var nepersPerMetre = 2 * Math.PI * frequencyMHz * 1e6 / SPEED_OF_LIGHT * imaginary;
        return nepersPerMetre * 8.685889638;
    }

    /**
     * Convert a conductivity to the equivalent imaginary relative permittivity (ITU-R P.2040, equation 9b).
     *
     * @param conductivity The conductivity, in S/m.
     * @param frequencyMHz The frequency, in MHz.
     * @return The imaginary part of the relative permittivity.
     */
    public static double conductivityToLossFactor(double conductivity, double frequencyMHz) {
        return 17.98 * conductivity / (frequencyMHz / 1000.0);
    }
}
