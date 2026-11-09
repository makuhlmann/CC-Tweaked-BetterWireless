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
 *         way. Near each antenna we walk individual blocks and use their material's attenuation. Further away we only
 *         have heightmaps, so we classify the ray as being underground, in vegetation, or in the open air.
 *     </li>
 *     <li>
 *         <strong>Over</strong>: the loss of the signal leaving any enclosure around each antenna (walls, a cave),
 *         and then diffracting over the terrain and buildings between them (Deygout's method, ITU-R P.526).
 *     </li>
 * </ol>
 * The signal takes whichever of the through and over paths is better.
 * <p>
 * Evaluating a link costs at most two short voxel walks and one profile of a bounded size, regardless of how far apart
 * the antennas are. The model never loads chunks: anything not exposed by the {@link TerrainView} is guessed.
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
     * Evaluate a link between two antennas.
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
     */
    public static LinkResult evaluate(
        double tx, double ty, double tz, double rx, double ry, double rz,
        double frequencyMHz, double linkBudget, RadioEnvironment env, TerrainView terrain
    ) {
        var horizontalBlocks = Math.hypot(rx - tx, rz - tz);
        var dy = ry - ty;
        var rayBlocks = Math.sqrt(horizontalBlocks * horizontalBlocks + dy * dy);

        var horizontal = horizontalBlocks * env.metresPerBlock();
        var distance = Math.hypot(horizontal, dy * env.metresPerBlockVertical());
        if (rayBlocks < 1e-6) {
            var loss = RadioMath.freeSpaceLoss(1, frequencyMHz);
            return new LinkResult(loss, loss, 0, 0, 0);
        }

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

        // Loss from distance alone.
        double base;
        if (env.groundReflection()) {
            var meanGround = 0.0;
            for (var height : ground) meanGround += height;
            meanGround /= ground.length;

            var height1 = Math.max(env.minAntennaHeight(), (ty - meanGround) * env.metresPerBlockVertical());
            var height2 = Math.max(env.minAntennaHeight(), (ry - meanGround) * env.metresPerBlockVertical());
            base = RadioMath.groundReflectionLoss(distance, frequencyMHz, height1, height2);
        } else {
            base = RadioMath.freeSpaceLoss(distance, frequencyMHz);
        }

        var headroom = linkBudget - base;
        if (headroom <= 0) return new LinkResult(base, base, 0, 0, 0);

        // Walk the blocks near each end of the link.
        var lossScale = env.materialLossScale() * (distance / rayBlocks);
        var walkLength = Math.min(env.voxelRadius(), rayBlocks);
        var txThrough = walkLength;
        var rxThrough = Math.min(env.voxelRadius(), rayBlocks - txThrough);

        var fromTx = new Walk(terrain, frequencyMHz, lossScale, headroom, txThrough, rayBlocks - MOUNT_CLEARANCE);
        fromTx.start(tx, ty, tz);
        VoxelRay.traverse(tx, ty, tz, rx, ry, rz, walkLength, fromTx);
        var fromRx = new Walk(terrain, frequencyMHz, lossScale, headroom, rxThrough, rayBlocks - MOUNT_CLEARANCE);
        fromRx.start(rx, ry, rz);
        VoxelRay.traverse(rx, ry, rz, tx, ty, tz, walkLength, fromRx);

        // Straight through: the walked bits near each end, plus whatever is in the middle.
        var through = fromTx.through + fromRx.through;
        var middleStart = txThrough / rayBlocks;
        var middleEnd = 1 - rxThrough / rayBlocks;
        for (var i = 0; i < segments && through <= headroom; i++) {
            var start = Math.max(middleStart, (double) i / segments);
            var end = Math.min(middleEnd, (double) (i + 1) / segments);
            if (end <= start) continue;

            var midpoint = (start + end) / 2;
            var rayY = ty + dy * midpoint;
            var sample = (int) Math.round(midpoint * segments);
            var material = rayY < ground[sample] ? TERRAIN : rayY < surface[sample] ? RadioMaterial.VEGETATION : RadioMaterial.AIR;
            through += material.attenuation(frequencyMHz) * (end - start) * rayBlocks * lossScale;
        }

        // Over the top: escape any enclosure around each antenna, then diffract over the terrain.
        var txEscape = escape(fromTx, terrain, tx, ty, tz, frequencyMHz, headroom, env);
        var rxEscape = escape(fromRx, terrain, rx, ry, rz, frequencyMHz, headroom, env);
        var over = Double.POSITIVE_INFINITY;
        var diffraction = 0.0;
        if (txEscape != null && rxEscape != null) {
            var distances = new double[segments + 1];
            var heights = new double[segments + 1];
            var effectiveRadius = env.effectiveEarthRadius();
            var txClear = Math.max(txEscape.exit() / rayBlocks * horizontalBlocks, PROFILE_CLEARANCE) * env.metresPerBlock();
            var rxClear = Math.max(rxEscape.exit() / rayBlocks * horizontalBlocks, PROFILE_CLEARANCE) * env.metresPerBlock();

            for (var i = 0; i <= segments; i++) {
                var d1 = horizontal * i / segments;
                var d2 = horizontal - d1;
                distances[i] = d1;
                heights[i] = d1 <= txClear || d2 <= rxClear
                    ? Double.NEGATIVE_INFINITY
                    : surface[i] * env.metresPerBlockVertical() + RadioMath.earthBulge(d1, d2, effectiveRadius);
            }

            diffraction = RadioMath.deygoutLoss(
                distances, heights, 0, segments,
                txEscape.height() * env.metresPerBlockVertical(), rxEscape.height() * env.metresPerBlockVertical(),
                RadioMath.wavelength(frequencyMHz), 1
            );
            over = txEscape.loss() + rxEscape.loss() + diffraction;
        }

        // Note that when the direct ray is clear, the through path wins outright, even if the terrain intrudes into the
        // first Fresnel zone. This is deliberate: the two-ray model already accounts for the ground close to the path,
        // and charging for both would penalise perfectly flat terrain.

        return new LinkResult(base + Math.min(through, over), base, through, over, diffraction);
    }

    /**
     * How a signal escapes the enclosure around an antenna.
     *
     * @param loss   The penetration loss on the way out, in dB.
     * @param exit   How far along the ray (in blocks) the signal reaches open air. Zero if it escapes vertically.
     * @param height The height the signal diffracts from. Usually the antenna, but the surface for buried antennas.
     */
    private record Escape(double loss, double exit, double height) {
    }

    private static @Nullable Escape escape(
        Walk walk, TerrainView terrain, double x, double y, double z, double frequencyMHz, double cap, RadioEnvironment env
    ) {
        if (!Double.isNaN(walk.exit)) return new Escape(walk.escape, walk.exit, y);

        // The ray towards the other antenna stays enclosed, so try going straight up instead. This handles antennas in
        // basements and bunkers: they reach the surface through the ceiling, then propagate from there.
        var up = new Walk(terrain, frequencyMHz, env.materialLossScale() * env.metresPerBlockVertical(), cap, 0, Double.MAX_VALUE);
        VoxelRay.traverse(x, y, z, x, y + env.voxelRadius(), z, env.voxelRadius(), up);
        return Double.isNaN(up.exit) ? null : new Escape(up.escape, 0, y + up.exit);
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
     * Walks the blocks along a ray from one antenna. This tracks two things:
     * <ul>
     *     <li>The loss in the first {@code throughLength} blocks, for the straight-through path.</li>
     *     <li>The loss before the ray first reaches open air, for the path over the terrain.</li>
     * </ul>
     */
    private static final class Walk implements VoxelRay.Visitor {
        private final TerrainView terrain;
        private final double frequencyMHz;
        private final double lossScale;
        private final double cap;
        private final double throughLength;
        private final double farLimit;

        double loss;
        double through;
        double escape = Double.POSITIVE_INFINITY;
        double exit = Double.NaN;

        Walk(TerrainView terrain, double frequencyMHz, double lossScale, double cap, double throughLength, double farLimit) {
            this.terrain = terrain;
            this.frequencyMHz = frequencyMHz;
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
                escape = 0;
            }
        }

        @Override
        public boolean visit(int x, int y, int z, double enter, double exit) {
            if (Double.isNaN(this.exit) && enter >= MOUNT_CLEARANCE) {
                var ground = terrain.groundHeight(x, z);
                if (ground != TerrainView.UNKNOWN && y >= ground) {
                    this.exit = enter;
                    escape = loss;
                }
            }

            // Ignore the blocks right next to each antenna, which it is mounted on.
            var start = Math.max(enter, MOUNT_CLEARANCE);
            var end = Math.min(exit, farLimit);
            if (end > start) {
                var info = terrain.block(x, y, z);
                var attenuation = info == null
                    ? guessMaterial(x, y, z).attenuation(frequencyMHz)
                    : info.material().attenuation(frequencyMHz) * info.fill();
                attenuation *= lossScale;

                loss += attenuation * (end - start);
                through += attenuation * Math.max(0, Math.min(end, throughLength) - start);
            }

            // Stop once we've escaped and covered the through section, or once nothing can get through anyway.
            return loss <= cap && (Double.isNaN(this.exit) || exit < throughLength);
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
