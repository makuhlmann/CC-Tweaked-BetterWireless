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
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Wired networks across chunks which aren't loaded: a pretend level, where wired blocks are {@link NetworkTest}'s
 * elements, connected to their neighbours as cables are.
 */
@WithMinecraft
public class DormantWiringTest {
    private static final int ALONG_X = bit(Direction.EAST) | bit(Direction.WEST);

    private static int bit(Direction direction) {
        return 1 << direction.get3DDataValue();
    }

    /**
     * A pretend level: which chunks are loaded, and the wired blocks in them.
     */
    private static final class World {
        final Map<BlockPos, Integer> blocks = new HashMap<>();
        final Map<BlockPos, NetworkTest.NetworkElement> live = new HashMap<>();
        final LongSet unloaded = new LongOpenHashSet();
        DormantWiring wiring = new DormantWiring(null);

        // Add a wired block, which connects to its neighbours as a cable would.
        NetworkTest.NetworkElement place(BlockPos pos, int sides, @Nullable String peripheral) {
            blocks.put(pos, sides);
            var element = new NetworkTest.NetworkElement(peripheral == null ? pos.toShortString() : peripheral, peripheral != null);
            live.put(pos, element);
            connect(pos);
            return element;
        }

        void cable(int fromX, int toX) {
            for (var x = fromX; x <= toX; x++) place(new BlockPos(x, 64, 8), ALONG_X, null);
        }

        void breakBlock(BlockPos pos) {
            blocks.remove(pos);
            Objects.requireNonNull(live.remove(pos)).getNode().remove();
        }

        // What CableBlockEntity.connectionsChanged does.
        void connect(BlockPos pos) {
            var node = live.get(pos).getNode();
            for (var direction : Direction.values()) {
                if ((blocks.get(pos) & bit(direction)) == 0) continue;
                var other = pos.relative(direction);
                WiredNode otherNode;
                if (unloaded.contains(ChunkPos.pack(other))) {
                    otherNode = wiring.nodeAt(other, direction.getOpposite());
                } else {
                    otherNode = find(other, direction.getOpposite());
                }
                if (otherNode != null) DormantWiring.connect(node, otherNode);
            }
        }

        @Nullable
        WiredNode find(BlockPos pos, Direction side) {
            var element = live.get(pos);
            var sides = blocks.get(pos);
            return element == null || sides == null || (sides & bit(side)) == 0 ? null : element.getNode();
        }

        List<DormantWiring.Block> blocksIn(long chunk) {
            var result = new ArrayList<DormantWiring.Block>();
            for (var entry : blocks.entrySet()) {
                if (ChunkPos.pack(entry.getKey()) == chunk) result.add(new DormantWiring.Block(entry.getKey(), entry.getValue()));
            }
            return result;
        }

        void unload(int chunkX) {
            unloadChunk(ChunkPos.pack(chunkX, 0));
        }

        void unloadChunk(long chunk) {
            wiring.unload(chunk, blocksIn(chunk), this::find);
            unloaded.add(chunk);
            for (var block : blocksIn(chunk)) Objects.requireNonNull(live.remove(block.pos())).getNode().remove();
        }

        void load(int chunkX) {
            var chunk = ChunkPos.pack(chunkX, 0);
            unloaded.remove(chunk);
            var retire = wiring.load(chunk);
            var loaded = blocksIn(chunk);
            for (var block : loaded) {
                live.put(block.pos(), new NetworkTest.NetworkElement(block.pos().toShortString(), false));
            }
            for (var block : loaded) connect(block.pos());
            retire.run();
        }

        // The chunk is no longer fully loaded: its blocks stay, but blocks next to it see it as unloaded, and its
        // wiring is remembered.
        void demote(int chunkX) {
            var chunk = ChunkPos.pack(chunkX, 0);
            wiring.unload(chunk, blocksIn(chunk), this::find);
            unloaded.add(chunk);
        }

        // The chunk is fully loaded again, with the blocks it kept: they join their networks again.
        void promote(int chunkX) {
            var chunk = ChunkPos.pack(chunkX, 0);
            unloaded.remove(chunk);
            var retire = wiring.load(chunk);
            for (var block : blocksIn(chunk)) connect(block.pos());
            retire.run();
        }

        // The server restarts: only what was saved is left (loaded chunks as they are), and no chunk is loaded.
        void restart() {
            var saved = new ArrayList<>(wiring.ports());
            var loaded = new LongOpenHashSet();
            for (var pos : blocks.keySet()) {
                var chunk = ChunkPos.pack(pos);
                if (!unloaded.contains(chunk) && loaded.add(chunk)) saved.addAll(DormantWiring.findPieces(chunk, blocksIn(chunk)));
            }
            for (var element : live.values()) element.getNode().remove();
            live.clear();
            for (var pos : blocks.keySet()) unloaded.add(ChunkPos.pack(pos));
            wiring = new DormantWiring(null);
            wiring.restore(saved, this::find);
        }
    }

    private static WiredNetworkImpl network(NetworkTest.NetworkElement element) {
        return element.getNode().getNetwork();
    }

    @Test
    public void findsPiecesAndPorts() {
        var chunk = ChunkPos.pack(0, 0);
        var blocks = new ArrayList<DormantWiring.Block>();
        // A cable across the chunk, from x = 0 to 15.
        for (var x = 0; x <= 15; x++) blocks.add(new DormantWiring.Block(new BlockPos(x, 64, 3), ALONG_X));
        // Another, which turns the corner at (15, 70, 15), the chunk's corner.
        for (var x = 10; x <= 15; x++) {
            blocks.add(new DormantWiring.Block(new BlockPos(x, 70, 15), ALONG_X | (x == 15 ? bit(Direction.SOUTH) : 0)));
        }
        // A cable which doesn't reach the chunk's edge.
        blocks.add(new DormantWiring.Block(new BlockPos(5, 80, 5), ALONG_X));
        // A cable at the edge which doesn't connect outwards (a modem faces that way, say).
        blocks.add(new DormantWiring.Block(new BlockPos(0, 90, 5), bit(Direction.EAST)));

        var pieces = DormantWiring.findPieces(chunk, blocks);
        assertEquals(2, pieces.size());

        var straight = pieces.stream().filter(x -> x.positions().length == 2).findFirst().orElseThrow();
        assertEquals(Set.of(new BlockPos(0, 64, 3).asLong(), new BlockPos(15, 64, 3).asLong()), Set.of(straight.positions()[0], straight.positions()[1]));

        var corner = pieces.stream().filter(x -> x.positions().length == 1).findFirst().orElseThrow();
        assertEquals(new BlockPos(15, 70, 15).asLong(), corner.positions()[0]);
        assertEquals(bit(Direction.EAST) | bit(Direction.SOUTH), corner.sides()[0]);
    }

    @Test
    public void keepsANetworkConnectedThroughUnloadedChunks() {
        var world = new World();
        var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 78);
        var b = world.place(new BlockPos(79, 64, 8), ALONG_X, "b");
        assertEquals(80, network(a).nodes.size());

        // The chunks between unload, one by one, from the middle outwards.
        for (var chunk : new int[]{ 2, 1, 3 }) {
            world.unload(chunk);
            assertSame(network(a), network(b), "Connected after chunk " + chunk + " unloads");
        }
        assertTrue(a.allPeripherals().containsKey("b"));
        assertTrue(b.allPeripherals().containsKey("a"));
        // 16 loaded cables at each end, and one piece for each of the chunks between.
        assertEquals(16 + 16 + 3, network(a).nodes.size());

        // A chunk loads again: its cables take its piece's place.
        world.load(2);
        assertSame(network(a), network(b));
        assertEquals(16 + 16 + 16 + 2, network(a).nodes.size());

        // Breaking the cable splits the network, as it would if everything were loaded.
        world.breakBlock(new BlockPos(70, 64, 8));
        assertNotSame(network(a), network(b));
        assertFalse(a.allPeripherals().containsKey("b"));
    }

    @Test
    public void keepsANetworkConnectedThroughChunksNoLongerFullyLoaded() {
        var world = new World();
        var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 46);
        var b = world.place(new BlockPos(47, 64, 8), ALONG_X, "b");

        // The middle chunk is no longer fully loaded. A cable next to it, placed again, connects through what's
        // remembered of it.
        world.demote(1);
        world.breakBlock(new BlockPos(32, 64, 8));
        assertNotSame(network(a), network(b));
        world.place(new BlockPos(32, 64, 8), ALONG_X, null);
        assertSame(network(a), network(b));
        assertTrue(a.allPeripherals().containsKey("b"));

        // Then it unloads: its piece stays, once.
        world.unload(1);
        assertSame(network(a), network(b));
        assertEquals(16 + 16 + 1, network(a).nodes.size());
        assertEquals(1, world.wiring.ports().size());
    }

    /**
     * Breaking a cable splits its network in two, and placing it again joins the halves, the larger taking in the
     * smaller. Whichever half that is, their locks must be taken the same way round as when they split: the lock checker
     * throws otherwise, when assertions are on, as in a development environment.
     */
    @Test
    public void rejoinsANetworkSplitInTwo() {
        for (var broken = 1; broken <= 30; broken++) {
            var world = new World();
            var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
            world.cable(1, 30);
            var b = world.place(new BlockPos(31, 64, 8), ALONG_X, "b");

            world.breakBlock(new BlockPos(broken, 64, 8));
            assertNotSame(network(a), network(b));
            world.place(new BlockPos(broken, 64, 8), ALONG_X, null);
            assertSame(network(a), network(b), "Connected after replacing the cable at " + broken);
            assertEquals(32, network(a).nodes.size());
            assertTrue(a.allPeripherals().containsKey("b"));
        }
    }

    @Test
    public void forgetsAChunksPiecesWhenItsFullyLoadedAgain() {
        var world = new World();
        var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 46);
        var b = world.place(new BlockPos(47, 64, 8), ALONG_X, "b");

        world.demote(1);
        assertEquals(48 + 1, network(a).nodes.size());
        world.promote(1);
        assertSame(network(a), network(b));
        assertEquals(48, network(a).nodes.size());
        assertEquals(0, world.wiring.ports().size());
    }

    @Test
    public void findsTheChunksCablesLeadIntoWhichArentKnown() {
        var world = new World();
        world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 78);
        world.unload(1);
        world.unload(2);
        // A cable which turns south at the edge of chunk 3, into chunk (3, 1).
        world.place(new BlockPos(63, 64, 15), bit(Direction.WEST) | bit(Direction.SOUTH), null);

        // Chunks 0 and 4 are loaded, 1 and 2 remembered; 3 and (3, 1) are neither.
        LongSet loaded = new LongOpenHashSet(new long[]{ ChunkPos.pack(0, 0), ChunkPos.pack(4, 0) });
        var ports = new ArrayList<>(world.wiring.ports());
        ports.addAll(DormantWiring.findPieces(ChunkPos.pack(3, 0), world.blocksIn(ChunkPos.pack(3, 0))));
        var frontier = DormantWiring.frontier(ports, pos -> loaded.contains(pos) || world.wiring.has(pos));
        assertEquals(Set.of(ChunkPos.pack(3, 0), ChunkPos.pack(3, 1)), Set.of(Arrays.stream(frontier.toLongArray()).boxed().toArray(Long[]::new)));
    }

    @Test
    public void unloadingAChunkTwiceReplacesItsPieces() {
        var world = new World();
        var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 46);
        var b = world.place(new BlockPos(47, 64, 8), ALONG_X, "b");

        world.unload(1);
        // The chunk loads only briefly: it unloads again before its cables replaced its piece.
        world.unloaded.remove(ChunkPos.pack(1, 0));
        for (var block : world.blocksIn(ChunkPos.pack(1, 0))) {
            world.live.put(block.pos(), new NetworkTest.NetworkElement(block.pos().toShortString(), false));
        }
        world.unload(1);
        assertSame(network(a), network(b));
        assertEquals(1, world.wiring.ports().size());
        assertEquals(16 + 16 + 1, network(a).nodes.size());
    }

    @Test
    public void reconnectsAfterARestart() {
        var world = new World();
        world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 78);
        world.place(new BlockPos(79, 64, 8), ALONG_X, "b");
        world.unload(2);
        world.unload(3);

        // Only the chunks at the ends load after the restart, and they're connected all the same.
        world.restart();
        world.load(0);
        world.load(4);
        var a = world.live.get(new BlockPos(0, 64, 8));
        var b = world.live.get(new BlockPos(79, 64, 8));
        a.addPeripheral("a");
        b.addPeripheral("b");
        assertSame(network(a), network(b));
        assertTrue(a.allPeripherals().containsKey("b"));
        assertEquals(16 + 16 + 3, network(a).nodes.size());
    }

    @Test
    public void findsPortsAtCornersAndEveryHeight() {
        // A chunk with negative coordinates: its blocks run from -32 to -17.
        var chunk = ChunkPos.pack(-2, -1);
        var all = 0x3f;
        var blocks = new ArrayList<DormantWiring.Block>();
        // A block at each corner, at the bottom and top of the overworld, and at the least and greatest heights a level
        // may have.
        var heights = new int[]{ -64, 319, -2032, 2031 };
        for (var y : heights) {
            for (var x : new int[]{ -32, -17 }) {
                for (var z : new int[]{ -16, -1 }) blocks.add(new DormantWiring.Block(new BlockPos(x, y, z), all));
            }
        }
        // A block in the middle, which connects up and down alone.
        blocks.add(new DormantWiring.Block(new BlockPos(-24, 0, -8), bit(Direction.UP) | bit(Direction.DOWN)));

        var pieces = DormantWiring.findPieces(chunk, blocks);
        assertEquals(16, pieces.size());
        var seen = new HashSet<BlockPos>();
        for (var piece : pieces) {
            assertEquals(chunk, piece.chunk());
            assertEquals(1, piece.positions().length);
            var pos = BlockPos.of(piece.positions()[0]);
            assertTrue(seen.add(pos));

            // Each has two ports, out of the chunk, and none up or down.
            var expected = bit(pos.getX() == -32 ? Direction.WEST : Direction.EAST) | bit(pos.getZ() == -16 ? Direction.NORTH : Direction.SOUTH);
            assertEquals(expected, piece.sides()[0], "Sides of " + pos);
        }

        // Blocks one above another are one piece, however tall.
        blocks.clear();
        for (var y = -64; y < 320; y++) blocks.add(new DormantWiring.Block(new BlockPos(-17, y, -1), all));
        pieces = DormantWiring.findPieces(chunk, blocks);
        assertEquals(1, pieces.size());
        assertEquals(384, pieces.get(0).positions().length);
    }

    @Test
    public void connectsAcrossSidesButNotCorners() {
        var all = 0x3f;
        // A block in the corner of chunk (-1, -1), and one in each of the three chunks which meet it there: across its
        // east and south sides, and across the corner.
        var corner = new BlockPos(-1, 64, -1);
        for (var other : new BlockPos[]{ corner.east(), corner.south(), new BlockPos(0, 64, 0) }) {
            var world = new World();
            world.place(corner, all, null);
            var b = world.place(other, all, "b");
            var beside = other.distManhattan(corner) == 1;

            world.unloadChunk(ChunkPos.pack(corner));
            assertEquals(1, world.wiring.ports().size());
            assertEquals(bit(Direction.EAST) | bit(Direction.SOUTH), world.wiring.ports().get(0).sides()[0]);
            assertNotNull(world.wiring.nodeAt(corner, Direction.SOUTH));
            assertNull(world.wiring.nodeAt(corner, Direction.NORTH), "A side within the chunk");
            assertNull(world.wiring.nodeAt(corner, Direction.UP));
            assertNull(world.wiring.nodeAt(corner.above(), Direction.EAST), "No block there");

            var piece = (WiredNodeImpl) world.wiring.nodeAt(corner, Direction.EAST);
            assertNotNull(piece);
            assertEquals(beside, piece.getNetwork() == network(b), "Connected to the block at " + other);

            // And the same once the other chunk has unloaded too.
            world.unloadChunk(ChunkPos.pack(other));
            var otherPiece = (WiredNodeImpl) world.wiring.nodeAt(other, other.getX() == 0 ? Direction.WEST : Direction.NORTH);
            assertNotNull(otherPiece);
            assertEquals(beside, piece.getNetwork() == otherPiece.getNetwork(), "Connected to the piece at " + other);
            assertEquals(beside ? 2 : 1, piece.getNetwork().nodes.size());
        }
    }

    @Test
    public void remembersNothingOfChunksWithoutWiring() {
        var world = new World();
        var chunk = ChunkPos.pack(3, -7);

        // A chunk with no wired blocks, or none which reach its edge.
        world.wiring.unload(chunk, List.of(), world::find);
        assertFalse(world.wiring.has(chunk));
        world.wiring.unload(chunk, List.of(new DormantWiring.Block(new BlockPos(3 * 16 + 5, 64, -7 * 16 + 5), 0x3f)), world::find);
        assertFalse(world.wiring.has(chunk));
        assertEquals(0, world.wiring.chunkCount());
        assertEquals(List.of(), world.wiring.ports());

        // Loading a chunk we know nothing of, twice, changes nothing.
        world.wiring.load(chunk).run();
        var retire = world.wiring.load(chunk);
        retire.run();
        retire.run();
        assertEquals(0, world.wiring.chunkCount());
    }

    @Test
    public void loadingOrUnloadingAChunkTwiceIsTheSameAsOnce() {
        var world = new World();
        var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 46);
        var b = world.place(new BlockPos(47, 64, 8), ALONG_X, "b");
        var chunk = ChunkPos.pack(1, 0);

        // It's told to unload three times over: as it stops being fully loaded, as it unloads, and once more.
        world.demote(1);
        world.unload(1);
        world.wiring.unload(chunk, world.blocksIn(chunk), world::find);
        assertEquals(1, world.wiring.ports().size());
        assertEquals(16 + 16 + 1, network(a).nodes.size());

        // And to load twice, before its blocks join their networks. Its piece stays in its network until they have.
        var retire = world.wiring.load(chunk);
        var retireAgain = world.wiring.load(chunk);
        assertFalse(world.wiring.has(chunk));
        assertSame(network(a), network(b));

        world.unloaded.remove(chunk);
        for (var block : world.blocksIn(chunk)) world.live.put(block.pos(), new NetworkTest.NetworkElement(block.pos().toShortString(), false));
        for (var block : world.blocksIn(chunk)) world.connect(block.pos());
        retireAgain.run();
        retire.run();
        retire.run();
        assertSame(network(a), network(b));
        assertEquals(48, network(a).nodes.size());
    }

    @Test
    public void keepsCablesApartWhoseChunksWereNeverSeen() {
        var world = new World();
        world.cable(0, 79);
        world.unload(1);
        world.unload(3);

        // The server restarts without the wiring of chunk 2, as if it had never been loaded.
        var saved = new ArrayList<>(world.wiring.ports());
        for (var chunkX : new int[]{ 0, 4 }) {
            var chunk = ChunkPos.pack(chunkX, 0);
            saved.addAll(DormantWiring.findPieces(chunk, world.blocksIn(chunk)));
        }
        for (var element : world.live.values()) element.getNode().remove();
        world.live.clear();
        for (var chunk = 0; chunk <= 4; chunk++) world.unloaded.add(ChunkPos.pack(chunk, 0));
        world.wiring = new DormantWiring(null);
        world.wiring.restore(saved, world::find);

        world.load(0);
        world.load(4);
        var a = world.live.get(new BlockPos(0, 64, 8));
        var b = world.live.get(new BlockPos(79, 64, 8));
        assertNotSame(network(a), network(b), "Nothing is known of the chunk between");
        assertEquals(16 + 1, network(a).nodes.size());
        var known = world;
        LongSet unknown = DormantWiring.frontier(world.wiring.ports(), pos -> known.wiring.has(pos) || !known.unloaded.contains(pos));
        assertEquals(new LongOpenHashSet(new long[]{ ChunkPos.pack(2, 0) }), new LongOpenHashSet(unknown));

        // Once it has loaded, and unloaded again, they're connected.
        world.load(2);
        assertSame(network(a), network(b));
        world.unload(2);
        assertSame(network(a), network(b));
        assertEquals(16 + 16 + 3, network(a).nodes.size());
        assertEquals(0, DormantWiring.frontier(world.wiring.ports(), pos -> known.wiring.has(pos) || !known.unloaded.contains(pos)).size());
    }

    @Test
    public void keepsLevelsApart() {
        // Two levels, with cables at the same place in each.
        var overworld = new World();
        var nether = new World();
        var a = overworld.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        var b = nether.place(new BlockPos(0, 64, 8), ALONG_X, "b");
        for (var world : List.of(overworld, nether)) {
            world.cable(1, 47);
            world.unload(1);
        }

        assertEquals(1, overworld.wiring.ports().size());
        assertEquals(1, nether.wiring.ports().size());
        var port = new BlockPos(16, 64, 8);
        assertNotSame(overworld.wiring.nodeAt(port, Direction.WEST), nether.wiring.nodeAt(port, Direction.WEST));
        assertNotSame(network(a), network(b));
        assertEquals(16 + 16 + 1, network(a).nodes.size());
        assertFalse(a.allPeripherals().containsKey("b"));

        nether.load(1);
        assertTrue(overworld.wiring.has(ChunkPos.pack(1, 0)));
        assertEquals(16 + 16 + 1, network(a).nodes.size());
        assertEquals(48, network(b).nodes.size());
    }

    /**
     * A cable across very many chunks which aren't loaded, restored all at once as when the server starts, with only
     * its ends loaded.
     */
    @Test
    public void keepsAVeryLongCableConnected() {
        var chunks = 2000;
        var saved = new ArrayList<DormantWiring.Ports>();
        for (var chunk = 1; chunk <= chunks; chunk++) {
            saved.add(new DormantWiring.Ports(
                ChunkPos.pack(chunk, 0),
                new long[]{ new BlockPos(chunk * 16, 64, 8).asLong(), new BlockPos(chunk * 16 + 15, 64, 8).asLong() },
                new byte[]{ (byte) bit(Direction.WEST), (byte) bit(Direction.EAST) }
            ));
        }
        // In no particular order, as they are in the file.
        Collections.shuffle(saved, new Random(1));

        var world = new World();
        for (var chunk = 1; chunk <= chunks; chunk++) world.unloaded.add(ChunkPos.pack(chunk, 0));
        world.wiring.restore(saved, world::find);
        assertEquals(chunks, world.wiring.chunkCount());

        var a = world.place(new BlockPos(15, 64, 8), ALONG_X, "a");
        var b = world.place(new BlockPos((chunks + 1) * 16, 64, 8), ALONG_X, "b");
        assertSame(network(a), network(b));
        assertEquals(chunks + 2, network(a).nodes.size());
        assertTrue(a.allPeripherals().containsKey("b"));

        // A chunk in the middle loads with its cable gone, which splits the network, and nothing else.
        world.load(chunks / 2);
        assertNotSame(network(a), network(b));
        assertEquals(chunks / 2, network(a).nodes.size());
        assertEquals(chunks - chunks / 2 + 1, network(b).nodes.size());
        assertFalse(a.allPeripherals().containsKey("b"));
    }

    /**
     * Two chunks which meet along a wall of wired blocks, as tall as the world: one piece each, with a port for every
     * block of the wall.
     */
    @Test
    public void connectsPiecesWithVeryManyPorts() {
        var world = new World();
        var all = 0x3f;
        for (var y = -64; y < 320; y++) {
            for (var z = 0; z < 16; z++) {
                world.blocks.put(new BlockPos(15, y, z), all);
                world.blocks.put(new BlockPos(16, y, z), all);
            }
        }

        // Their blocks never joined a network (which takes too long here, with every change checked): the chunks unload
        // as they are.
        var west = ChunkPos.pack(0, 0);
        var east = ChunkPos.pack(1, 0);
        var unloaded = assertTimeout(Duration.ofSeconds(20), () -> {
            world.wiring.unload(west, world.blocksIn(west), world::find);
            world.wiring.unload(east, world.blocksIn(east), world::find);
            return world.wiring.ports();
        });
        world.unloaded.add(west);
        world.unloaded.add(east);
        assertEquals(2, unloaded.size());
        for (var ports : unloaded) assertEquals(16 * 384, ports.positions().length);

        // A block north of one wall's end, and one south of the other's.
        var a = world.place(new BlockPos(15, 64, -1), all, "a");
        var b = world.place(new BlockPos(16, 64, 16), all, "b");

        var westPiece = (WiredNodeImpl) world.wiring.nodeAt(new BlockPos(15, 0, 0), Direction.EAST);
        var eastPiece = (WiredNodeImpl) world.wiring.nodeAt(new BlockPos(16, 300, 15), Direction.WEST);
        assertNotNull(westPiece);
        assertNotNull(eastPiece);
        assertNotSame(westPiece, eastPiece);
        assertSame(westPiece.getNetwork(), eastPiece.getNetwork());
        assertNotNull(world.wiring.nodeAt(new BlockPos(15, 0, 0), Direction.NORTH));
        assertNull(world.wiring.nodeAt(new BlockPos(15, 0, 1), Direction.NORTH));
        assertSame(network(a), network(b));
        assertSame(network(a), westPiece.getNetwork());
    }

    @Test
    public void keepsSeparateCablesInAChunkApart() {
        var world = new World();
        var a = world.place(new BlockPos(0, 64, 8), ALONG_X, "a");
        world.cable(1, 46);
        var b = world.place(new BlockPos(47, 64, 8), ALONG_X, "b");
        // Another cable through the same chunks, not joined to the first.
        var c = world.place(new BlockPos(0, 70, 8), ALONG_X, "c");
        for (var x = 1; x <= 46; x++) world.place(new BlockPos(x, 70, 8), ALONG_X, null);
        var d = world.place(new BlockPos(47, 70, 8), ALONG_X, "d");

        world.unload(1);
        assertSame(network(a), network(b));
        assertSame(network(c), network(d));
        assertNotSame(network(a), network(c));
        assertEquals(2, world.wiring.ports().size());
    }
}
