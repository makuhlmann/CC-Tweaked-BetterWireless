// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.jqwik.api.ForAll;
import net.jqwik.api.Property;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;
import java.util.Random;
import java.util.function.IntBinaryOperator;

import static org.junit.jupiter.api.Assertions.*;

public class PropagationModelTest {
    private static final int GROUND = 64;
    private static final double VHF = 150, UHF = 2400;
    private static final RadioEnvironment ENV = RadioEnvironment.DEFAULT;

    /** A link budget which reaches exactly 1024 blocks over flat ground on VHF. */
    private static final double BUDGET = ENV.flatGroundLoss(1024, VHF);

    @Test
    public void flatGroundMatchesCalibration() {
        var terrain = new FakeTerrain((x, z) -> GROUND);
        var link = evaluate(terrain, 0, 0, 1024, VHF);

        assertEquals(BUDGET, link.loss(), 0.5, "Ground level antennas 1024 blocks apart are right at the edge");
        assertEquals(0, link.through(), 1e-9);
    }

    @Test
    public void heightIncreasesRange() {
        var terrain = new FakeTerrain((x, z) -> GROUND);
        var low = evaluate(terrain, 0, 0, 2048, VHF);
        var high = PropagationModel.evaluate(0.5, GROUND + 30, 0.5, 2048.5, GROUND + 30, 0.5, VHF, BUDGET, ENV, terrain);

        assertTrue(low.loss() > BUDGET, "Ground level antennas should not reach 2048 blocks");
        assertTrue(high.loss() < BUDGET, "Antennas on 30m towers should: " + high.loss());
    }

    @Test
    public void hillDiffracts() {
        var flat = new FakeTerrain((x, z) -> GROUND);
        // A 40-block high, 100-block wide ridge in the middle of the path.
        var hill = new FakeTerrain((x, z) -> x >= 450 && x < 550 ? GROUND + 40 : GROUND);

        var clear = evaluate(flat, 0, 0, 1000, VHF);
        var blocked = evaluate(hill, 0, 0, 1000, VHF);

        assertTrue(blocked.diffracted(), "Signal should go over the hill, not through it");
        assertTrue(blocked.diffraction() > 15, "Hill should cost a fair amount: " + blocked.diffraction());
        assertEquals(clear.baseLoss(), blocked.baseLoss(), 1e-6);
        assertTrue(blocked.loss() > clear.loss());
    }

    @Test
    public void higherFrequencyDiffractsWorse() {
        var hill = new FakeTerrain((x, z) -> x >= 450 && x < 550 ? GROUND + 40 : GROUND);
        var vhf = evaluate(hill, 0, 0, 1000, VHF);
        var uhf = evaluate(hill, 0, 0, 1000, UHF);
        assertTrue(uhf.diffraction() > vhf.diffraction());
    }

    @Test
    public void wallNearAntennaAttenuates() {
        // A single block thick, very tall rock wall 10 blocks from the transmitter, so going over it is expensive.
        var terrain = new FakeTerrain((x, z) -> x == 10 ? GROUND + 200 : GROUND);
        terrain.solid = (x, y, z) -> x == 10 && y < GROUND + 200 ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;

        var link = evaluate(terrain, 0, 0, 100, VHF);
        assertFalse(link.diffracted(), "Signal should go through the wall");
        assertEquals(RadioMaterial.ROCK.attenuation(VHF), link.through(), 0.5);
    }

    @Test
    public void woodIsCheaperThanRock() {
        var rock = new FakeTerrain((x, z) -> x == 10 ? GROUND + 200 : GROUND);
        rock.solid = (x, y, z) -> x == 10 && y < GROUND + 200 ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;
        var wood = new FakeTerrain((x, z) -> x == 10 ? GROUND + 200 : GROUND);
        wood.solid = (x, y, z) -> x == 10 && y < GROUND + 200 ? BlockRadioInfo.full(RadioMaterial.WOOD) : null;

        assertTrue(evaluate(wood, 0, 0, 100, UHF).loss() < evaluate(rock, 0, 0, 100, UHF).loss());
    }

    @Test
    public void buriedAntennaIsCutOff() {
        // The transmitter sits 30 blocks underground; everything in that column above it is rock.
        var terrain = new FakeTerrain((x, z) -> GROUND);
        terrain.solid = (x, y, z) -> y < GROUND ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;

        var link = PropagationModel.evaluate(0.5, GROUND - 30, 0.5, 200.5, GROUND + 1, 0.5, VHF, BUDGET, ENV, terrain);
        assertTrue(link.loss() > BUDGET, "Signal should not escape 30 blocks of rock: " + link);
    }

    @Test
    public void shallowAntennaGetsThrough() {
        var terrain = new FakeTerrain((x, z) -> GROUND);
        terrain.solid = (x, y, z) -> y < GROUND ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;

        // Two blocks under the surface, transmitting straight up to a receiver above it.
        var link = PropagationModel.evaluate(0.5, GROUND - 2, 0.5, 0.5, GROUND + 40, 0.5, VHF, BUDGET, ENV, terrain);
        assertTrue(link.loss() < BUDGET, "Signal should escape two blocks of rock: " + link);
    }

    @Test
    public void bunkerEscapesUpwards() {
        // The transmitter is three blocks under the surface, and the receiver is far away at ground level, so the
        // straight line between them runs through rock. The signal should instead escape through the ceiling.
        var terrain = new FakeTerrain((x, z) -> GROUND);
        terrain.solid = (x, y, z) -> y < GROUND ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;

        var link = PropagationModel.evaluate(0.5, GROUND - 3, 0.5, 500.5, GROUND + 1, 0.5, VHF, BUDGET + 100, ENV, terrain);
        assertTrue(link.diffracted(), "Signal should go up and over: " + link);
        assertEquals(2 * RadioMaterial.ROCK.attenuation(VHF), link.over() - link.diffraction(), 0.5);
    }

    @Test
    public void longTunnelCarriesSignal() {
        // A straight tunnel, 3 wide and 5 tall, 50 blocks underground. The link is much longer than the block radius,
        // so this relies on walking the real blocks in the middle too.
        var terrain = tunnel();
        var link = PropagationModel.evaluate(0.5, GROUND + 1.5, 0.5, 300.5, GROUND + 0.5, 0.5, VHF, BUDGET, ENV, terrain);

        assertEquals(0, link.through(), 1e-9, "Nothing in the way: " + link);
        assertTrue(link.loss() < BUDGET, "Signal should reach the end of the tunnel: " + link);
    }

    @Test
    public void unloadedTunnelIsSolid() {
        // If the middle of the tunnel isn't loaded, all we know is that it's underground, so we assume it's rock.
        var terrain = tunnel();
        terrain.loaded = (x, z) -> x < 100 || x > 200;
        var link = PropagationModel.evaluate(0.5, GROUND + 1.5, 0.5, 300.5, GROUND + 0.5, 0.5, VHF, BUDGET, ENV, terrain);

        assertTrue(link.loss() > BUDGET, "Signal should not get through 100 blocks of (presumed) rock: " + link);
    }

    @Test
    public void wallFarFromAntennasAttenuates() {
        // The same wall as wallNearAntennaAttenuates, but in the middle of a link much longer than the block radius.
        var terrain = new FakeTerrain((x, z) -> x == 300 ? GROUND + 200 : GROUND);
        terrain.solid = (x, y, z) -> x == 300 && y < GROUND + 200 ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;

        var link = evaluate(terrain, 0, 0, 600, VHF);
        assertFalse(link.diffracted(), "Signal should go through the wall");
        assertEquals(RadioMaterial.ROCK.attenuation(VHF), link.through(), 0.5);
    }

    private static FakeTerrain tunnel() {
        var terrain = new FakeTerrain((x, z) -> GROUND + 50);
        terrain.solid = (x, y, z) -> x >= -1 && x <= 302 && z >= -1 && z <= 1 && y >= GROUND && y < GROUND + 5 ? BlockRadioInfo.AIR : null;
        return terrain;
    }

    @Test
    public void unknownTerrainIsInterpolated() {
        // We only know the ground near each end; the model should assume it continues flat.
        var terrain = new FakeTerrain((x, z) -> x < 50 || x > 950 ? GROUND : TerrainView.UNKNOWN);
        var known = new FakeTerrain((x, z) -> GROUND);
        assertEquals(evaluate(known, 0, 0, 1000, VHF).loss(), evaluate(terrain, 0, 0, 1000, VHF).loss(), 1e-6);
    }

    @Test
    public void onePathServesEveryFrequency() {
        // A single wooden wall in the middle of the link, beyond the block radius, which the signal goes through.
        var wall = new FakeTerrain((x, z) -> x == 300 ? GROUND + 200 : GROUND);
        wall.solid = (x, y, z) -> x == 300 && y < GROUND + 200 ? BlockRadioInfo.full(RadioMaterial.WOOD) : null;
        var throughWall = PropagationModel.trace(0.5, GROUND + 1, 0.5, 600.5, GROUND + 1, 0.5, BUDGET + 200, ENV, wall);

        // A hill, which it goes over.
        var hill = new FakeTerrain((x, z) -> x >= 450 && x < 550 ? GROUND + 40 : GROUND);
        var overHill = PropagationModel.trace(0.5, GROUND + 1, 0.5, 1000.5, GROUND + 1, 0.5, BUDGET + 200, ENV, hill);

        for (var frequency : new double[]{ VHF, UHF }) {
            var traced = throughWall.evaluate(frequency);
            assertEquals(evaluate(wall, 0, 0, 600, frequency).loss(), traced.loss(), 1e-9);
            assertEquals(RadioMaterial.WOOD.attenuation(frequency), traced.through(), 0.01 * traced.through());

            var diffracted = overHill.evaluate(frequency);
            assertEquals(evaluate(hill, 0, 0, 1000, frequency).loss(), diffracted.loss(), 1e-9);
            assertTrue(diffracted.diffracted());
        }
        assertTrue(overHill.evaluate(UHF).diffraction() > overHill.evaluate(VHF).diffraction());
    }

    @Test
    public void tracingFurtherChangesNothingWithinBudget() {
        // The near trace gives up walking through the hill sooner, but the signal goes over it either way.
        var terrain = new FakeTerrain((x, z) -> x >= 450 && x < 550 ? GROUND + 40 : GROUND);
        var near = PropagationModel.trace(0.5, GROUND + 1, 0.5, 1000.5, GROUND + 1, 0.5, BUDGET + 60, ENV, terrain);
        var far = PropagationModel.trace(0.5, GROUND + 1, 0.5, 1000.5, GROUND + 1, 0.5, BUDGET + 200, ENV, terrain);

        assertTrue(near.evaluate(VHF).loss() < BUDGET + 60, "The link should be within budget: " + near.evaluate(VHF));
        assertEquals(near.evaluate(VHF).loss(), far.evaluate(VHF).loss(), 1e-9);
    }

    @Test
    public void linksTooFarForTheirBudgetAreNotWalked() {
        // Two ground-level modems 5km apart are far beyond each other's reach on flat ground, whatever is in the way.
        var terrain = new FakeTerrain((x, z) -> GROUND);
        var weak = PropagationModel.trace(0.5, GROUND + 1, 0.5, 5000.5, GROUND + 1, 0.5, BUDGET, ENV, terrain);
        assertFalse(weak.walked(), "Distance alone should rule the link out");

        // A much stronger transmitter might still reach, so the same link is walked for that.
        var strong = PropagationModel.trace(0.5, GROUND + 1, 0.5, 5000.5, GROUND + 1, 0.5, BUDGET + 40, ENV, terrain);
        assertTrue(strong.walked());

        // The weak path can't answer for the stronger transmitter, but can for anything weaker.
        assertFalse(weak.serves(VHF, BUDGET + 40));
        assertTrue(weak.serves(VHF, BUDGET - 10));
    }

    @Test
    public void linksWithinBudgetServeStrongerTransmitters() {
        var terrain = new FakeTerrain((x, z) -> GROUND);
        var path = PropagationModel.trace(0.5, GROUND + 1, 0.5, 500.5, GROUND + 1, 0.5, BUDGET, ENV, terrain);
        assertTrue(path.evaluate(VHF).loss() < BUDGET);
        assertTrue(path.serves(VHF, BUDGET + 100), "A link within budget is exact whatever the budget");
    }

    @Test
    public void lostLinksAreLostAtEveryFrequency() {
        // A link traced for one budget, and lost, is lost however well the frequency penetrates.
        var terrain = new FakeTerrain((x, z) -> GROUND);
        terrain.solid = (x, y, z) -> y < GROUND ? BlockRadioInfo.full(RadioMaterial.ROCK) : null;
        var path = PropagationModel.trace(0.5, GROUND - 30, 0.5, 200.5, GROUND + 1, 0.5, BUDGET, ENV, terrain);

        for (var frequency : new double[]{ RadioMaterial.MIN_FREQUENCY, VHF, UHF, RadioMaterial.MAX_FREQUENCY }) {
            assertTrue(path.evaluate(frequency).loss() > BUDGET, "Lost at " + frequency + "MHz: " + path.evaluate(frequency));
        }
    }

    @Test
    public void linksAreReciprocal() {
        var terrain = new FakeTerrain((x, z) -> GROUND + (int) (20 * Math.sin(x / 50.0)) + (x == 30 ? 3 : 0));
        var forward = PropagationModel.evaluate(0.5, GROUND + 25, 0.5, 700.5, GROUND + 30, 0.5, VHF, BUDGET + 100, ENV, terrain);
        var backward = PropagationModel.evaluate(700.5, GROUND + 30, 0.5, 0.5, GROUND + 25, 0.5, VHF, BUDGET + 100, ENV, terrain);
        assertTrue(forward.diffraction() > 0, "Hills should intrude on the Fresnel zone: " + forward);
        assertEquals(forward.loss(), backward.loss(), 1.0);
    }

    /**
     * The Nether, more or less: a ceiling whose top is at Y 128, five blocks thick, with open space beneath it.
     *
     * @return The terrain.
     */
    private static FakeTerrain cavern() {
        var terrain = new FakeTerrain((x, z) -> 128);
        terrain.ceiling = 128;
        terrain.solid = (x, y, z) -> y >= 123 && y < 128 ? BlockRadioInfo.full(RadioMaterial.ROCK) : BlockRadioInfo.AIR;
        return terrain;
    }

    @Test
    public void unloadedSpaceBeneathACeilingIsMostlyOpen() {
        // Heights beneath a ceiling are the ceiling's, so say nothing about what's in the 800 blocks we can't see.
        var terrain = cavern();
        terrain.loaded = (x, z) -> x < 100 || x >= 900;
        var link = PropagationModel.evaluate(0.5, 60.5, 0.5, 1000.5, 60.5, 0.5, VHF, BUDGET + 200, ENV, terrain);

        var expected = RadioMaterial.ROCK.attenuation(VHF) * ENV.ceilingUnknownFill() * 800;
        assertEquals(expected, link.through(), expected * 0.02, "Unloaded space should cost a little for each block");
        assertFalse(link.diffracted(), "There's nothing to go over");

        // Seen as it is, it's open.
        terrain.loaded = (x, z) -> true;
        var open = PropagationModel.evaluate(0.5, 60.5, 0.5, 1000.5, 60.5, 0.5, VHF, BUDGET + 200, ENV, terrain);
        assertEquals(0, open.through(), 1e-9);
        assertEquals(open.baseLoss(), link.baseLoss(), 1e-9);

        // Without a ceiling, the same heights mean solid rock all the way.
        terrain.ceiling = TerrainView.UNKNOWN;
        terrain.loaded = (x, z) -> x < 100 || x >= 900;
        var buried = PropagationModel.evaluate(0.5, 60.5, 0.5, 1000.5, 60.5, 0.5, VHF, BUDGET + 200, ENV, terrain);
        assertTrue(link.loss() < BUDGET + 200, "The signal should get through unloaded space: " + link.loss());
        assertTrue(buried.loss() > BUDGET + 200, "But not through that much rock: " + buried.loss());
    }

    @Test
    public void nothingGoesOverACeiling() {
        // A wall from floor to ceiling. In the open, the signal would go over it.
        var terrain = cavern();
        var wall = terrain.solid;
        terrain.solid = (x, y, z) -> x >= 450 && x < 550 ? BlockRadioInfo.full(RadioMaterial.ROCK) : wall.get(x, y, z);
        var link = PropagationModel.evaluate(0.5, 60.5, 0.5, 1000.5, 60.5, 0.5, VHF, BUDGET + 200, ENV, terrain);

        assertFalse(link.diffracted());
        assertEquals(Double.POSITIVE_INFINITY, link.over());
        assertTrue(link.loss() > BUDGET + 200, "A hundred blocks of rock should block the signal: " + link.loss());
    }

    @Test
    public void aboveACeilingIsOpenGround() {
        var terrain = cavern();
        terrain.loaded = (x, z) -> x < 100 || x >= 900;
        var link = PropagationModel.evaluate(0.5, 129, 0.5, 1024.5, 129, 0.5, VHF, BUDGET + 200, ENV, terrain);

        assertEquals(BUDGET, link.loss(), 0.5, "Antennas on the ceiling reach as far as on any flat ground");
        assertEquals(0, link.through(), 1e-9);
    }

    @Test
    public void anUnloadedCeilingStillBlocks() {
        // From beneath the ceiling to above it, through chunks which aren't loaded.
        var terrain = cavern();
        terrain.loaded = (x, z) -> false;
        var link = PropagationModel.evaluate(0.5, 100.5, 0.5, 40.5, 140.5, 0.5, VHF, BUDGET + 200, ENV, terrain);

        // The ray climbs a block for each block along, so is in the ceiling's five blocks for about seven.
        var rock = RadioMaterial.ROCK.attenuation(VHF);
        assertTrue(link.through() > rock * 5, "The ceiling should cost as much as rock: " + link.through());
        assertTrue(link.through() < rock * 12, "The space beneath it shouldn't: " + link.through());
    }

    /** Frequencies across the whole range radios may use, and the bands in between. */
    private static final double[] FREQUENCIES = {
        RadioMaterial.MIN_FREQUENCY, VHF, 450, 800, 1575.42, UHF, 2600, RadioMaterial.MAX_FREQUENCY,
    };

    /**
     * Rolling hills, with a wall of wood or rock across them, or none.
     *
     * @param random Where to get random numbers.
     * @return The terrain.
     */
    private static FakeTerrain randomTerrain(Random random) {
        var big = random.nextDouble() * 40;
        var wide = 20 + random.nextDouble() * 200;
        var small = random.nextDouble() * 15;
        var narrow = 5 + random.nextDouble() * 50;
        var phase = random.nextDouble() * 1000;
        var kind = random.nextInt(3);
        var wallX = random.nextInt(1200) - 300;
        var wallTop = GROUND + random.nextInt(60);
        IntBinaryOperator hills = (x, z) -> GROUND + (int) Math.floor(big * Math.sin((x + phase) / wide) + small * Math.cos((z - phase) / narrow + x / (2 * narrow)));
        var terrain = new FakeTerrain(kind == 0 ? hills : (x, z) -> x == wallX ? Math.max(wallTop, hills.applyAsInt(x, z)) : hills.applyAsInt(x, z));
        if (kind > 0) {
            var material = kind == 1 ? RadioMaterial.WOOD : RadioMaterial.ROCK;
            terrain.solid = (x, y, z) -> x == wallX && y < wallTop ? BlockRadioInfo.full(material) : null;
        }
        return terrain;
    }

    /**
     * Two antennas: a few blocks to 1500 apart, above the ground or now and then a little below it.
     *
     * @param tx The first antenna's X position.
     * @param ty The first antenna's Y position.
     * @param tz The first antenna's Z position.
     * @param rx The second antenna's X position.
     * @param ry The second antenna's Y position.
     * @param rz The second antenna's Z position.
     */
    private record Link(double tx, double ty, double tz, double rx, double ry, double rz) {
        static Link random(Random random, TerrainView terrain) {
            var tx = random.nextInt(400) - 200 + 0.5;
            var tz = random.nextInt(400) - 200 + 0.5;
            var angle = random.nextDouble() * 2 * Math.PI;
            var length = 3 + random.nextDouble() * 1500;
            var rx = Math.floor(tx + Math.cos(angle) * length) + 0.5;
            var rz = Math.floor(tz + Math.sin(angle) * length) + 0.5;
            return new Link(tx, height(random, terrain, tx, tz), tz, rx, height(random, terrain, rx, rz), rz);
        }

        private static double height(Random random, TerrainView terrain, double x, double z) {
            var ground = terrain.groundHeight((int) Math.floor(x), (int) Math.floor(z));
            return ground + (random.nextInt(8) == 0 ? -random.nextInt(6) : 1 + random.nextInt(40)) + 0.5;
        }

        LinkPath trace(double budget, TerrainView terrain) {
            return PropagationModel.trace(tx, ty, tz, rx, ry, rz, budget, ENV, terrain);
        }

        LinkPath back(double budget, TerrainView terrain) {
            return PropagationModel.trace(rx, ry, rz, tx, ty, tz, budget, ENV, terrain);
        }
    }

    @Property(tries = 300)
    public void cachedPathsAnswerAsAFreshTraceWould(@ForAll long seed) {
        // The link cache keeps one traced path for each pair of blocks, and answers packets of any frequency and
        // budget from it when it says it serves them.
        var random = new Random(seed);
        var terrain = randomTerrain(random);
        var link = Link.random(random, terrain);
        var traced = BUDGET - 20 + random.nextDouble() * 120;
        var path = link.trace(traced, terrain);
        for (var frequency : FREQUENCIES) {
            var budget = traced - 40 + random.nextDouble() * 120;
            if (!path.serves(frequency, budget)) continue;
            var cached = path.evaluate(frequency).loss();
            var fresh = link.trace(budget, terrain).evaluate(frequency).loss();
            var what = link + " at " + frequency + "MHz, traced for " + traced + ", asked for " + budget;
            assertEquals(fresh <= budget, cached <= budget, "Whether it's heard: " + what + ", " + fresh + " vs " + cached);
            if (fresh <= budget) assertEquals(fresh, cached, 1e-6, what);
        }
    }

    @Property(tries = 300)
    public void linksAreNumbersWhicheverWayRound(@ForAll long seed) {
        var random = new Random(seed);
        var terrain = randomTerrain(random);
        var link = Link.random(random, terrain);
        var budget = BUDGET + random.nextDouble() * 100;
        var forward = link.trace(budget, terrain);
        var backward = link.back(budget, terrain);
        var lastBase = Double.NEGATIVE_INFINITY;
        for (var frequency : FREQUENCIES) {
            var there = forward.evaluate(frequency);
            var back = backward.evaluate(frequency);
            var what = link + " at " + frequency + "MHz: " + there + " / " + back;
            for (var value : new double[]{ there.loss(), there.baseLoss(), there.through(), there.diffraction() }) {
                assertFalse(Double.isNaN(value), "NaN in " + what);
            }
            assertTrue(there.baseLoss() >= 0 && there.through() >= 0 && there.diffraction() >= 0, "Negative loss in " + what);
            assertTrue(there.loss() >= there.baseLoss() - 1e-9, "Less loss than distance alone in " + what);
            assertTrue(there.baseLoss() >= lastBase - 1e-9, "Distance costs less at a higher frequency in " + what);
            lastBase = there.baseLoss();
            // The cache answers either way round from one path, so both should agree, at least on whether it's heard.
            if (there.loss() <= budget - 1 || back.loss() <= budget - 1) {
                assertEquals(there.loss(), back.loss(), 1.0, "Not reciprocal: " + what);
            }
        }
    }

    private static LinkResult evaluate(TerrainView terrain, int fromX, int fromZ, int toX, double frequency) {
        return PropagationModel.evaluate(fromX + 0.5, GROUND + 1, fromZ + 0.5, toX + 0.5, GROUND + 1, fromZ + 0.5, frequency, BUDGET + 200, ENV, terrain);
    }

    private static final class FakeTerrain implements TerrainView {
        private final IntBinaryOperator height;
        private final Map<Long, BlockRadioInfo> overrides = new HashMap<>();
        BlockLookup solid = (x, y, z) -> null;
        ColumnTest loaded = (x, z) -> true;
        int ceiling = UNKNOWN;

        FakeTerrain(IntBinaryOperator height) {
            this.height = height;
        }

        @Override
        public int groundHeight(int x, int z) {
            return height.applyAsInt(x, z);
        }

        @Override
        public int surfaceHeight(int x, int z) {
            return height.applyAsInt(x, z);
        }

        @Override
        public int ceilingHeight() {
            return ceiling;
        }

        @Override
        public @Nullable BlockRadioInfo block(int x, int y, int z) {
            if (!loaded.test(x, z)) return null;
            var override = overrides.get(((long) x << 40) ^ ((long) y << 20) ^ z);
            if (override != null) return override;
            var block = solid.get(x, y, z);
            if (block != null) return block;

            var ground = groundHeight(x, z);
            if (ground == UNKNOWN) return null;
            return y < ground ? BlockRadioInfo.full(RadioMaterial.ROCK) : BlockRadioInfo.AIR;
        }
    }

    @FunctionalInterface
    private interface BlockLookup {
        @Nullable
        BlockRadioInfo get(int x, int y, int z);
    }

    @FunctionalInterface
    private interface ColumnTest {
        boolean test(int x, int z);
    }
}
