// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wired;

import dan200.computercraft.api.network.wired.WiredNode;
import dan200.computercraft.impl.network.wired.DormantWiring;
import dan200.computercraft.shared.computer.core.ServerContext;
import dan200.computercraft.shared.util.DirectionUtil;
import it.unimi.dsi.fastutil.longs.LongLinkedOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.SectionPos;
import net.minecraft.resources.Identifier;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.chunk.LevelChunk;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.*;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.*;
import java.util.function.LongPredicate;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

/**
 * Keeps wired networks connected through chunks which aren't loaded, and across server restarts.
 * <p>
 * When a chunk unloads, its cables and wired modems leave their networks. Instead, we remember the chunk's wiring (see
 * {@link DormantWiring}), which keeps the networks it joined connected, and lets cables next to it connect to it. When
 * the chunk loads again, its blocks join their networks, and we forget its wiring.
 * <p>
 * The wiring is saved to a file of its own, every minute or so when it has changed, and when the server stops. That
 * includes the wiring of loaded chunks, so networks come back after a restart before any chunk loads, and after a crash
 * as they were when last saved.
 */
public final class UnloadedWiring {
    private static final Logger LOG = LoggerFactory.getLogger(UnloadedWiring.class);

    private static final int VERSION = 1;

    /** How often to save the wiring when it has changed, in ticks. */
    private static final int SAVE_INTERVAL = 20 * 60;

    private static final class LevelWiring {
        final ServerLevel level;
        final DormantWiring wiring;

        /** Chunks which have loaded again, whose pieces are waiting for their blocks to join their networks. */
        final LongSet loading = new LongLinkedOpenHashSet();

        /** Loaded chunks which have (or have had) wired blocks, whose wiring is saved as it is. */
        final LongSet live = new LongOpenHashSet();

        LevelWiring(ServerLevel level) {
            this.level = level;
            wiring = new DormantWiring(level);
        }
    }

    private final Path file;
    private final Map<String, List<DormantWiring.Ports>> saved;
    private final IdentityHashMap<ServerLevel, LevelWiring> levels = new IdentityHashMap<>();
    private boolean dirty;
    private int sinceSave;

    public UnloadedWiring(Path file) {
        this.file = file;
        saved = read(file);
    }

    private static @Nullable UnloadedWiring of(@Nullable Level level) {
        if (!(level instanceof ServerLevel serverLevel)) return null;
        var context = ServerContext.getIfRunning(serverLevel.getServer());
        return context == null ? null : context.unloadedWiring();
    }

    private LevelWiring get(ServerLevel level) {
        var state = levels.get(level);
        if (state != null) return state;

        state = new LevelWiring(level);
        levels.put(level, state);

        // The wiring as it was when last saved. Its chunks join their networks as they load (and those already loaded,
        // straight away).
        var pieces = saved.remove(level.dimension().identifier().toString());
        if (pieces != null) {
            state.wiring.restore(pieces, (pos, side) -> liveNode(level, pos, side));
            for (var piece : pieces) {
                var chunk = piece.chunk();
                if (level.getChunkSource().getChunkNow(ChunkPos.getX(chunk), ChunkPos.getZ(chunk)) != null) state.loading.add(chunk);
            }
        }
        return state;
    }

    /**
     * Find what stands for a wired block in a chunk which isn't loaded, for a block next to it to connect to.
     *
     * @param level The level.
     * @param pos   The position of the block in the chunk which isn't loaded.
     * @param side  The side of it the block next to it is on.
     * @return The node to connect to, or {@code null} if we know of no wired block there which connects on that side.
     */
    static @Nullable WiredNode nodeAt(Level level, BlockPos pos, Direction side) {
        var wiring = of(level);
        return wiring == null ? null : wiring.get((ServerLevel) level).wiring.nodeAt(pos, side);
    }

    /**
     * A wired block has been added to a level, or loaded.
     *
     * @param blockEntity The block's block entity.
     */
    static void onAdded(BlockEntity blockEntity) {
        var level = blockEntity.getLevel();
        var wiring = of(level);
        if (wiring == null) return;
        wiring.get((ServerLevel) level).live.add(ChunkPos.pack(blockEntity.getBlockPos()));
        wiring.dirty = true;
    }

    /**
     * A wired block has changed, or been removed.
     *
     * @param blockEntity The block's block entity.
     */
    static void onChanged(BlockEntity blockEntity) {
        var wiring = of(blockEntity.getLevel());
        if (wiring != null) wiring.dirty = true;
    }

    /**
     * Connect two nodes, one of which may be in a network crossing many chunks.
     *
     * @param a One node.
     * @param b The other.
     */
    static void connect(WiredNode a, WiredNode b) {
        DormantWiring.connect(a, b);
    }

    /**
     * A chunk is unloading. This is called while its block entities are still in their networks.
     *
     * @param level The chunk's level.
     * @param chunk The chunk.
     */
    public void onChunkUnload(ServerLevel level, LevelChunk chunk) {
        var pos = chunk.getPos().pack();
        var blocks = wiredBlocks(chunk);
        var state = blocks.isEmpty() ? levels.get(level) : get(level);
        if (state == null) return;

        state.loading.remove(pos);
        state.live.remove(pos);
        if (blocks.isEmpty() && !state.wiring.has(pos)) return;

        state.wiring.unload(pos, blocks, (other, side) -> liveNode(level, other, side));
        dirty = true;
    }

    /**
     * A chunk has loaded. Its blocks join their networks again on the next tick.
     * <p>
     * Blocks would connect to their neighbours on their first tick, but chunks at the edge of what's loaded (such as
     * those around a computer kept loaded) don't tick. So we connect the wired blocks of every chunk which loads, not
     * only those we remember.
     *
     * @param level The chunk's level.
     * @param chunk The chunk.
     */
    public void onChunkLoad(ServerLevel level, LevelChunk chunk) {
        // Its block entities may not all be there yet, so look for wired blocks on the next tick.
        get(level).loading.add(chunk.getPos().pack());
    }

    public void tick() {
        // Joining a chunk may load others (and so add to the chunks loading, possibly in another level): see drain.
        for (var state : List.copyOf(levels.values())) drain(state.loading, pos -> join(state, pos));

        sinceSave++;
        if (dirty && sinceSave >= SAVE_INTERVAL) save();
    }

    /**
     * Try each of a set of chunks, and take out those which are done.
     * <p>
     * Trying one may load other chunks, which adds them to the set: a block looking at its neighbour in a chunk which is
     * still loading waits for that chunk, and the server finishes loading others meanwhile. Changing a set while going
     * through it spoils it, so go through a copy.
     *
     * @param chunks The chunks.
     * @param done   Tries a chunk, returning whether it's done.
     */
    static void drain(LongSet chunks, LongPredicate done) {
        for (var pos : chunks.toLongArray()) {
            if (chunks.contains(pos) && done.test(pos)) chunks.remove(pos);
        }
    }

    /**
     * A chunk which has loaded again: connect its blocks to their neighbours, and then take its pieces out of their
     * networks.
     *
     * @param state The chunk's level.
     * @param pos   The chunk.
     * @return Whether this was done, or should be tried again on the next tick.
     */
    private boolean join(LevelWiring state, long pos) {
        var level = state.level;
        var chunk = level.getChunkSource().getChunkNow(ChunkPos.getX(pos), ChunkPos.getZ(pos));
        if (chunk == null || !level.hasChunk(ChunkPos.getX(pos), ChunkPos.getZ(pos))) return false;

        var remembered = state.wiring.has(pos);
        var retire = state.wiring.load(pos);
        // Connect every block now: chunks at the edge of what's loaded don't tick, and nothing must be left unconnected
        // when the pieces go.
        var wired = false;
        for (var blockEntity : List.copyOf(chunk.getBlockEntities().values())) {
            if (blockEntity.isRemoved()) continue;
            if (blockEntity instanceof CableBlockEntity cable) {
                cable.connectionsChanged();
                wired = true;
            } else if (blockEntity instanceof WiredModemFullBlockEntity modem) {
                modem.connectionsChanged();
                wired = true;
            }
        }
        retire.run();
        if (wired) state.live.add(pos);
        if (wired || remembered) dirty = true;
        return true;
    }

    /**
     * Find the wired blocks in a chunk, and the sides they connect on.
     *
     * @param chunk The chunk.
     * @return The wired blocks.
     */
    private static List<DormantWiring.Block> wiredBlocks(LevelChunk chunk) {
        List<DormantWiring.Block> blocks = new ArrayList<>();
        for (var blockEntity : chunk.getBlockEntities().values()) {
            if (blockEntity.isRemoved()) continue;
            var sides = 0;
            if (blockEntity instanceof CableBlockEntity) {
                var state = blockEntity.getBlockState();
                for (var direction : DirectionUtil.FACINGS) {
                    if (CableBlock.canConnectIn(state, direction)) sides |= 1 << direction.get3DDataValue();
                }
            } else if (blockEntity instanceof WiredModemFullBlockEntity) {
                sides = DirectionUtil.ALL_SIDES;
            }
            if (sides != 0) blocks.add(new DormantWiring.Block(blockEntity.getBlockPos(), sides));
        }
        return blocks;
    }

    /**
     * Find the node of a wired block in a loaded chunk, if it connects on a side.
     *
     * @param level The level.
     * @param pos   The block's position.
     * @param side  The side.
     * @return The block's node, or {@code null}.
     */
    private static @Nullable WiredNode liveNode(ServerLevel level, BlockPos pos, Direction side) {
        var chunk = level.getChunkSource().getChunkNow(SectionPos.blockToSectionCoord(pos.getX()), SectionPos.blockToSectionCoord(pos.getZ()));
        if (chunk == null) return null;

        var blockEntity = chunk.getBlockEntity(pos, LevelChunk.EntityCreationType.CHECK);
        if (blockEntity == null || blockEntity.isRemoved()) return null;
        if (blockEntity instanceof CableBlockEntity cable) {
            var element = cable.getWiredElement(side);
            return element == null ? null : element.getNode();
        } else if (blockEntity instanceof WiredModemFullBlockEntity modem) {
            return modem.getElement().getNode();
        } else {
            return null;
        }
    }

    /**
     * Save the wiring of every chunk we know of: those which aren't loaded as we remember them, and those which are
     * as they are now.
     */
    public void save() {
        var result = new TreeMap<String, List<DormantWiring.Ports>>(saved);
        for (var state : levels.values()) {
            List<DormantWiring.Ports> pieces = new ArrayList<>();

            // Chunks which have just loaded are saved as they are now, along with every other loaded one.
            var loaded = new LongOpenHashSet(state.live);
            loaded.addAll(state.loading);
            for (var piece : state.wiring.ports()) {
                if (!loaded.contains(piece.chunk())) pieces.add(piece);
            }

            for (var it = loaded.iterator(); it.hasNext(); ) {
                var pos = it.nextLong();
                var chunk = state.level.getChunkSource().getChunkNow(ChunkPos.getX(pos), ChunkPos.getZ(pos));
                var blocks = chunk == null ? List.<DormantWiring.Block>of() : wiredBlocks(chunk);
                if (chunk == null || blocks.isEmpty()) {
                    state.live.remove(pos);
                    if (chunk == null && state.wiring.has(pos)) {
                        // Not loaded after all: keep what we remember.
                        for (var piece : state.wiring.ports()) {
                            if (piece.chunk() == pos) pieces.add(piece);
                        }
                    }
                    continue;
                }
                pieces.addAll(DormantWiring.findPieces(pos, blocks));
            }

            result.put(state.level.dimension().identifier().toString(), pieces);
        }

        write(file, result);
        dirty = false;
        sinceSave = 0;
    }

    /**
     * Save the wiring when the server stops.
     *
     * @param server The server.
     */
    public static void onServerStopping(MinecraftServer server) {
        var context = ServerContext.getIfRunning(server);
        if (context != null) context.unloadedWiring().save();
    }

    /**
     * Write the wiring of each dimension to a file.
     *
     * @param file       The file.
     * @param dimensions Each dimension's pieces of wiring, by name.
     */
    static void write(Path file, Map<String, List<DormantWiring.Ports>> dimensions) {
        // As with ComputerChunkLoader, write to a temporary file and move it over the original, so we're less likely to
        // corrupt it if the game is stopped.
        var newFile = file.resolveSibling(file.getFileName() + ".new");
        try {
            Files.createDirectories(Objects.requireNonNull(file.getParent()));
            try (var output = new DataOutputStream(new BufferedOutputStream(new GZIPOutputStream(Files.newOutputStream(newFile))))) {
                output.writeInt(VERSION);
                output.writeInt(dimensions.size());
                for (var dimension : dimensions.entrySet()) {
                    output.writeUTF(dimension.getKey());
                    output.writeInt(dimension.getValue().size());
                    for (var piece : dimension.getValue()) {
                        output.writeLong(piece.chunk());
                        output.writeInt(piece.positions().length);
                        for (var i = 0; i < piece.positions().length; i++) {
                            output.writeLong(piece.positions()[i]);
                            output.writeByte(piece.sides()[i]);
                        }
                    }
                }
            }

            try {
                Files.move(newFile, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException | UnsupportedOperationException e) {
                Files.move(newFile, file, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException e) {
            LOG.error("Cannot save '{}'", file, e);
        }
    }

    /**
     * Read the wiring of each dimension from a file.
     *
     * @param file The file.
     * @return Each dimension's pieces of wiring, by name, or nothing if the file is missing or can't be read.
     */
    static Map<String, List<DormantWiring.Ports>> read(Path file) {
        if (!Files.exists(file)) return new HashMap<>();
        try (var input = new DataInputStream(new BufferedInputStream(new GZIPInputStream(Files.newInputStream(file))))) {
            var version = input.readInt();
            if (version != VERSION) {
                LOG.warn("Cannot read '{}' (version {}), so wired networks will only reconnect as their chunks load.", file, version);
                return new HashMap<>();
            }

            var dimensionCount = input.readInt();
            Map<String, List<DormantWiring.Ports>> result = new HashMap<>();
            for (var d = 0; d < dimensionCount; d++) {
                var dimension = input.readUTF();
                var pieceCount = input.readInt();
                List<DormantWiring.Ports> pieces = new ArrayList<>(Math.min(pieceCount, 4096));
                for (var p = 0; p < pieceCount; p++) {
                    var chunk = input.readLong();
                    var portCount = input.readInt();
                    if (portCount <= 0 || portCount > 16 * 16 * 4096) throw new IOException("Bad number of ports " + portCount);
                    var positions = new long[portCount];
                    var sides = new byte[portCount];
                    for (var i = 0; i < portCount; i++) {
                        positions[i] = input.readLong();
                        sides[i] = input.readByte();
                    }
                    pieces.add(new DormantWiring.Ports(chunk, positions, sides));
                }
                // Only keep dimensions which (still) exist.
                if (Identifier.tryParse(dimension) != null) result.put(dimension, pieces);
            }
            return result;
        } catch (IOException | RuntimeException e) {
            LOG.error("Cannot read '{}', so wired networks will only reconnect as their chunks load.", file, e);
            return new HashMap<>();
        }
    }
}
