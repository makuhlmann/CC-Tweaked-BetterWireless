// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.impl.network.wired;

import dan200.computercraft.api.network.wired.WiredElement;
import dan200.computercraft.api.network.wired.WiredNode;
import dan200.computercraft.core.util.Nullability;
import it.unimi.dsi.fastutil.ints.Int2ObjectLinkedOpenHashMap;
import it.unimi.dsi.fastutil.longs.Long2IntOpenHashMap;
import it.unimi.dsi.fastutil.longs.Long2ObjectMap;
import it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap;
import it.unimi.dsi.fastutil.longs.LongLinkedOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.SectionPos;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.function.LongPredicate;

/**
 * The wiring of chunks which aren't loaded, which keeps wired networks connected through them.
 * <p>
 * A cable's block entity leaves its network when its chunk unloads, so a network crossing a chunk which isn't loaded
 * would fall apart. But nothing can change in a chunk which isn't loaded, so its wiring stays as it was until the chunk
 * loads again. We remember it: for each chunk, the connected pieces of wiring in it, and each piece's <em>ports</em>,
 * the blocks at the chunk's edge where it may connect to the next chunk. Each piece is one node in the network,
 * connected to whatever is on the other side of its ports: a wired block in a loaded chunk, or a piece in another
 * chunk which isn't loaded. So a network stays whole across any number of chunks which aren't loaded, for one node per
 * piece per chunk, rather than one per cable.
 * <p>
 * When a chunk loads, its blocks join the network again, and its pieces are retired once they have. The pieces can
 * also be {@linkplain #ports() saved} and {@linkplain #restore(Collection, LiveNodes) restored}, so networks come back
 * after the server restarts, before the chunks they cross are loaded.
 */
public final class DormantWiring {
    private static final Direction[] DIRECTIONS = Direction.values();

    /**
     * A wired block, and the sides it may connect on.
     *
     * @param pos   The block's position.
     * @param sides The sides it may connect on, as a bit set of {@link Direction#get3DDataValue()}.
     */
    public record Block(BlockPos pos, int sides) {
    }

    /**
     * A piece of wiring's ports: its blocks at the edge of its chunk, and the sides on which each may connect to the
     * next chunk.
     *
     * @param chunk     The chunk, as {@link ChunkPos#pack()}.
     * @param positions Each port's position, as {@link BlockPos#asLong()}.
     * @param sides     The sides each port may connect on, as a bit set of {@link Direction#get3DDataValue()}.
     */
    @SuppressWarnings("ArrayRecordComponent") // Never compared, and never changed once made.
    public record Ports(long chunk, long[] positions, byte[] sides) {
        public Ports {
            if (positions.length != sides.length || positions.length == 0) {
                throw new IllegalArgumentException("A piece needs at least one port, each with its sides");
            }
        }
    }

    /**
     * Find the node of a wired block in a loaded chunk.
     */
    @FunctionalInterface
    public interface LiveNodes {
        /**
         * Find the node of a loaded wired block which may connect on a side.
         *
         * @param pos  The block's position.
         * @param side The side it would connect on.
         * @return Its node, or {@code null} if there is no such block, or it doesn't connect on that side.
         */
        @Nullable
        WiredNode find(BlockPos pos, Direction side);
    }

    private final class Piece implements WiredElement {
        final Ports ports;
        final WiredNodeImpl node = new WiredNodeImpl(this);

        Piece(Ports ports) {
            this.ports = ports;
        }

        @Override
        public WiredNode getNode() {
            return node;
        }

        @Override
        public String getSenderID() {
            return "dormant";
        }

        @Override
        public Level getLevel() {
            return Nullability.assertNonNull(level);
        }

        @Override
        public Vec3 getPosition() {
            return Vec3.atCenterOf(BlockPos.of(ports.positions()[0]));
        }

        @Override
        public String toString() {
            return "DormantWiring.Piece{" + BlockPos.of(ports.positions()[0]) + "}";
        }

        int sides(long pos) {
            var positions = ports.positions();
            for (var i = 0; i < positions.length; i++) {
                if (positions[i] == pos) return ports.sides()[i];
            }
            return 0;
        }
    }

    private final @Nullable Level level;
    private final Long2ObjectMap<List<Piece>> chunks = new Long2ObjectOpenHashMap<>();
    private final Long2ObjectMap<Piece> byPort = new Long2ObjectOpenHashMap<>();

    /**
     * Create the wiring of a level's chunks which aren't loaded.
     *
     * @param level The level, which pieces report as theirs. This may only be {@code null} in tests, which never ask.
     */
    public DormantWiring(@Nullable Level level) {
        this.level = level;
    }

    /**
     * Find the pieces of wiring in a chunk, and their ports. Pieces without ports can't connect to anything outside
     * the chunk, and so are left out.
     *
     * @param chunk  The chunk, as {@link ChunkPos#pack()}.
     * @param blocks The wired blocks in the chunk.
     * @return Each piece's ports.
     */
    public static List<Ports> findPieces(long chunk, Collection<Block> blocks) {
        var count = blocks.size();
        var positions = new long[count];
        var sides = new int[count];
        var index = new Long2IntOpenHashMap(count);
        index.defaultReturnValue(-1);
        var i = 0;
        for (var block : blocks) {
            positions[i] = block.pos().asLong();
            sides[i] = block.sides();
            index.put(positions[i], i);
            i++;
        }

        // Join each block with those next to it which connect back.
        var parent = new int[count];
        for (i = 0; i < count; i++) parent[i] = i;
        for (i = 0; i < count; i++) {
            for (var direction : DIRECTIONS) {
                if ((sides[i] & bit(direction)) == 0) continue;
                var other = index.get(BlockPos.offset(positions[i], direction));
                if (other >= 0 && (sides[other] & bit(direction.getOpposite())) != 0) union(parent, i, other);
            }
        }

        // Then find each piece's ports: the sides of its blocks which face another chunk.
        var byPiece = new Int2ObjectLinkedOpenHashMap<List<long[]>>();
        for (i = 0; i < count; i++) {
            var outward = 0;
            for (var direction : Direction.Plane.HORIZONTAL) {
                if ((sides[i] & bit(direction)) != 0 && chunkOf(BlockPos.offset(positions[i], direction)) != chunk) {
                    outward |= bit(direction);
                }
            }
            if (outward != 0) byPiece.computeIfAbsent(find(parent, i), x -> new ArrayList<>()).add(new long[]{ positions[i], outward });
        }

        var pieces = new ArrayList<Ports>(byPiece.size());
        for (var list : byPiece.values()) {
            var piecePositions = new long[list.size()];
            var pieceSides = new byte[list.size()];
            for (var j = 0; j < list.size(); j++) {
                piecePositions[j] = list.get(j)[0];
                pieceSides[j] = (byte) list.get(j)[1];
            }
            pieces.add(new Ports(chunk, piecePositions, pieceSides));
        }
        return pieces;
    }

    /**
     * A chunk is unloading: remember its wiring, and keep the networks it joined connected through it. This must be
     * called while the chunk's wired blocks are still in their networks.
     *
     * @param chunk  The chunk, as {@link ChunkPos#pack()}.
     * @param blocks The wired blocks in the chunk.
     * @param live   Finds the wired blocks in loaded chunks.
     */
    public void unload(long chunk, Collection<Block> blocks, LiveNodes live) {
        // We may still have the pieces from when the chunk last unloaded, if it loaded again only briefly. Its blocks
        // are the truth, so start again, but only drop the old pieces once the new ones are in place.
        var old = remove(chunk);
        add(findPieces(chunk, blocks), live);
        if (old != null) retire(old);
    }

    /**
     * Restore pieces of wiring, such as those saved when the server last stopped.
     *
     * @param pieces The pieces' ports.
     * @param live   Finds the wired blocks in loaded chunks.
     */
    public void restore(Collection<Ports> pieces, LiveNodes live) {
        add(pieces, live);
    }

    private void add(Collection<Ports> pieces, LiveNodes live) {
        var added = new ArrayList<Piece>(pieces.size());
        for (var ports : pieces) {
            var piece = new Piece(ports);
            added.add(piece);
            chunks.computeIfAbsent(ports.chunk(), x -> new ArrayList<>()).add(piece);
            for (var pos : ports.positions()) byPort.put(pos, piece);
        }

        for (var piece : added) {
            var positions = piece.ports.positions();
            for (var i = 0; i < positions.length; i++) {
                for (var direction : Direction.Plane.HORIZONTAL) {
                    if ((piece.ports.sides()[i] & bit(direction)) == 0) continue;

                    var other = BlockPos.offset(positions[i], direction);
                    var otherChunk = chunkOf(other);
                    if (otherChunk == piece.ports.chunk()) continue;

                    WiredNode node;
                    if (chunks.containsKey(otherChunk)) {
                        // Another chunk which isn't loaded: connect to its piece there, if that connects back.
                        var otherPiece = byPort.get(other);
                        node = otherPiece != null && (otherPiece.sides(other) & bit(direction.getOpposite())) != 0 ? otherPiece.node : null;
                    } else {
                        node = live.find(BlockPos.of(other), direction.getOpposite());
                    }
                    if (node != null) connect(piece.node, node);
                }
            }
        }
    }

    /**
     * A chunk has loaded: stop using its pieces to find nodes. Once its wired blocks have joined their networks
     * again, retire the pieces.
     *
     * @param chunk The chunk, as {@link ChunkPos#pack()}.
     * @return Retires the chunk's pieces, taking them out of their networks. Call this once the chunk's wired blocks
     * have joined them again.
     */
    public Runnable load(long chunk) {
        var old = remove(chunk);
        return old == null ? () -> {
        } : () -> retire(old);
    }

    private @Nullable List<Piece> remove(long chunk) {
        var old = chunks.remove(chunk);
        if (old == null) return null;
        for (var piece : old) {
            for (var pos : piece.ports.positions()) byPort.remove(pos, piece);
        }
        return old;
    }

    private static void retire(List<Piece> pieces) {
        for (var piece : pieces) piece.node.remove();
    }

    /**
     * Whether we have the wiring of a chunk: it isn't loaded, or has only just loaded.
     *
     * @param chunk The chunk, as {@link ChunkPos#pack()}.
     * @return Whether we have its wiring.
     */
    public boolean has(long chunk) {
        return chunks.containsKey(chunk);
    }

    /**
     * Find the node standing for a wired block in a chunk which isn't loaded, for a block next to it to connect to.
     *
     * @param pos  The block's position.
     * @param side The side the block next to it is on.
     * @return The node of the block's piece, or {@code null} if we don't know of such a block, or it doesn't connect
     * on that side.
     */
    public @Nullable WiredNode nodeAt(BlockPos pos, Direction side) {
        var key = pos.asLong();
        var piece = byPort.get(key);
        return piece != null && (piece.sides(key) & bit(side)) != 0 ? piece.node : null;
    }

    /**
     * Get the ports of every piece we have, to save them.
     *
     * @return Every piece's ports, chunk by chunk.
     */
    public List<Ports> ports() {
        var result = new ArrayList<Ports>();
        for (var pieces : chunks.values()) {
            for (var piece : pieces) result.add(piece.ports);
        }
        return result;
    }

    /**
     * Count the chunks whose wiring we have.
     *
     * @return How many there are.
     */
    public int chunkCount() {
        return chunks.size();
    }

    /**
     * Find the chunks which wiring leads into, but which we know nothing of: the chunks across pieces' ports, which
     * aren't loaded, and whose wiring we don't have.
     *
     * @param ports The ports of the wiring we know of.
     * @param known Whether we know a chunk (given as {@link ChunkPos#pack()}): it's loaded, or we have its wiring.
     * @return The chunks, as {@link ChunkPos#pack()}, in the order their ports were given.
     */
    public static LongSet frontier(Collection<Ports> ports, LongPredicate known) {
        var result = new LongLinkedOpenHashSet();
        for (var piece : ports) {
            for (var i = 0; i < piece.positions().length; i++) {
                for (var direction : Direction.Plane.HORIZONTAL) {
                    if ((piece.sides()[i] & bit(direction)) == 0) continue;
                    var other = chunkOf(BlockPos.offset(piece.positions()[i], direction));
                    if (other != piece.chunk() && !known.test(other)) result.add(other);
                }
            }
        }
        return result;
    }

    /**
     * Connect two nodes. Connecting two networks copies one into the other, so this copies the smaller one, which
     * matters when one is large, as a network crossing many chunks may be.
     *
     * @param a One node.
     * @param b The other.
     */
    public static void connect(WiredNode a, WiredNode b) {
        if (a instanceof WiredNodeImpl wiredA && b instanceof WiredNodeImpl wiredB
            && wiredA.network.nodes.size() < wiredB.network.nodes.size()) {
            b.connectTo(a);
        } else {
            a.connectTo(b);
        }
    }

    private static long chunkOf(long pos) {
        return ChunkPos.pack(SectionPos.blockToSectionCoord(BlockPos.getX(pos)), SectionPos.blockToSectionCoord(BlockPos.getZ(pos)));
    }

    private static int bit(Direction direction) {
        return 1 << direction.get3DDataValue();
    }

    private static int find(int[] parent, int i) {
        while (parent[i] != i) {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        return i;
    }

    private static void union(int[] parent, int a, int b) {
        var rootA = find(parent, a);
        var rootB = find(parent, b);
        if (rootA != rootB) parent[rootA] = rootB;
    }
}
