// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Electrical properties of the materials blocks are made of.
 * <p>
 * Most materials use the frequency-dependent model and parameters from ITU-R P.2040 (table 3): {@code ε' = a·f^b} and
 * {@code σ = c·f^d}, with {@code f} in GHz. Those parameters are specified for roughly 1–100 GHz; we extrapolate them
 * down to VHF, which gives plausible (if not authoritative) values. Water uses a single Debye relaxation model, and
 * vegetation uses an empirical specific attenuation in the spirit of ITU-R P.833.
 * <p>
 * A material's attenuation depends only on the frequency, so each frequency's is worked out once, for every material
 * ({@link #attenuationTable(double)}).
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

    /** The lowest frequency the model works at, in MHz. Lower frequencies are treated as this one. */
    public static final double MIN_FREQUENCY = 30;

    /** The highest frequency the model works at, in MHz. Higher frequencies are treated as this one. */
    public static final double MAX_FREQUENCY = 10_000;

    /** How many materials there are, for arrays indexed by {@link #ordinal()}. */
    public static final int COUNT = values().length;

    /** Attenuation is capped, so that metal doesn't produce infinities. */
    private static final double MAX_ATTENUATION = 1000;

    /** How many frequencies' tables to keep. Frequencies come from channels, so there are only so many. */
    private static final int MAX_TABLES = 1 << 16;

    private static final Map<Double, double[]> TABLES = new ConcurrentHashMap<>();

    /**
     * Each material's least attenuation at any frequency the model works at, in dB per metre. A link which loses more
     * than its budget at these attenuations is lost at every frequency.
     */
    private static final double[] LEAST = leastAttenuation();

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

    /**
     * Whether a signal reflects off a wall of this material. Air doesn't, and nor do leaves or water, which make no
     * walls.
     *
     * @return Whether it does.
     */
    public boolean reflects() {
        return this != AIR && this != VEGETATION && this != WATER;
    }

    /**
     * How much a signal loses reflecting off a smooth wall of this material: Fresnel's coefficient for an electric field
     * along the wall (a vertical antenna and a vertical wall), from the material's permittivity (ITU-R P.2040). Concrete
     * loses about 8dB head-on, and almost nothing at a grazing angle; metal nothing at all.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @param cosIncidence The cosine of the angle between the path and the wall's normal: 1 head-on, 0 grazing.
     * @return The loss, in dB, or infinity if the material doesn't reflect.
     */
    public double reflectionLoss(double frequencyMHz, double cosIncidence) {
        if (this == METAL) return 0;
        if (!reflects()) return Double.POSITIVE_INFINITY;
        var frequency = Math.clamp(frequencyMHz, MIN_FREQUENCY, MAX_FREQUENCY);
        var ghz = frequency / 1000.0;
        var permittivity = a * Math.pow(ghz, b);
        var lossFactor = RadioMath.conductivityToLossFactor(Math.max(minConductivity, c * Math.pow(ghz, d)), frequency);
        var cos = Math.clamp(cosIncidence, 0, 1);

        // √(ε' − jε'' − sin²θ), the root with a negative imaginary part, and then (cosθ − √…) / (cosθ + √…).
        var real = permittivity - (1 - cos * cos);
        var modulus = Math.hypot(real, lossFactor);
        var rootReal = Math.sqrt((modulus + real) / 2);
        var rootImaginary = Math.sqrt(Math.max(0, (modulus - real) / 2));
        var gamma = Math.hypot(cos - rootReal, rootImaginary) / Math.hypot(cos + rootReal, rootImaginary);
        return -20 * Math.log10(Math.max(gamma, 1e-9));
    }

    /**
     * Every material's attenuation at a frequency, indexed by {@link #ordinal()}. Each frequency's is computed once.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @return The attenuations, in dB per metre. This must not be modified.
     */
    public static double[] attenuationTable(double frequencyMHz) {
        var table = TABLES.get(frequencyMHz);
        if (table != null) return table;

        table = new double[COUNT];
        for (var material : values()) table[material.ordinal()] = material.attenuation(frequencyMHz);
        if (TABLES.size() >= MAX_TABLES) TABLES.clear();
        TABLES.put(frequencyMHz, table);
        return table;
    }

    /**
     * Each material's least attenuation at any frequency between {@link #MIN_FREQUENCY} and {@link #MAX_FREQUENCY}.
     *
     * @return The attenuations, in dB per metre, indexed by {@link #ordinal()}. This must not be modified.
     */
    public static double[] leastAttenuationTable() {
        return LEAST;
    }

    private static double[] leastAttenuation() {
        // Not every material's attenuation rises with frequency (water's is a relaxation model, and ground's
        // permittivity falls), so sample the whole range rather than take the lowest frequency's. Sampling may miss a
        // dip between two samples, so leave some room.
        var samples = 512;
        var least = new double[COUNT];
        Arrays.fill(least, Double.POSITIVE_INFINITY);
        for (var i = 0; i <= samples; i++) {
            var frequency = MIN_FREQUENCY * Math.pow(MAX_FREQUENCY / MIN_FREQUENCY, (double) i / samples);
            for (var material : values()) {
                least[material.ordinal()] = Math.min(least[material.ordinal()], material.attenuation(frequency));
            }
        }
        for (var i = 0; i < COUNT; i++) least[i] *= 0.9;
        return least;
    }
}
