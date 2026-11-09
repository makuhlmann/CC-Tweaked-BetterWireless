// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.levelgen.Heightmap;
import org.jspecify.annotations.Nullable;

/**
 * A {@link TerrainView} of a real level. Loaded chunks are read directly, and everything else comes from the
 * {@link LevelHeights} cache.
 * <p>
 * This must only be used from the server thread, as it reads chunks directly.
 */
final class LevelTerrainView implements TerrainView {
    private final ServerLevel level;
    private final LevelHeights heights;
    private final int minY, maxY;

    private long lastPos = Long.MAX_VALUE;
    private @Nullable LevelChunk lastChunk;
    private @Nullable ChunkHeights lastHeights;

    LevelTerrainView(ServerLevel level, LevelHeights heights) {
        this.level = level;
        this.heights = heights;
        minY = level.getMinY();
        maxY = level.getMaxY();
    }

    private void select(int x, int z) {
        var pos = ChunkPos.pack(x >> 4, z >> 4);
        if (pos == lastPos) return;

        lastPos = pos;
        lastChunk = level.getChunkSource().getChunkNow(x >> 4, z >> 4);
        lastHeights = lastChunk == null ? heights.get(pos) : null;
    }

    /**
     * Check whether we know anything about the given chunk.
     *
     * @param chunkX The chunk's X coordinate.
     * @param chunkZ The chunk's Z coordinate.
     * @return Whether the chunk is loaded, or its heights are cached.
     */
    boolean isKnown(int chunkX, int chunkZ) {
        select(chunkX << 4, chunkZ << 4);
        return lastChunk != null || lastHeights != null;
    }

    @Override
    public int groundHeight(int x, int z) {
        select(x, z);
        var chunk = lastChunk;
        if (chunk != null) return chunk.getHeight(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, x & 15, z & 15) + 1;
        var heights = lastHeights;
        return heights == null ? UNKNOWN : heights.ground(x, z);
    }

    @Override
    public int surfaceHeight(int x, int z) {
        select(x, z);
        var chunk = lastChunk;
        if (chunk != null) {
            return Math.max(
                chunk.getHeight(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, x & 15, z & 15),
                chunk.getHeight(Heightmap.Types.WORLD_SURFACE, x & 15, z & 15)
            ) + 1;
        }
        var heights = lastHeights;
        return heights == null ? UNKNOWN : heights.surface(x, z);
    }

    @Override
    public @Nullable BlockRadioInfo block(int x, int y, int z) {
        select(x, z);
        var chunk = lastChunk;
        if (chunk == null) return null;
        if (y < minY || y > maxY) return BlockRadioInfo.AIR;

        var section = chunk.getSection(chunk.getSectionIndex(y));
        if (section.hasOnlyAir()) return BlockRadioInfo.AIR;
        return BlockRadioProperties.get(section.getBlockState(x & 15, y & 15, z & 15));
    }
}
