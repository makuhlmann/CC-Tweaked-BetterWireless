// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.jspecify.annotations.Nullable;

/**
 * The world, as seen by the propagation model.
 * <p>
 * Implementations must never load chunks. Instead, they should return {@link #UNKNOWN} or {@code null} for anything
 * they don't know about, and the model will make a best guess.
 */
public interface TerrainView {
    int UNKNOWN = Integer.MIN_VALUE;

    /**
     * The height of the ground in a column: the first free Y position above every motion-blocking block other than
     * leaves. This is the {@code MOTION_BLOCKING_NO_LEAVES} heightmap, so includes fluids and buildings.
     *
     * @param x The block X coordinate.
     * @param z The block Z coordinate.
     * @return The ground height, or {@link #UNKNOWN}.
     */
    int groundHeight(int x, int z);

    /**
     * The height of the surface in a column: the first free Y position above every non-air block, including leaves.
     * This is the {@code WORLD_SURFACE} heightmap.
     *
     * @param x The block X coordinate.
     * @param z The block Z coordinate.
     * @return The surface height, or {@link #UNKNOWN}.
     */
    int surfaceHeight(int x, int z);

    /**
     * Get the radio properties of a block.
     *
     * @param x The block X coordinate.
     * @param y The block Y coordinate.
     * @param z The block Z coordinate.
     * @return The block's properties, or {@code null} if the block is not loaded.
     */
    @Nullable
    BlockRadioInfo block(int x, int y, int z);

    /**
     * The height of this world's ceiling, if it has one, as the Nether does: the first Y position above it.
     * <p>
     * The heights of such a world are those of its ceiling, and say nothing of the space beneath it: every column looks
     * like solid rock. So where blocks aren't loaded, the model takes that space to be mostly open, rather than going
     * by the heights. Above the ceiling is open ground, as anywhere else.
     *
     * @return The ceiling's height, or {@link #UNKNOWN} if the world is open to the sky.
     */
    default int ceilingHeight() {
        return UNKNOWN;
    }
}
