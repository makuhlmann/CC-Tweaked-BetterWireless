// SPDX-FileCopyrightText: 2025 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.pocket.core;

import dan200.computercraft.api.pocket.IPocketUpgrade;
import dan200.computercraft.core.computer.ComputerSide;
import dan200.computercraft.impl.UpgradeData;
import dan200.computercraft.shared.ModRegistry;
import net.minecraft.core.component.DataComponentType;

/**
 * The side a {@linkplain IPocketUpgrade pocket upgrade} will be equipped on.
 * <p>
 * The bottom of a pocket computer is not a slot: a lectern puts the peripheral below it there.
 * <p>
 * Sides are named as on any other computer, from the pocket computer's point of view: looking at its screen, its left
 * is on your right. So in the crafting grid, an upgrade to the left of the pocket computer goes on its right, as with
 * turtles. The order here is the order the upgrades' adjectives appear in the item's name.
 *
 * @see PocketBrain
 */
public enum PocketSide {
    TOP(ComputerSide.TOP),
    LEFT(ComputerSide.LEFT),
    RIGHT(ComputerSide.RIGHT),
    BACK(ComputerSide.BACK);

    private final ComputerSide computerSide;

    PocketSide(ComputerSide computerSide) {
        this.computerSide = computerSide;
    }

    /**
     * The side of the computer an upgrade in this slot is attached to as a peripheral.
     *
     * @return The computer side.
     */
    public ComputerSide computerSide() {
        return computerSide;
    }

    /**
     * The item component which stores the upgrade in this slot.
     *
     * @return The data component.
     */
    public DataComponentType<UpgradeData<IPocketUpgrade>> component() {
        return switch (this) {
            case TOP -> ModRegistry.DataComponents.TOP_POCKET_UPGRADE.get();
            case LEFT -> ModRegistry.DataComponents.LEFT_POCKET_UPGRADE.get();
            case RIGHT -> ModRegistry.DataComponents.RIGHT_POCKET_UPGRADE.get();
            case BACK -> ModRegistry.DataComponents.BACK_POCKET_UPGRADE.get();
        };
    }
}
