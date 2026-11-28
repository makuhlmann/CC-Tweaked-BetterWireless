// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.peripheral.modem.wireless;

import dan200.computercraft.api.ComputerCraftAPI;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.api.network.PacketNetwork;
import dan200.computercraft.core.util.Nullability;
import dan200.computercraft.shared.config.Config;
import dan200.computercraft.shared.peripheral.modem.ModemPeripheral;
import dan200.computercraft.shared.peripheral.modem.ModemState;
import dan200.computercraft.shared.peripheral.modem.wireless.radio.RadioAntenna;
import dan200.computercraft.shared.peripheral.modem.wireless.radio.RadioSettings;

import java.util.Optional;

public abstract class WirelessModemPeripheral extends ModemPeripheral implements RadioAntenna {
    public static final String NORMAL_ADJECTIVE = "upgrade.computercraft.wireless_modem_normal.adjective";
    public static final String ADVANCED_ADJECTIVE = "upgrade.computercraft.wireless_modem_advanced.adjective";

    /** The least power a modem may be set to transmit with, in dBm: a microwatt. */
    public static final double MIN_TRANSMIT_POWER = -30;

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
     * The power this kind of device transmits with unless a program sets another.
     *
     * @return The power, in dBm.
     */
    protected double getDefaultTransmitPower() {
        return Config.radioTransmitPower;
    }

    /**
     * The most power a program may set this kind of device to transmit with.
     *
     * @return The power, in dBm.
     */
    protected double getMaxTransmitPower() {
        return Config.radioMaxTransmitPower;
    }

    /**
     * The power this modem is set to transmit with: what a program set, or the default, within what this kind of
     * device allows.
     *
     * @return The power, in dBm.
     */
    private double getSetTransmitPower() {
        var power = getModemState().getTransmitPower();
        if (Double.isNaN(power)) power = getDefaultTransmitPower();
        return Math.clamp(power, MIN_TRANSMIT_POWER, Math.max(MIN_TRANSMIT_POWER, getMaxTransmitPower()));
    }

    @Override
    public double getTransmitPower() {
        // Ender modems radiate less of their power than wireless modems.
        return getSetTransmitPower() + (advanced ? Config.radioEnderPowerOffset : 0);
    }

    /**
     * Set the power this modem transmits with, in dBm (decibels relative to a milliwatt). More power reaches further:
     * every 6 dB more roughly doubles the range over open ground, though walls and hills still cost what they cost.
     * <p>
     * Each kind of device has a limit: pocket computers' is lower than placed computers', for instance. Power beyond
     * the limit is reduced to it. The power lasts until it's set again, or the modem is removed or its chunk unloads.
     * Without a power, the modem goes back to its default.
     * <p>
     * Ender modems transmit with less power than they're set to.
     *
     * @param power The power, in dBm, or {@code nil} for the modem's default: about 8 dBm for a placed computer's.
     * @return The power the modem now transmits with, in dBm, once reduced to the limit.
     * @throws LuaException If the power isn't a number.
     * @cc.usage Transmit with as much power as this modem allows.
     *
     * <pre>{@code
     * local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
     * modem.setTransmitPower(math.huge)
     * }</pre>
     */
    @LuaFunction
    public final double setTransmitPower(Optional<Double> power) throws LuaException {
        if (power.isEmpty()) {
            getModemState().setTransmitPower(Double.NaN);
            return getSetTransmitPower();
        }
        if (Double.isNaN(power.get())) throw new LuaException("Expected a number");
        var set = Math.clamp(power.get(), MIN_TRANSMIT_POWER, Math.max(MIN_TRANSMIT_POWER, getMaxTransmitPower()));
        getModemState().setTransmitPower(set);
        return set;
    }

    /**
     * Get the power this modem transmits with, and the most and least it may be set to.
     *
     * @return The power, in dBm, and the limits for this kind of device, in dBm.
     * @cc.treturn number The power, in dBm.
     * @cc.treturn number The most power this modem may be set to, in dBm.
     * @cc.treturn number The least power this modem may be set to, in dBm.
     */
    @LuaFunction("getTransmitPower")
    public final Object[] getTransmitPowerForLua() {
        return new Object[]{ getSetTransmitPower(), Math.max(MIN_TRANSMIT_POWER, getMaxTransmitPower()), MIN_TRANSMIT_POWER };
    }

    /**
     * Get the weakest signal this modem can hear, in dBm. Pocket computers' and turtles' modems hear less than placed
     * computers': they need a stronger signal. While a thunderstorm rages, every modem needs a signal stronger still.
     *
     * @return The weakest signal it hears, in dBm.
     * @cc.usage Say how much stronger than it needs to be a message arrived.
     *
     * <pre>{@code
     * local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
     * modem.open(123)
     * local _, _, _, _, _, _, signal = os.pullEvent("modem_message")
     * print(("%.1f dB to spare"):format(signal - modem.getSensitivity()))
     * }</pre>
     */
    @LuaFunction
    public final double getSensitivity() {
        return RadioSettings.sensitivity(this);
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
