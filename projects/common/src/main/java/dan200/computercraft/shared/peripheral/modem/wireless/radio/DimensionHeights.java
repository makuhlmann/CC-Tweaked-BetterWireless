// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The heights at which signals from other dimensions may appear in a dimension.
 * <p>
 * An ender modem's signal appears in other dimensions at the same height, which needn't be a sensible one there: a
 * modem high up in a tall Overworld would be far above the Nether's roof. So the height is clamped to a range for each
 * dimension.
 *
 * @param min The lowest height a signal may appear at.
 * @param max The greatest height a signal may appear at.
 */
public record DimensionHeights(int min, int max) {
    private static final Logger LOG = LoggerFactory.getLogger(DimensionHeights.class);

    /**
     * The default ranges, as their config entries.
     * <p>
     * In the Nether, signals from high up appear on top of the roof (whose bedrock ends below Y 128), which to the
     * propagation model is flat, open ground. The End has no ceiling, so a signal above an island still has a clear
     * path down to it.
     */
    public static final List<String> DEFAULT_ENTRIES = List.of("minecraft:the_nether=0..128", "minecraft:the_end=0..128");

    public static final Map<String, DimensionHeights> DEFAULTS = parse(DEFAULT_ENTRIES);

    /**
     * Clamp a height to this range.
     *
     * @param y The height.
     * @return The nearest height within the range.
     */
    public double clamp(double y) {
        return Math.clamp(y, min, max);
    }

    /**
     * Check whether a config entry can be read.
     *
     * @param entry The entry, which should be of the form {@code namespace:dimension=min..max}.
     * @return Whether it's a string which {@link #parse(List)} would accept.
     */
    public static boolean isValid(Object entry) {
        return entry instanceof String string && parseEntry(string, new HashMap<>());
    }

    /**
     * Read the ranges from their config entries. Entries which can't be read are skipped.
     *
     * @param entries The entries, each of the form {@code namespace:dimension=min..max}.
     * @return The range for each dimension, by its ID.
     */
    public static Map<String, DimensionHeights> parse(List<? extends String> entries) {
        var result = new HashMap<String, DimensionHeights>();
        for (var entry : entries) {
            if (!parseEntry(entry, result)) LOG.warn("Ignoring the height range {}: expected dimension=min..max.", entry);
        }
        return Map.copyOf(result);
    }

    private static boolean parseEntry(String entry, Map<String, DimensionHeights> out) {
        var equals = entry.lastIndexOf('=');
        var dots = entry.indexOf("..", equals + 1);
        if (equals <= 0 || dots < 0) return false;

        var dimension = entry.substring(0, equals).trim();
        if (dimension.isEmpty()) return false;
        // Dimensions without a namespace are Minecraft's own.
        if (dimension.indexOf(':') < 0) dimension = "minecraft:" + dimension;

        try {
            var min = Integer.parseInt(entry.substring(equals + 1, dots).trim());
            var max = Integer.parseInt(entry.substring(dots + 2).trim());
            if (min > max) return false;
            out.put(dimension, new DimensionHeights(min, max));
            return true;
        } catch (NumberFormatException e) {
            return false;
        }
    }
}
