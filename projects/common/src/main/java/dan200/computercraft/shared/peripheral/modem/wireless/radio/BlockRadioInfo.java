// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

/**
 * The radio properties of a block.
 *
 * @param material The material the block is made of.
 * @param fill     How much of the block is filled by the material, between 0 and 1. A fence is mostly air, a slab is
 *                 half full.
 */
public record BlockRadioInfo(RadioMaterial material, float fill) {
    public static final BlockRadioInfo AIR = new BlockRadioInfo(RadioMaterial.AIR, 0);

    public BlockRadioInfo {
        if (fill < 0 || fill > 1) throw new IllegalArgumentException("fill must be between 0 and 1");
    }

    public static BlockRadioInfo full(RadioMaterial material) {
        return new BlockRadioInfo(material, 1);
    }
}
