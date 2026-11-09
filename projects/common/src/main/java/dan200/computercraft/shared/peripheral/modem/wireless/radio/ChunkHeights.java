// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.util.Mth;
import net.minecraft.util.SimpleBitStorage;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.levelgen.Heightmap;
import org.jspecify.annotations.Nullable;

/**
 * A snapshot of the ground and surface heights of a chunk. This is all the propagation model needs to know about chunks
 * which aren't loaded, and at 1KiB per chunk is cheap enough to keep around for a large area.
 *
 * @see TerrainView#groundHeight(int, int)
 * @see TerrainView#surfaceHeight(int, int)
 */
public final class ChunkHeights {
    private final short @Nullable [] ground;
    private final short @Nullable [] surface;
    private final Source source;
    private final long created;

    /**
     * Create a new snapshot.
     *
     * @param ground  The first free Y position above the ground in each column, or {@code null} if this chunk's heights
     *                could not be found. Indexed by {@code x + z * 16}.
     * @param surface The first free Y position above everything in each column.
     * @param source  Where these heights came from.
     * @param created When this snapshot was taken, in milliseconds.
     */
    public ChunkHeights(short @Nullable [] ground, short @Nullable [] surface, Source source, long created) {
        this.ground = ground;
        this.surface = surface;
        this.source = source;
        this.created = created;
    }

    public Source source() {
        return source;
    }

    public long created() {
        return created;
    }

    public enum Source {
        /** Taken from a loaded chunk, usually as it was unloaded. */
        CHUNK,
        /** Read from the chunk's heightmaps on disk. */
        DISK,
        /** Read from Distant Horizons' LOD data. */
        DISTANT_HORIZONS,
        /** Estimated by the chunk generator. This only knows about terrain, not trees or buildings. */
        GENERATOR,
        /** We don't know anything about this chunk. */
        UNAVAILABLE,
    }

    public static ChunkHeights unavailable() {
        return new ChunkHeights(null, null, Source.UNAVAILABLE, System.currentTimeMillis());
    }

    public boolean isAvailable() {
        return ground != null;
    }

    public int ground(int x, int z) {
        var ground = this.ground;
        return ground == null ? TerrainView.UNKNOWN : ground[(x & 15) + (z & 15) * 16];
    }

    public int surface(int x, int z) {
        var surface = this.surface;
        return surface == null ? TerrainView.UNKNOWN : surface[(x & 15) + (z & 15) * 16];
    }

    /**
     * Take a snapshot of a chunk's heightmaps.
     *
     * @param chunk The chunk to snapshot.
     * @return The chunk's heights.
     */
    public static ChunkHeights of(ChunkAccess chunk) {
        var ground = new short[256];
        var surface = new short[256];
        for (var z = 0; z < 16; z++) {
            for (var x = 0; x < 16; x++) {
                var groundY = chunk.getHeight(Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, x, z) + 1;
                ground[x + z * 16] = (short) groundY;
                surface[x + z * 16] = (short) Math.max(groundY, chunk.getHeight(Heightmap.Types.WORLD_SURFACE, x, z) + 1);
            }
        }
        return new ChunkHeights(ground, surface, Source.CHUNK, System.currentTimeMillis());
    }

    /**
     * Decode a pair of heightmaps, as stored in a chunk's NBT.
     *
     * @param groundData  The {@code MOTION_BLOCKING_NO_LEAVES} heightmap.
     * @param surfaceData The {@code WORLD_SURFACE} heightmap.
     * @param minY        The level's minimum Y position.
     * @param height      The level's height.
     * @return The decoded heights, or {@code null} if the data was not in the format we expected (for instance, it came
     * from an older version or the world height has changed).
     */
    public static @Nullable ChunkHeights decode(long[] groundData, long[] surfaceData, int minY, int height) {
        var bits = Mth.ceillog2(height + 1);
        SimpleBitStorage groundStorage, surfaceStorage;
        try {
            groundStorage = new SimpleBitStorage(bits, 256, groundData);
            surfaceStorage = new SimpleBitStorage(bits, 256, surfaceData);
        } catch (RuntimeException e) {
            return null;
        }

        var ground = new short[256];
        var surface = new short[256];
        for (var i = 0; i < 256; i++) {
            ground[i] = (short) (groundStorage.get(i) + minY);
            surface[i] = (short) Math.max(ground[i], surfaceStorage.get(i) + minY);
        }
        return new ChunkHeights(ground, surface, Source.DISK, System.currentTimeMillis());
    }
}
