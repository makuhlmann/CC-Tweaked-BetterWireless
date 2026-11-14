// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

import java.util.Arrays;

/**
 * Estimates the path loss of a single radio link.
 * <p>
 * The model has three parts:
 * <ol>
 *     <li>
 *         <strong>Base loss</strong> from distance alone: free space loss, or (by default) the two-ray ground
 *         reflection model, which makes loss grow much faster for antennas close to the ground.
 *     </li>
 *     <li>
 *         <strong>Through</strong>: the loss of the signal travelling in a straight line through whatever is in the
 *         way. We walk every block along the ray and use its material's attenuation. In chunks which aren't loaded we
 *         only have heightmaps, so we classify the ray as being underground, in vegetation, or in the open air.
 *     </li>
 *     <li>
 *         <strong>Over</strong>: the loss of the signal leaving any enclosure around each antenna (walls, a cave),
 *         and then diffracting over the terrain and buildings between them (Deygout's method, ITU-R P.526).
 *     </li>
 * </ol>
 * The signal takes whichever of the through and over paths is better.
 * <p>
 * None of the walking or sampling depends on the frequency: only how much each material, obstacle and metre costs
 * does. So a link is {@linkplain #trace traced} once, into a {@link LinkPath} which records how much of each material
 * the signal passes through and which obstacles it diffracts over, and that is {@linkplain LinkPath#evaluate
 * evaluated} at each frequency it's used at.
 * <p>
 * Worlds with a ceiling (the Nether) are a special case. Their heightmaps are those of the ceiling, so say nothing of
 * the space beneath it. Where chunks aren't loaded, that space is taken to be mostly open, with a small fixed loss:
 * rock, at a small fraction of its attenuation. There's no path over the terrain from beneath a ceiling, as there's
 * nothing to go over, while above it is open ground like any other.
 * <p>
 * Tracing a link costs one walk along the ray (which stops as soon as the signal is lost at every frequency), a short
 * walk at each end to find where the signal leaves any enclosure, and one profile of a bounded size. The model never
 * loads chunks: anything not exposed by the {@link TerrainView} is guessed.
 */
public final class PropagationModel {
    /**
     * How much of the ray near each antenna we ignore, in blocks. This stops the block the modem is attached to from
     * attenuating its own signal.
     */
    private static final double MOUNT_CLEARANCE = 1.0;

    /**
     * How far from each antenna we ignore terrain when computing diffraction, in blocks.
     */
    private static final double PROFILE_CLEARANCE = 1.5;

    /**
     * The material we assume the ground to be made of, when we only have heightmaps.
     */
    private static final RadioMaterial TERRAIN = RadioMaterial.ROCK;

    /**
     * How thick we take a world's ceiling to be, in blocks, when we only have heightmaps: the Nether's is bedrock mixed
     * with netherrack, five blocks deep.
     */
    private static final int CEILING_THICKNESS = 5;

    private PropagationModel() {
    }

    @FunctionalInterface
    public interface ColumnConsumer {
        void accept(int index, int x, int z);
    }

    /**
     * Get the number of segments a terrain profile is split into.
     *
     * @param horizontalBlocks The horizontal length of the link, in blocks.
     * @param maxSamples       The maximum number of samples.
     * @return The number of segments. There is one more sample than segments.
     */
    public static int segmentCount(double horizontalBlocks, int maxSamples) {
        return Math.max(1, Math.min(maxSamples, (int) Math.ceil(horizontalBlocks)));
    }

    /**
     * Visit every column sampled by the terrain profile between two points. This is used to find which chunks need to
     * be available before evaluating a link.
     *
     * @param tx         The transmitter's X position.
     * @param tz         The transmitter's Z position.
     * @param rx         The receiver's X position.
     * @param rz         The receiver's Z position.
     * @param maxSamples The maximum number of samples.
     * @param consumer   The function to call with each column.
     */
    public static void forEachSample(double tx, double tz, double rx, double rz, int maxSamples, ColumnConsumer consumer) {
        var segments = segmentCount(Math.hypot(rx - tx, rz - tz), maxSamples);
        for (var i = 0; i <= segments; i++) {
            var t = (double) i / segments;
            consumer.accept(i, (int) Math.floor(tx + (rx - tx) * t), (int) Math.floor(tz + (rz - tz) * t));
        }
    }

    /**
     * Evaluate a link between two antennas at one frequency.
     *
     * @param tx           The transmitting antenna's X position.
     * @param ty           The transmitting antenna's Y position.
     * @param tz           The transmitting antenna's Z position.
     * @param rx           The receiving antenna's X position.
     * @param ry           The receiving antenna's Y position.
     * @param rz           The receiving antenna's Z position.
     * @param frequencyMHz The frequency, in MHz.
     * @param linkBudget   The link budget, in dB. We stop evaluating once the loss exceeds this.
     * @param env          The model parameters.
     * @param terrain      The terrain to propagate through.
     * @return The evaluated link. If the loss exceeds the link budget, the individual components are lower bounds.
     * @see #trace
     */
    public static LinkResult evaluate(
        double tx, double ty, double tz, double rx, double ry, double rz,
        double frequencyMHz, double linkBudget, RadioEnvironment env, TerrainView terrain
    ) {
        return trace(tx, ty, tz, rx, ry, rz, linkBudget, env, terrain).evaluate(frequencyMHz);
    }

    /**
     * Trace a link between two antennas, to evaluate it at any frequency.
     *
     * @param tx         The transmitting antenna's X position.
     * @param ty         The transmitting antenna's Y position.
     * @param tz         The transmitting antenna's Z position.
     * @param rx         The receiving antenna's X position.
     * @param ry         The receiving antenna's Y position.
     * @param rz         The receiving antenna's Z position.
     * @param linkBudget The largest link budget the path is needed for, in dB. We stop tracing once the loss exceeds
     *                   this at every frequency.
     * @param env        The model parameters.
     * @param terrain    The terrain to propagate through.
     * @return The traced link.
     */
    public static LinkPath trace(
        double tx, double ty, double tz, double rx, double ry, double rz,
        double linkBudget, RadioEnvironment env, TerrainView terrain
    ) {
        var horizontalBlocks = Math.hypot(rx - tx, rz - tz);
        var dy = ry - ty;
        var rayBlocks = Math.sqrt(horizontalBlocks * horizontalBlocks + dy * dy);

        var horizontal = horizontalBlocks * env.metresPerBlock();
        var distance = Math.hypot(horizontal, dy * env.metresPerBlockVertical());
        if (rayBlocks < 1e-6) return new LinkPath(1, false, 0, 0, linkBudget, false, new double[RadioMaterial.COUNT], null, null, null);

        // Sample the terrain profile.
        var segments = segmentCount(horizontalBlocks, env.maxProfileSamples());
        var ground = new double[segments + 1];
        var surface = new double[segments + 1];
        forEachSample(tx, tz, rx, rz, env.maxProfileSamples(), (i, x, z) -> {
            var groundY = terrain.groundHeight(x, z);
            var surfaceY = terrain.surfaceHeight(x, z);
            ground[i] = groundY == TerrainView.UNKNOWN ? Double.NaN : groundY;
            surface[i] = surfaceY == TerrainView.UNKNOWN ? Double.NaN : surfaceY;
        });
        var fallback = Math.floor(Math.min(ty, ry));
        fillUnknown(ground, fallback);
        fillUnknown(surface, fallback);
        for (var i = 0; i < surface.length; i++) surface[i] = Math.max(surface[i], ground[i]);

        // Loss from distance alone. This is least at the lowest frequency.
        var groundReflection = env.groundReflection();
        double height1 = 0, height2 = 0;
        if (groundReflection) {
            var meanGround = 0.0;
            for (var height : ground) meanGround += height;
            meanGround /= ground.length;

            height1 = Math.max(env.minAntennaHeight(), (ty - meanGround) * env.metresPerBlockVertical());
            height2 = Math.max(env.minAntennaHeight(), (ry - meanGround) * env.metresPerBlockVertical());
        }
        var base = LinkPath.baseLoss(distance, groundReflection, height1, height2, RadioMaterial.MIN_FREQUENCY);

        var headroom = linkBudget - base;
        if (headroom <= 0) {
            return new LinkPath(distance, groundReflection, height1, height2, linkBudget, false, new double[RadioMaterial.COUNT], null, null, null);
        }

        // Walk the blocks near each end of the link. Until the end, losses are measured at each material's least
        // attenuation, so the walks only stop once the signal is lost at every frequency.
        var lossScale = env.materialLossScale() * (distance / rayBlocks);
        var walkLength = Math.min(env.voxelRadius(), rayBlocks);
        var txThrough = walkLength;
        var rxThrough = Math.min(env.voxelRadius(), rayBlocks - txThrough);

        var cavern = Cavern.of(terrain, env);
        var fromTx = new Walk(terrain, cavern, lossScale, headroom, txThrough, rayBlocks - MOUNT_CLEARANCE);
        fromTx.start(tx, ty, tz);
        VoxelRay.traverse(tx, ty, tz, rx, ry, rz, walkLength, fromTx);
        var fromRx = new Walk(terrain, cavern, lossScale, headroom, rxThrough, rayBlocks - MOUNT_CLEARANCE);
        fromRx.start(rx, ry, rz);
        VoxelRay.traverse(rx, ry, rz, tx, ty, tz, walkLength, fromRx);

        // Straight through: the walked bits near each end, plus whatever is in the middle.
        var through = new double[RadioMaterial.COUNT];
        add(through, fromTx.through);
        add(through, fromRx.through);
        var least = RadioMaterial.leastAttenuationTable();
        var throughLoss = LinkPath.loss(least, through);
        var middleLength = rayBlocks - txThrough - rxThrough;
        if (middleLength > 0 && throughLoss <= headroom) {
            var start = txThrough / rayBlocks;
            var end = 1 - rxThrough / rayBlocks;
            var middle = new MiddleWalk(terrain, cavern, lossScale, headroom - throughLoss, ground, surface, start, 1 / rayBlocks);
            VoxelRay.traverse(
                tx + (rx - tx) * start, ty + dy * start, tz + (rz - tz) * start,
                tx + (rx - tx) * end, ty + dy * end, tz + (rz - tz) * end,
                middleLength, middle
            );
            add(through, middle.metres);
        }

        // Over the top: escape any enclosure around each antenna, then find what the signal diffracts over.
        var txEscape = escape(fromTx, terrain, cavern, tx, ty, tz, headroom, env);
        var rxEscape = escape(fromRx, terrain, cavern, rx, ry, rz, headroom, env);
        RadioMath.DiffractionEdge diffraction = null;
        if (txEscape != null && rxEscape != null) {
            var distances = new double[segments + 1];
            var heights = new double[segments + 1];
            var effectiveRadius = env.effectiveEarthRadius();
            var txClear = Math.max(txEscape.exit / rayBlocks * horizontalBlocks, PROFILE_CLEARANCE) * env.metresPerBlock();
            var rxClear = Math.max(rxEscape.exit / rayBlocks * horizontalBlocks, PROFILE_CLEARANCE) * env.metresPerBlock();

            for (var i = 0; i <= segments; i++) {
                var d1 = horizontal * i / segments;
                var d2 = horizontal - d1;
                distances[i] = d1;
                heights[i] = d1 <= txClear || d2 <= rxClear
                    ? Double.NEGATIVE_INFINITY
                    : surface[i] * env.metresPerBlockVertical() + RadioMath.earthBulge(d1, d2, effectiveRadius);
            }

            diffraction = RadioMath.deygoutEdges(
                distances, heights, 0, segments,
                txEscape.height * env.metresPerBlockVertical(), rxEscape.height * env.metresPerBlockVertical(), 1
            );
        }

        // Note that when the direct ray is clear, the through path wins outright, even if the terrain intrudes into the
        // first Fresnel zone. This is deliberate: the two-ray model already accounts for the ground close to the path,
        // and charging for both would penalise perfectly flat terrain.

        return new LinkPath(
            distance, groundReflection, height1, height2, linkBudget, true, through,
            txEscape == null ? null : txEscape.metres, rxEscape == null ? null : rxEscape.metres, diffraction
        );
    }

    private static void add(double[] total, double[] metres) {
        for (var i = 0; i < total.length; i++) total[i] += metres[i];
    }

    /**
     * How a signal escapes the enclosure around an antenna.
     */
    private static final class Escape {
        /** How many metres of each material it passes through on the way out. */
        final double[] metres;
        /** How far along the ray (in blocks) the signal reaches open air. Zero if it escapes vertically. */
        final double exit;
        /** The height the signal diffracts from. Usually the antenna, but the surface for buried antennas. */
        final double height;

        Escape(double[] metres, double exit, double height) {
            this.metres = metres;
            this.exit = exit;
            this.height = height;
        }
    }

    private static @Nullable Escape escape(
        Walk walk, TerrainView terrain, @Nullable Cavern cavern, double x, double y, double z, double cap, RadioEnvironment env
    ) {
        if (walk.escape != null) return new Escape(walk.escape, walk.exit, y);

        // Beneath a world's ceiling, there's nothing above to go over.
        if (cavern != null && y < cavern.ceiling) return null;

        // The ray towards the other antenna stays enclosed, so try going straight up instead. This handles antennas in
        // basements and bunkers: they reach the surface through the ceiling, then propagate from there.
        var up = new Walk(terrain, cavern, env.materialLossScale() * env.metresPerBlockVertical(), cap, 0, Double.MAX_VALUE);
        VoxelRay.traverse(x, y, z, x, y + env.voxelRadius(), z, env.voxelRadius(), up);
        return up.escape == null ? null : new Escape(up.escape, 0, y + up.exit);
    }

    /**
     * The space beneath a world's ceiling, where we only have heightmaps.
     *
     * @param ceiling The ceiling's height: the first Y position above it.
     * @param fill    How much of the space beneath it is rock, between 0 and 1.
     */
    private record Cavern(int ceiling, double fill) {
        static @Nullable Cavern of(TerrainView terrain, RadioEnvironment env) {
            var ceiling = terrain.ceilingHeight();
            if (ceiling == TerrainView.UNKNOWN) return null;
            return new Cavern(ceiling, env.ceilingUnknownFill());
        }

        /**
         * Guess how much rock a block we know nothing else about holds.
         *
         * @param y      The block's Y position.
         * @param ground The ground height of its column (which is the top of the ceiling, or of whatever was built on
         *               it), or {@link TerrainView#UNKNOWN}.
         * @return How much of it is rock, between 0 and 1, or {@link Double#NaN} if the block is above the ceiling,
         * and so should be treated as in any other world.
         */
        double guess(int y, int ground) {
            if (y >= ceiling) return Double.NaN;
            // Where something is built on the ceiling, the ceiling is still where it always is.
            var top = ground == TerrainView.UNKNOWN ? ceiling : Math.min(ground, ceiling);
            return y >= top - CEILING_THICKNESS ? 1 : fill;
        }
    }

    /**
     * Replace unknown ({@link Double#NaN}) samples by interpolating between their known neighbours.
     *
     * @param values   The values to fill in.
     * @param fallback The value to use if nothing is known.
     */
    static void fillUnknown(double[] values, double fallback) {
        var previous = -1;
        for (var i = 0; i < values.length; i++) {
            if (Double.isNaN(values[i])) continue;

            if (previous + 1 < i) {
                var from = previous < 0 ? values[i] : values[previous];
                for (var j = previous + 1; j < i; j++) {
                    values[j] = previous < 0 ? from : from + (values[i] - from) * (j - previous) / (i - previous);
                }
            }
            previous = i;
        }

        if (previous < 0) {
            Arrays.fill(values, fallback);
        } else {
            for (var j = previous + 1; j < values.length; j++) values[j] = values[previous];
        }
    }

    /**
     * Walks the blocks in the middle of a link, between the sections walked from each antenna.
     * <p>
     * Where the chunk is loaded, this uses the real blocks, so tunnels, buildings and caves work however long the link
     * is. Elsewhere we only have heightmaps, so we guess: anything below the ground is rock, and anything between the
     * ground and the surface is vegetation. Where we don't even have heightmaps, we use the (interpolated) profile.
     */
    private static final class MiddleWalk implements VoxelRay.Visitor {
        private final TerrainView terrain;
        private final @Nullable Cavern cavern;
        private final double lossScale;
        private final double cap;
        private final double[] ground;
        private final double[] surface;
        private final double start;
        private final double scale;
        private final double[] least = RadioMaterial.leastAttenuationTable();

        /** How many metres of each material the walk has passed through. */
        final double[] metres = new double[RadioMaterial.COUNT];
        /** The loss so far, at each material's least attenuation. */
        double loss;

        /**
         * Create a new walk.
         *
         * @param terrain   The terrain to walk through.
         * @param cavern    The space beneath the world's ceiling, if it has one.
         * @param lossScale A multiplier for material attenuation.
         * @param cap       The loss at which to give up, at each material's least attenuation.
         * @param ground    The ground heights along the profile.
         * @param surface   The surface heights along the profile.
         * @param start     How far along the whole link the walk starts, between 0 and 1.
         * @param scale     The fraction of the whole link covered by one block.
         */
        MiddleWalk(
            TerrainView terrain, @Nullable Cavern cavern, double lossScale, double cap,
            double[] ground, double[] surface, double start, double scale
        ) {
            this.terrain = terrain;
            this.cavern = cavern;
            this.lossScale = lossScale;
            this.cap = cap;
            this.ground = ground;
            this.surface = surface;
            this.start = start;
            this.scale = scale;
        }

        @Override
        public boolean visit(int x, int y, int z, double enter, double exit) {
            var info = terrain.block(x, y, z);
            RadioMaterial material;
            double fill;
            if (info != null) {
                if (info.fill() == 0) return true;
                material = info.material();
                fill = info.fill();
            } else {
                fill = cavern == null ? Double.NaN : cavern.guess(y, terrain.groundHeight(x, z));
                if (Double.isNaN(fill)) {
                    material = guessMaterial(x, y, z, (enter + exit) / 2);
                    fill = 1;
                } else {
                    material = TERRAIN;
                }
            }

            var length = fill * lossScale * (exit - enter);
            metres[material.ordinal()] += length;
            loss += least[material.ordinal()] * length;
            return loss <= cap;
        }

        private RadioMaterial guessMaterial(int x, int y, int z, double distance) {
            var groundY = terrain.groundHeight(x, z);
            var surfaceY = terrain.surfaceHeight(x, z);
            if (groundY != TerrainView.UNKNOWN && surfaceY != TerrainView.UNKNOWN) return classify(y, groundY, surfaceY);

            var sample = Math.clamp(Math.round((start + distance * scale) * (ground.length - 1)), 0, ground.length - 1);
            return classify(y, ground[sample], surface[sample]);
        }

        private static RadioMaterial classify(int y, double ground, double surface) {
            return y < ground ? TERRAIN : y < surface ? RadioMaterial.VEGETATION : RadioMaterial.AIR;
        }
    }

    /**
     * Walks the blocks along a ray from one antenna. This tracks two things:
     * <ul>
     *     <li>What the first {@code throughLength} blocks are made of, for the straight-through path.</li>
     *     <li>What lies before the ray first reaches open air, for the path over the terrain.</li>
     * </ul>
     */
    private static final class Walk implements VoxelRay.Visitor {
        private final TerrainView terrain;
        private final @Nullable Cavern cavern;
        private final double lossScale;
        private final double cap;
        private final double throughLength;
        private final double farLimit;
        private final double[] least = RadioMaterial.leastAttenuationTable();

        /** How many metres of each material the walk has passed through. */
        final double[] metres = new double[RadioMaterial.COUNT];
        /** The same, within the first {@code throughLength} blocks. */
        final double[] through = new double[RadioMaterial.COUNT];
        /** The loss so far, at each material's least attenuation. */
        double loss;
        /** What the walk passed through before reaching open air, or {@code null} if it hasn't. */
        double @Nullable [] escape;
        /** How far along the ray the walk reached open air. */
        double exit = Double.NaN;

        Walk(
            TerrainView terrain, @Nullable Cavern cavern, double lossScale, double cap, double throughLength, double farLimit
        ) {
            this.terrain = terrain;
            this.cavern = cavern;
            this.lossScale = lossScale;
            this.cap = cap;
            this.throughLength = throughLength;
            this.farLimit = farLimit;
        }

        /**
         * Check whether the antenna is already in the open (nothing but leaves above it), in which case it has
         * nothing to escape from, even if the ray immediately heads into the ground.
         *
         * @param x The antenna's X position.
         * @param y The antenna's Y position.
         * @param z The antenna's Z position.
         */
        void start(double x, double y, double z) {
            var ground = terrain.groundHeight((int) Math.floor(x), (int) Math.floor(z));
            if (ground != TerrainView.UNKNOWN && Math.floor(y) >= ground) {
                exit = 0;
                escape = new double[RadioMaterial.COUNT];
            }
        }

        @Override
        public boolean visit(int x, int y, int z, double enter, double exit) {
            if (escape == null && enter >= MOUNT_CLEARANCE) {
                var ground = terrain.groundHeight(x, z);
                if (ground != TerrainView.UNKNOWN && y >= ground) {
                    this.exit = enter;
                    escape = metres.clone();
                }
            }

            // Ignore the blocks right next to each antenna, which it is mounted on.
            var start = Math.max(enter, MOUNT_CLEARANCE);
            var end = Math.min(exit, farLimit);
            if (end > start) {
                var info = terrain.block(x, y, z);
                RadioMaterial material;
                double fill;
                if (info != null) {
                    material = info.material();
                    fill = info.fill();
                } else {
                    fill = cavern == null ? Double.NaN : cavern.guess(y, terrain.groundHeight(x, z));
                    if (Double.isNaN(fill)) {
                        material = guessMaterial(x, y, z);
                        fill = 1;
                    } else {
                        material = TERRAIN;
                    }
                }

                var scale = fill * lossScale;
                var length = scale * (end - start);
                metres[material.ordinal()] += length;
                through[material.ordinal()] += scale * Math.max(0, Math.min(end, throughLength) - start);
                loss += least[material.ordinal()] * length;
            }

            // Stop once we've escaped and covered the through section, or once nothing can get through anyway. Until we
            // escape, keep going whatever it costs (the walk is short): whether the ray reaches open air, and where,
            // decides whether the signal goes straight up instead. That mustn't depend on how far the link is traced,
            // or a link traced for a weak transmitter could go up and over where one traced further doesn't.
            return escape == null || (loss <= cap && exit < throughLength);
        }

        private RadioMaterial guessMaterial(int x, int y, int z) {
            var ground = terrain.groundHeight(x, z);
            if (ground != TerrainView.UNKNOWN && y < ground) return TERRAIN;
            var surface = terrain.surfaceHeight(x, z);
            if (surface != TerrainView.UNKNOWN && y < surface) return RadioMaterial.VEGETATION;
            return RadioMaterial.AIR;
        }
    }
}
