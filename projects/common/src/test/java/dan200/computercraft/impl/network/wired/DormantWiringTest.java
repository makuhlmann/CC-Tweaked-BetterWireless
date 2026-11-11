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
            var chunk = ChunkPos.pack(chunkX, 0);
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
