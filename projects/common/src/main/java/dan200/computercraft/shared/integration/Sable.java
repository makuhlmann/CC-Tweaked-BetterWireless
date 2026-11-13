// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.integration;

import dan200.computercraft.shared.platform.PlatformHelper;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

/**
 * Support for <a href="https://modrinth.com/mod/sable">Sable</a>, which turns groups of blocks into physical objects
 * which move around (such as Create Aeronautics' balloons).
 * <p>
 * Sable keeps the blocks of each such object in a "plot", in a far-off part of the same level (X and Z around
 * 20,480,000), and only draws them where the object really is. Block entities on one report their position in the
 * plot, so anything which compares it with positions in the world, such as the distance between two wireless modems,
 * must first map it back with {@link #toWorld(Level, Vec3)}. Sable patches some of vanilla's distance checks itself
 * (such as how far a player can reach), but it can't know about ours, which only compare two {@link Vec3}s.
 * <p>
 * This goes through <a href="https://github.com/ryanhcode/sable-companion">Sable Companion</a>'s
 * {@code SableCompanion.INSTANCE.projectOutOfSubLevel(Level, Vec3)}, which Sable requires. Sable Companion isn't
 * published for this version of Minecraft, so we look it up by name rather than compiling against it. It is only
 * looked up when Sable itself is installed: Sable Companion on its own has no plots, so every position is already in
 * the world.
 */
public final class Sable {
    private static final Logger LOG = LoggerFactory.getLogger(Sable.class);
    private static final String MOD_ID = "sable";
    private static final String COMPANION = "dev.ryanhcode.sable.companion.SableCompanion";

    private static final @Nullable MethodHandle PROJECT = PlatformHelper.get().isModLoaded(MOD_ID) ? find() : null;

    private static volatile boolean failed;

    private Sable() {
    }

    /**
     * Map a position from a Sable plot back to where it is in the world.
     * <p>
     * This may be called from any thread. Off the server thread, it may see an object's pose while it is being
     * updated, and so be slightly off for that one call.
     *
     * @param level    The level the position is in.
     * @param position The position, which may be in a plot.
     * @return Where the position is in the world. This is {@code position} itself if it isn't in a plot, or if Sable
     * isn't installed.
     */
    public static Vec3 toWorld(@Nullable Level level, Vec3 position) {
        var project = PROJECT;
        return project == null || level == null ? position : project(project, level, position);
    }

    /**
     * Look up Sable Companion's {@code projectOutOfSubLevel}.
     *
     * @return The method, bound to Sable Companion's instance, or {@code null} if it couldn't be found.
     */
    static @Nullable MethodHandle find() {
        try {
            var companion = Class.forName(COMPANION, true, Sable.class.getClassLoader());
            var instance = companion.getField("INSTANCE").get(null);
            return MethodHandles.publicLookup()
                .findVirtual(companion, "projectOutOfSubLevel", MethodType.methodType(Vec3.class, Level.class, Vec3.class))
                .bindTo(instance);
        } catch (ReflectiveOperationException | LinkageError | RuntimeException e) {
            LOG.warn("Sable is installed, but Sable Companion could not be found. Wireless modems on Sable objects will not work.", e);
            return null;
        }
    }

    /**
     * Map a position out of a plot with the method from {@link #find()}.
     *
     * @param project  The bound {@code projectOutOfSubLevel} method.
     * @param level    The level the position is in.
     * @param position The position.
     * @return Where the position is in the world, or {@code position} itself if Sable failed.
     */
    static Vec3 project(MethodHandle project, @Nullable Level level, Vec3 position) {
        try {
            return (Vec3) project.invokeExact(level, position);
        } catch (RuntimeException | LinkageError e) {
            if (!failed) {
                failed = true;
                LOG.error("Sable failed to find where {} is in the world. Wireless modems on Sable objects may not work.", position, e);
            }
            return position;
        } catch (Error e) {
            throw e;
        } catch (Throwable e) {
            // projectOutOfSubLevel declares no checked exceptions, so this can't happen.
            throw new IllegalStateException(e);
        }
    }
}
