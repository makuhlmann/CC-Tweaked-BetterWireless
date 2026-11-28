// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import com.seibel.distanthorizons.api.enums.worldGeneration.EDhApiLevelType;
import com.seibel.distanthorizons.api.interfaces.block.IDhApiBiomeWrapper;
import com.seibel.distanthorizons.api.interfaces.block.IDhApiBlockStateWrapper;
import com.seibel.distanthorizons.api.interfaces.data.IDhApiTerrainDataCache;
import com.seibel.distanthorizons.api.interfaces.data.IDhApiTerrainDataRepo;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiLevelWrapper;
import com.seibel.distanthorizons.api.interfaces.world.IDhApiWorldProxy;
import com.seibel.distanthorizons.api.objects.DhApiResult;
import com.seibel.distanthorizons.api.objects.data.DhApiTerrainDataPoint;
import net.minecraft.world.level.ChunkPos;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Proxy;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.function.Supplier;

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

    @Test
    public void readsTheRestOfTheSectionWhileItsLoaded() {
        var repo = new Repo();
        var known = known();
        repo.odd.put(ChunkPos.pack(7, 11), () -> DhApiResult.createSuccess(NO_DATA));

        var heights = readSection(repo, 5, 9, known);
        assertNotNull(heights);
        assertEquals(height(5, 9), heights.ground(0, 0));
        // It's remembered here too, in case whatever asked for it gave up waiting.
        assertSame(heights, known.get(5, 9));

        // DH loaded the section once, for all of it, and was given it back straight away.
        assertEquals(1, repo.loads);
        assertEquals(16, repo.reads.size());
        assertEquals(1, repo.caches.size());
        assertEquals(1, repo.caches.getFirst().closed);

        // So the rest of the section is known now, except a chunk DH doesn't have, and nothing past it is.
        for (var x = 4; x < 8; x++) {
            for (var z = 8; z < 12; z++) {
                if (x == 5 && z == 9) continue;
                var other = known.get(x, z);
                if (x == 7 && z == 11) {
                    assertNull(other);
                } else {
                    assertNotNull(other, "Chunk " + x + ", " + z);
                    assertEquals(height(x, z), other.ground(0, 0));
                    assertEquals(ChunkHeights.Source.DISTANT_HORIZONS, other.source());
                }
            }
        }
        assertNull(known.get(8, 9));
        assertNull(known.get(5, 12));

        // And asking for another chunk of it doesn't ask DH.
        var sibling = readSection(repo, 6, 10, known);
        assertNotNull(sibling);
        assertSame(known.get(6, 10), sibling);
        assertEquals(1, repo.caches.size());
        assertEquals(16, repo.reads.size());
    }

    @Test
    public void findsTheSectionsOfNegativeChunks() {
        var repo = new Repo();
        var known = known();
        assertNotNull(readSection(repo, -1, -5, known));

        assertEquals(1, repo.loads);
        assertNotNull(known.get(-4, -8));
        assertNotNull(known.get(-4, -5));
        assertNull(known.get(0, -5));
        assertNull(known.get(-1, -4));
        assertNull(known.get(-5, -5));
    }

    @Test
    public void onlyReadsChunksWeDontKnowAsWell() {
        var repo = new Repo();
        var known = known();
        var disk = heights(ChunkHeights.Source.DISK);
        known.put(4, 8, disk);
        known.put(4, 9, heights(ChunkHeights.Source.GENERATOR));

        assertNotNull(readSection(repo, 5, 9, known));
        assertFalse(repo.reads.contains(ChunkPos.pack(4, 8)));
        assertSame(disk, known.get(4, 8));
        // But a guess from the generator is replaced.
        assertEquals(ChunkHeights.Source.DISTANT_HORIZONS, Objects.requireNonNull(known.get(4, 9)).source());

        // Nor is a chunk we're asked for, if we know it as well already.
        assertSame(disk, readSection(repo, 4, 8, known));
        assertEquals(1, repo.caches.size());
    }

    @Test
    public void givesTheSectionBackWhenReadsFail() {
        var repo = new Repo();
        var known = known();

        // DH can't read the chunk we want, perhaps as it's unloaded the level.
        repo.odd.put(ChunkPos.pack(0, 0), () -> DhApiResult.createFail("Level unloaded"));
        assertThrows(IllegalStateException.class, () -> readSection(repo, 0, 0, known));
        repo.odd.put(ChunkPos.pack(4, 0), () -> {
            throw new IllegalStateException("Level unloaded");
        });
        assertThrows(IllegalStateException.class, () -> readSection(repo, 4, 0, known));

        // Or one of the rest of the section: we still have the one we want.
        repo.odd.put(ChunkPos.pack(9, 1), () -> {
            throw new IllegalStateException("Level unloaded");
        });
        assertNotNull(readSection(repo, 8, 0, known));

        // DH doesn't have the chunk we want, so we don't look at the rest.
        repo.odd.put(ChunkPos.pack(12, 0), () -> DhApiResult.createSuccess(NO_DATA));
        var reads = repo.reads.size();
        assertNull(readSection(repo, 12, 0, known));
        assertEquals(reads + 1, repo.reads.size());

        assertEquals(4, repo.caches.size());
        for (var cache : repo.caches) assertEquals(1, cache.closed);
    }

    private static final IDhApiLevelWrapper LEVEL = level(new Object());

    private static final DhApiTerrainDataPoint[][][] NO_DATA = grid(new DhApiTerrainDataPoint[0]);

    private static @Nullable ChunkHeights readSection(Repo repo, int chunkX, int chunkZ, LevelHeights known) {
        return DistantHorizonsHeightSource.readSection(
            repo.proxy(), LEVEL, chunkX, chunkZ, known, data -> DistantHorizonsHeightSource.toHeights(data, MIN_Y, MAX_Y, x -> true)
        );
    }

    private static LevelHeights known() {
        // The level is only passed to sources, and there are none here.
        return new LevelHeights(null, 4096, () -> {
        });
    }

    private static ChunkHeights heights(ChunkHeights.Source source) {
        return new ChunkHeights(new short[256], new short[256], source, System.currentTimeMillis());
    }

    /**
     * The height of the ground in each column of a chunk our fake DH has: different in every chunk.
     *
     * @param chunkX The chunk's X coordinate.
     * @param chunkZ The chunk's Z coordinate.
     * @return The height.
     */
    private static int height(int chunkX, int chunkZ) {
        return 600 + 4 * chunkX + 64 * chunkZ;
    }

    /** DH's terrain repository, which loads a whole section into the cache it's given to read any chunk of it. */
    private static final class Repo {
        final List<Cache> caches = new ArrayList<>();
        final List<Long> reads = new ArrayList<>();
        /** How many sections were loaded from DH's database. */
        int loads;
        /** What reading some chunks gives, rather than their data. */
        final Map<Long, Supplier<DhApiResult<DhApiTerrainDataPoint[][][]>>> odd = new HashMap<>();

        IDhApiTerrainDataRepo proxy() {
            return fake(IDhApiTerrainDataRepo.class, (method, args) -> switch (method) {
                case "createSoftCache" -> {
                    var cache = new Cache();
                    caches.add(cache);
                    yield cache.proxy;
                }
                case "getAllTerrainDataAtChunkPos" -> read((int) args[1], (int) args[2], (IDhApiTerrainDataCache) args[3]);
                default -> throw new UnsupportedOperationException(method);
            });
        }

        private DhApiResult<DhApiTerrainDataPoint[][][]> read(int chunkX, int chunkZ, IDhApiTerrainDataCache given) {
            var cache = caches.stream().filter(x -> x.proxy == given).findFirst().orElseThrow();
            assertEquals(0, cache.closed, "Read with a cache which was closed");
            if (cache.sections.add(ChunkPos.pack(chunkX >> 2, chunkZ >> 2))) loads++;

            var chunk = ChunkPos.pack(chunkX, chunkZ);
            reads.add(chunk);
            var odd = this.odd.get(chunk);
            if (odd != null) return odd.get();

            var height = height(chunkX, chunkZ);
            return DhApiResult.createSuccess(grid(new DhApiTerrainDataPoint[]{ point(AIR, height, MAX_Y + 1), point(STONE, MIN_Y, height) }));
        }
    }

    /** DH's cache of loaded sections, which counts how often it's closed. */
    private static final class Cache {
        final Set<Long> sections = new HashSet<>();
        int closed;
        final IDhApiTerrainDataCache proxy = fake(IDhApiTerrainDataCache.class, method -> switch (method) {
            case "close" -> {
                closed++;
                yield null;
            }
            default -> throw new UnsupportedOperationException(method);
        });
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
    private static <T> T fake(Class<T> type, Function<String, @Nullable Object> methods) {
        return fake(type, (method, args) -> methods.apply(method));
    }

    /**
     * Implement one of DH's interfaces, which have far more methods than we use.
     *
     * @param type    The interface.
     * @param methods The result of each method, by its name and arguments.
     * @param <T>     The interface.
     * @return The implementation.
     */
    private static <T> T fake(Class<T> type, BiFunction<String, Object[], @Nullable Object> methods) {
        return type.cast(Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{ type }, (proxy, method, args) -> switch (method.getName()) {
            case "hashCode" -> System.identityHashCode(proxy);
            case "equals" -> proxy == args[0];
            case "toString" -> type.getSimpleName();
            default -> methods.apply(method.getName(), args);
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
