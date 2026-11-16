// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import java.util.ArrayList;

/**
 * A path which reflects once off a wall near one end of a link, found by the image method (see
 * {@link PropagationModel#trace}). Like the rest of a {@link LinkPath}, nothing about it depends on the frequency, so it
 * is evaluated at each frequency the link is used at.
 */
final class Reflection {
    private final double length;
    private final double toWall;
    private final double cosIncidence;
    private final RadioMaterial wall;
    private final double[] metres;
    private final double left;
    private final double right;
    private final double down;
    private final double up;

    /**
     * Where to look within the first Fresnel zone around the point where the path meets the wall, in half its radius:
     * the points of a five by five grid which lie within it.
     */
    private static final int[][] ZONE = zone();

    /**
     * The smallest cosine of the angle of incidence the zone is stretched for. A path which only grazes the wall
     * stretches the zone far along it; this keeps it within reason.
     */
    private static final double MIN_COS = 0.2;

    /**
     * Create a reflected path.
     *
     * @param length       The length of the path, from one antenna to the wall and on to the other, in metres.
     * @param toWall       How far the wall is from the nearer antenna, along the path, in metres.
     * @param cosIncidence The cosine of the angle between the path and the wall's normal: 1 head-on, 0 grazing.
     * @param wall         What the wall is made of.
     * @param metres       How many metres of each material the path passes through, indexed by
     *                     {@link RadioMaterial#ordinal()}, as {@link LinkPath} counts them.
     * @param left         How far the wall reaches to one side of the point where the path meets it, in metres.
     * @param right        How far it reaches to the other side.
     * @param down         How far it reaches down.
     * @param up           How far it reaches up.
     */
    Reflection(
        double length, double toWall, double cosIncidence, RadioMaterial wall, double[] metres,
        double left, double right, double down, double up
    ) {
        this.length = length;
        this.toWall = toWall;
        this.cosIncidence = cosIncidence;
        this.wall = wall;
        this.metres = metres;
        this.left = left;
        this.right = right;
        this.down = down;
        this.up = up;
    }

    /**
     * The length of the path, from one antenna to the wall and on to the other.
     *
     * @return The length, in metres.
     */
    double length() {
        return length;
    }

    /**
     * What the wall is made of.
     *
     * @return The wall's material.
     */
    RadioMaterial wall() {
        return wall;
    }

    private static int[][] zone() {
        var points = new ArrayList<int[]>();
        for (var i = -2; i <= 2; i++) {
            for (var j = -2; j <= 2; j++) {
                if (i * i + j * j <= 5) points.add(new int[]{ i, j });
            }
        }
        return points.toArray(new int[0][]);
    }

    /**
     * How much of the first Fresnel zone around the point where the path meets the wall the wall covers, from 0 to 1.
     * A wall reflects as much as it covers of the zone: a lone block hardly at all, as the zone is metres across. The
     * zone is stretched along the wall as the path meets it at an angle.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @return How much it covers.
     */
    double coverage(double frequencyMHz) {
        var far = length - toWall;
        if (toWall <= 0 || far <= 0) return 0;
        var radius = Math.sqrt(RadioMath.wavelength(frequencyMHz) * toWall * far / length);
        var stretch = 1 / Math.max(cosIncidence, MIN_COS);
        var covered = 0;
        for (var point : ZONE) {
            var along = point[0] / 2.0 * radius * stretch;
            var height = point[1] / 2.0 * radius;
            if (along >= -left && along <= right && height >= -down && height <= up) covered++;
        }
        return (double) covered / ZONE.length;
    }

    /**
     * How much more this path loses than its distance alone: reflecting off the wall, as little of the zone as it
     * covers, and whatever it passes through.
     *
     * @param frequencyMHz The frequency, in MHz.
     * @param attenuation  Each material's attenuation at that frequency, in dB per metre.
     * @return The loss, in dB, or infinity if the wall doesn't reflect it at all.
     */
    double loss(double frequencyMHz, double[] attenuation) {
        var coverage = coverage(frequencyMHz);
        if (coverage <= 0) return Double.POSITIVE_INFINITY;
        return wall.reflectionLoss(frequencyMHz, cosIncidence) - 20 * Math.log10(coverage) + LinkPath.loss(attenuation, metres);
    }
}
