// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;


/**
 * Walks every voxel a ray passes through (Amanatides and Woo, "A Fast Voxel Traversal Algorithm"), reporting the exact
 * length of the ray inside each one. Unlike Bresenham's algorithm this never skips voxels the ray clips, and there is
 * no need to correct for diagonal paths.
 * <p>
 * A walk which may skip chunks (with a {@link Skipper}) works out where the ray leaves each voxel afresh on entering
 * each chunk (a 16×16 column), and adds up step by step within it, so the walk through a chunk is the same however the
 * ray got there. Skipping a chunk then changes nothing after it: the walk carries on exactly as it would have if it had
 * visited every voxel in between.
 */
public final class VoxelRay {
    private VoxelRay() {
    }

    @FunctionalInterface
    public interface Visitor {
        /**
         * Visit a single voxel.
         *
         * @param x     The voxel's X coordinate.
         * @param y     The voxel's Y coordinate.
         * @param z     The voxel's Z coordinate.
         * @param enter The distance along the ray at which it enters this voxel.
         * @param exit  The distance along the ray at which it leaves this voxel (or the end of the traversal).
         * @return Whether to continue walking.
         */
        boolean visit(int x, int y, int z, double enter, double exit);
    }

    /**
     * Says which of the voxels the ray passes through in a chunk (a 16×16 column) can be skipped, as visiting them
     * would change nothing. It's asked on entering each chunk, and the ray's stretch through the chunk is skipped if
     * every voxel it visits there can be. Skipping it is the same as visiting those voxels with a visitor which does
     * nothing with them.
     */
    @FunctionalInterface
    public interface Skipper {
        /**
         * The lowest voxel Y coordinate from which up the voxels the ray passes through in a chunk may be skipped. It's
         * first asked with only where the ray enters the chunk, for a bound the answer is no lower than: if the ray
         * enters below that, the chunk is walked without working out where it leaves.
         *
         * @param chunkX The chunk's X coordinate.
         * @param chunkZ The chunk's Z coordinate.
         * @param enter  The distance along the ray at which it enters the chunk.
         * @param exit   The distance along the ray at which it leaves the chunk (or the end of the traversal), or
         *               {@link Double#NaN} if that's yet to be worked out.
         * @return The Y coordinate, or {@link Integer#MAX_VALUE} if none may be skipped.
         */
        int skipFrom(int chunkX, int chunkZ, double enter, double exit);
    }

    /**
     * Walk the voxels between two points.
     *
     * @param x0          The start X coordinate.
     * @param y0          The start Y coordinate.
     * @param z0          The start Z coordinate.
     * @param x1          The end X coordinate.
     * @param y1          The end Y coordinate.
     * @param z1          The end Z coordinate.
     * @param maxDistance The maximum distance to walk along the ray.
     * @param visitor     The visitor to call for each voxel.
     */
    public static void traverse(double x0, double y0, double z0, double x1, double y1, double z1, double maxDistance, Visitor visitor) {
        var dx = x1 - x0;
        var dy = y1 - y0;
        var dz = z1 - z0;
        var length = Math.sqrt(dx * dx + dy * dy + dz * dz);

        var x = (int) Math.floor(x0);
        var y = (int) Math.floor(y0);
        var z = (int) Math.floor(z0);
        if (length == 0) {
            visitor.visit(x, y, z, 0, 0);
            return;
        }

        var limit = Math.min(length, maxDistance);
        dx /= length;
        dy /= length;
        dz /= length;

        var stepX = (int) Math.signum(dx);
        var stepY = (int) Math.signum(dy);
        var stepZ = (int) Math.signum(dz);

        var deltaX = stepX == 0 ? Double.POSITIVE_INFINITY : Math.abs(1 / dx);
        var deltaY = stepY == 0 ? Double.POSITIVE_INFINITY : Math.abs(1 / dy);
        var deltaZ = stepZ == 0 ? Double.POSITIVE_INFINITY : Math.abs(1 / dz);

        var maxX = boundary(x0, x, stepX, dx);
        var maxY = boundary(y0, y, stepY, dy);
        var maxZ = boundary(z0, z, stepZ, dz);

        var t = 0.0;
        while (t < limit) {
            var next = Math.min(maxX, Math.min(maxY, maxZ));
            if (!visitor.visit(x, y, z, t, Math.min(next, limit))) return;
            t = next;

            if (maxX <= maxY && maxX <= maxZ) {
                x += stepX;
                maxX += deltaX;
            } else if (maxY <= maxZ) {
                y += stepY;
                maxY += deltaY;
            } else {
                z += stepZ;
                maxZ += deltaZ;
            }
        }
    }

    private static double boundary(double origin, int cell, int step, double direction) {
        if (step > 0) return (cell + 1 - origin) / direction;
        if (step < 0) return (origin - cell) / -direction;
        return Double.POSITIVE_INFINITY;
    }

    /**
     * Walk the voxels between two points, perhaps skipping some chunks. This works out where the ray leaves each voxel
     * afresh on entering each chunk (see above), so it's a little different from {@link #traverse(double, double, double,
     * double, double, double, double, Visitor)}, in the last few digits; but with a skipper which never skips, the
     * same as itself skipping chunks, wherever it doesn't.
     *
     * @param x0          The start X coordinate.
     * @param y0          The start Y coordinate.
     * @param z0          The start Z coordinate.
     * @param x1          The end X coordinate.
     * @param y1          The end Y coordinate.
     * @param z1          The end Z coordinate.
     * @param maxDistance The maximum distance to walk along the ray.
     * @param visitor     The visitor to call for each voxel which isn't skipped.
     * @param skipper     Says which chunks to skip.
     */
    public static void traverse(
        double x0, double y0, double z0, double x1, double y1, double z1, double maxDistance, Visitor visitor,
        Skipper skipper
    ) {
        var dx = x1 - x0;
        var dy = y1 - y0;
        var dz = z1 - z0;
        var length = Math.sqrt(dx * dx + dy * dy + dz * dz);

        var x = (int) Math.floor(x0);
        var y = (int) Math.floor(y0);
        var z = (int) Math.floor(z0);
        if (length == 0) {
            visitor.visit(x, y, z, 0, 0);
            return;
        }

        var limit = Math.min(length, maxDistance);
        dx /= length;
        dy /= length;
        dz /= length;

        var stepX = (int) Math.signum(dx);
        var stepY = (int) Math.signum(dy);
        var stepZ = (int) Math.signum(dz);
        var inverseX = 1 / dx;
        var inverseY = 1 / dy;
        var inverseZ = 1 / dz;
        var deltaX = Math.abs(inverseX);
        var deltaY = Math.abs(inverseY);
        var deltaZ = Math.abs(inverseZ);
        // The ray leaves cell c along an axis at (c + offset) × inverse: offset is 1 - origin going up, -origin going down.
        var offsetX = offset(x0, stepX);
        var offsetY = offset(y0, stepY);
        var offsetZ = offset(z0, stepZ);

        // When the ray leaves the current voxel along each axis. These are worked out afresh on entering each chunk,
        // and added up from there, so the walk through a chunk is the same however the ray got to it.
        var leaveX = leave(x, stepX, offsetX, inverseX);
        var leaveY = leave(y, stepY, offsetY, inverseY);
        var leaveZ = leave(z, stepZ, offsetZ, inverseZ);
        // Which cell along X and Z is the first in a chunk, going this way.
        var firstX = stepX > 0 ? 0 : 15;
        var firstZ = stepZ > 0 ? 0 : 15;

        var t = 0.0;
        var newChunk = true;
        while (t < limit) {
            // Mostly, the ray enters a chunk below where it may be skipped from, and that's all there is to know.
            if (newChunk && y >= skipper.skipFrom(x >> 4, z >> 4, t, Double.NaN)) {
                // Where the ray leaves this chunk: through the next chunk boundary across X or Z (X first, on a tie, as
                // below), or at the end. As stepping would, adding up from where it entered.
                var chunkLeaveX = advance(leaveX, deltaX, stepX > 0 ? 15 - (x & 15) : x & 15);
                var chunkLeaveZ = advance(leaveZ, deltaZ, stepZ > 0 ? 15 - (z & 15) : z & 15);
                var acrossX = chunkLeaveX <= chunkLeaveZ;
                var chunkLeave = Math.min(chunkLeaveX, chunkLeaveZ);

                // Skip the chunk if every voxel visited before then may be: those visited are between where it enters
                // and where it leaves, found by the same rules as each step below (crossing X happens before crossing Y
                // at the same distance, and Y before Z).
                var from = skipper.skipFrom(x >> 4, z >> 4, t, Math.min(chunkLeave, limit));
                if (y >= from) {
                    var lastY = chunkLeave < limit
                        ? cellAt(y, stepY, leaveY, deltaY, chunkLeave, !acrossX)
                        : cellAt(y, stepY, leaveY, deltaY, limit, false);
                    if (lastY >= from) {
                        if (chunkLeave >= limit) return;

                        // Carry on from the next chunk, just as stepping through every voxel would have.
                        if (acrossX) {
                            z = cellAt(z, stepZ, leaveZ, deltaZ, chunkLeave, false);
                            x = stepX > 0 ? (x | 15) + 1 : (x & -16) - 1;
                        } else {
                            x = cellAt(x, stepX, leaveX, deltaX, chunkLeave, true);
                            z = stepZ > 0 ? (z | 15) + 1 : (z & -16) - 1;
                        }
                        y = lastY;
                        leaveX = leave(x, stepX, offsetX, inverseX);
                        leaveY = leave(y, stepY, offsetY, inverseY);
                        leaveZ = leave(z, stepZ, offsetZ, inverseZ);
                        t = chunkLeave;
                        continue;
                    }
                }
            }
            newChunk = false;

            var next = Math.min(leaveX, Math.min(leaveY, leaveZ));
            if (!visitor.visit(x, y, z, t, Math.min(next, limit))) return;
            t = next;

            if (leaveX <= leaveY && leaveX <= leaveZ) {
                x += stepX;
                if ((x & 15) == firstX) {
                    leaveX = leave(x, stepX, offsetX, inverseX);
                    leaveY = leave(y, stepY, offsetY, inverseY);
                    leaveZ = leave(z, stepZ, offsetZ, inverseZ);
                    newChunk = true;
                } else {
                    leaveX += deltaX;
                }
            } else if (leaveY <= leaveZ) {
                y += stepY;
                leaveY += deltaY;
            } else {
                z += stepZ;
                if ((z & 15) == firstZ) {
                    leaveX = leave(x, stepX, offsetX, inverseX);
                    leaveY = leave(y, stepY, offsetY, inverseY);
                    leaveZ = leave(z, stepZ, offsetZ, inverseZ);
                    newChunk = true;
                } else {
                    leaveZ += deltaZ;
                }
            }
        }
    }

    private static double offset(double origin, int step) {
        return step > 0 ? 1 - origin : -origin;
    }

    // How far along the ray it leaves a cell along one axis, worked out from the cell alone.
    private static double leave(int cell, int step, double offset, double inverse) {
        return step == 0 ? Double.POSITIVE_INFINITY : (cell + offset) * inverse;
    }

    // Add a step's length some number of times, just as stepping does.
    private static double advance(double leave, double delta, int steps) {
        for (var i = 0; i < steps; i++) leave += delta;
        return leave;
    }

    // Which cell the ray is in along one axis at some distance, from the cell it's in now and when it leaves that,
    // stepping as the walk does: every cell it leaves before then is left, and one it leaves at exactly that distance
    // too, if `atTime` says so (as when this axis steps before the one which steps there).
    private static int cellAt(int cell, int step, double leave, double delta, double distance, boolean atTime) {
        if (step == 0) return cell;
        while (leave < distance || (atTime && leave == distance)) {
            cell += step;
            leave += delta;
        }
        return cell;
    }
}
