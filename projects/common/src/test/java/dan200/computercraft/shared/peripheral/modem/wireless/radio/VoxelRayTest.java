// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.jqwik.api.ForAll;
import net.jqwik.api.Property;
import net.jqwik.api.statistics.Statistics;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Skipping chunks of a ray must leave everything after them exactly as visiting every voxel would.
 */
class VoxelRayTest {
    private record Visit(int x, int y, int z, double enter, double exit) {
        long chunk() {
            return chunkKey(x >> 4, z >> 4);
        }
    }

    private record Ask(int chunkX, int chunkZ, double enter, double exit) {
    }

    private static long chunkKey(int chunkX, int chunkZ) {
        return ((long) chunkX << 32) ^ (chunkZ & 0xffffffffL);
    }

    // A ray, which is sometimes awkward: along an axis, straight up, at exactly 45° through corners, starting on a
    // chunk boundary, or cut short.
    private static double[] ray(Random random) {
        var ray = new double[7];
        for (var i = 0; i < 6; i++) ray[i] = (random.nextDouble() - 0.5) * 400;
        switch (random.nextInt(8)) {
            case 0 -> ray[4] = ray[1]; // level
            case 1 -> {
                ray[3] = ray[0]; // straight up or down
                ray[5] = ray[2];
            }
            case 2 -> {
                // 45° through block corners.
                for (var i = 0; i < 3; i++) ray[i] = Math.floor(ray[i]);
                var length = 1 + random.nextInt(200);
                ray[3] = ray[0] + length;
                ray[4] = ray[1] + (random.nextBoolean() ? length : 0);
                ray[5] = ray[2] - length;
            }
            case 3 -> {
                ray[0] = 16 * Math.floor(ray[0] / 16); // on chunk boundaries
                ray[2] = 16 * Math.floor(ray[2] / 16);
            }
            case 4 -> ray[5] = ray[2]; // along X
            default -> {
            }
        }
        ray[6] = random.nextInt(4) == 0 ? random.nextDouble() * 300 : Double.POSITIVE_INFINITY;
        return ray;
    }

    @Property(tries = 3000)
    public void skippingChunksChangesNothingAfterThem(@ForAll long seed) {
        var random = new Random(seed);
        var ray = ray(random);
        var skipSeed = random.nextLong();

        // Every voxel, never skipping.
        var all = new ArrayList<Visit>();
        VoxelRay.traverse(ray[0], ray[1], ray[2], ray[3], ray[4], ray[5], ray[6], (x, y, z, enter, exit) -> {
            all.add(new Visit(x, y, z, enter, exit));
            return true;
        }, (chunkX, chunkZ, enter, exit) -> Integer.MAX_VALUE);

        var visited = new ArrayList<Visit>();
        var asked = new ArrayList<Ask>();
        VoxelRay.traverse(ray[0], ray[1], ray[2], ray[3], ray[4], ray[5], ray[6], (x, y, z, enter, exit) -> {
            visited.add(new Visit(x, y, z, enter, exit));
            return true;
        }, (chunkX, chunkZ, enter, exit) -> {
            asked.add(new Ask(chunkX, chunkZ, enter, exit));
            return skipFrom(skipSeed, chunkX, chunkZ);
        });

        // What visiting every voxel says of each chunk the ray crosses, in order.
        var expectedAsks = new ArrayList<Ask>();
        var expectedVisits = new ArrayList<Visit>();
        for (var start = 0; start < all.size(); ) {
            var end = start;
            var lowest = all.get(start).y();
            while (end + 1 < all.size() && all.get(end + 1).chunk() == all.get(start).chunk()) {
                end++;
                lowest = Math.min(lowest, all.get(end).y());
            }
            var first = all.get(start);
            var from = skipFrom(skipSeed, first.x() >> 4, first.z() >> 4);
            // Asked where it enters, and then, if it enters high enough, where it leaves too.
            expectedAsks.add(new Ask(first.x() >> 4, first.z() >> 4, first.enter(), Double.NaN));
            if (first.y() >= from) expectedAsks.add(new Ask(first.x() >> 4, first.z() >> 4, first.enter(), all.get(end).exit()));
            // Skipped if every voxel visited in it may be.
            if (lowest < from) expectedVisits.addAll(all.subList(start, end + 1));
            start = end + 1;
        }

        var plain = new ArrayList<Visit>();
        VoxelRay.traverse(ray[0], ray[1], ray[2], ray[3], ray[4], ray[5], ray[6], (x, y, z, enter, exit) -> {
            plain.add(new Visit(x, y, z, enter, exit));
            return true;
        });
        // The plain walk adds up its steps all the way, so differs in the last few digits (and so, through corners,
        // in which of the voxels there it visits for no distance at all); but it covers the same distance.
        assertEquals(length(plain), length(all), 1e-6, "The plain walk's distance");

        assertEquals(expectedAsks, asked, "What each chunk was said to hold");
        assertEquals(expectedVisits, visited, "The voxels visited");
        Statistics.label("chunks").collect(expectedAsks.size() <= 1 ? "one" : expectedAsks.size() < 10 ? "a few" : "many");
    }

    private static double length(List<Visit> visits) {
        var length = 0.0;
        for (var visit : visits) length += visit.exit() - visit.enter();
        return length;
    }

    // Where each chunk may be skipped from: anywhere, nowhere, or somewhere in the rays' range of heights.
    private static int skipFrom(long seed, int chunkX, int chunkZ) {
        var mixed = (chunkKey(chunkX, chunkZ) ^ seed) * 0x9E3779B97F4A7C15L;
        return switch ((int) ((mixed >>> 33) & 3)) {
            case 0 -> Integer.MIN_VALUE;
            case 1 -> Integer.MAX_VALUE;
            default -> (int) Math.floorMod(mixed >>> 7, 400) - 200;
        };
    }

    @Property(tries = 200)
    public void stoppingInASkippedChunkEndsTheWalk(@ForAll long seed) {
        var random = new Random(seed);
        var ray = ray(random);
        List<Visit> visited = new ArrayList<>();
        // Skip everything: nothing is visited, whatever the ray.
        VoxelRay.traverse(ray[0], ray[1], ray[2], ray[3], ray[4], ray[5], ray[6], (x, y, z, enter, exit) -> {
            visited.add(new Visit(x, y, z, enter, exit));
            return true;
        }, (chunkX, chunkZ, enter, exit) -> Integer.MIN_VALUE);
        // A ray of no length visits its one voxel without asking.
        var length = Math.hypot(ray[3] - ray[0], Math.hypot(ray[4] - ray[1], ray[5] - ray[2]));
        assertEquals(length == 0 ? 1 : 0, visited.size());
    }
}
