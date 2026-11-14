// SPDX-FileCopyrightText: 2017 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.api.network;

import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;


/**
 * An object on a {@link PacketNetwork}, capable of sending packets.
 */
public interface PacketSender {
    /**
     * Get the world in which this packet sender exists.
     *
     * @return The sender's world.
     */
    Level getLevel();

    /**
     * Get the position in the world at which this sender exists.
     *
     * @return The sender's position.
     */
    Vec3 getPosition();

    /**
     * Get some sort of identification string for this sender. This does not strictly need to be unique, but you
     * should be able to extract some identifiable information from it.
     *
     * @return This device's id.
     */
    String getSenderID();

    /**
     * The power this device transmits with, in dBm. When radio propagation is simulated, a receiver hears a packet if
     * this, less the loss along the way, is above what the receiver can hear.
     * <p>
     * Wireless modems' power can be set by programs, up to a limit for each kind of device (pocket computers' is lower
     * than placed computers', say). Ender modems transmit with less power than they're set to.
     *
     * @return The power, in dBm, or {@link Double#NaN} to use the server's default for wireless modems on placed
     * computers. More than the server allows any device is treated as that.
     */
    default double getTransmitPower() {
        return Double.NaN;
    }
}
