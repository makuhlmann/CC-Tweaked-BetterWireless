// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.world.phys.Vec3;

/**
 * A device with a radio antenna.
 * <p>
 * A modem reports the position of the block it is attached to (or of the turtle it is on), so that the distances
 * passed to {@code modem_message} events, and so GPS, line up with block coordinates. That position is no good for the
 * propagation model, though: a computer set into a wall or ceiling would transmit from inside the rock around it, even
 * though its modem hangs out in the open. Devices implementing this interface say where their antenna actually is.
 */
public interface RadioAntenna {
    /**
     * Get the position of this device's antenna. This may be called from any thread.
     *
     * @return The antenna's position.
     */
    Vec3 getAntennaPosition();

    /**
     * Find where a device's antenna is.
     *
     * @param device   The device.
     * @param position The device's position, as reported by its {@code getPosition()}.
     * @return The antenna's position.
     */
    static Vec3 of(Object device, Vec3 position) {
        // Devices which don't say are assumed to have their antenna half a block above their position.
        return device instanceof RadioAntenna antenna ? antenna.getAntennaPosition() : position.add(0, 0.5, 0);
    }
}
