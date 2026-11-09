// SPDX-FileCopyrightText: 2022 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.gametest

import com.mojang.blaze3d.platform.InputConstants
import dan200.computercraft.api.lua.Coerced
import dan200.computercraft.api.lua.LuaException
import dan200.computercraft.client.gui.AbstractComputerScreen
import dan200.computercraft.core.apis.CryptoAPI
import dan200.computercraft.core.apis.OSAPI
import dan200.computercraft.core.apis.RedstoneAPI
import dan200.computercraft.core.apis.TermAPI
import dan200.computercraft.core.computer.ComputerSide
import dan200.computercraft.gametest.api.*
import dan200.computercraft.shared.ModRegistry
import dan200.computercraft.shared.computer.core.ServerContext
import dan200.computercraft.shared.computer.enclave.EnclaveAPI
import dan200.computercraft.test.core.assertArrayEquals
import dan200.computercraft.test.core.computer.getApi
import net.minecraft.client.input.KeyEvent
import net.minecraft.core.BlockPos
import net.minecraft.core.Direction
import net.minecraft.gametest.framework.GameTestHelper
import net.minecraft.world.item.ItemStack
import net.minecraft.world.item.Items
import net.minecraft.world.level.Level
import net.minecraft.world.level.block.Blocks
import net.minecraft.world.level.block.LeverBlock
import net.minecraft.world.level.block.RedstoneLampBlock
import net.minecraft.world.phys.Vec3
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import java.nio.ByteBuffer
import java.util.*
import kotlin.time.Duration.Companion.milliseconds

class Computer_Test {
    /**
     * Ensures redstone signals do not travel through computers.
     *
     * @see [#548](https://github.com/cc-tweaked/CC-Tweaked/issues/548)
     */
    @GameTest
    fun No_through_signal(context: GameTestHelper) = context.sequence {
        val lamp = BlockPos(2, 1, 4)
        val lever = BlockPos(2, 1, 0)
        thenExecute {
            context.assertBlockHas(lamp, RedstoneLampBlock.LIT, false, "Lamp should not be lit")
            context.modifyBlock(lever) { x -> x.setValue(LeverBlock.POWERED, true) }
        }
        thenIdle(3)
        thenExecute { context.assertBlockHas(lamp, RedstoneLampBlock.LIT, false, "Lamp should still not be lit") }
    }

    /**
     * Similar to the above, but with a repeater before the computer
     */
    @GameTest
    fun No_through_signal_reverse(context: GameTestHelper) = context.sequence {
        val lamp = BlockPos(2, 1, 4)
        val lever = BlockPos(2, 1, 0)
        thenExecute {
            context.assertBlockHas(lamp, RedstoneLampBlock.LIT, false, "Lamp should not be lit")
            context.modifyBlock(lever) { x -> x.setValue(LeverBlock.POWERED, true) }
        }
        thenIdle(3)
        thenExecute { context.assertBlockHas(lamp, RedstoneLampBlock.LIT, false, "Lamp should still not be lit") }
    }

    /**
     * Check computers propagate redstone to surrounding blocks.
     */
    @GameTest
    fun Set_and_destroy(context: GameTestHelper) = context.sequence {
        val lamp = BlockPos(2, 1, 3)

        thenOnComputer { getApi<RedstoneAPI>().setOutput(ComputerSide.BACK, true) }
        thenIdle(3)
        thenExecute { context.assertBlockHas(lamp, RedstoneLampBlock.LIT, true, "Lamp should be lit") }
        thenExecute { context.setBlock(BlockPos(2, 1, 2), Blocks.AIR) }
        thenIdle(4)
        thenExecute { context.assertBlockHas(lamp, RedstoneLampBlock.LIT, false, "Lamp should not be lit") }
    }

    /**
     * Check placed computers can ask to keep running when nobody is nearby, and that turtles can't.
     */
    @GameTest
    fun Keep_loaded(context: GameTestHelper) = context.sequence {
        val computer = BlockPos(1, 1, 2)

        thenOnComputer("computer") {
            val os = getApi<OSAPI>()
            assertEquals(false, os.getKeepLoaded(), "Computer should not start out kept loaded")
            os.setKeepLoaded(true)
            assertEquals(true, os.getKeepLoaded(), "Computer should be kept loaded")
        }
        thenIdle(2)
        thenExecute {
            val chunkLoader = ServerContext.get(context.level.server).chunkLoader()
            assertTrue(chunkLoader.isKeptLoaded(context.level, context.absolutePos(computer)), "Computer's chunk should be kept loaded")
        }

        thenOnComputer("turtle") {
            val error = assertThrows(LuaException::class.java) { getApi<OSAPI>().setKeepLoaded(true) }
            assertEquals("This computer cannot be kept loaded", error.message)
        }

        thenOnComputer("computer") { getApi<OSAPI>().setKeepLoaded(false) }
    }

    /**
     * Check computers have an enclave, and that its keys work with the crypto API.
     */
    @GameTest
    fun Enclave_signs(context: GameTestHelper) = context.sequence {
        thenOnComputer {
            val enclave = getApi<EnclaveAPI>()
            val crypto = getApi<CryptoAPI>()

            // Structures share computer IDs, and so enclaves, so start from a clean slate.
            enclave.delete("test")
            val public = enclave.generate("test", "ed25519", Optional.empty())!![0] as ByteArray
            assertEquals(mapOf("kind" to "ed25519", "requirePin" to false), enclave.list()["test"])

            val message = ByteBuffer.wrap("Hello, world!".toByteArray())
            val signature = enclave.sign("test", message)
            assertTrue(crypto.verify(ByteBuffer.wrap(public), message, ByteBuffer.wrap(signature)), "Signature should verify")
            enclave.delete("test")
        }
    }

    /**
     * Check computers pick up propagated redstone to surrounding blocks.
     *
     * @see [#1520](https://github.com/cc-tweaked/CC-Tweaked/issues/1520)
     */
    @GameTest
    fun Self_output_update(context: GameTestHelper) = context.sequence {
        thenOnComputer {
            getApi<RedstoneAPI>().setOutput(ComputerSide.BACK, true)
            sleep(100.milliseconds)
            assertEquals(true, getApi<RedstoneAPI>().getInput(ComputerSide.BACK), "Input should be on")

            getApi<RedstoneAPI>().setOutput(ComputerSide.BACK, false)
            sleep(100.milliseconds)
            assertEquals(false, getApi<RedstoneAPI>().getInput(ComputerSide.BACK), "Input should be off")
        }
    }

    /**
     * Check chest peripherals are reattached with a new size.
     */
    @GameTest
    fun Chest_resizes_on_change(context: GameTestHelper) = context.sequence {
        thenOnComputer { callPeripheral("right", "size").assertArrayEquals(27) }
        thenExecute { context.placeItemAt(ItemStack(Items.CHEST), BlockPos(2, 1, 2), Direction.WEST) }
        thenIdle(1)
        thenOnComputer { callPeripheral("right", "size").assertArrayEquals(54) }
    }

    /**
     * Tests a computer item is dropped on explosion.
     */
    @GameTest
    fun Drops_on_explosion(context: GameTestHelper) = context.sequence {
        thenExecute {
            val explosionPos = Vec3.atCenterOf(context.absolutePos(BlockPos(2, 1, 2)))
            context.level.explode(null, explosionPos.x, explosionPos.y, explosionPos.z, 2.0f, Level.ExplosionInteraction.TNT)

            context.assertItemEntityCountIs(ModRegistry.Items.COMPUTER_NORMAL.get(), 1)
        }
    }

    /**
     * Check the client can open the computer UI and interact with it.
     */
    @GameTest(tag = TestTags.CLIENT)
    fun Open_on_client(context: GameTestHelper) = context.sequence {
        // Write "Hello, world!" and then print each event to the terminal.
        thenOnComputer { getApi<TermAPI>().write(Coerced("Hello, world!")) }
        thenStartComputer {
            val term = getApi<TermAPI>().terminal
            while (true) {
                val event = pullEvent()
                if (term.cursorY >= term.height) {
                    term.scroll(1)
                    term.setCursorPos(0, term.height)
                } else {
                    term.setCursorPos(0, term.cursorY + 1)
                }

                term.write(event.contentToString())
            }
        }
        // Teleport the player to the computer and then open it.
        thenExecute {
            context.positionAt(BlockPos(2, 1, 1))
            context.useBlock(BlockPos(2, 1, 2), context.level.randomPlayer!!)
        }
        // Assert the terminal is synced to the client.
        thenIdle(2)
        thenOnClient {
            val menu = getOpenMenu(ModRegistry.Menus.COMPUTER.get())
            val term = menu.terminal
            assertEquals("Hello, world!", term.getLine(0).toString().trim(), "Terminal contents is synced")
            assertTrue(menu.isOn, "Computer is on")
        }
        // Press a key on the client
        thenOnClient {
            val screen = minecraft.gui.screen() as AbstractComputerScreen<*>
            screen.keyPressed(KeyEvent(InputConstants.KEYCODE_A, 0, 0))
            screen.keyReleased(KeyEvent(InputConstants.KEYCODE_A, 0, 0))
        }
        // And assert it is handled and sent back to the client
        thenIdle(2)
        thenOnClient {
            val term = getOpenMenu(ModRegistry.Menus.COMPUTER.get()).terminal
            assertEquals(
                "[key, 65, false]",
                term.getLine(1).toString().trim(),
                "Terminal contents is synced",
            )
            assertEquals(
                "[key_up, 65]",
                term.getLine(2).toString().trim(),
                "Terminal contents is synced",
            )
        }
    }
}
