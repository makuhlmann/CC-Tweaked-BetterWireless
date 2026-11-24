// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.pocket.recipes;

import com.mojang.serialization.MapCodec;
import dan200.computercraft.api.pocket.IPocketUpgrade;
import dan200.computercraft.impl.PocketUpgrades;
import dan200.computercraft.impl.UpgradeData;
import dan200.computercraft.shared.pocket.core.PocketSide;
import dan200.computercraft.shared.pocket.items.PocketComputerItem;
import dan200.computercraft.shared.util.RegistryHelper;
import net.minecraft.core.HolderLookup;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.CraftingInput;
import net.minecraft.world.item.crafting.CustomRecipe;
import net.minecraft.world.item.crafting.RecipeSerializer;
import net.minecraft.world.level.Level;
import org.jspecify.annotations.Nullable;

import java.util.EnumMap;

public final class PocketComputerUpgradeRecipe extends CustomRecipe {
    public static final MapCodec<PocketComputerUpgradeRecipe> CODEC = RegistryHelper.retrieveRegistryCodec(IPocketUpgrade.REGISTRY)
        .xmap(PocketComputerUpgradeRecipe::new, x -> x.upgradeRegistry);
    public static final StreamCodec<RegistryFriendlyByteBuf, PocketComputerUpgradeRecipe> STREAM_CODEC = RegistryHelper.retrieveRegistryStreamCodec(IPocketUpgrade.REGISTRY)
        .map(PocketComputerUpgradeRecipe::new, x -> x.upgradeRegistry);
    public static final RecipeSerializer<PocketComputerUpgradeRecipe> SERIALIZER = new RecipeSerializer<>(CODEC, STREAM_CODEC);

    private final HolderLookup<IPocketUpgrade> upgradeRegistry;

    public PocketComputerUpgradeRecipe(HolderLookup<IPocketUpgrade> upgradeRegistry) {
        this.upgradeRegistry = upgradeRegistry;
    }

    @Override
    public boolean matches(CraftingInput inventory, Level world) {
        return !assemble(inventory).isEmpty();
    }

    @Override
    public ItemStack assemble(CraftingInput inventory) {
        // Scan the grid for a pocket computer
        var computer = ItemStack.EMPTY;
        var computerX = -1;
        var computerY = -1;
        computer:
        for (var y = 0; y < inventory.height(); y++) {
            for (var x = 0; x < inventory.width(); x++) {
                var item = inventory.getItem(x, y);
                if (!item.isEmpty() && item.getItem() instanceof PocketComputerItem) {
                    computer = item;
                    computerX = x;
                    computerY = y;
                    break computer;
                }
            }
        }

        if (computer.isEmpty()) return ItemStack.EMPTY;

        // Check for upgrades around the item. The pocket computer faces us, so an upgrade to its left goes on its
        // right side, and the other way around (as with turtles).
        var upgrades = new EnumMap<PocketSide, UpgradeData<IPocketUpgrade>>(PocketSide.class);
        for (var y = 0; y < inventory.height(); y++) {
            for (var x = 0; x < inventory.width(); x++) {
                var item = inventory.getItem(x, y);
                if (item.isEmpty() || (x == computerX && y == computerY)) continue;

                var side = getSide(x - computerX, y - computerY);
                if (side == null) return ItemStack.EMPTY;

                var upgrade = PocketUpgrades.instance().get(upgradeRegistry, item);
                if (upgrade == null) return ItemStack.EMPTY;

                // Abort if we've already got an upgrade in that slot.
                if (PocketComputerItem.getUpgrade(computer, side) != null) return ItemStack.EMPTY;

                upgrades.put(side, upgrade);
            }
        }

        // Abort if we have no upgrades
        if (upgrades.isEmpty()) return ItemStack.EMPTY;

        // Construct the new stack
        var result = computer.copyWithCount(1);
        for (var upgrade : upgrades.entrySet()) result.set(upgrade.getKey().component(), upgrade.getValue());
        return result;
    }

    /**
     * Get the slot an upgrade crafted next to the pocket computer goes in.
     *
     * @param dx The upgrade's column, relative to the pocket computer.
     * @param dy The upgrade's row, relative to the pocket computer.
     * @return The slot, or {@code null} if the upgrade isn't directly next to the pocket computer.
     */
    private static @Nullable PocketSide getSide(int dx, int dy) {
        if (dx == 0 && dy == -1) return PocketSide.TOP;
        if (dx == 0 && dy == 1) return PocketSide.BACK;
        if (dx == -1 && dy == 0) return PocketSide.RIGHT;
        if (dx == 1 && dy == 0) return PocketSide.LEFT;
        return null;
    }

    @Override
    public RecipeSerializer<? extends PocketComputerUpgradeRecipe> getSerializer() {
        return SERIALIZER;
    }
}
