// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

/**
 * The result of evaluating a single radio link.
 *
 * @param loss        The total path loss, in dB: the direct path (through or over, whichever is better), together with
 *                    any paths reflected off walls near either end, their powers added.
 * @param baseLoss    Loss from distance alone (free space, or two-ray ground reflection), in dB.
 * @param through     Extra loss for the signal travelling straight through any obstructions, in dB.
 * @param over        Extra loss for the signal escaping any enclosure near the antennas and diffracting over the
 *                    terrain, in dB.
 * @param diffraction The diffraction part of {@code over}, in dB.
 * @param reflected   The loss of the paths reflected off walls near either end, together, in dB, or infinity if there
 *                    are none.
 */
public record LinkResult(double loss, double baseLoss, double through, double over, double diffraction, double reflected) {
    /**
     * Whether the signal took the path over the terrain rather than straight through it.
     *
     * @return Whether the over-the-terrain path won.
     */
    public boolean diffracted() {
        return over < through;
    }

    /**
     * Whether reflections off walls bring in more of the signal than the direct path does.
     *
     * @return Whether they do.
     */
    public boolean reflectionsWin() {
        return reflected < baseLoss + Math.min(through, over);
    }
}
