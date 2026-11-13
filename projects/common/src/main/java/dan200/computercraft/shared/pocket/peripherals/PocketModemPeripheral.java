// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.pocket.peripherals;

import dan200.computercraft.api.peripheral.IPeripheral;
import dan200.computercraft.api.pocket.IPocketAccess;
import dan200.computercraft.shared.config.Config;
import dan200.computercraft.shared.integration.Sable;
import dan200.computercraft.shared.peripheral.modem.ModemState;
import dan200.computercraft.shared.peripheral.modem.wireless.WirelessModemPeripheral;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;

public class PocketModemPeripheral extends WirelessModemPeripheral {
    private final IPocketAccess access;

    public PocketModemPeripheral(boolean advanced, IPocketAccess access) {
        super(new ModemState(), advanced);
        this.access = access;
    }

    @Override
    public Level getLevel() {
        return access.getLevel();
    }

    @Override
    public Vec3 getPosition() {
        // A lectern on a Sable object is in its far-off plot, so map it back to the world. Anyone holding the pocket
        // computer is already in the world.
        return Sable.toWorld(access.getLevel(), access.getPosition());
    }

    @Override
    public Vec3 getAntennaPosition() {
        // This is the holder's eyes, or the middle of a lectern, both of which are already a sensible place for it.
        return getPosition();
    }

    @Override
    public double getTransmitOffset() {
        return Config.radioPocketTransmitOffset + getEnderTransmitOffset();
    }

    @Override
    public double getReceiveOffset() {
        return Config.radioPocketReceiveOffset;
    }

    @Override
    public boolean equals(@Nullable IPeripheral other) {
        return other instanceof PocketModemPeripheral;
    }
}
