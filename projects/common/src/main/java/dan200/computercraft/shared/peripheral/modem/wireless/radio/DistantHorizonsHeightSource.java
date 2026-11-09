// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import com.seibel.distanthorizons.api.DhApi;
import com.seibel.distanthorizons.api.enums.worldGeneration.EDhApiLevelType;
import com.seibel.distanthorizons.api.interfaces.data.IDhApiTerrainDataCache;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiLevelWrapper;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiWorldProxy;
import com.seibel.distanthorizons.api.objects.data.DhApiTerrainDataPoint;
import dan200.computercraft.core.util.ThreadUtils;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Heightmap;
import org.jspecify.annotations.Nullable;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.Predicate;

/**
 * Reads terrain heights from Distant Horizons' level of detail data.
 * <p>
 * DH keeps a compressed copy of every column it has generated or seen, including on dedicated servers. With mods like
 * Tellus, DH often has terrain for regions far beyond anything which exists as real chunks, which makes it a great
 * source of heights for long distance links.
 * <p>
 * The terrain repository is synchronous and may hit DH's database (or even queue LOD generation), so all calls happen
 * on a dedicated thread, and we give up on any request which takes too long.
 * <p>
 * This class references the DH API directly, and so must only be loaded when DH is installed. Use
 * {@link DistantHorizonsHeights#get()} instead.
 */
final class DistantHorizonsHeightSource implements HeightSource {
    private static final long TIMEOUT_SECONDS = 2;

    private final ExecutorService executor = Executors.newSingleThreadExecutor(ThreadUtils.lowPriorityFactory("Radio-DistantHorizons"));
    private @Nullable IDhApiTerrainDataCache cache;

    @Override
    public CompletableFuture<@Nullable ChunkHeights> fetch(ServerLevel level, int chunkX, int chunkZ, Executor worker) {
        return CompletableFuture.supplyAsync(() -> read(level, chunkX, chunkZ), executor)
            .completeOnTimeout(null, TIMEOUT_SECONDS, TimeUnit.SECONDS);
    }

    private @Nullable ChunkHeights read(ServerLevel level, int chunkX, int chunkZ) {
        var repo = DhApi.Delayed.terrainRepo;
        var world = DhApi.Delayed.worldProxy;
        if (repo == null || world == null || !world.worldLoaded()) return null;

        var wrapper = findLevel(world, level);
        if (wrapper == null) return null;

        var cache = this.cache;
        if (cache == null) this.cache = cache = repo.createSoftCache();

        var result = repo.getAllTerrainDataAtChunkPos(wrapper, chunkX, chunkZ, cache);
        var data = result.payload;
        if (!result.success || data == null) return null;

        return toHeights(data, level.getMinY(), level.getMaxY(), Heightmap.Types.MOTION_BLOCKING_NO_LEAVES.isOpaque());
    }

    /**
     * Convert DH's data for a chunk into heights.
     *
     * @param data     The chunk's data, as returned by {@code getAllTerrainDataAtChunkPos}: a 16x16 grid of columns,
     *                 each ordered from top to bottom.
     * @param minY     The level's minimum Y position.
     * @param maxY     The level's maximum Y position, inclusive.
     * @param isGround Whether a block counts as ground, for blocks DH gives us a {@link BlockState} for.
     * @return The heights, or {@code null} if DH doesn't have data for every column.
     */
    static @Nullable ChunkHeights toHeights(DhApiTerrainDataPoint[][][] data, int minY, int maxY, Predicate<BlockState> isGround) {
        if (data.length < 16) return null;

        var ground = new short[256];
        var surface = new short[256];

        for (var x = 0; x < 16; x++) {
            var row = data[x];
            if (row == null || row.length < 16) return null;

            for (var z = 0; z < 16; z++) {
                var column = row[z];
                // DH has no data for this column (it's not been generated yet), so we can't use this chunk.
                if (column == null || column.length == 0) return null;

                var offset = columnOffset(column, minY, maxY);
                int surfaceY = TerrainView.UNKNOWN, groundY = minY;
                for (var point : column) {
                    if (point == null || point.blockStateWrapper == null || point.blockStateWrapper.isAir()) continue;

                    var top = Math.clamp(offset + point.topYBlockPos, minY, maxY + 1);
                    if (surfaceY == TerrainView.UNKNOWN) surfaceY = top;

                    var state = point.blockStateWrapper.getWrappedMcObject();
                    if (state instanceof BlockState blockState ? isGround.test(blockState) : point.blockStateWrapper.isSolid()) {
                        groundY = top;
                        break;
                    }
                }

                ground[x + z * 16] = (short) groundY;
                surface[x + z * 16] = (short) Math.max(groundY, surfaceY == TerrainView.UNKNOWN ? groundY : surfaceY);
            }
        }

        return new ChunkHeights(ground, surface, ChunkHeights.Source.DISTANT_HORIZONS, System.currentTimeMillis());
    }

    /**
     * Work out what to add to a column's Y positions to make them absolute.
     * <p>
     * {@link DhApiTerrainDataPoint}'s documentation says positions are relative to the bottom of the level, which is
     * true of the points you give DH when generating terrain. However, the terrain repository adds the level's minimum
     * height when reading them back, so its positions are absolute. Treating them as relative puts the terrain
     * {@code -minY} blocks too low (512 blocks in a Tellus world), which hides mountains entirely.
     * <p>
     * In case DH ever changes this, we check: the top of each column is open sky, which reaches the top of the level.
     * Absolute positions end there, while relative positions end {@code -minY} blocks above it.
     *
     * @param column The column, ordered from top to bottom.
     * @param minY   The level's minimum Y position.
     * @param maxY   The level's maximum Y position, inclusive.
     * @return The offset to add to every position in this column.
     */
    private static int columnOffset(DhApiTerrainDataPoint[] column, int minY, int maxY) {
        var top = Integer.MIN_VALUE;
        for (var point : column) {
            if (point != null) top = Math.max(top, point.topYBlockPos);
        }
        return minY < 0 && top > maxY + 1 - minY / 2 ? minY : 0;
    }

    private static @Nullable IDhApiLevelWrapper findLevel(IDhApiWorldProxy world, ServerLevel level) {
        for (var wrapper : world.getAllLoadedLevelWrappers()) {
            if (wrapper.getLevelType() == EDhApiLevelType.SERVER_LEVEL && wrapper.getWrappedMcObject() == level) return wrapper;
        }
        return null;
    }
}
