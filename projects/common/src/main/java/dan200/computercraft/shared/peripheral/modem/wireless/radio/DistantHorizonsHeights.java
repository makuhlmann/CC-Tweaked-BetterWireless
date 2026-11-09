// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.shared.platform.PlatformHelper;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Optional support for reading terrain heights from Distant Horizons.
 * <p>
 * This class must not reference the DH API itself, so that it can be loaded when DH isn't installed.
 *
 * @see DistantHorizonsHeightSource
 */
final class DistantHorizonsHeights {
    private static final Logger LOG = LoggerFactory.getLogger(DistantHorizonsHeights.class);
    private static final String MOD_ID = "distanthorizons";

    private static boolean checked;
    private static @Nullable HeightSource instance;

    private DistantHorizonsHeights() {
    }

    /**
     * Get the Distant Horizons height source, if DH is installed.
     *
     * @return The height source, or {@code null} if DH is not available.
     */
    static synchronized @Nullable HeightSource get() {
        if (checked) return instance;
        checked = true;

        try {
            if (PlatformHelper.get().isModLoaded(MOD_ID)) instance = new DistantHorizonsHeightSource();
        } catch (LinkageError | RuntimeException e) {
            LOG.warn("Distant Horizons is installed, but its API could not be loaded. Radio propagation will not use LODs.", e);
        }
        return instance;
    }
}
