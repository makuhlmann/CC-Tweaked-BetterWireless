// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

/**
 * A group of channels which share a frequency and link budget.
 *
 * @param id           A small identifier for this band, used in cache keys.
 * @param frequencyMHz The carrier frequency, in MHz.
 * @param linkBudget   The maximum path loss a link can have before the receiver can no longer decode it, in dB. This
 *                     is transmit power plus antenna gains, minus receiver sensitivity.
 */
public record RadioBand(int id, double frequencyMHz, double linkBudget) {
    /**
     * The nominal sensitivity of a receiver, in dBm. This only affects the signal strength we report to computers: the
     * link budget decides whether a message is received.
     */
    public static final double SENSITIVITY = -100;

    /**
     * The effective radiated power of a transmitter on this band.
     *
     * @return The radiated power, in dBm.
     */
    public double transmitPower() {
        return SENSITIVITY + linkBudget;
    }
}
