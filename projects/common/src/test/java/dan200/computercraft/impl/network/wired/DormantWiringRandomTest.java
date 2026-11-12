// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.impl.network.wired;

import dan200.computercraft.api.network.wired.WiredNode;
import dan200.computercraft.test.shared.WithMinecraft;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.level.ChunkPos;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Random changes to a pretend level, whose chunks load and unload under its wired networks. After each one, the
 * networks are compared with what a search of the level's blocks says is connected.
 * <p>
 * The seeds are fixed, so a failure happens again. Its message gives the seed and the changes which led to it.
 */
@WithMinecraft
public class DormantWiringRandomTest {
    private static final Direction[] DIRECTIONS = Direction.values();
    private static final int ALL_SIDES = 0x3f;

    /** The chunks of the pretend level, which include negative coordinates. */
    private static final int MIN_CHUNK_X = -2, MAX_CHUNK_X = 1, MIN_CHUNK_Z = -1, MAX_CHUNK_Z = 1;

    /** The heights wired blocks are placed at: two next to each other, and the lowest and highest of the overworld. */
    private static final int[] HEIGHTS = { 64, 65, -64, 319 };

    private static int bit(Direction direction) {
        return 1 << direction.get3DDataValue();
    }

    private enum ChunkState {
        /** Fully loaded, and its blocks have joined their networks. */
        LOADED,
        /** Fully loaded (blocks next to it see it as loaded), but its blocks have yet to join their networks. */
        LOADING,
        /** No longer fully loaded: its blocks are still there, but its wiring is remembered. */
        DEMOTED,
        /** Not loaded: its wiring is remembered. */
        UNLOADED,
        /** Not loaded, and nothing is remembered of it. */
        UNKNOWN;

        boolean isLoaded() {
            return this == LOADED || this == LOADING;
        }

        boolean hasBlocks() {
            return this == LOADED || this == LOADING || this == DEMOTED;
        }
    }

    /**
     * A pretend level: chunks, which load and unload, and the wired blocks in them, which are {@link NetworkTest}'s
     * elements while their chunk is in memory.
     */
    private static final class World {
        final long seed;
        final Random random;
        final List<String> history = new ArrayList<>();

        final List<BlockPos> lattice = new ArrayList<>();
        final Map<BlockPos, Integer> blocks = new HashMap<>();
        final Set<BlockPos> peripherals = new HashSet<>();
        final Map<BlockPos, NetworkTest.NetworkElement> live = new HashMap<>();
        final Map<Long, ChunkState> chunks = new TreeMap<>();
        DormantWiring wiring = new DormantWiring(null);

        World(long seed) {
            this.seed = seed;
            random = new Random(seed);

            for (var chunkX = MIN_CHUNK_X; chunkX <= MAX_CHUNK_X; chunkX++) {
                for (var chunkZ = MIN_CHUNK_Z; chunkZ <= MAX_CHUNK_Z; chunkZ++) chunks.put(ChunkPos.pack(chunkX, chunkZ), ChunkState.LOADED);
            }

            // Blocks go on lines along each chunk's edges and through its middle, so that wiring often crosses chunks,
            // runs along their edges, and meets at their corners.
            for (var x = MIN_CHUNK_X * 16; x < (MAX_CHUNK_X + 1) * 16; x++) {
                for (var z = MIN_CHUNK_Z * 16; z < (MAX_CHUNK_Z + 1) * 16; z++) {
                    if (!onLine(x) && !onLine(z)) continue;
                    for (var y : HEIGHTS) lattice.add(new BlockPos(x, y, z));
                }
            }
        }

        private static boolean onLine(int coordinate) {
            var within = coordinate & 15;
            return within == 0 || within == 8 || within == 15;
        }

        // region Changes to the level
        void fill(double density) {
            history.add("fill " + density);
            var positions = new ArrayList<>(lattice);
            Collections.shuffle(positions, random);
            for (var pos : positions) {
                // Fewer blocks away from the main layer.
                var chance = pos.getY() == 64 ? density : density * 0.15;
                if (random.nextDouble() < chance) place(pos, randomSides(), random.nextInt(12) == 0);
            }
        }

        int randomSides() {
            return random.nextInt(4) == 0 ? random.nextInt(ALL_SIDES + 1) : ALL_SIDES;
        }

        void place(BlockPos pos, int sides, boolean peripheral) {
            blocks.put(pos, sides);
            if (peripheral) peripherals.add(pos);
            live.put(pos, element(pos));
            connect(pos);
        }

        NetworkTest.NetworkElement element(BlockPos pos) {
            return new NetworkTest.NetworkElement(pos.toShortString(), peripherals.contains(pos));
        }

        void breakBlock(BlockPos pos) {
            blocks.remove(pos);
            peripherals.remove(pos);
            Objects.requireNonNull(live.remove(pos)).getNode().remove();
        }

        // What CableBlockEntity.connectionsChanged does.
        void connect(BlockPos pos) {
            var node = live.get(pos).getNode();
            for (var direction : DIRECTIONS) {
                if ((blocks.get(pos) & bit(direction)) == 0) continue;
                var other = pos.relative(direction);
                var otherNode = state(ChunkPos.pack(other)).isLoaded()
                    ? find(other, direction.getOpposite())
                    : wiring.nodeAt(other, direction.getOpposite());
                if (otherNode != null) DormantWiring.connect(node, otherNode);
            }
        }

        ChunkState state(long chunk) {
            // Chunks beyond the edge of the level are never loaded.
            return chunks.getOrDefault(chunk, ChunkState.UNKNOWN);
        }

        // The wired block in a fully loaded chunk, as UnloadedWiring.liveNode finds it.
        @Nullable
        WiredNode find(BlockPos pos, Direction side) {
            if (!state(ChunkPos.pack(pos)).isLoaded()) return null;
            var element = live.get(pos);
            var sides = blocks.get(pos);
            return element == null || sides == null || (sides & bit(side)) == 0 ? null : element.getNode();
        }

        List<DormantWiring.Block> blocksIn(long chunk) {
            var result = new ArrayList<DormantWiring.Block>();
            for (var entry : blocks.entrySet()) {
                if (ChunkPos.pack(entry.getKey()) == chunk) result.add(new DormantWiring.Block(entry.getKey(), entry.getValue()));
            }
            // In no particular order, as a chunk's block entities are.
            Collections.shuffle(result, random);
            return result;
        }

        // The chunk is no longer fully loaded: its blocks stay as they are, and its wiring is remembered.
        void demote(long chunk) {
            wiring.unload(chunk, blocksIn(chunk), this::find);
            chunks.put(chunk, ChunkState.DEMOTED);
        }

        // The chunk unloads: its wiring is remembered (again, if it was no longer fully loaded), and its blocks go.
        void unload(long chunk) {
            wiring.unload(chunk, blocksIn(chunk), this::find);
            chunks.put(chunk, ChunkState.UNLOADED);
            for (var block : blocksIn(chunk)) Objects.requireNonNull(live.remove(block.pos())).getNode().remove();
        }

        // The chunk is fully loaded (again): its blocks are there, but only join their networks on the next tick.
        void startLoading(long chunk) {
            if (!state(chunk).hasBlocks()) {
                for (var block : blocksIn(chunk)) live.put(block.pos(), element(block.pos()));
            }
            chunks.put(chunk, ChunkState.LOADING);
        }

        // What UnloadedWiring.join does.
        void join(long chunk) {
            var retire = wiring.load(chunk);
            for (var block : blocksIn(chunk)) connect(block.pos());
            retire.run();
            chunks.put(chunk, ChunkState.LOADED);
        }

        void tick() {
            var loading = chunksIn(ChunkState.LOADING);
            Collections.shuffle(loading, random);
            for (var chunk : loading) join(chunk);
        }

        // What UnloadedWiring.save writes: chunks which aren't loaded as they're remembered, and loaded ones as they
        // are.
        List<DormantWiring.Ports> save() {
            var saved = new ArrayList<DormantWiring.Ports>();
            for (var ports : wiring.ports()) {
                if (!state(ports.chunk()).isLoaded()) saved.add(ports);
            }
            for (var entry : chunks.entrySet()) {
                if (entry.getValue().isLoaded()) saved.addAll(DormantWiring.findPieces(entry.getKey(), blocksIn(entry.getKey())));
            }
            return saved;
        }

        // The server restarts: no chunk is loaded, and only what was saved is remembered.
        void restart(List<DormantWiring.Ports> saved) {
            for (var element : live.values()) element.getNode().remove();
            live.clear();
            wiring = new DormantWiring(null);
            wiring.restore(saved, this::find);
        }
        // endregion

        List<Long> chunksIn(ChunkState... states) {
            var result = new ArrayList<Long>();
            for (var entry : chunks.entrySet()) {
                if (Arrays.asList(states).contains(entry.getValue())) result.add(entry.getKey());
            }
            return result;
        }

        <T> @Nullable T pick(List<T> list) {
            return list.isEmpty() ? null : list.get(random.nextInt(list.size()));
        }

        @Nullable
        BlockPos pickBlock(ChunkState... states) {
            var candidates = new ArrayList<BlockPos>();
            var chunks = chunksIn(states);
            for (var pos : blocks.keySet()) {
                if (chunks.contains(ChunkPos.pack(pos))) candidates.add(pos);
            }
            // The map's order depends on the positions' hashes alone, but sort to be sure a seed always does the same.
            Collections.sort(candidates);
            return pick(candidates);
        }

        void step() {
            var roll = random.nextInt(100);
            if (roll < 26) {
                var chunk = pick(chunksIn(ChunkState.LOADED));
                if (chunk == null) return;
                var free = new ArrayList<BlockPos>();
                for (var pos : lattice) {
                    if (ChunkPos.pack(pos) == chunk && !blocks.containsKey(pos) && (pos.getY() == 64 || random.nextInt(6) == 0)) free.add(pos);
                }
                var pos = pick(free);
                if (pos == null) return;
                var sides = randomSides();
                history.add("place " + pos.toShortString() + " sides " + sides);
                place(pos, sides, random.nextInt(8) == 0);
            } else if (roll < 44) {
                var pos = pickBlock(ChunkState.LOADED);
                if (pos == null) return;
                history.add("break " + pos.toShortString());
                breakBlock(pos);
            } else if (roll < 52) {
                var chunk = pick(chunksIn(ChunkState.LOADED, ChunkState.LOADING));
                if (chunk == null) return;
                history.add("demote " + describe(chunk));
                demote(chunk);
            } else if (roll < 63) {
                var chunk = pick(chunksIn(ChunkState.LOADED, ChunkState.LOADING, ChunkState.DEMOTED));
                if (chunk == null) return;
                history.add("unload " + describe(chunk));
                unload(chunk);
            } else if (roll < 76) {
                var chunk = pick(chunksIn(ChunkState.DEMOTED, ChunkState.UNLOADED, ChunkState.UNKNOWN));
                if (chunk == null) return;
                history.add("load " + describe(chunk));
                startLoading(chunk);
            } else if (roll < 90) {
                history.add("tick");
                tick();
            } else if (roll < 94) {
                // A block ticks before its chunk joins its networks, or ticks again.
                var pos = pickBlock(ChunkState.LOADED, ChunkState.LOADING);
                if (pos == null) return;
                history.add("connect " + pos.toShortString());
                connect(pos);
            } else if (roll < 96) {
                // Every chunk unloads, or loads, as when the last player leaves or the first arrives.
                var unload = random.nextBoolean();
                history.add(unload ? "unload all" : "load all");
                var all = unload
                    ? chunksIn(ChunkState.LOADED, ChunkState.LOADING, ChunkState.DEMOTED)
                    : chunksIn(ChunkState.DEMOTED, ChunkState.UNLOADED, ChunkState.UNKNOWN);
                Collections.shuffle(all, random);
                for (var chunk : all) {
                    if (unload) {
                        unload(chunk);
                    } else {
                        startLoading(chunk);
                    }
                }
            } else if (roll < 99) {
                history.add("restart");
                var saved = save();
                restart(saved);
                for (var entry : chunks.entrySet()) {
                    if (entry.getValue() != ChunkState.UNKNOWN) entry.setValue(ChunkState.UNLOADED);
                }
            } else {
                // The wiring file is lost.
                history.add("restart with nothing saved");
                restart(List.of());
                for (var entry : chunks.entrySet()) entry.setValue(ChunkState.UNKNOWN);
            }
        }

        static String describe(long chunk) {
            return "[" + ChunkPos.getX(chunk) + ", " + ChunkPos.getZ(chunk) + "]";
        }

        String describe() {
            var recent = history.subList(Math.max(0, history.size() - 40), history.size());
            return "Seed " + seed + " after " + history.size() + " changes, the last of which were:\n  " + String.join("\n  ", recent) + "\n";
        }

        // region What should be connected
        /**
         * Find which blocks are connected to which, going by the blocks alone: in every chunk which is loaded or
         * remembered, as nothing is known of the others.
         *
         * @return A number for each block, the same for those connected to each other.
         */
        Map<BlockPos, Integer> components() {
            var components = new HashMap<BlockPos, Integer>();
            var next = 0;
            for (var start : blocks.keySet()) {
                if (components.containsKey(start) || state(ChunkPos.pack(start)) == ChunkState.UNKNOWN) continue;

                var component = next++;
                var queue = new ArrayDeque<BlockPos>();
                components.put(start, component);
                queue.add(start);
                while (!queue.isEmpty()) {
                    var pos = queue.remove();
                    for (var direction : DIRECTIONS) {
                        var other = pos.relative(direction);
                        if (!connected(pos, direction) || state(ChunkPos.pack(other)) == ChunkState.UNKNOWN) continue;
                        if (components.putIfAbsent(other, component) == null) queue.add(other);
                    }
                }
            }
            return components;
        }

        // Whether a block connects to the one on a side of it, which connects back.
        boolean connected(BlockPos pos, Direction direction) {
            var sides = blocks.get(pos);
            var otherSides = blocks.get(pos.relative(direction));
            return sides != null && otherSides != null && (sides & bit(direction)) != 0 && (otherSides & bit(direction.getOpposite())) != 0;
        }

        /**
         * Find the pieces of a chunk's wiring, going by its blocks alone.
         *
         * @param chunk The chunk.
         * @return Each piece's ports, and the sides they're on.
         */
        Set<Map<Long, Integer>> pieces(long chunk) {
            var seen = new HashSet<BlockPos>();
            var pieces = new HashSet<Map<Long, Integer>>();
            for (var start : blocks.keySet()) {
                if (ChunkPos.pack(start) != chunk || !seen.add(start)) continue;

                var ports = new HashMap<Long, Integer>();
                var queue = new ArrayDeque<BlockPos>();
                queue.add(start);
                while (!queue.isEmpty()) {
                    var pos = queue.remove();
                    for (var direction : DIRECTIONS) {
                        var other = pos.relative(direction);
                        if (ChunkPos.pack(other) != chunk) {
                            if ((blocks.get(pos) & bit(direction)) != 0) ports.merge(pos.asLong(), bit(direction), (a, b) -> a | b);
                        } else if (connected(pos, direction) && seen.add(other)) {
                            queue.add(other);
                        }
                    }
                }
                if (!ports.isEmpty()) pieces.add(ports);
            }
            return pieces;
        }
        // endregion

        void check() {
            var components = components();

            // The nodes which stand for something: blocks in memory, and the ports of chunks which aren't loaded.
            var nodes = new ArrayList<WiredNodeImpl>();
            var nodeComponents = new ArrayList<Integer>();
            var settled = new ArrayList<Boolean>();
            for (var entry : live.entrySet()) {
                nodes.add(entry.getValue().getNode());
                nodeComponents.add(Objects.requireNonNull(components.get(entry.getKey())));
                // Blocks in a chunk which has yet to join its networks, or is no longer fully loaded, needn't be
                // connected to everything they should be.
                settled.add(state(ChunkPos.pack(entry.getKey())) == ChunkState.LOADED);
            }

            var pieceCount = 0;
            for (var entry : chunks.entrySet()) {
                var chunk = entry.getKey();
                var state = entry.getValue();
                if (state == ChunkState.LOADED || state == ChunkState.UNKNOWN) {
                    assertFalse(wiring.has(chunk), () -> "Nothing is remembered of " + describe(chunk) + ". " + describe());
                    continue;
                }
                // A chunk which is loading still has the pieces it had, if any.
                if (state == ChunkState.LOADING && !wiring.has(chunk)) continue;

                var expected = pieces(chunk);
                var actual = new HashSet<Map<Long, Integer>>();
                for (var ports : wiring.ports()) {
                    if (ports.chunk() != chunk) continue;
                    var piece = new HashMap<Long, Integer>();
                    for (var i = 0; i < ports.positions().length; i++) piece.put(ports.positions()[i], (int) ports.sides()[i]);
                    actual.add(piece);
                }
                assertEquals(expected, actual, () -> "Pieces of " + describe(chunk) + ". " + describe());
                assertEquals(!expected.isEmpty(), wiring.has(chunk), () -> "Remembers " + describe(chunk) + ". " + describe());
                pieceCount += expected.size();

                for (var piece : expected) {
                    for (var port : piece.entrySet()) {
                        var pos = BlockPos.of(port.getKey());
                        for (var direction : Direction.Plane.HORIZONTAL) {
                            var node = wiring.nodeAt(pos, direction);
                            if ((port.getValue() & bit(direction)) == 0) {
                                assertNull(node, () -> "No port at " + pos + " " + direction + ". " + describe());
                                continue;
                            }
                            assertNotNull(node, () -> "A port at " + pos + " " + direction + ". " + describe());
                            nodes.add((WiredNodeImpl) node);
                            nodeComponents.add(Objects.requireNonNull(components.get(pos)));
                            settled.add(true);
                        }
                    }
                }
            }
            assertEquals(pieceCount, wiring.ports().size(), () -> "Number of pieces. " + describe());

            // No two nodes are in one network unless they should be connected, and once every chunk has joined its
            // networks, all those which should be connected are.
            var allJoined = chunksIn(ChunkState.LOADING).isEmpty();
            var networkComponent = new IdentityHashMap<WiredNetworkImpl, Integer>();
            var componentNetwork = new HashMap<Integer, WiredNetworkImpl>();
            for (var i = 0; i < nodes.size(); i++) {
                var node = nodes.get(i);
                var network = node.getNetwork();
                var component = nodeComponents.get(i);

                var existing = networkComponent.putIfAbsent(network, component);
                if (existing != null && !existing.equals(component)) {
                    fail(node + " is in a network with blocks it isn't connected to. " + describe());
                }

                if (allJoined && settled.get(i)) {
                    var existingNetwork = componentNetwork.putIfAbsent(component, network);
                    if (existingNetwork != null && existingNetwork != network) {
                        fail(node + " isn't in the network of blocks it's connected to. " + describe());
                    }
                }
            }

            // Networks are well-formed, hold nothing which has gone (blocks of unloaded chunks, pieces of loaded ones),
            // and everything in one sees the same peripherals.
            var liveNodes = Collections.newSetFromMap(new IdentityHashMap<WiredNodeImpl, Boolean>());
            for (var element : live.values()) liveNodes.add(element.getNode());
            var pieceNodes = 0;
            for (var network : networkComponent.keySet()) {
                InvariantChecker.checkNetwork(network);
                var networkPeripherals = new HashSet<String>();
                for (var node : network.nodes) {
                    assertSame(network, node.getNetwork(), () -> node + " is in its network. " + describe());
                    networkPeripherals.addAll(node.peripherals.keySet());
                    if (node.element instanceof NetworkTest.NetworkElement) {
                        assertTrue(liveNodes.contains(node), () -> node + " has gone, but is still in a network. " + describe());
                    } else {
                        pieceNodes++;
                    }
                }
                for (var node : network.nodes) {
                    if (node.element instanceof NetworkTest.NetworkElement element) {
                        assertEquals(networkPeripherals, element.allPeripherals().keySet(), () -> "Peripherals of " + node + ". " + describe());
                    }
                }
            }
            assertEquals(wiring.ports().size(), pieceNodes, () -> "Number of pieces in networks. " + describe());

            // The chunks which wiring leads into, but which aren't known.
            LongSet expectedFrontier = new LongOpenHashSet();
            var knownPorts = new ArrayList<>(wiring.ports());
            for (var entry : chunks.entrySet()) {
                if (!wiring.has(entry.getKey()) && entry.getValue().isLoaded()) {
                    knownPorts.addAll(DormantWiring.findPieces(entry.getKey(), blocksIn(entry.getKey())));
                }
            }
            for (var entry : blocks.entrySet()) {
                var chunk = ChunkPos.pack(entry.getKey());
                if (!known(chunk)) continue;
                for (var direction : Direction.Plane.HORIZONTAL) {
                    var other = ChunkPos.pack(entry.getKey().relative(direction));
                    if (other != chunk && (entry.getValue() & bit(direction)) != 0 && !known(other)) expectedFrontier.add(other);
                }
            }
            assertEquals(expectedFrontier, new LongOpenHashSet(DormantWiring.frontier(knownPorts, this::known)), () -> "Unknown chunks. " + describe());
        }

        // What UnloadedWiring.known says.
        boolean known(long chunk) {
            return wiring.has(chunk) || state(chunk).isLoaded();
        }
    }

    @ParameterizedTest(name = "seed {0}")
    @ValueSource(longs = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 })
    public void staysConnectedAsChunksLoadAndUnload(long seed) {
        var world = new World(seed);
        // Dense, half-full and sparse levels: long networks through many chunks, or many small ones.
        world.fill(new double[]{ 0.97, 0.85, 0.5 }[(int) (seed % 3)]);
        world.check();

        for (var i = 0; i < 250; i++) {
            world.step();
            world.check();
        }

        // In the end, with every chunk loaded again, the networks are just what the blocks say.
        for (var chunk : world.chunksIn(ChunkState.DEMOTED, ChunkState.UNLOADED, ChunkState.UNKNOWN)) world.startLoading(chunk);
        world.tick();
        world.history.add("load all, and tick");
        world.check();
        assertEquals(0, world.wiring.ports().size(), world::describe);
        assertEquals(0, world.wiring.chunkCount(), world::describe);
    }
}
