// SPDX-FileCopyrightText: 2019 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.util;

import net.minecraft.core.Vec3i;
import net.minecraft.world.phys.Vec3;

import java.util.ArrayList;
import java.util.List;

/**
 * Helpers for wireless communication distance calculation
 */
public final class WirelessHelpers {

    public static Vec3i floorToVec3i(Vec3 vector) {
        return new Vec3i((int)Math.floor(vector.x), (int)Math.floor(vector.y), (int)Math.floor(vector.z));
    }

    public static double getDiagonalCompensation(Vec3i sender, Vec3i receiver) {
        // Compute yaw and pitch angles
        int dx = receiver.getX() - sender.getX();
        int dy = receiver.getY() - sender.getY();
        int dz = receiver.getZ() - sender.getZ();

        double yaw = Math.atan2(dz, dx);
        double pitch = Math.atan2(Math.sqrt(dx * dx + dz * dz), dy) + Math.PI;

        // Compute tan of 45 degree deviation
        yaw = Math.tan(Math.abs(yaw - Math.round(yaw / (Math.PI / 2)) * (Math.PI / 2)));
        pitch = Math.tan(Math.abs(pitch - Math.round(pitch / (Math.PI / 2)) * (Math.PI / 2)));

        // Compute diameter with angle in a 1x1 square
        double yawDiagonal = Math.sqrt(yaw * yaw + 1);
        double pitchDiagonal = Math.sqrt(pitch * pitch + 1);

        return yawDiagonal * pitchDiagonal;
    }

    public static List<Vec3i> Bresenham3D(Vec3i source, Vec3i target) {
        int x1 = source.getX();
        int y1 = source.getY();
        int z1 = source.getZ();

        int x2 = target.getX();
        int y2 = target.getY();
        int z2 = target.getZ();

        List<Vec3i> ListOfPoints = new ArrayList<>();
        ListOfPoints.add(new Vec3i(x1, y1, z1));
        int dx = Math.abs(x2 - x1);
        int dy = Math.abs(y2 - y1);
        int dz = Math.abs(z2 - z1);
        int xs;
        int ys;
        int zs;
        if (x2 > x1) {
            xs = 1;
        } else {
            xs = -1;
        }
        if (y2 > y1) {
            ys = 1;
        } else {
            ys = -1;
        }
        if (z2 > z1) {
            zs = 1;
        } else {
            zs = -1;
        }

        // Driving axis is X-axis
        if (dx >= dy && dx >= dz) {
            int p1 = 2 * dy - dx;
            int p2 = 2 * dz - dx;
            while (x1 != x2) {
                x1 += xs;
                if (p1 >= 0) {
                    y1 += ys;
                    p1 -= 2 * dx;
                }
                if (p2 >= 0) {
                    z1 += zs;
                    p2 -= 2 * dx;
                }
                p1 += 2 * dy;
                p2 += 2 * dz;
                ListOfPoints.add(new Vec3i(x1, y1, z1));
            }

            // Driving axis is Y-axis
        } else if (dy >= dx && dy >= dz) {
            int p1 = 2 * dx - dy;
            int p2 = 2 * dz - dy;
            while (y1 != y2) {
                y1 += ys;
                if (p1 >= 0) {
                    x1 += xs;
                    p1 -= 2 * dy;
                }
                if (p2 >= 0) {
                    z1 += zs;
                    p2 -= 2 * dy;
                }
                p1 += 2 * dx;
                p2 += 2 * dz;
                ListOfPoints.add(new Vec3i(x1, y1, z1));
            }

            // Driving axis is Z-axis
        } else {
            int p1 = 2 * dy - dz;
            int p2 = 2 * dx - dz;
            while (z1 != z2) {
                z1 += zs;
                if (p1 >= 0) {
                    y1 += ys;
                    p1 -= 2 * dz;
                }
                if (p2 >= 0) {
                    x1 += xs;
                    p2 -= 2 * dz;
                }
                p1 += 2 * dy;
                p2 += 2 * dx;
                ListOfPoints.add(new Vec3i(x1, y1, z1));
            }
        }
        return ListOfPoints;
    }
}
