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
import dan200.computercraft.shared.util.WirelessHelpers;
import net.minecraft.core.Vec3i;
import net.minecraft.util.Tuple;

import java.util.HashMap;

public abstract class WirelessModemPeripheral extends ModemPeripheral {
    public static final String NORMAL_ADJECTIVE = "upgrade.computercraft.wireless_modem_normal.adjective";
    public static final String ADVANCED_ADJECTIVE = "upgrade.computercraft.wireless_modem_advanced.adjective";

    private final boolean advanced;
    private HashMap<Vec3i, HashMap<Vec3i, Tuple<Double, Long>>> cachedSignalStrengths = new HashMap<>();

    public Long lastLFTransmit = 0L;
    public Long lastMFTransmit = 0L;

    public WirelessModemPeripheral(ModemState state, boolean advanced) {
        super(state);
        this.advanced = advanced;
    }

    @Override
    public boolean isInterdimensional() {
        return advanced;
    }

    @Override
    public double getRange() {
        if (advanced) {
            return Integer.MAX_VALUE;
        } else {
            var world = getLevel();
            if (world != null) {
                double range = Config.modemRange;
                if (world.isRaining() && world.isThundering()) {
                    range = Config.modemRangeDuringStorm;
                }
                return range;
            }
            return 0.0;
        }
    }

    @Override
    protected PacketNetwork getNetwork() {
        return ComputerCraftAPI.getWirelessNetwork(Nullability.assertNonNull(getLevel().getServer()));
    }

    public double getCachedSignalDegradation(Vec3i receiverPos) {
        var senderPos = WirelessHelpers.floorToVec3i(getPosition());
        var senderCachedSignals = cachedSignalStrengths.get(senderPos);
        if (senderCachedSignals != null) {
            var receiverCachedSignal = senderCachedSignals.get(receiverPos);
            if (receiverCachedSignal != null) {
                double signalDegradation = receiverCachedSignal.getA();
                Long expiration = receiverCachedSignal.getB();
                if (getLevel().getDayTime() < expiration) {
                    return signalDegradation;
                }
                // Remove invalidated caches
                senderCachedSignals.remove(receiverPos);
                if (senderCachedSignals.isEmpty()) {
                    cachedSignalStrengths.remove(senderPos);
                }
            }
        }
        return Integer.MAX_VALUE;
    }

    public void addCachedSignalDegradation(Vec3i receiverPos, double signalDegradation) {
        // Prevent overflow the lazy way
        if (cachedSignalStrengths.size() > 2000) {
            cachedSignalStrengths.clear();
        }

        var senderPos = WirelessHelpers.floorToVec3i(getPosition());
        var expiration = getLevel().getDayTime() + 2400;
        if (cachedSignalStrengths.containsKey(senderPos)) {
            cachedSignalStrengths.get(senderPos).put(receiverPos, new Tuple<>(signalDegradation, expiration));
            return;
        }
        var senderCachedSignals = new HashMap<Vec3i, Tuple<Double, Long>>();
        senderCachedSignals.put(receiverPos, new Tuple<>(signalDegradation, expiration));
        cachedSignalStrengths.put(senderPos, senderCachedSignals);
    }
}
