// SPDX-FileCopyrightText: 2022 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.gametest

import dan200.computercraft.gametest.api.GameTest
import dan200.computercraft.gametest.api.Timeouts
import dan200.computercraft.gametest.api.sequence
import dan200.computercraft.gametest.api.thenComputerOk
import net.minecraft.gametest.framework.GameTestHelper

class CraftOs_Test {
    /**
     * Sends a rednet message to another a computer and back again.
     */
    @GameTest(timeoutTicks = Timeouts.COMPUTER_TIMEOUT)
    fun Sends_basic_rednet_messages(context: GameTestHelper) = context.sequence { thenComputerOk("main") }

    /**
     * Two computers with wireless modems ping each other with the network stack.
     */
    @GameTest(timeoutTicks = Timeouts.COMPUTER_TIMEOUT)
    fun Net_ping_wireless(context: GameTestHelper) = context.sequence { thenComputerOk("main") }

    /**
     * Two computers on a cable ping each other with the network stack.
     */
    @GameTest(timeoutTicks = Timeouts.COMPUTER_TIMEOUT)
    fun Net_ping_wired(context: GameTestHelper) = context.sequence { thenComputerOk("main") }
}
