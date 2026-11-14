// SPDX-FileCopyrightText: 2018 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem;

import dan200.computercraft.api.lua.LuaException;
import it.unimi.dsi.fastutil.ints.IntOpenHashSet;
import it.unimi.dsi.fastutil.ints.IntSet;
import org.jspecify.annotations.Nullable;

import java.util.concurrent.atomic.AtomicBoolean;

public class ModemState {
    private final @Nullable Runnable onChanged;
    private final AtomicBoolean changed = new AtomicBoolean(true);

    private boolean open = false;
    private final IntSet channels = new IntOpenHashSet();

    /** The power a program set a wireless modem to transmit with, in dBm, or {@link Double#NaN} for its default. */
    private volatile double transmitPower = Double.NaN;

    public ModemState() {
        onChanged = null;
    }

    public ModemState(Runnable onChanged) {
        this.onChanged = onChanged;
    }

    private void setOpen(boolean open) {
        if (this.open == open) return;
        this.open = open;
        if (!changed.getAndSet(true) && onChanged != null) onChanged.run();
    }

    public boolean pollChanged() {
        return changed.getAndSet(false);
    }

    public boolean isOpen() {
        return open;
    }

    public boolean isOpen(int channel) {
        synchronized (channels) {
            return channels.contains(channel);
        }
    }

    public void open(int channel) throws LuaException {
        synchronized (channels) {
            if (!channels.contains(channel)) {
                if (channels.size() >= 128) throw new LuaException("Too many open channels");
                channels.add(channel);
                setOpen(true);
            }
        }
    }

    public void close(int channel) {
        synchronized (channels) {
            channels.remove(channel);
            if (channels.isEmpty()) setOpen(false);
        }
    }

    public void closeAll() {
        synchronized (channels) {
            channels.clear();
            setOpen(false);
        }
    }

    /**
     * Get the power a program set a wireless modem to transmit with.
     *
     * @return The power in dBm, or {@link Double#NaN} if none was set, and the modem uses its default.
     */
    public double getTransmitPower() {
        return transmitPower;
    }

    /**
     * Set the power a wireless modem transmits with.
     *
     * @param power The power in dBm, or {@link Double#NaN} to use the modem's default.
     */
    public void setTransmitPower(double power) {
        transmitPower = power;
    }
}
