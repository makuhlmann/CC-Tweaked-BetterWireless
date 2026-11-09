// SPDX-FileCopyrightText: 2022 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.gametest

import dan200.computercraft.api.lua.LuaException
import dan200.computercraft.api.lua.ObjectArguments
import dan200.computercraft.core.apis.PeripheralAPI
import dan200.computercraft.core.computer.ComputerSide
import dan200.computercraft.gametest.api.*
import dan200.computercraft.gametest.api.GameTest
import dan200.computercraft.impl.network.wired.WiredNodeImpl
import dan200.computercraft.shared.ModRegistry
import dan200.computercraft.shared.peripheral.modem.wired.CableBlock
import dan200.computercraft.shared.peripheral.modem.wired.CableModemVariant
import dan200.computercraft.shared.peripheral.modem.wired.WiredModemFullBlockEntity
import dan200.computercraft.test.core.assertArrayEquals
import dan200.computercraft.test.core.computer.LuaTaskContext
import dan200.computercraft.test.core.computer.getApi
import net.minecraft.core.BlockPos
import net.minecraft.core.Direction
import net.minecraft.gametest.framework.GameTestHelper
import net.minecraft.world.item.ItemStack
import net.minecraft.world.item.Items
import net.minecraft.world.level.block.Blocks
import org.junit.jupiter.api.Assertions.assertEquals
import kotlin.time.Duration.Companion.milliseconds

class Modem_Test {
    @GameTest
    fun Have_peripherals(helper: GameTestHelper) = helper.sequence {
        thenOnComputer {
            assertEquals(listOf("monitor_0", "printer_0", "right"), getPeripheralNames(), "Starts with peripherals")
        }
    }

    @GameTest
    fun Gains_peripherals(helper: GameTestHelper) = helper.sequence {
        val position = BlockPos(2, 1, 2)
        thenOnComputer {
            assertEquals(listOf("back"), getPeripheralNames(), "Starts with peripherals")
        }
        thenExecute {
            helper.setBlock(
                position,
                CableBlock.correctConnections(
                    helper.level,
                    helper.absolutePos(position),
                    ModRegistry.Blocks.CABLE.get().defaultBlockState().setValue(CableBlock.CABLE, true),
                ),
            )
        }
        thenIdle(1)
        thenOnComputer {
            assertEquals(listOf("back", "monitor_1", "printer_1"), getPeripheralNames(), "Gains new peripherals")
        }
    }

    /**
     * Sends a modem message to another computer on the same network
     */
    @GameTest
    fun Transmits_messages(context: GameTestHelper) = context.sequence {
        thenStartComputer("send") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            while (true) {
                callPeripheral(modem, "transmit", 12, 34, "Hello")
                sleep(50.milliseconds)
            }
        }
        thenOnComputer("receive") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            callPeripheral(modem, "open", 12)

            pullEvent("modem_message")
                .assertArrayEquals("modem_message", "left", 12, 34, "Hello", 4, message = "Modem message")
        }
    }

    /**
     * Sends a message between two wireless modems, and checks the receiver is told how strong the signal was.
     */
    @GameTest
    fun Wireless_reports_signal_strength(context: GameTestHelper) = context.sequence {
        thenStartComputer("send") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            while (true) {
                callPeripheral(modem, "transmit", 12, 34, "Hello")
                sleep(50.milliseconds)
            }
        }
        thenOnComputer("receive") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            callPeripheral(modem, "open", 12)

            val event = pullEvent("modem_message")
            assertEquals(7, event.size, "modem_message should include the signal strength")
            assertEquals("Hello", event[4])

            val signal = (event[6] as Number).toDouble()
            if (signal <= -100 || signal >= 0) throw AssertionError("Unexpected signal strength $signal")
        }
    }

    /**
     * Wireless modems refuse messages over the size limit, and say they aren't ender modems.
     */
    @GameTest
    fun Wireless_rejects_large_messages(context: GameTestHelper) = context.sequence {
        thenOnComputer {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            assertEquals(false, callPeripheral(modem, "isInterdimensional")!![0])

            callPeripheral(modem, "transmit", 1, 1, "x".repeat(1000))
            try {
                callPeripheral(modem, "transmit", 1, 1, "x".repeat(100_000))
                throw AssertionError("A 100 KB message should be refused")
            } catch (e: LuaException) {
                assertEquals("Message too large (at most 65536 bytes)", e.message)
            }
        }
    }

    /**
     * Sends a high band message between two computers set into a thick stone ceiling, with their modems hanging
     * underneath. The computers are buried, but the modems can see each other, so the message should get through.
     */
    @GameTest
    fun Ceiling_modems_see_each_other(context: GameTestHelper) = context.sequence {
        thenStartComputer("send") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            while (true) {
                callPeripheral(modem, "transmit", 2000, 34, "Hello")
                sleep(50.milliseconds)
            }
        }
        thenOnComputer("receive") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            callPeripheral(modem, "open", 2000)

            val event = pullEvent("modem_message")
            assertEquals("Hello", event[4])

            // Nothing but air between the modems, so the signal should be strong (around -70dBm).
            val signal = (event[6] as Number).toDouble()
            if (signal <= -85) throw AssertionError("Signal is too weak: $signal")
        }
    }

    /**
     * Assert that full block modems act like cables.
     *
     * @see [#1278](https://github.com/cc-tweaked/CC-Tweaked/issues/1278)
     */
    @GameTest(setupTicks = 1)
    fun Full_modems_form_networks(helper: GameTestHelper) = helper.sequence {
        thenExecute {
            val modem1 = helper.getBlockEntity(BlockPos(1, 1, 1), WiredModemFullBlockEntity::class.java)
            val modem2 = helper.getBlockEntity(BlockPos(3, 1, 1), WiredModemFullBlockEntity::class.java)
            assertEquals((modem1.element.node as WiredNodeImpl).network, (modem2.element.node as WiredNodeImpl).network, "On the same network")
        }
    }

    /**
     * Modems do not include the current peripheral when attached.
     */
    @GameTest
    fun Cable_modem_does_not_report_self(helper: GameTestHelper) = helper.sequence {
        // Modem does not report the computer as a peripheral.
        thenOnComputer { assertEquals(listOf("back", "right"), getPeripheralNames()) }

        // However, if we connect the network, the other modem does.
        thenExecute {
            helper.setBlock(
                BlockPos(1, 1, 3),
                ModRegistry.Blocks.CABLE.get().defaultBlockState().setValue(CableBlock.CABLE, true),
            )
        }
        thenIdle(2)
        thenOnComputer { assertEquals(listOf("back", "computer_0", "right"), getPeripheralNames()) }
    }

    /**
     * Modems do not include the current peripheral when attached.
     */
    @GameTest
    fun Full_block_modem_does_not_report_self(helper: GameTestHelper) = helper.sequence {
        // Modem does not report the computer as a peripheral.
        thenOnComputer { assertEquals(listOf("back", "right"), getPeripheralNames()) }

        // However, if we connect the network, the other modem does.
        thenExecute {
            helper.setBlock(
                BlockPos(1, 1, 3),
                ModRegistry.Blocks.CABLE.get().defaultBlockState().setValue(CableBlock.CABLE, true),
            )
        }
        thenIdle(2)
        thenOnComputer { assertEquals(listOf("back", "computer_1", "right"), getPeripheralNames()) }
    }

    /**
     * Test wired modems (without a cable) drop an item when the adjacent block is removed.
     */
    @GameTest
    fun Modem_drops_when_neighbour_removed(helper: GameTestHelper) = helper.sequence {
        thenExecute {
            helper.setBlock(BlockPos(2, 2, 2), Blocks.AIR)
            helper.assertItemEntityPresent(ModRegistry.Items.WIRED_MODEM.get(), BlockPos(2, 1, 2), 0.0)
            helper.assertBlockPresent(Blocks.AIR, BlockPos(2, 1, 2))
        }
    }

    /**
     * Test wired modems (with a cable) drop an item, but keep their cable when the adjacent block is removed.
     */
    @GameTest
    fun Modem_keeps_cable_when_neighbour_removed(helper: GameTestHelper) = helper.sequence {
        thenExecute {
            helper.setBlock(BlockPos(2, 2, 2), Blocks.AIR)
            helper.assertItemEntityPresent(ModRegistry.Items.WIRED_MODEM.get(), BlockPos(2, 1, 2), 0.0)
            helper.assertBlockIs(BlockPos(2, 1, 2)) {
                it.block == ModRegistry.Blocks.CABLE.get() && it.getValue(CableBlock.MODEM) == CableModemVariant.None && it.getValue(CableBlock.CABLE)
            }
        }
    }

    /**
     * Check chest peripherals are reattached with a new size.
     */
    @GameTest
    fun Chest_resizes_on_change(context: GameTestHelper) = context.sequence {
        thenOnComputer {
            callRemotePeripheral("minecraft:chest_0", "size").assertArrayEquals(27)
        }
        thenExecute { context.placeItemAt(ItemStack(Items.CHEST), BlockPos(2, 1, 2), Direction.WEST) }
        thenIdle(1)
        thenOnComputer {
            callRemotePeripheral("minecraft:chest_0", "size").assertArrayEquals(54)
        }
    }
}

private fun LuaTaskContext.findPeripheral(type: String): String? {
    val peripheral = getApi<PeripheralAPI>()
    for (side in ComputerSide.NAMES) {
        val hasType = peripheral.hasType(side, type)
        if (hasType != null && hasType[0] == true) return side
    }

    return null
}

private suspend fun LuaTaskContext.getPeripheralNames(): List<String> {
    val peripheral = getApi<PeripheralAPI>()
    val peripherals = mutableListOf<String>()
    for (side in ComputerSide.NAMES) {
        if (!peripheral.isPresent(side)) continue
        peripherals.add(side)

        val hasType = peripheral.hasType(side, "peripheral_hub")
        if (hasType == null || hasType[0] != true) continue

        val names = peripheral.call(context, ObjectArguments(side, "getNamesRemote")).await() ?: continue
        @Suppress("UNCHECKED_CAST")
        peripherals.addAll(names[0] as Collection<String>)
    }

    peripherals.sort()
    return peripherals
}

private suspend fun LuaTaskContext.callRemotePeripheral(name: String, method: String, vararg args: Any): Array<out Any?>? {
    val peripheral = getApi<PeripheralAPI>()
    if (peripheral.isPresent(name)) return peripheral.call(context, ObjectArguments(name, method, *args)).await()

    for (side in ComputerSide.NAMES) {
        if (!peripheral.isPresent(side)) continue

        val hasType = peripheral.hasType(side, "peripheral_hub")
        if (hasType == null || hasType[0] != true) continue

        val isPresent = peripheral.call(context, ObjectArguments(side, "isPresentRemote", name)).await() ?: continue
        if (isPresent[0] as Boolean) {
            return peripheral.call(context, ObjectArguments(side, "callRemote", name, method, *args)).await()
        }
    }

    throw IllegalArgumentException("No such peripheral $name")
}
