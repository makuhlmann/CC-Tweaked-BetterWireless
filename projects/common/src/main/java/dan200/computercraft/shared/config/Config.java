// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.config;

/**
 * ComputerCraft's global config.
 *
 * @see ConfigSpec The definition of our config values.
 */
public final class Config {
    public static int uploadMaxSize = 512 * 1024; // 512 KB
    public static boolean commandRequireCreative = true;
    public static boolean allowKeepLoaded = true;

    public static boolean enableCommandBlock = false;
    public static int modemRange = 64;
    public static int modemHighAltitudeRange = 384;
    public static int modemRangeDuringStorm = 64;
    public static int modemHighAltitudeRangeDuringStorm = 384;

    public static boolean radioEnabled = true;
    public static int radioReferenceRange = 1024;
    public static int radioMaxRange = 16384;
    public static int radioMaxMessageSize = 64 * 1024;
    public static double radioLowBandFrequency = 150;
    public static double radioHighBandFrequency = 2400;
    public static int radioHighBandFirstChannel = 1024;
    public static double radioHighBandBudgetOffset = -20;
    public static double radioMetresPerBlock = 1;
    public static double radioMetresPerBlockVertical = 1;
    public static double radioEarthRadius = 0;
    public static boolean radioGroundReflection = true;
    public static double radioMinAntennaHeight = 2;
    public static double radioMaterialLossScale = 1;
    public static int radioVoxelRadius = 64;
    public static int radioProfileSamples = 512;
    public static double radioStormPenalty = 6;
    public static int radioTickBudgetMicros = 2000;
    public static int radioCacheTicks = 100;
    public static int radioLookupTimeoutTicks = 40;
    public static boolean radioUseGenerator = true;
    public static boolean radioUseDistantHorizons = true;
    public static int maxNotesPerTick = 8;
    public static int monitorDistance = 65;
    public static long monitorBandwidth = 1_000_000;

    public static boolean turtlesNeedFuel = true;
    public static int turtleFuelLimit = 20000;
    public static int advancedTurtleFuelLimit = 100000;
    public static boolean turtlesCanPush = true;

    public static final int DEFAULT_COMPUTER_TERM_WIDTH = 51;
    public static final int DEFAULT_COMPUTER_TERM_HEIGHT = 19;

    public static final int TURTLE_TERM_WIDTH = 39;
    public static final int TURTLE_TERM_HEIGHT = 13;

    public static final int DEFAULT_POCKET_TERM_WIDTH = 26;
    public static final int DEFAULT_POCKET_TERM_HEIGHT = 20;

    public static int monitorWidth = 8;
    public static int monitorHeight = 6;

    public static int uploadNagDelay = 5;

    private Config() {
    }
}
