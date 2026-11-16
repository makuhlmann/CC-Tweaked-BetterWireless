// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.jqwik.api.ForAll;
import net.jqwik.api.Property;
import net.jqwik.api.statistics.Statistics;
import org.jspecify.annotations.Nullable;

import java.util.HashMap;
import java.util.Map;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Skipping open sky along a link (see {@link TerrainView#chunkTop}) must give exactly the result of looking at every
 * block: over random mountains which reach into the ray or not, with chunks which are loaded, whose heights are known,
 * or of which nothing is known, under open sky or a ceiling.
 */
class OpenSkyTest {
    private static final double[] FREQUENCIES = { 150, 465, 806, 1842.5, 2655, 5800 };

    /**
     * Mountains: random bumps on rolling ground, up to a few hundred blocks high, with each chunk loaded, or with its
     * heights known, or with nothing known, at random.
     */
    private static final class Mountains implements TerrainView {
        private final double[][] bumps;
        private final long seed;
        private final int ceiling;
        private final Map<Long, Integer> kinds = new HashMap<>();

        static final int LOADED = 0, KNOWN = 1, NOTHING = 2;

        Mountains(Random random, int ceiling) {
            seed = random.nextLong();
            this.ceiling = ceiling;
            bumps = new double[2 + random.nextInt(12)][];
            for (var i = 0; i < bumps.length; i++) {
                bumps[i] = new double[]{
                    random.nextDouble() * 3000, random.nextDouble() * 3000, // where
                    20 + random.nextDouble() * 400, // how wide
                    random.nextDouble() * 250, // how high
                };
            }
        }

        int kind(int chunkX, int chunkZ) {
            return kinds.computeIfAbsent(((long) chunkX << 32) ^ (chunkZ & 0xffffffffL), key -> {
                var mixed = key * 0x9E3779B97F4A7C15L ^ seed;
                return (int) Math.floorMod(mixed ^ (mixed >>> 29), 3);
            });
        }

        int height(int x, int z) {
            var height = 64 + 8 * Math.sin(x / 97.0) * Math.cos(z / 131.0);
            for (var bump : bumps) {
                var dx = (x - bump[0]) / bump[2];
                var dz = (z - bump[1]) / bump[2];
                height += bump[3] * Math.exp(-(dx * dx + dz * dz));
            }
            return (int) height;
        }

        @Override
        public int groundHeight(int x, int z) {
            return kind(x >> 4, z >> 4) == NOTHING ? UNKNOWN : height(x, z);
        }

        @Override
        public int surfaceHeight(int x, int z) {
            // Trees on some columns.
            return kind(x >> 4, z >> 4) == NOTHING ? UNKNOWN : height(x, z) + ((x * 31 + z * 17) % 5 == 0 ? 6 : 0);
        }

        @Override
        public @Nullable BlockRadioInfo block(int x, int y, int z) {
            if (kind(x >> 4, z >> 4) != LOADED) return null;
            var ground = height(x, z);
            if (y < ground) return BlockRadioInfo.full(RadioMaterial.ROCK);
            return y < surfaceHeight(x, z) ? BlockRadioInfo.full(RadioMaterial.VEGETATION) : BlockRadioInfo.AIR;
        }

        @Override
        public int chunkTop(int chunkX, int chunkZ) {
            return switch (kind(chunkX, chunkZ)) {
                case LOADED -> UNKNOWN;
                case NOTHING -> NO_HEIGHTS;
                default -> {
                    var top = Integer.MIN_VALUE + 2;
                    for (var x = chunkX << 4; x < (chunkX << 4) + 16; x++) {
                        for (var z = chunkZ << 4; z < (chunkZ << 4) + 16; z++) {
                            top = Math.max(top, Math.max(groundHeight(x, z), surfaceHeight(x, z)));
                        }
                    }
                    yield top;
                }
            };
        }

        @Override
        public int ceilingHeight() {
            return ceiling;
        }
    }

    @Property(tries = 1200)
    public void givesTheSameResultAsLookingAtEveryBlock(@ForAll long seed) {
        var random = new Random(seed);
        var nether = random.nextInt(10) == 0;
        var terrain = new Mountains(random, nether ? 128 : TerrainView.UNKNOWN);

        var tx = random.nextDouble() * 3000;
        var tz = random.nextDouble() * 3000;
        var rx = random.nextDouble() * 3000;
        var rz = random.nextDouble() * 3000;
        // Antennas on the ground, on a mast, or high above the mountains.
        var ty = terrain.height((int) Math.floor(tx), (int) Math.floor(tz)) + 1.5 + random.nextDouble() * (random.nextBoolean() ? 5 : 400);
        var ry = terrain.height((int) Math.floor(rx), (int) Math.floor(rz)) + 1.5 + random.nextDouble() * (random.nextBoolean() ? 5 : 400);
        var budget = 100 + random.nextDouble() * 120;
        var env = random.nextBoolean() ? RadioEnvironment.DEFAULT
            : new RadioEnvironment(1, 1, 0, true, 2, 1, 0.3, true, 64, 64 + random.nextInt(512), 0.02);

        var everyBlock = PropagationModel.trace(tx, ty, tz, rx, ry, rz, budget, env, terrain, false);
        var skipping = PropagationModel.trace(tx, ty, tz, rx, ry, rz, budget, env, terrain, true);
        for (var frequency : FREQUENCIES) {
            assertEquals(everyBlock.evaluate(frequency), skipping.evaluate(frequency), () -> "At " + frequency + " MHz");
        }

        var loss = everyBlock.evaluate(806).loss();
        Statistics.label("link").collect(nether ? "under a ceiling" : loss <= budget ? "within budget" : "lost");
    }
}
