// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import com.seibel.distanthorizons.api.enums.worldGeneration.EDhApiLevelType;
import com.seibel.distanthorizons.api.interfaces.block.IDhApiBiomeWrapper;
import com.seibel.distanthorizons.api.interfaces.block.IDhApiBlockStateWrapper;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiLevelWrapper;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiWorldProxy;
import com.seibel.distanthorizons.api.objects.data.DhApiTerrainDataPoint;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Proxy;
import java.util.ArrayDeque;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Checks we read heights from Distant Horizons' data correctly. The columns here mirror what DH's terrain repository
 * returns for a Tellus world (minimum Y of -512, height 2544): ordered top to bottom, starting with the sky.
 */
public class DistantHorizonsHeightSourceTest {
    private static final int MIN_Y = -512;
    private static final int MAX_Y = 2031;

    private static final Block AIR = new Block(true, false);
    private static final Block STONE = new Block(false, true);
    private static final Block LEAVES = new Block(false, false);

    @Test
    public void readsAbsolutePositions() {
        // This is what DH 3.3 returns: the level's minimum height has already been added to every position.
        var heights = toHeights(
            point(AIR, 600, MAX_Y + 1),
            point(STONE, MIN_Y, 600)
        );

        assertEquals(600, heights.ground(0, 0), "Mountain should be at its real height");
        assertEquals(600, heights.surface(0, 0));
    }

    @Test
    public void readsRelativePositions() {
        // DH's documentation says positions are relative to the bottom of the level. Make sure we cope with that too.
        var heights = toHeights(
            point(AIR, 600 - MIN_Y, MAX_Y + 1 - MIN_Y),
            point(STONE, 0, 600 - MIN_Y)
        );

        assertEquals(600, heights.ground(0, 0));
        assertEquals(600, heights.surface(0, 0));
    }

    @Test
    public void separatesGroundAndSurface() {
        var heights = toHeights(
            point(AIR, 160, MAX_Y + 1),
            point(LEAVES, 150, 160),
            point(AIR, 141, 150),
            point(STONE, MIN_Y, 141)
        );

        assertEquals(141, heights.ground(0, 0));
        assertEquals(160, heights.surface(0, 0));
    }

    @Test
    public void rejectsMissingColumns() {
        var data = grid(new DhApiTerrainDataPoint[] { point(AIR, 64, MAX_Y + 1), point(STONE, MIN_Y, 64) });
        data[3][7] = new DhApiTerrainDataPoint[0];

        assertNull(DistantHorizonsHeightSource.toHeights(data, MIN_Y, MAX_Y, x -> true));
    }

    @Test
    public void skipsReadsWhichTimedOut() {
        var queue = new ArrayDeque<Runnable>();
        var reads = new AtomicInteger();

        // The first read waits so long behind others that we give up on it, so it's never read.
        var late = DistantHorizonsHeightSource.supplyUnlessLate(() -> "late" + reads.incrementAndGet(), queue::add, 10, TimeUnit.MILLISECONDS);
        assertNull(late.join());

        var onTime = DistantHorizonsHeightSource.supplyUnlessLate(() -> "on time" + reads.incrementAndGet(), queue::add, 1, TimeUnit.MINUTES);
        while (!queue.isEmpty()) queue.remove().run();

        assertEquals("on time1", onTime.join());
        assertEquals(1, reads.get());
    }

    @Test
    public void passesOnErrors() {
        var error = new IllegalStateException("DH unloaded the level");
        var result = DistantHorizonsHeightSource.supplyUnlessLate(() -> {
            throw error;
        }, Runnable::run, 1, TimeUnit.MINUTES);

        var thrown = assertThrows(CompletionException.class, result::join);
        assertSame(error, thrown.getCause());
    }

    @Test
    public void remembersLevels() {
        var overworld = new Object();
        var nether = new Object();
        var world = new World(level(overworld), level(nether));
        var levels = new DistantHorizonsHeightSource.Levels();

        var wrapper = levels.find(world.proxy(), overworld);
        assertNotNull(wrapper);
        assertSame(overworld, wrapper.getWrappedMcObject());
        assertSame(wrapper, levels.find(world.proxy(), overworld));
        assertEquals(1, world.listed, "Levels should only be listed once");

        // Each level is remembered.
        assertSame(nether, Objects.requireNonNull(levels.find(world.proxy(), nether)).getWrappedMcObject());
        assertSame(wrapper, levels.find(world.proxy(), overworld));
        assertEquals(2, world.listed);

        // Until it's forgotten, when it's looked for again.
        levels.forget(overworld);
        assertSame(wrapper, levels.find(world.proxy(), overworld));
        assertEquals(3, world.listed);

        // Levels DH doesn't have aren't found, nor remembered as missing.
        var end = new Object();
        assertNull(levels.find(world.proxy(), end));
        assertNull(levels.find(world.proxy(), end));
        assertEquals(5, world.listed);
    }

    /** DH's world, which counts how often its levels are listed. */
    private static final class World {
        final List<IDhApiLevelWrapper> levels;
        int listed;

        World(IDhApiLevelWrapper... levels) {
            this.levels = List.of(levels);
        }

        IDhApiWorldProxy proxy() {
            return fake(IDhApiWorldProxy.class, method -> switch (method) {
                case "getAllLoadedLevelWrappers" -> {
                    listed++;
                    yield levels;
                }
                case "worldLoaded" -> true;
                default -> throw new UnsupportedOperationException(method);
            });
        }
    }

    private static IDhApiLevelWrapper level(Object level) {
        return fake(IDhApiLevelWrapper.class, method -> switch (method) {
            case "getLevelType" -> EDhApiLevelType.SERVER_LEVEL;
            case "getWrappedMcObject" -> level;
            default -> throw new UnsupportedOperationException(method);
        });
    }

    /**
     * Implement one of DH's interfaces, which have far more methods than we use.
     *
     * @param type    The interface.
     * @param methods The result of each method, by its name.
     * @param <T>     The interface.
     * @return The implementation.
     */
    private static <T> T fake(Class<T> type, Function<String, Object> methods) {
        return type.cast(Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{ type }, (proxy, method, args) -> switch (method.getName()) {
            case "hashCode" -> System.identityHashCode(proxy);
            case "equals" -> proxy == args[0];
            case "toString" -> type.getSimpleName();
            default -> methods.apply(method.getName());
        }));
    }

    private static ChunkHeights toHeights(DhApiTerrainDataPoint... column) {
        var heights = DistantHorizonsHeightSource.toHeights(grid(column), MIN_Y, MAX_Y, x -> true);
        assertNotNull(heights);
        return heights;
    }

    private static DhApiTerrainDataPoint[][][] grid(DhApiTerrainDataPoint[] column) {
        var data = new DhApiTerrainDataPoint[16][16][];
        for (var x = 0; x < 16; x++) {
            for (var z = 0; z < 16; z++) data[x][z] = column;
        }
        return data;
    }

    private static DhApiTerrainDataPoint point(Block block, int bottom, int top) {
        return DhApiTerrainDataPoint.create((byte) 0, 0, 15, bottom, top, block, Biome.INSTANCE);
    }

    private record Block(boolean isAir, boolean isSolid) implements IDhApiBlockStateWrapper {
        @Override
        public boolean isLiquid() {
            return false;
        }

        @Override
        public int getOpacity() {
            return isSolid ? 15 : 0;
        }

        @Override
        public String getSerialString() {
            return toString();
        }

        @Override
        public byte getMaterialId() {
            return 0;
        }

        @Override
        public @Nullable Object getWrappedMcObject() {
            return null;
        }
    }

    private enum Biome implements IDhApiBiomeWrapper {
        INSTANCE;

        @Override
        public String getName() {
            return "plains";
        }

        @Override
        public String getSerialString() {
            return "minecraft:plains";
        }

        @Override
        public @Nullable Object getWrappedMcObject() {
            return null;
        }
    }
}
