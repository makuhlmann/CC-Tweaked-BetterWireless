// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.StringTag;
import net.minecraft.nbt.visitors.CollectFields;
import net.minecraft.nbt.visitors.FieldSelector;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.levelgen.Heightmap;
import org.jspecify.annotations.Nullable;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;

/**
 * Somewhere we can find the heights of a chunk which isn't loaded.
 * <p>
 * Sources are never called on the server thread, and must not load or generate chunks.
 */
public interface HeightSource {
    /**
     * Find the heights of a chunk.
     *
     * @param level  The level the chunk is in.
     * @param chunkX The chunk's X coordinate.
     * @param chunkZ The chunk's Z coordinate.
     * @param known  The heights we know in this level. A source which reads more chunks than it's asked for at once
     *               may add them here, rather than read them again when they're asked for.
     * @param worker An executor for any slow work.
     * @return The chunk's heights, or {@code null} if this source doesn't know about this chunk.
     */
    CompletableFuture<@Nullable ChunkHeights> fetch(ServerLevel level, int chunkX, int chunkZ, Known known, Executor worker);

    /**
     * The heights we know of a level's chunks. This may be used from any thread.
     */
    interface Known {
        /**
         * Get the heights we know for a chunk.
         *
         * @param chunkX The chunk's X coordinate.
         * @param chunkZ The chunk's Z coordinate.
         * @return Its heights, or {@code null} if we don't know them (or know only that they couldn't be found).
         */
        @Nullable
        ChunkHeights get(int chunkX, int chunkZ);

        /**
         * Remember a chunk's heights, unless we know better ones already.
         *
         * @param chunkX  The chunk's X coordinate.
         * @param chunkZ  The chunk's Z coordinate.
         * @param heights Its heights.
         */
        void put(int chunkX, int chunkZ, ChunkHeights heights);
    }

    /**
     * Reads the heightmaps of chunks which have been generated and saved, without loading them. This uses the same
     * mechanism vanilla uses to check for structures in unloaded chunks, and runs on the chunk IO thread.
     */
    HeightSource DISK = (level, chunkX, chunkZ, known, worker) -> {
        var heightmapsKey = "Heightmaps";
        var fields = new CollectFields(
            new FieldSelector(StringTag.TYPE, "Status"),
            new FieldSelector(CompoundTag.TYPE, heightmapsKey)
        );
        var minY = level.getMinY();
        var height = level.getHeight();

        return level.getChunkSource().chunkScanner().scanChunk(new ChunkPos(chunkX, chunkZ), fields).thenApply(x -> {
            if (!(fields.getResult() instanceof CompoundTag tag)) return null;
            if (!tag.getStringOr("Status", "").equals("minecraft:full")) return null;

            var heightmaps = tag.getCompound(heightmapsKey).orElse(null);
            if (heightmaps == null) return null;
            var ground = heightmaps.getLongArray(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES.getSerializationKey()).orElse(null);
            var surface = heightmaps.getLongArray(Heightmap.Types.WORLD_SURFACE.getSerializationKey()).orElse(null);
            return ground == null || surface == null ? null : ChunkHeights.decode(ground, surface, minY, height);
        }).exceptionally(e -> null);
    };

    /**
     * Asks the chunk generator for the height of the terrain. This is only an estimate (it doesn't include trees,
     * buildings or anything placed by players), but works for chunks which have never been generated.
     * <p>
     * For the vanilla noise generator this is fairly expensive, so we only sample every fourth column. For terrain
     * generated from elevation data (such as Tellus), it is often very cheap.
     */
    HeightSource GENERATOR = (level, chunkX, chunkZ, known, worker) -> CompletableFuture.<@Nullable ChunkHeights>supplyAsync(() -> {
        var chunkSource = level.getChunkSource();
        var generator = chunkSource.getGenerator();
        var random = chunkSource.randomState();

        var heights = new short[256];
        for (var z = 0; z < 16; z += 4) {
            for (var x = 0; x < 16; x += 4) {
                var y = (short) generator.getBaseHeight(chunkX * 16 + x + 2, chunkZ * 16 + z + 2, Heightmap.Types.WORLD_SURFACE_WG, level, random);
                for (var dz = 0; dz < 4; dz++) {
                    for (var dx = 0; dx < 4; dx++) heights[x + dx + (z + dz) * 16] = y;
                }
            }
        }

        return new ChunkHeights(heights, heights, ChunkHeights.Source.GENERATOR, System.currentTimeMillis());
    }, worker);
}
