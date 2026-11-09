// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

/**
 * Walks every voxel a ray passes through (Amanatides and Woo, "A Fast Voxel Traversal Algorithm"), reporting the exact
 * length of the ray inside each one. Unlike Bresenham's algorithm this never skips voxels the ray clips, and there is
 * no need to correct for diagonal paths.
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
}
