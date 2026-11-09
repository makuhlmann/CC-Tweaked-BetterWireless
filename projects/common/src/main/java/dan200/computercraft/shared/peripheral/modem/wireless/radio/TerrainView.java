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
}
