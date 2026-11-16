// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

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
 * The signal takes whichever of the through and over paths is better. Besides that direct path, it may reflect once off
 * a wall near either end (the image method), which brings some of it round whatever is in the way there: in a town, a
 * neighbour's wall. The powers of the paths add.
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

    /**
     * The least-attenuation loss at which walks give up whose results mustn't depend on the budget a link is traced
     * for: those for reflected paths. No link's budget is anywhere near this (a modem's power is at most 100dBm, and
     * receivers hear down to -100dBm), so a path which loses this much is lost, whatever the budget.
     */
    private static final double FIXED_CAP = 300;

    /** How far from an end to look for walls to reflect off, in blocks. */
    private static final int REFLECTION_RADIUS = 24;

    /** How many reflections to keep near each end: the shortest. */
    private static final int MAX_REFLECTIONS = 8;

    /** How far along a wall, each way from where a path meets it, to look for its edge, in blocks. */
    private static final int MAX_WALL_EXTENT = 16;

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
     * How many blocks near each end of a link the diffraction profile samples every block of, as well as the evenly
     * spread samples. On a link longer than the profile has samples, those are further apart than a block, and a house
     * or a wall near an end, where one matters most, would fall between them.
     *
     * @param horizontalBlocks The horizontal length of the link, in blocks.
     * @param segments         The number of segments of the evenly spread samples (see {@link #segmentCount}).
     * @param voxelRadius      How far from each end the blocks are walked, in blocks.
     * @return How many blocks near each end to sample.
     */
    static int nearSamples(double horizontalBlocks, int segments, int voxelRadius) {
        if (segments >= Math.ceil(horizontalBlocks)) return 0;
        return Math.min(voxelRadius, (int) Math.floor(horizontalBlocks / 2));
    }

    /**
     * Visit every column a link's terrain profile samples: the evenly spread samples, and every block near each end
     * (see {@link #nearSamples}). This is used to find which chunks need to be available before evaluating a link.
     *
     * @param tx       The transmitter's X position.
     * @param tz       The transmitter's Z position.
     * @param rx       The receiver's X position.
     * @param rz       The receiver's Z position.
     * @param env      The model parameters.
     * @param consumer The function to call with each column. Its index is -1 for those near the ends.
     */
    public static void forEachProfileColumn(double tx, double tz, double rx, double rz, RadioEnvironment env, ColumnConsumer consumer) {
        forEachSample(tx, tz, rx, rz, env.maxProfileSamples(), consumer);
        var horizontalBlocks = Math.hypot(rx - tx, rz - tz);
        var near = nearSamples(horizontalBlocks, segmentCount(horizontalBlocks, env.maxProfileSamples()), env.voxelRadius());
        for (var k = 1; k <= near; k++) {
            var t = k / horizontalBlocks;
            consumer.accept(-1, (int) Math.floor(tx + (rx - tx) * t), (int) Math.floor(tz + (rz - tz) * t));
            consumer.accept(-1, (int) Math.floor(rx + (tx - rx) * t), (int) Math.floor(rz + (tz - rz) * t));
        }
    }

    /**
     * Visit every column sampled by the terrain profile between two points, evenly spread.
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
        return trace(tx, ty, tz, rx, ry, rz, linkBudget, env, terrain, true);
    }

    /**
     * Trace a link between two antennas, perhaps looking at every block of open sky along the way. That gives the same
     * result as not (see {@link TerrainView#chunkTop}), which the tests check.
     *
     * @param tx         The transmitting antenna's X position.
     * @param ty         The transmitting antenna's Y position.
     * @param tz         The transmitting antenna's Z position.
     * @param rx         The receiving antenna's X position.
     * @param ry         The receiving antenna's Y position.
     * @param rz         The receiving antenna's Z position.
     * @param linkBudget The largest link budget the path is needed for, in dB.
     * @param env        The model parameters.
     * @param terrain    The terrain to propagate through.
     * @param skipSky    Whether to skip open sky.
     * @return The traced link.
     */
    static LinkPath trace(
        double tx, double ty, double tz, double rx, double ry, double rz,
        double linkBudget, RadioEnvironment env, TerrainView terrain, boolean skipSky
    ) {
        var horizontalBlocks = Math.hypot(rx - tx, rz - tz);
        var dy = ry - ty;
        var rayBlocks = Math.sqrt(horizontalBlocks * horizontalBlocks + dy * dy);

        var horizontal = horizontalBlocks * env.metresPerBlock();
        var distance = Math.hypot(horizontal, dy * env.metresPerBlockVertical());
        if (rayBlocks < 1e-6) {
            return new LinkPath(1, false, 0, 0, linkBudget, false, new double[RadioMaterial.COUNT], null, null, null, List.of());
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
            return new LinkPath(
                distance, groundReflection, height1, height2, linkBudget, false, new double[RadioMaterial.COUNT], null, null, null,
                List.of()
            );
        }

        // Walk the blocks near each end of the link. Until the end, losses are measured at each material's least
        // attenuation, so the walks only stop once the signal is lost at every frequency.
        var lossScale = env.materialLossScale() * (distance / rayBlocks);
        var builtScale = env.builtLossScale();
        var walkLength = Math.min(env.voxelRadius(), rayBlocks);
        var txThrough = walkLength;
        var rxThrough = Math.min(env.voxelRadius(), rayBlocks - txThrough);

        var cavern = Cavern.of(terrain, env);
        var fromTx = new Walk(terrain, cavern, lossScale, builtScale, headroom, txThrough, rayBlocks - MOUNT_CLEARANCE);
        fromTx.start(tx, ty, tz);
        VoxelRay.traverse(tx, ty, tz, rx, ry, rz, walkLength, fromTx);
        var fromRx = new Walk(terrain, cavern, lossScale, builtScale, headroom, rxThrough, rayBlocks - MOUNT_CLEARANCE);
        fromRx.start(rx, ry, rz);
        VoxelRay.traverse(rx, ry, rz, tx, ty, tz, walkLength, fromRx);

        // Straight through: the walked bits near each end, plus whatever is in the middle.
        var through = new double[RadioMaterial.COUNT];
        add(through, fromTx.through);
        add(through, fromRx.through);
        var least = RadioMaterial.leastAttenuationTable();
        var throughLoss = LinkPath.loss(least, through);
        var middleLength = rayBlocks - txThrough - rxThrough;
        MiddleWalk middle = null;
        if (middleLength > 0 && throughLoss <= headroom) {
            var start = txThrough / rayBlocks;
            var end = 1 - rxThrough / rayBlocks;
            middle = new MiddleWalk(
                terrain, cavern, lossScale, builtScale, headroom - throughLoss, ground, surface, start, 1 / rayBlocks, skipSky
            );
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
            var profile = Profile.of(terrain, tx, tz, rx, rz, horizontalBlocks, segments, surface, env.voxelRadius(), fallback);
            var count = profile.fractions.length;
            var distances = new double[count];
            var heights = new double[count];
            var effectiveRadius = env.effectiveEarthRadius();
            var txClear = Math.max(txEscape.exit / rayBlocks * horizontalBlocks, PROFILE_CLEARANCE) * env.metresPerBlock();
            var rxClear = Math.max(rxEscape.exit / rayBlocks * horizontalBlocks, PROFILE_CLEARANCE) * env.metresPerBlock();

            for (var i = 0; i < count; i++) {
                var d1 = horizontal * profile.fractions[i];
                var d2 = horizontal - d1;
                distances[i] = d1;
                heights[i] = d1 <= txClear || d2 <= rxClear
                    ? Double.NEGATIVE_INFINITY
                    : profile.heights[i] * env.metresPerBlockVertical() + RadioMath.earthBulge(d1, d2, effectiveRadius);
            }

            diffraction = RadioMath.deygoutEdges(
                distances, heights, 0, count - 1,
                txEscape.height * env.metresPerBlockVertical(), rxEscape.height * env.metresPerBlockVertical(), 1
            );
        }

        // Note that when the direct ray is clear, the through path wins outright, even if the terrain intrudes into the
        // first Fresnel zone. This is deliberate: the two-ray model already accounts for the ground close to the path,
        // and charging for both would penalise perfectly flat terrain.

        // Walls near either end which the signal may reflect off, round whatever is in the way there.
        List<Reflection> reflections = List.of();
        if (env.reflections()) {
            var search = new ReflectionSearch(
                terrain, cavern, env, new double[]{ tx, ty, tz }, new double[]{ rx, ry, rz }, rayBlocks, walkLength,
                txThrough, rxThrough, lossScale, fromTx, fromRx, middle, ground, surface, skipSky
            );
            var found = new ArrayList<Reflection>();
            search.near(found, false);
            search.near(found, true);
            if (!found.isEmpty()) reflections = found;
        }

        return new LinkPath(
            distance, groundReflection, height1, height2, linkBudget, true, through,
            txEscape == null ? null : txEscape.metres, rxEscape == null ? null : rxEscape.metres, diffraction, reflections
        );
    }

    /**
     * The terrain profile the signal diffracts over: the evenly spread samples, and every block near each end (see
     * {@link #nearSamples}), in order along the link.
     */
    private static final class Profile {
        /** How far along the link each sample is, from 0 to 1. */
        final double[] fractions;
        /** The height of the surface at each sample, in blocks. */
        final double[] heights;

        private Profile(double[] fractions, double[] heights) {
            this.fractions = fractions;
            this.heights = heights;
        }

        static Profile of(
            TerrainView terrain, double tx, double tz, double rx, double rz, double horizontalBlocks, int segments,
            double[] surface, int voxelRadius, double fallback
        ) {
            var near = nearSamples(horizontalBlocks, segments, voxelRadius);
            if (near == 0) {
                var fractions = new double[segments + 1];
                for (var i = 0; i <= segments; i++) fractions[i] = (double) i / segments;
                return new Profile(fractions, surface);
            }

            var fractions = new double[segments + 1 + 2 * near];
            var heights = new double[fractions.length];
            var count = 0;
            fractions[count] = 0;
            heights[count++] = surface[0];
            for (var k = 1; k <= near; k++) {
                var t = k / horizontalBlocks;
                fractions[count] = t;
                heights[count++] = height(terrain, tx + (rx - tx) * t, tz + (rz - tz) * t);
            }
            for (var i = 1; i < segments; i++) {
                var t = (double) i / segments;
                if (t * horizontalBlocks <= near || (1 - t) * horizontalBlocks <= near) continue;
                fractions[count] = t;
                heights[count++] = surface[i];
            }
            for (var k = near; k >= 1; k--) {
                var t = 1 - k / horizontalBlocks;
                if (t <= fractions[count - 1]) continue;
                fractions[count] = t;
                heights[count++] = height(terrain, tx + (rx - tx) * t, tz + (rz - tz) * t);
            }
            fractions[count] = 1;
            heights[count++] = surface[segments];

            fractions = Arrays.copyOf(fractions, count);
            heights = Arrays.copyOf(heights, count);
            fillUnknown(heights, fallback);
            return new Profile(fractions, heights);
        }

        // The height of a column's surface, or of its ground if that's higher: NaN if neither is known.
        private static double height(TerrainView terrain, double x, double z) {
            var column = (int) Math.floor(x);
            var row = (int) Math.floor(z);
            var surface = terrain.surfaceHeight(column, row);
            var ground = terrain.groundHeight(column, row);
            if (surface == TerrainView.UNKNOWN && ground == TerrainView.UNKNOWN) return Double.NaN;
            if (surface == TerrainView.UNKNOWN) return ground;
            if (ground == TerrainView.UNKNOWN) return surface;
            return Math.max(surface, ground);
        }
    }

    /**
     * Looks for walls near the ends of a link which the signal may reflect off, round whatever is in the way near that
     * end, by the image method: for each vertical plane of block faces within {@link #REFLECTION_RADIUS} blocks of the
     * end, mirror the other end in it, and see where the line from this end to the image meets it. Where that is a
     * wall's face, with open space in front, the signal may go there and on to the other end.
     * <p>
     * Only ends with something in the way of the direct ray near them, from which the ray reaches open air, are looked
     * around. Both legs of each reflected path are walked, the one to the wall all the way, and the one on to the other
     * end as far as this end's section of the link; beyond that, it shares the rest of the direct path. Everything is
     * walked without regard to the link's budget, so the same reflections are found however far it was traced: the
     * direct path's walks are only reused where they weren't cut short.
     */
    private static final class ReflectionSearch {
        private final TerrainView terrain;
        private final @Nullable Cavern cavern;
        private final RadioEnvironment env;
        private final double[] tx;
        private final double[] rx;
        private final double rayBlocks;
        private final double walkLength;
        private final double txThrough;
        private final double rxThrough;
        private final double lossScale;
        private final Walk fromTx;
        private final Walk fromRx;
        private final @Nullable MiddleWalk middle;
        private final double[] ground;
        private final double[] surface;
        private final boolean skipSky;
        private double @Nullable [] middleMetres;

        ReflectionSearch(
            TerrainView terrain, @Nullable Cavern cavern, RadioEnvironment env, double[] tx, double[] rx, double rayBlocks,
            double walkLength, double txThrough, double rxThrough, double lossScale, Walk fromTx, Walk fromRx,
            @Nullable MiddleWalk middle, double[] ground, double[] surface, boolean skipSky
        ) {
            this.skipSky = skipSky;
            this.terrain = terrain;
            this.cavern = cavern;
            this.env = env;
            this.tx = tx;
            this.rx = rx;
            this.rayBlocks = rayBlocks;
            this.walkLength = walkLength;
            this.txThrough = txThrough;
            this.rxThrough = rxThrough;
            this.lossScale = lossScale;
            this.fromTx = fromTx;
            this.fromRx = fromRx;
            this.middle = middle;
            this.ground = ground;
            this.surface = surface;
        }

        /**
         * Find the reflections near one end.
         *
         * @param found  Where to put them.
         * @param nearRx Whether to look near the second antenna, rather than the first.
         */
        void near(List<Reflection> found, boolean nearRx) {
            var walk = nearRx ? fromRx : fromTx;
            if (walk.escape == null || !obstructed(walk.through)) return;
            var end = nearRx ? rx : tx;
            var other = nearRx ? tx : rx;

            // Every wall face where a reflection could be, nearest path first.
            var candidates = new ArrayList<Candidate>();
            for (var axis : new int[]{ 0, 2 }) {
                var first = (int) Math.floor(end[axis]) - REFLECTION_RADIUS;
                var last = (int) Math.floor(end[axis]) + REFLECTION_RADIUS + 1;
                for (var plane = first; plane <= last; plane++) {
                    var fromEnd = end[axis] - plane;
                    var fromOther = other[axis] - plane;
                    // The image method needs both ends on the same side of the wall.
                    if (fromEnd == 0 || fromOther == 0 || (fromEnd > 0) != (fromOther > 0)) continue;

                    var image = other.clone();
                    image[axis] = 2 * plane - other[axis];
                    var along = (plane - end[axis]) / (image[axis] - end[axis]);
                    var at = new double[3];
                    for (var i = 0; i < 3; i++) at[i] = end[i] + along * (image[i] - end[i]);
                    if (Math.hypot(at[0] - end[0], at[2] - end[2]) > REFLECTION_RADIUS) continue;

                    // The wall is on the far side of the plane, and open space on ours.
                    var wallCell = fromEnd < 0 ? plane : plane - 1;
                    var frontCell = fromEnd < 0 ? plane - 1 : plane;
                    var across = (int) Math.floor(at[axis == 0 ? 2 : 0]);
                    if (!isWall(axis, wallCell, frontCell, across, (int) Math.floor(at[1]))) continue;
                    candidates.add(new Candidate(axis, wallCell, frontCell, image, at, along));
                }
            }
            candidates.sort(Comparator.comparingDouble(candidate -> metres(end, candidate.image)));

            var kept = 0;
            for (var candidate : candidates) {
                if (kept >= MAX_REFLECTIONS) break;
                var reflection = reflection(end, other, candidate, nearRx);
                if (reflection != null) {
                    found.add(reflection);
                    kept++;
                }
            }
        }

        private @Nullable Reflection reflection(double[] end, double[] other, Candidate candidate, boolean nearRx) {
            var axis = candidate.axis;
            var across = axis == 0 ? 2 : 0;
            var wall = wallBlock(axis, candidate.wallCell, (int) Math.floor(candidate.at[across]), (int) Math.floor(candidate.at[1]));
            if (wall == null) return null;

            // Just in front of the wall, so the walks don't start inside it.
            var front = candidate.at.clone();
            front[axis] += candidate.wallCell == candidate.frontCell + 1 ? -1e-3 : 1e-3;

            // To the wall, all the way; and on, as far as this end's section of the link reaches, if not all the way.
            // On short links, all the way, so each way round the link walks the same.
            var metres = leg(end, front, blocks(end, front), blocks(end, front));
            var onward = blocks(front, other);
            var length = onward;
            if (rayBlocks > 2 * env.voxelRadius()) {
                var direction = new double[]{ other[0] - end[0], other[1] - end[1], other[2] - end[2] };
                var norm = Math.sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
                var ahead = ((front[0] - end[0]) * direction[0] + (front[1] - end[1]) * direction[1] + (front[2] - end[2]) * direction[2]) / norm;
                length = Math.clamp((nearRx ? rxThrough : txThrough) - ahead, 0, onward);
            }
            var whole = length >= onward - MOUNT_CLEARANCE;
            add(metres, leg(front, other, whole ? onward : length, whole ? onward - MOUNT_CLEARANCE : length));
            if (!whole) {
                add(metres, exactMiddle());
                add(metres, exactThrough(!nearRx));
            }

            var total = metres(end, candidate.image);
            var normal = Math.abs(candidate.image[axis] - end[axis]) * env.metresPerBlock();
            var extent = extent(axis, candidate.wallCell, candidate.frontCell, candidate.at);
            return new Reflection(
                total, candidate.along * total, normal / total, wall.material(), metres, extent[0], extent[1], extent[2], extent[3]
            );
        }

        // What the direct path passes through in the middle of the link, exactly, whatever the budget.
        private double[] exactMiddle() {
            if (middleMetres != null) return middleMetres;
            var middleLength = rayBlocks - txThrough - rxThrough;
            if (middleLength <= 0) return middleMetres = new double[RadioMaterial.COUNT];
            if (middle != null && middle.loss <= middle.cap) return middleMetres = middle.metres;

            var start = txThrough / rayBlocks;
            var end = 1 - rxThrough / rayBlocks;
            var walk = new MiddleWalk(
                terrain, cavern, lossScale, env.builtLossScale(), FIXED_CAP, ground, surface, start, 1 / rayBlocks, skipSky
            );
            VoxelRay.traverse(
                tx[0] + (rx[0] - tx[0]) * start, tx[1] + (rx[1] - tx[1]) * start, tx[2] + (rx[2] - tx[2]) * start,
                tx[0] + (rx[0] - tx[0]) * end, tx[1] + (rx[1] - tx[1]) * end, tx[2] + (rx[2] - tx[2]) * end,
                middleLength, walk
            );
            return middleMetres = walk.metres;
        }

        // What the direct path passes through in one end's section of the link, exactly, whatever the budget.
        private double[] exactThrough(boolean nearRx) {
            var walk = nearRx ? fromRx : fromTx;
            if (!walk.cut) return walk.through;
            var from = nearRx ? rx : tx;
            var to = nearRx ? tx : rx;
            var again = new Walk(
                terrain, cavern, lossScale, env.builtLossScale(), FIXED_CAP, nearRx ? rxThrough : txThrough, rayBlocks - MOUNT_CLEARANCE
            );
            again.start(from[0], from[1], from[2]);
            VoxelRay.traverse(from[0], from[1], from[2], to[0], to[1], to[2], walkLength, again);
            return again.through;
        }

        // Walk a leg of a reflected path, and get what it passes through.
        private double[] leg(double[] from, double[] to, double length, double farLimit) {
            var blocks = blocks(from, to);
            var scale = blocks <= 0 ? 0 : env.materialLossScale() * metres(from, to) / blocks;
            var walk = new Walk(terrain, cavern, scale, env.builtLossScale(), FIXED_CAP, length, farLimit);
            walk.start(from[0], from[1], from[2]);
            VoxelRay.traverse(from[0], from[1], from[2], to[0], to[1], to[2], length, walk);
            return walk.through;
        }

        // How far the wall reaches each way from where a path meets it (left, right, down, up), in metres.
        private double[] extent(int axis, int wallCell, int frontCell, double[] at) {
            var acrossAxis = axis == 0 ? 2 : 0;
            var across = (int) Math.floor(at[acrossAxis]);
            var y = (int) Math.floor(at[1]);
            int left = 0, right = 0, down = 0, up = 0;
            while (right < MAX_WALL_EXTENT && isWall(axis, wallCell, frontCell, across + right + 1, y)) right++;
            while (left < MAX_WALL_EXTENT && isWall(axis, wallCell, frontCell, across - left - 1, y)) left++;
            while (up < MAX_WALL_EXTENT && isWall(axis, wallCell, frontCell, across, y + up + 1)) up++;
            while (down < MAX_WALL_EXTENT && isWall(axis, wallCell, frontCell, across, y - down - 1)) down++;
            var horizontal = env.metresPerBlock();
            var vertical = env.metresPerBlockVertical();
            return new double[]{
                (at[acrossAxis] - (across - left)) * horizontal, (across + right + 1 - at[acrossAxis]) * horizontal,
                (at[1] - (y - down)) * vertical, (y + up + 1 - at[1]) * vertical,
            };
        }

        // Whether there's a wall's face on a plane: a block a signal reflects off, with open space in front.
        private boolean isWall(int axis, int wallCell, int frontCell, int across, int y) {
            var wall = wallBlock(axis, wallCell, across, y);
            if (wall == null || !wall.reflects()) return false;
            var front = wallBlock(axis, frontCell, across, y);
            return front != null && front.fill() < 0.5f;
        }

        private @Nullable BlockRadioInfo wallBlock(int axis, int cell, int across, int y) {
            return axis == 0 ? terrain.block(cell, y, across) : terrain.block(across, y, cell);
        }

        private double metres(double[] from, double[] to) {
            var dx = (to[0] - from[0]) * env.metresPerBlock();
            var dy = (to[1] - from[1]) * env.metresPerBlockVertical();
            var dz = (to[2] - from[2]) * env.metresPerBlock();
            return Math.sqrt(dx * dx + dy * dy + dz * dz);
        }

        private static double blocks(double[] from, double[] to) {
            var dx = to[0] - from[0];
            var dy = to[1] - from[1];
            var dz = to[2] - from[2];
            return Math.sqrt(dx * dx + dy * dy + dz * dz);
        }

        // Whether something is in the way: anything but air.
        private static boolean obstructed(double[] metres) {
            for (var i = 0; i < metres.length; i++) {
                if (i != RadioMaterial.AIR.ordinal() && metres[i] > 0) return true;
            }
            return false;
        }

        // A wall face where a reflection could be.
        private static final class Candidate {
            /** The axis the wall faces along: 0 for X, 2 for Z. */
            final int axis;
            /** The wall block's coordinate along that axis. */
            final int wallCell;
            /** The coordinate of the open space in front of it. */
            final int frontCell;
            /** The other end, mirrored in the wall's plane. */
            final double[] image;
            /** Where the path meets the wall. */
            final double[] at;
            /** How far along the path from this end to the image that is, from 0 to 1. */
            final double along;

            Candidate(int axis, int wallCell, int frontCell, double[] image, double[] at, double along) {
                this.axis = axis;
                this.wallCell = wallCell;
                this.frontCell = frontCell;
                this.image = image;
                this.at = at;
                this.along = along;
            }
        }
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
        var up = new Walk(
            terrain, cavern, env.materialLossScale() * env.metresPerBlockVertical(), env.builtLossScale(), cap, 0, Double.MAX_VALUE
        );
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
        private final double builtScale;
        private final double cap;
        private final double[] ground;
        private final double[] surface;
        private final double start;
        private final double scale;
        private final double[] least = RadioMaterial.leastAttenuationTable();

        /** Whether to skip open sky: not beneath a ceiling (the Nether), where unloaded space isn't air. */
        private final boolean skipSky;
        // The chunk the walk is in, and its top (see TerrainView.chunkTop).
        private int chunkX = Integer.MIN_VALUE, chunkZ = Integer.MIN_VALUE;
        private int top = TerrainView.UNKNOWN;

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
         * @param builtScale A further multiplier for blocks people build with.
         * @param cap       The loss at which to give up, at each material's least attenuation.
         * @param ground    The ground heights along the profile.
         * @param surface   The surface heights along the profile.
         * @param start     How far along the whole link the walk starts, between 0 and 1.
         * @param scale     The fraction of the whole link covered by one block.
         * @param skipSky   Whether to skip open sky, where the model would only find air.
         */
        MiddleWalk(
            TerrainView terrain, @Nullable Cavern cavern, double lossScale, double builtScale, double cap,
            double[] ground, double[] surface, double start, double scale, boolean skipSky
        ) {
            this.skipSky = skipSky && cavern == null;
            this.terrain = terrain;
            this.cavern = cavern;
            this.lossScale = lossScale;
            this.builtScale = builtScale;
            this.cap = cap;
            this.ground = ground;
            this.surface = surface;
            this.start = start;
            this.scale = scale;
        }

        @Override
        public boolean visit(int x, int y, int z, double enter, double exit) {
            // Open sky: what the rest of this would find to be air, which costs nothing. Most of a long link is this, so
            // it's worth not asking about each block.
            if (skipSky && openSky(x, y, z, enter, exit)) return true;

            var info = terrain.block(x, y, z);
            RadioMaterial material;
            double fill;
            if (info != null) {
                if (info.fill() == 0) return true;
                material = info.material();
                fill = info.built() ? info.fill() * builtScale : info.fill();
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

        // Whether a block is air, as the rest of visit would find: above the top of a chunk whose heights are known, or,
        // in a chunk with none, above the profile's heights, as guessMaterial would go by. Loaded chunks aren't skipped.
        private boolean openSky(int x, int y, int z, double enter, double exit) {
            var cx = x >> 4;
            var cz = z >> 4;
            if (cx != chunkX || cz != chunkZ) {
                chunkX = cx;
                chunkZ = cz;
                top = terrain.chunkTop(cx, cz);
            }
            if (top == TerrainView.UNKNOWN) return false;
            if (top != TerrainView.NO_HEIGHTS) return y >= top;

            var sample = profileSample((enter + exit) / 2);
            return y >= ground[sample] && y >= surface[sample];
        }

        private int profileSample(double distance) {
            return Math.clamp(Math.round((start + distance * scale) * (ground.length - 1)), 0, ground.length - 1);
        }

        private RadioMaterial guessMaterial(int x, int y, int z, double distance) {
            var groundY = terrain.groundHeight(x, z);
            var surfaceY = terrain.surfaceHeight(x, z);
            if (groundY != TerrainView.UNKNOWN && surfaceY != TerrainView.UNKNOWN) return classify(y, groundY, surfaceY);

            var sample = profileSample(distance);
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
        private final double builtScale;
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
        /**
         * Whether the walk gave up within its first {@code throughLength} blocks, as the signal was lost by then: so
         * {@link #through} is only a lower bound.
         */
        boolean cut;

        Walk(
            TerrainView terrain, @Nullable Cavern cavern, double lossScale, double builtScale, double cap, double throughLength,
            double farLimit
        ) {
            this.terrain = terrain;
            this.cavern = cavern;
            this.lossScale = lossScale;
            this.builtScale = builtScale;
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
                    fill = info.built() ? info.fill() * builtScale : info.fill();
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
            if (escape == null) return true;
            if (exit >= throughLength) return false;
            if (loss > cap) {
                cut = true;
                return false;
            }
            return true;
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
