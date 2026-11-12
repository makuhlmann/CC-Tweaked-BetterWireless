// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.peripheral.modem.wireless;

import dan200.computercraft.api.ComputerCraftAPI;
import dan200.computercraft.api.network.PacketNetwork;
import dan200.computercraft.core.util.Nullability;
import dan200.computercraft.shared.config.Config;
import dan200.computercraft.shared.peripheral.modem.ModemPeripheral;
import dan200.computercraft.shared.peripheral.modem.ModemState;
import dan200.computercraft.shared.peripheral.modem.wireless.radio.RadioAntenna;

public abstract class WirelessModemPeripheral extends ModemPeripheral implements RadioAntenna {
    public static final String NORMAL_ADJECTIVE = "upgrade.computercraft.wireless_modem_normal.adjective";
    public static final String ADVANCED_ADJECTIVE = "upgrade.computercraft.wireless_modem_advanced.adjective";

    private final boolean advanced;

    public WirelessModemPeripheral(ModemState state, boolean advanced) {
        super(state);
        this.advanced = advanced;
    }

    @Override
    public boolean isInterdimensional() {
        return advanced;
    }

    /**
     * How much weaker this modem transmits for being an ender modem, in dB. Devices which are weaker themselves add
     * this to their own offset.
     *
     * @return The offset, which is zero for wireless modems.
     */
    protected final double getEnderTransmitOffset() {
        return advanced ? Config.radioEnderPowerOffset : 0;
    }

    @Override
    public double getTransmitOffset() {
        return getEnderTransmitOffset();
    }

    @Override
    public double getRange() {
        if (Config.radioEnabled) {
            // Range is decided by the propagation model, for ender modems too; this is just an upper bound.
            return Config.radioMaxRange;
        } else if (advanced) {
            return Integer.MAX_VALUE;
        } else {
            var world = getLevel();
            if (world != null) {
                var position = getPosition();
                double minRange = Config.modemRange;
                double maxRange = Config.modemHighAltitudeRange;
                if (world.isRaining() && world.isThundering()) {
                    minRange = Config.modemRangeDuringStorm;
                    maxRange = Config.modemHighAltitudeRangeDuringStorm;
                }
                if (position.y > 96.0 && maxRange > minRange) {
                    return minRange + (position.y - 96.0) * ((maxRange - minRange) / (world.getMaxY() - 96.0));
                }
                return minRange;
            }
            return 0.0;
        }
    }

    @Override
    protected PacketNetwork getNetwork() {
        return ComputerCraftAPI.getWirelessNetwork(Nullability.assertNonNull(getLevel().getServer()));
    }
}
