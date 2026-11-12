// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.world.level.Level;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.phys.Vec3;

import java.util.Map;

/**
 * Finds where an ender modem's signal appears in another dimension.
 * <p>
 * The horizontal position is scaled as for travel between the dimensions, so a signal from the Overworld appears in the
 * Nether at an eighth of its coordinates, and a link through the Nether covers eight times the distance. The height
 * stays the same, clamped to the {@linkplain DimensionHeights range} for the dimension it appears in, or to the
 * dimension's build height if it has none.
 */
public final class DimensionMapping {
    private DimensionMapping() {
    }

    /**
     * Find the position in another dimension which corresponds to a position in this one.
     *
     * @param position The position, in {@code from}.
     * @param from     The dimension the position is in.
     * @param to       The dimension to find the corresponding position in.
     * @param ranges   The heights signals may appear at in each dimension, by its ID.
     * @return The corresponding position, in {@code to}.
     */
    public static Vec3 map(Vec3 position, Level from, Level to, Map<String, DimensionHeights> ranges) {
        var scale = DimensionType.getTeleportationScale(from.dimensionType(), to.dimensionType());
        var range = ranges.get(to.dimension().identifier().toString());
        // One above the top block, as that's the first place which is certainly in the open.
        if (range == null) range = new DimensionHeights(to.getMinY(), to.getMaxY() + 1);
        return map(position, scale, range);
    }

    /**
     * Find the position in another dimension which corresponds to a position in this one.
     *
     * @param position The position.
     * @param scale    How much further apart places are in this dimension than in the other.
     * @param range    The heights signals may appear at in the other dimension.
     * @return The corresponding position.
     */
    public static Vec3 map(Vec3 position, double scale, DimensionHeights range) {
        return new Vec3(position.x * scale, range.clamp(position.y), position.z * scale);
    }
}
