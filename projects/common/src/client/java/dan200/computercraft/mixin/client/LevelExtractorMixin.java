// SPDX-FileCopyrightText: 2022 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.mixin.client;

import dan200.computercraft.client.ClientHooks;
import net.minecraft.client.Camera;
import net.minecraft.client.renderer.extract.LevelExtractor;
import net.minecraft.client.renderer.state.level.LevelRenderState;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyArg;

/**
 * Provides custom block breaking progress for modems, so it only applies to the current part.
 * <p>
 * This picks the part's state while the breaking render state is built, rather than swapping in a new render state
 * when it is drawn. Other mods attach data to the render state when it is built (Create stores the model to draw),
 * and a copy made later would lose it.
 *
 * @see LevelExtractor#extractBlockDestroyAnimation(Camera, LevelRenderState)
 */
@Mixin(LevelExtractor.class)
abstract class LevelExtractorMixin {
    @ModifyArg(
        method = "extractBlockDestroyAnimation",
        at = @At(
            value = "INVOKE",
            target = "Lnet/minecraft/client/renderer/state/level/BlockBreakingRenderState;<init>(Lnet/minecraft/core/BlockPos;Lnet/minecraft/world/level/block/state/BlockState;I)V"
        ),
        index = 1
    )
    @SuppressWarnings("unused")
    private BlockState extractBlockDestroyAnimation(BlockPos pos, BlockState state, int progress) {
        return ClientHooks.getBlockBreakingState(state, pos);
    }
}
