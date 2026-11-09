// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import com.seibel.distanthorizons.api.interfaces.block.IDhApiBiomeWrapper;
import com.seibel.distanthorizons.api.interfaces.block.IDhApiBlockStateWrapper;
import com.seibel.distanthorizons.api.objects.data.DhApiTerrainDataPoint;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Checks we read heights from Distant Horizons' data correctly. The columns here mirror what DH's terrain repository
 * returns for a Tellus world (minimum Y of -512, height 2544): ordered top to bottom, starting with the sky.
 */
public class DistantHorizonsHeightSourceTest {
    private static final int MIN_Y = -512;
    private static final int MAX_Y = 2031;

    private static final Block AIR = new Block(true, false);
    private static final Block STONE = new Block(false, true);
    private static final Block LEAVES = new Block(false, false);

    @Test
    public void readsAbsolutePositions() {
        // This is what DH 3.3 returns: the level's minimum height has already been added to every position.
        var heights = toHeights(
            point(AIR, 600, MAX_Y + 1),
            point(STONE, MIN_Y, 600)
        );

        assertEquals(600, heights.ground(0, 0), "Mountain should be at its real height");
        assertEquals(600, heights.surface(0, 0));
    }

    @Test
    public void readsRelativePositions() {
        // DH's documentation says positions are relative to the bottom of the level. Make sure we cope with that too.
        var heights = toHeights(
            point(AIR, 600 - MIN_Y, MAX_Y + 1 - MIN_Y),
            point(STONE, 0, 600 - MIN_Y)
        );

        assertEquals(600, heights.ground(0, 0));
        assertEquals(600, heights.surface(0, 0));
    }

    @Test
    public void separatesGroundAndSurface() {
        var heights = toHeights(
            point(AIR, 160, MAX_Y + 1),
            point(LEAVES, 150, 160),
            point(AIR, 141, 150),
            point(STONE, MIN_Y, 141)
        );

        assertEquals(141, heights.ground(0, 0));
        assertEquals(160, heights.surface(0, 0));
    }

    @Test
    public void rejectsMissingColumns() {
        var data = grid(new DhApiTerrainDataPoint[] { point(AIR, 64, MAX_Y + 1), point(STONE, MIN_Y, 64) });
        data[3][7] = new DhApiTerrainDataPoint[0];

        assertNull(DistantHorizonsHeightSource.toHeights(data, MIN_Y, MAX_Y, x -> true));
    }

    private static ChunkHeights toHeights(DhApiTerrainDataPoint... column) {
        var heights = DistantHorizonsHeightSource.toHeights(grid(column), MIN_Y, MAX_Y, x -> true);
        assertNotNull(heights);
        return heights;
    }

    private static DhApiTerrainDataPoint[][][] grid(DhApiTerrainDataPoint[] column) {
        var data = new DhApiTerrainDataPoint[16][16][];
        for (var x = 0; x < 16; x++) {
            for (var z = 0; z < 16; z++) data[x][z] = column;
        }
        return data;
    }

    private static DhApiTerrainDataPoint point(Block block, int bottom, int top) {
        return DhApiTerrainDataPoint.create((byte) 0, 0, 15, bottom, top, block, Biome.INSTANCE);
    }

    private record Block(boolean isAir, boolean isSolid) implements IDhApiBlockStateWrapper {
        @Override
        public boolean isLiquid() {
            return false;
        }

        @Override
        public int getOpacity() {
            return isSolid ? 15 : 0;
        }

        @Override
        public String getSerialString() {
            return toString();
        }

        @Override
        public byte getMaterialId() {
            return 0;
        }

        @Override
        public @Nullable Object getWrappedMcObject() {
            return null;
        }
    }

    private enum Biome implements IDhApiBiomeWrapper {
        INSTANCE;

        @Override
        public String getName() {
            return "plains";
        }

        @Override
        public String getSerialString() {
            return "minecraft:plains";
        }

        @Override
        public @Nullable Object getWrappedMcObject() {
            return null;
        }
    }
}
