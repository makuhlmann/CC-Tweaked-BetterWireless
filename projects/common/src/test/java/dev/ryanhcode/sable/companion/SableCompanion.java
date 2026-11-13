// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dev.ryanhcode.sable.companion;

import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;

/**
 * A stand-in for Sable Companion's entry point, with the same name, instance field and method that
 * {@link dan200.computercraft.shared.integration.Sable} looks up. Its one plot is the 16x16 column at the origin, whose
 * object sits {@link #OFFSET} away in the world.
 */
public interface SableCompanion {
    SableCompanion INSTANCE = new SableCompanion() {
    };

    Vec3 OFFSET = new Vec3(1000, 64, -2000);

    default Vec3 projectOutOfSubLevel(Level level, Vec3 position) {
        var inPlot = position.x >= 0 && position.x < 16 && position.z >= 0 && position.z < 16;
        return inPlot ? position.add(OFFSET) : position;
    }
}
