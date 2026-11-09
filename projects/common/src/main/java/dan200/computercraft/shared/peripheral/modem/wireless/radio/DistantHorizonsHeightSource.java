// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import com.seibel.distanthorizons.api.DhApi;
import com.seibel.distanthorizons.api.enums.worldGeneration.EDhApiLevelType;
import com.seibel.distanthorizons.api.interfaces.data.IDhApiTerrainDataCache;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiLevelWrapper;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiWorldProxy;
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
        if (!result.success || data == null || data.length < 16) return null;

        var minY = level.getMinY();
        var ground = new short[256];
        var surface = new short[256];
        var isGround = Heightmap.Types.MOTION_BLOCKING_NO_LEAVES.isOpaque();

        for (var x = 0; x < 16; x++) {
            var row = data[x];
            if (row == null || row.length < 16) return null;

            for (var z = 0; z < 16; z++) {
                var column = row[z];
                // DH has no data for this column (it's not been generated yet), so we can't use this chunk.
                if (column == null || column.length == 0) return null;

                int surfaceY = TerrainView.UNKNOWN, groundY = minY;
                // Columns are ordered from top to bottom.
                for (var point : column) {
                    if (point == null || point.blockStateWrapper == null || point.blockStateWrapper.isAir()) continue;

                    var top = minY + point.topYBlockPos;
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

    private static @Nullable IDhApiLevelWrapper findLevel(IDhApiWorldProxy world, ServerLevel level) {
        for (var wrapper : world.getAllLoadedLevelWrappers()) {
            if (wrapper.getLevelType() == EDhApiLevelType.SERVER_LEVEL && wrapper.getWrappedMcObject() == level) return wrapper;
        }
        return null;
    }
}
