// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

import java.util.List;

/**
 * What lies along a link between two antennas, whatever the frequency: how far apart and how high they are, how much
 * of each material the signal passes through, the obstacles it diffracts over, and the walls near either end it may
 * reflect off.
 * <p>
 * Finding these means walking the blocks along the link and sampling the terrain, which is the expensive part of
 * evaluating it. Turning them into a loss at a particular frequency ({@link #evaluate(double)}) is cheap, so a link is
 * traced once ({@link PropagationModel#trace}) and then evaluated for each frequency it's used at: the two directions
 * of a link whose uplink and downlink use different frequencies, say.
 * <p>
 * The walks along the link stop once the signal is lost at every frequency for the budget it was traced for
 * ({@link #budget()}). So the path's losses are exact for any link within that budget, and only lower bounds (which
 * are still more than the budget) for those beyond it. A link within the budget at some frequency is exact at that
 * frequency for any budget, so the path serves stronger transmitters too ({@link #serves(double, double)}).
 */
public final class LinkPath {
    private final double distance;
    private final boolean groundReflection;
    private final double height1;
    private final double height2;
    private final double budget;
    private final boolean walked;
    private final double[] through;
    private final double @Nullable [] txEscape;
    private final double @Nullable [] rxEscape;
    private final RadioMath.@Nullable DiffractionEdge diffraction;
    private final List<Reflection> reflections;

    /**
     * Create a path.
     *
     * @param distance         The distance between the antennas, in metres.
     * @param groundReflection Whether to use the two-ray ground reflection model.
     * @param height1          The height of the first antenna above the average terrain, in metres.
     * @param height2          The height of the second antenna above the average terrain, in metres.
     * @param budget           The largest link budget the path was traced for, in dB.
     * @param walked           Whether the blocks along the path were walked. They aren't when distance alone loses more
     *                         than the budget.
     * @param through          How many metres of each material the straight path passes through, scaled by how full
     *                         each block is and by the material loss multiplier, indexed by
     *                         {@link RadioMaterial#ordinal()}.
     * @param txEscape         The same, for the signal leaving any enclosure around the first antenna, or
     *                         {@code null} if it doesn't.
     * @param rxEscape         The same for the second antenna.
     * @param diffraction      The obstacles the signal diffracts over once it has left both enclosures, if any.
     * @param reflections      The paths reflected off walls near either end.
     */
    LinkPath(
        double distance, boolean groundReflection, double height1, double height2, double budget, boolean walked,
        double[] through, double @Nullable [] txEscape, double @Nullable [] rxEscape, RadioMath.@Nullable DiffractionEdge diffraction,
        List<Reflection> reflections
    ) {
        this.distance = distance;
        this.groundReflection = groundReflection;
        this.height1 = height1;
        this.height2 = height2;
        this.budget = budget;
        this.walked = walked;
        this.through = through;
        this.txEscape = txEscape;
        this.rxEscape = rxEscape;
        this.diffraction = diffraction;
        this.reflections = reflections;
    }

    /**
     * The link budget this path was traced for.
     *
     * @return The budget, in dB.
     */
    public double budget() {
        return budget;
    }

    /**
     * Whether this path's loss at a frequency is right for a link with some budget. It is if the budget is no more
     * than the path was traced for, or if the link is within the budget it was traced for at that frequency, as then
     * walking further would change nothing.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @param budget       The link's budget, in dB.
     * @return Whether the path serves the link.
     */
    public boolean serves(double frequencyMHz, double budget) {
        return budget <= this.budget || evaluate(frequencyMHz).loss() <= this.budget;
    }

    /**
     * Whether the blocks along the link were walked. They aren't when distance alone loses more than the budget at
     * every frequency.
     *
     * @return Whether they were walked.
     */
    boolean walked() {
        return walked;
    }

    /**
     * Evaluate the link at a frequency.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @return The evaluated link. If its loss is more than {@link #budget()}, the individual components are lower bounds.
     */
    public LinkResult evaluate(double frequencyMHz) {
        var base = baseLoss(distance, groundReflection, height1, height2, frequencyMHz);
        if (!walked) return new LinkResult(base, base, 0, 0, 0, Double.POSITIVE_INFINITY);

        var attenuation = RadioMaterial.attenuationTable(frequencyMHz);
        var through = loss(attenuation, this.through);
        var over = Double.POSITIVE_INFINITY;
        var diffraction = 0.0;
        if (txEscape != null && rxEscape != null) {
            diffraction = this.diffraction == null ? 0 : this.diffraction.loss(RadioMath.wavelength(frequencyMHz));
            over = loss(attenuation, txEscape) + loss(attenuation, rxEscape) + diffraction;
        }

        var direct = base + Math.min(through, over);
        if (reflections.isEmpty()) return new LinkResult(direct, base, through, over, diffraction, Double.POSITIVE_INFINITY);

        // Each reflected path brings some of the signal by another way, which adds to what comes directly.
        var reflectedPower = 0.0;
        for (var reflection : reflections) {
            var extra = reflection.loss(frequencyMHz, attenuation);
            if (extra == Double.POSITIVE_INFINITY) continue;
            var loss = baseLoss(reflection.length(), groundReflection, height1, height2, frequencyMHz) + extra;
            reflectedPower += Math.pow(10, -loss / 10);
        }
        if (reflectedPower <= 0) return new LinkResult(direct, base, through, over, diffraction, Double.POSITIVE_INFINITY);
        var reflected = -10 * Math.log10(reflectedPower);
        var total = -10 * Math.log10(Math.pow(10, -direct / 10) + reflectedPower);
        return new LinkResult(total, base, through, over, diffraction, reflected);
    }

    /**
     * The paths reflected off walls near either end.
     *
     * @return The reflections.
     */
    List<Reflection> reflections() {
        return reflections;
    }

    /**
     * The loss from distance alone.
     *
     * @param distance         The distance between the antennas, in metres.
     * @param groundReflection Whether to use the two-ray ground reflection model.
     * @param height1          The height of the first antenna above the average terrain, in metres.
     * @param height2          The height of the second antenna above the average terrain, in metres.
     * @param frequencyMHz     The frequency, in MHz.
     * @return The loss, in dB. This never decreases as the frequency rises.
     */
    static double baseLoss(double distance, boolean groundReflection, double height1, double height2, double frequencyMHz) {
        return groundReflection
            ? RadioMath.groundReflectionLoss(distance, frequencyMHz, height1, height2)
            : RadioMath.freeSpaceLoss(distance, frequencyMHz);
    }

    /**
     * The loss through some materials.
     *
     * @param attenuation Each material's attenuation, in dB per metre.
     * @param metres      How many metres of each material there are.
     * @return The loss, in dB.
     */
    static double loss(double[] attenuation, double[] metres) {
        var loss = 0.0;
        for (var i = 0; i < metres.length; i++) {
            if (metres[i] != 0) loss += attenuation[i] * metres[i];
        }
        return loss;
    }
}
