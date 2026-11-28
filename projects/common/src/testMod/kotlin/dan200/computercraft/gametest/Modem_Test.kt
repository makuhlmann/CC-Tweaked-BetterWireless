// SPDX-FileCopyrightText: 2022 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.gametest

import dan200.computercraft.api.ComputerCraftAPI
import dan200.computercraft.api.lua.LuaException
import dan200.computercraft.api.lua.ObjectArguments
import dan200.computercraft.api.network.Packet
import dan200.computercraft.api.network.PacketReceiver
import dan200.computercraft.api.network.PacketSender
import dan200.computercraft.core.apis.PeripheralAPI
import dan200.computercraft.core.computer.ComputerSide
import dan200.computercraft.gametest.api.*
import dan200.computercraft.gametest.api.GameTest
import dan200.computercraft.impl.network.wired.WiredNodeImpl
import dan200.computercraft.shared.ModRegistry
import dan200.computercraft.shared.config.Config
import dan200.computercraft.shared.peripheral.modem.wired.CableBlock
import dan200.computercraft.shared.peripheral.modem.wired.CableModemVariant
import dan200.computercraft.shared.peripheral.modem.wired.WiredModemFullBlockEntity
import dan200.computercraft.shared.peripheral.modem.wireless.radio.BlockRadioProperties
import dan200.computercraft.shared.peripheral.modem.wireless.radio.DimensionMapping
import dan200.computercraft.shared.peripheral.modem.wireless.radio.RadioSettings
import dan200.computercraft.test.core.assertArrayEquals
import dan200.computercraft.test.core.computer.LuaTaskContext
import dan200.computercraft.test.core.computer.getApi
import net.minecraft.core.BlockPos
import net.minecraft.core.Direction
import net.minecraft.gametest.framework.GameTestHelper
import net.minecraft.world.item.ItemStack
import net.minecraft.world.item.Items
import net.minecraft.world.level.Level
import net.minecraft.world.level.block.Block
import net.minecraft.world.level.block.Blocks
import net.minecraft.world.phys.Vec3
import org.junit.jupiter.api.Assertions.assertEquals
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration.Companion.milliseconds

class Modem_Test {
    /**
     * Blocks people build with lose less than natural terrain: stone as the world generates it is natural (which takes
     * the world's tags), while cobblestone, stone bricks and planks are built.
     */
    @GameTest(template = Structures.DEFAULT)
    fun Built_blocks_are_told_from_terrain(helper: GameTestHelper) = helper.sequence {
        thenExecute {
            fun built(block: Block) = BlockRadioProperties.get(block.defaultBlockState()).built()
            for (block in listOf(
                Blocks.STONE, Blocks.DEEPSLATE, Blocks.GRANITE, Blocks.TUFF, Blocks.NETHERRACK, Blocks.DIRT, Blocks.SAND,
                Blocks.GRAVEL, Blocks.IRON_ORE, Blocks.DIAMOND_ORE, Blocks.SANDSTONE, Blocks.TERRACOTTA, Blocks.OAK_LEAVES,
            )) {
                if (built(block)) throw AssertionError("$block should be natural terrain")
            }
            for (block in listOf(
                Blocks.COBBLESTONE, Blocks.STONE_BRICKS, Blocks.POLISHED_ANDESITE, Blocks.OAK_PLANKS, Blocks.OAK_LOG,
                Blocks.BRICKS, Blocks.GLASS, Blocks.IRON_BLOCK,
            )) {
                if (!built(block)) throw AssertionError("$block should be built")
            }
        }
    }

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

            // Channel 12 is the lowest frequency there is, which loses little over a block or two, so the signal may
            // be above 0 dBm. It's never stronger than it was sent with.
            val signal = (event[6] as Number).toDouble()
            if (signal <= -100 || signal > Config.radioTransmitPower) throw AssertionError("Unexpected signal strength $signal")
        }
    }

    /**
     * Wireless modems refuse messages over the size limit, say they aren't ender modems, and transmit with the power
     * programs set them to, within their limit.
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

            // Programs set the power, within the limit for placed computers.
            suspend fun power() = callPeripheral(modem, "getTransmitPower")!!.map { (it as Number).toDouble() }
            assertEquals(listOf(Config.radioTransmitPower, Config.radioMaxTransmitPower, -30.0), power())
            assertEquals(Config.radioMaxTransmitPower, (callPeripheral(modem, "setTransmitPower", 1000)!![0] as Number).toDouble())
            assertEquals(listOf(Config.radioMaxTransmitPower, Config.radioMaxTransmitPower, -30.0), power())
            assertEquals(-30.0, (callPeripheral(modem, "setTransmitPower", -1000)!![0] as Number).toDouble())
            assertEquals(12.5, (callPeripheral(modem, "setTransmitPower", 12.5)!![0] as Number).toDouble())
            assertEquals(12.5, power()[0])
            // And back to the default, given none.
            assertEquals(Config.radioTransmitPower, (callPeripheral(modem, "setTransmitPower")!![0] as Number).toDouble())
            assertEquals(listOf(Config.radioTransmitPower, Config.radioMaxTransmitPower, -30.0), power())

            // And hear as weak a signal as any modem.
            assertEquals(RadioSettings.SENSITIVITY, (callPeripheral(modem, "getSensitivity")!![0] as Number).toDouble())
        }
    }

    /**
     * Ender modems are radios too, if weaker ones, whose signal also appears at the corresponding place in other
     * dimensions, where only other ender modems hear it.
     */
    @GameTest(template = Structures.DEFAULT, timeoutTicks = Timeouts.SECOND * 15)
    fun Ender_signals_cross_dimensions(helper: GameTestHelper) = helper.sequence {
        class Heard(val message: Any?, val distance: Double?, val signal: Double?)

        class Sender(private val level: Level, private val position: Vec3, private val power: Double) : PacketSender {
            override fun getLevel(): Level = level
            override fun getPosition(): Vec3 = position
            override fun getSenderID(): String = "test"
            override fun getTransmitPower(): Double = power
        }

        class Receiver(private val level: Level, private val position: Vec3, private val ender: Boolean) : PacketReceiver {
            val heard = CopyOnWriteArrayList<Heard>()
            override fun getLevel(): Level = level
            override fun getPosition(): Vec3 = position
            override fun getRange(): Double = 0.0
            override fun isInterdimensional(): Boolean = ender

            // Other tests' computers are on the air too: only this test's packets count.
            private fun hear(packet: Packet, distance: Double?, signal: Double?) {
                if (packet.sender is Sender) heard.add(Heard(packet.payload, distance, signal))
            }

            override fun receiveSameDimension(packet: Packet, distance: Double) = hear(packet, distance, null)
            override fun receiveSameDimension(packet: Packet, distance: Double, signalStrength: Double) = hear(packet, distance, signalStrength)
            override fun receiveDifferentDimension(packet: Packet) = hear(packet, null, null)
            override fun receiveDifferentDimension(packet: Packet, signalStrength: Double) = hear(packet, null, signalStrength)

            fun messages() = heard.map { it.message }
        }

        val server = helper.level.server
        val network = ComputerCraftAPI.getWirelessNetwork(server)
        val overworld = helper.level
        val nether = server.getLevel(Level.NETHER) ?: throw IllegalStateException("There's no Nether")

        // Somewhere in the test, and the place in the Nether which corresponds to it.
        val here = Vec3.atCenterOf(helper.absolutePos(BlockPos(2, 3, 2)))
        val there = DimensionMapping.map(here, overworld, nether, Config.radioEnderYRanges)
        assertEquals(here.x / 8, there.x, 1e-6, "The Nether is an eighth of the size")
        assertEquals(here.z / 8, there.z, 1e-6, "The Nether is an eighth of the size")

        val beside = Receiver(overworld, here.add(0.0, 2.0, 0.0), false)
        val across = Receiver(nether, there, true)
        val acrossWireless = Receiver(nether, there, false)
        // Too far whichever way: 2,000 blocks of the Nether we know nothing of, or 16,000 across the Overworld.
        val acrossFar = Receiver(nether, there.add(2000.0, 0.0, 0.0), true)
        val receivers = listOf(beside, across, acrossWireless, acrossFar)
        val ender = Sender(overworld, here, Config.radioTransmitPower + Config.radioEnderPowerOffset)
        val wireless = Sender(overworld, here, Config.radioTransmitPower)

        thenExecute {
            for (receiver in receivers) network.addReceiver(receiver)
            // As ender and wireless modems send them.
            // On channel 1500, 150MHz.
            network.transmitInterdimensional(Packet(1500, 1500, "ender", ender))
            network.transmitSameDimension(Packet(1500, 1500, "wireless", wireless), 64.0)
        }
        // The link through the Nether crosses chunks which aren't loaded, whose heights are looked up first.
        thenWaitUntil {
            if (across.heard.isEmpty() || beside.heard.size < 2) helper.fail("Nothing heard yet")
        }
        thenIdle(60)
        thenExecute {
            for (receiver in receivers) network.removeReceiver(receiver)

            // A receiver in the same dimension hears both, the ender modem 10 dB weaker.
            assertEquals(setOf("ender", "wireless"), beside.messages().toSet())
            val enderSignal = beside.heard.first { it.message == "ender" }.signal!!
            val wirelessSignal = beside.heard.first { it.message == "wireless" }.signal!!
            assertEquals(-Config.radioEnderPowerOffset, wirelessSignal - enderSignal, 0.11, "Ender modems are weaker")

            // In the Nether, only the ender modem hears, only the ender modem, and only where its signal appears.
            assertEquals(listOf("ender"), across.messages())
            assertEquals(null, across.heard[0].distance, "There's no distance between dimensions")
            val signal = across.heard[0].signal ?: throw AssertionError("There should be a signal strength")
            if (signal <= -100 || signal >= 0) throw AssertionError("Unexpected signal strength $signal")
            assertEquals(listOf<Any?>(), acrossWireless.messages())
            assertEquals(listOf<Any?>(), acrossFar.messages())
        }
    }

    /**
     * A packet over a link which was traced a moment ago is delivered at once, on the thread which sent it, while one
     * over a new link waits for the server thread. A sender's packets wait behind any it has still waiting, so they
     * arrive in the order it sent them.
     */
    @GameTest(template = Structures.DEFAULT, timeoutTicks = Timeouts.SECOND * 15)
    fun Cached_links_deliver_at_once(helper: GameTestHelper) = helper.sequence {
        class Sender(private val level: Level, private val position: Vec3) : PacketSender {
            override fun getLevel(): Level = level
            override fun getPosition(): Vec3 = position
            override fun getSenderID(): String = "test"
            override fun getTransmitPower(): Double = Config.radioTransmitPower
        }

        class Receiver(private val level: Level, private val position: Vec3, private val from: Sender) : PacketReceiver {
            val heard = CopyOnWriteArrayList<Any?>()
            override fun getLevel(): Level = level
            override fun getPosition(): Vec3 = position
            override fun getRange(): Double = 0.0
            override fun isInterdimensional(): Boolean = false

            // Other tests' computers are on the air too: only this test's packets count.
            private fun hear(packet: Packet) {
                if (packet.sender === from) heard.add(packet.payload)
            }

            override fun receiveSameDimension(packet: Packet, distance: Double) = hear(packet)
            override fun receiveSameDimension(packet: Packet, distance: Double, signalStrength: Double) = hear(packet)
            override fun receiveDifferentDimension(packet: Packet) = Unit
        }

        val network = ComputerCraftAPI.getWirelessNetwork(helper.level.server)
        fun at(x: Int, z: Int) = Vec3.atCenterOf(helper.absolutePos(BlockPos(x, 3, z)))
        val sender = Sender(helper.level, at(1, 1))
        val near = Receiver(helper.level, at(3, 3), sender)
        val other = Receiver(helper.level, at(4, 1), sender)
        fun send(message: String) = network.transmitSameDimension(Packet(1500, 1500, message, sender), 64.0)

        thenExecute {
            network.addReceiver(near)
            send("first")
            assertEquals(listOf<Any?>(), near.heard, "A new link waits for the server thread")
        }
        thenWaitUntil { if (near.heard.isEmpty()) helper.fail("Nothing heard yet") }

        // What each receiver had heard after each packet below.
        val seen = mutableListOf<List<Any?>>()
        thenWaitUntil {
            // Other tests' receivers may be in range too, and while one's link is new, the sender's packets wait behind
            // the one queued for it. Two packets in a row going at once say nothing is queued, and every link is
            // cached, for the rest of this tick: the cache goes by ticks.
            val before = near.heard.size
            send("probe")
            send("probe")
            if (near.heard.size != before + 2) helper.fail("The sender still has packets waiting")

            near.heard.clear()
            send("second")
            seen.add(near.heard.toList())

            // The new receiver's link waits, while the first's goes at once.
            network.addReceiver(other)
            send("third")
            seen.add(near.heard.toList())
            seen.add(other.heard.toList())

            // Now the sender has a packet waiting, so this one waits behind it, even where its link is cached.
            send("fourth")
            seen.add(near.heard.toList())
        }
        thenExecute {
            assertEquals(listOf<Any?>("second"), seen[0], "A link traced a moment ago goes at once")
            assertEquals(listOf<Any?>("second", "third"), seen[1])
            assertEquals(listOf<Any?>(), seen[2], "A new link waits")
            assertEquals(listOf<Any?>("second", "third"), seen[3], "Packets wait behind those still waiting")
        }
        thenWaitUntil { if (near.heard.size < 3 || other.heard.size < 2) helper.fail("Not everything heard yet") }
        thenExecute {
            network.removeReceiver(near)
            network.removeReceiver(other)
            assertEquals(listOf<Any?>("second", "third", "fourth"), near.heard)
            assertEquals(listOf<Any?>("third", "fourth"), other.heard)
        }
    }

    /**
     * A link in use is traced again in the background before its cached path expires, so packets between two radios
     * which stay put keep going at once, rather than one every few seconds waiting for the server thread.
     */
    @GameTest(template = Structures.DEFAULT, timeoutTicks = Timeouts.SECOND * 20)
    fun Links_in_use_stay_cached(helper: GameTestHelper) = helper.sequence {
        // In the End's void, where no other test's radios are: a new link to one of those would hold this test's
        // packets up while it's traced.
        val end = helper.level.server.getLevel(Level.END) ?: throw IllegalStateException("There's no End")
        val chunkX = 504 shr 4
        val chunkZ = 504 shr 4

        class Sender : PacketSender {
            override fun getLevel(): Level = end
            override fun getPosition(): Vec3 = Vec3(504.5, 100.5, 504.5)
            override fun getSenderID(): String = "test"
            override fun getTransmitPower(): Double = Config.radioTransmitPower
        }

        class Receiver(private val from: Sender) : PacketReceiver {
            val heard = CopyOnWriteArrayList<Any?>()
            override fun getLevel(): Level = end
            override fun getPosition(): Vec3 = Vec3(506.5, 100.5, 504.5)
            override fun getRange(): Double = 0.0
            override fun isInterdimensional(): Boolean = false

            private fun hear(packet: Packet) {
                if (packet.sender === from) heard.add(packet.payload)
            }

            override fun receiveSameDimension(packet: Packet, distance: Double) = hear(packet)
            override fun receiveSameDimension(packet: Packet, distance: Double, signalStrength: Double) = hear(packet)
            override fun receiveDifferentDimension(packet: Packet) = Unit
        }

        val network = ComputerCraftAPI.getWirelessNetwork(helper.level.server)
        val sender = Sender()
        val receiver = Receiver(sender)

        // Send a packet, and say whether it arrived at once.
        fun send(message: String): Boolean {
            val before = receiver.heard.size
            network.transmitSameDimension(Packet(31337, 31337, message, sender), 64.0)
            return receiver.heard.size == before + 1
        }

        thenExecute {
            // The chunk's terrain is known while it's loaded, so its links are cached for as long as links are.
            end.setChunkForced(chunkX, chunkZ, true)
            network.addReceiver(receiver)
            send("first")
        }
        // Once the link has been traced, packets over it go at once.
        thenWaitUntil { if (!send("probe")) helper.fail("The link hasn't been traced yet") }

        // For longer than a cached path lasts, a packet every few ticks.
        val late = mutableListOf<Int>()
        val sends = (minOf(Config.radioCacheTicks, 200) + 40) / 4
        for (i in 1..sends) {
            thenIdle(4)
            thenExecute { if (!send("packet $i")) late.add(i) }
        }
        thenExecute {
            network.removeReceiver(receiver)
            end.setChunkForced(chunkX, chunkZ, false)
            assertEquals(listOf<Int>(), late, "Packets which waited for the server thread")
        }
    }

    /**
     * Sends a 2.4GHz message between two computers set into a thick stone ceiling, with their modems hanging
     * underneath. The computers are buried, but the modems can see each other, so the message should get through.
     */
    @GameTest
    fun Ceiling_modems_see_each_other(context: GameTestHelper) = context.sequence {
        thenStartComputer("send") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            while (true) {
                callPeripheral(modem, "transmit", 24000, 34, "Hello")
                sleep(50.milliseconds)
            }
        }
        thenOnComputer("receive") {
            val modem = findPeripheral("modem") ?: throw IllegalStateException("Cannot find modem")
            callPeripheral(modem, "open", 24000)

            val event = pullEvent("modem_message")
            assertEquals("Hello", event[4])

            // Nothing but air between the modems, so the signal should be strong (around -50dBm).
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
