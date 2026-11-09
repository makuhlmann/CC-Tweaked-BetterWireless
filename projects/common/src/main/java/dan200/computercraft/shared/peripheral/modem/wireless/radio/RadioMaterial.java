// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

/**
 * Electrical properties of the materials blocks are made of.
 * <p>
 * Most materials use the frequency-dependent model and parameters from ITU-R P.2040 (table 3): {@code ε' = a·f^b} and
 * {@code σ = c·f^d}, with {@code f} in GHz. Those parameters are specified for roughly 1–100 GHz; we extrapolate them
 * down to VHF, which gives plausible (if not authoritative) values. Water uses a single Debye relaxation model, and
 * vegetation uses an empirical specific attenuation in the spirit of ITU-R P.833.
 */
public enum RadioMaterial {
    AIR(1, 0, 0, 0, 0),

    /** Natural rock and anything stone-like. ITU-R P.2040 "concrete". */
    ROCK(5.24, 0, 0.0462, 0.7822, 1e-4),
    /**
     * Brick. ITU-R P.2040 gives a conductivity exponent of 0.16, which extrapolates very poorly below 1GHz (brick ends up
     * lossier than rock at VHF). We use concrete's exponent instead.
     */
    BRICK(3.91, 0, 0.0238, 0.7822, 1e-4),
    WOOD(1.99, 0, 0.0047, 1.0718, 1e-4),
    GLASS(6.31, 0, 0.0036, 1.3394, 1e-4),
    /** Wool, carpets, beds. ITU-R P.2040 "ceiling board". */
    FABRIC(1.48, 0, 0.0011, 1.075, 1e-4),
    /** Effectively opaque. Signals still reach around metal through diffraction. */
    METAL(1, 0, 1e7, 0, 0),
    /** Sand and other very dry granular materials. */
    DRY_GROUND(3, 0, 0.00015, 2.52, 2e-4),
    /** Dirt, gravel, clay. */
    GROUND(15, -0.1, 0.035, 1.63, 1e-3),
    /** Mud and other waterlogged soil. */
    WET_GROUND(30, -0.4, 0.15, 1.3, 1e-2),
    /** Ice and dry snow: low permittivity and nearly lossless. */
    ICE(3.15, 0, 0.0001, 1.0, 1e-5),
    SNOW(1.5, 0, 0.0001, 1.0, 1e-5),
    WATER(0, 0, 0, 0, 0),
    VEGETATION(0, 0, 0, 0, 0);

    /** Attenuation is capped, so that metal doesn't produce infinities. */
    private static final double MAX_ATTENUATION = 1000;

    /** Static permittivity, high-frequency permittivity, relaxation frequency (GHz) and conductivity of fresh water. */
    private static final double WATER_STATIC = 80.1, WATER_INFINITE = 4.9, WATER_RELAXATION = 17.0, WATER_CONDUCTIVITY = 0.05;

    private final double a, b, c, d;
    private final double minConductivity;

    /**
     * Create a new material.
     *
     * @param a               Permittivity coefficient.
     * @param b               Permittivity frequency exponent.
     * @param c               Conductivity coefficient, in S/m.
     * @param d               Conductivity frequency exponent.
     * @param minConductivity A lower bound on the conductivity, in S/m. Some of the steeper exponents produce
     *                        unrealistically small conductivities once extrapolated to VHF.
     */
    RadioMaterial(double a, double b, double c, double d, double minConductivity) {
        this.a = a;
        this.b = b;
        this.c = c;
        this.d = d;
        this.minConductivity = minConductivity;
    }

    /**
     * The specific attenuation of this material.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @return The attenuation, in dB per metre.
     */
    public double attenuation(double frequencyMHz) {
        var ghz = frequencyMHz / 1000.0;
        var attenuation = switch (this) {
            case AIR -> 0;
            case VEGETATION -> 0.25 * Math.pow(ghz, 0.6);
            case WATER -> {
                var ratio = ghz / WATER_RELAXATION;
                var denominator = 1 + ratio * ratio;
                var permittivity = WATER_INFINITE + (WATER_STATIC - WATER_INFINITE) / denominator;
                var lossFactor = (WATER_STATIC - WATER_INFINITE) * ratio / denominator
                    + RadioMath.conductivityToLossFactor(WATER_CONDUCTIVITY, frequencyMHz);
                yield RadioMath.dielectricAttenuation(frequencyMHz, permittivity, lossFactor);
            }
            default -> {
                var permittivity = a * Math.pow(ghz, b);
                var conductivity = Math.max(minConductivity, c * Math.pow(ghz, d));
                yield RadioMath.dielectricAttenuation(frequencyMHz, permittivity, RadioMath.conductivityToLossFactor(conductivity, frequencyMHz));
            }
        };
        return Math.min(attenuation, MAX_ATTENUATION);
    }
}
