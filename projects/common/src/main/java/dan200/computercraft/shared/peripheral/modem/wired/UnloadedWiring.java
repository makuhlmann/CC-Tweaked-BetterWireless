// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wired;

import dan200.computercraft.api.network.wired.WiredNode;
import dan200.computercraft.core.util.Nullability;
import dan200.computercraft.impl.network.wired.DormantWiring;
import dan200.computercraft.shared.computer.core.ServerContext;
import dan200.computercraft.shared.util.DirectionUtil;
import it.unimi.dsi.fastutil.longs.LongArrayFIFOQueue;
import it.unimi.dsi.fastutil.longs.LongLinkedOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.SectionPos;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ChunkLevel;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.*;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.*;
import java.util.function.Consumer;
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
 * A chunk which stops being fully loaded (as one does when nothing nearby needs it any more) often stays in memory a
 * while before it unloads, or for good, beside a chunk kept loaded. Blocks next to it see it as unloaded from the start,
 * so we remember its wiring then, as if it had unloaded; and when it's fully loaded again, its blocks join their networks
 * as for a chunk which has loaded.
 * <p>
 * Chunks which cables lead into, but which have never been loaded since, aren't known at all. {@link #startTrace} loads
 * them one at a time, following the cables, so they are.
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

    /** The most chunks one trace looks at. */
    private static final int MAX_TRACE = 4096;

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

    /**
     * A search for wiring in chunks which cables lead into, but which we know nothing of: see {@link #startTrace}.
     */
    private static final class Trace {
        final LevelWiring state;
        final Consumer<Component> report;
        final LongArrayFIFOQueue queue = new LongArrayFIFOQueue();
        final LongSet seen = new LongOpenHashSet();
        int looked;
        int wired;

        Trace(LevelWiring state, Consumer<Component> report) {
            this.state = state;
            this.report = report;
        }
    }

    /**
     * What we know of a level's wiring.
     *
     * @param remembered How many chunks' wiring we remember.
     * @param unknown    How many chunks cables lead into which we know nothing of.
     * @param looked     How many chunks the trace running has looked at, if one is.
     * @param toLook     How many chunks it has yet to look at.
     * @param tracing    Whether a trace is running.
     */
    public record Status(int remembered, int unknown, int looked, int toLook, boolean tracing) {
    }

    private final Path file;
    private final Map<String, List<DormantWiring.Ports>> saved;
    private final IdentityHashMap<ServerLevel, LevelWiring> levels = new IdentityHashMap<>();
    private boolean dirty;
    private int sinceSave;
    private @Nullable Trace trace;

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
     * A chunk is unloading, or is no longer fully loaded. This is called while its block entities are still in their
     * networks.
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

    /**
     * A chunk's ticket level has changed. One which is no longer fully loaded stays in memory a while (or for good,
     * beside a chunk kept loaded), but blocks next to it see it as unloaded, and we're not told when it does unload: so
     * remember its wiring now, as if it had unloaded. One which is fully loaded again joins its networks again.
     *
     * @param level    The chunk's level.
     * @param pos      The chunk, as {@link ChunkPos#pack()}.
     * @param oldLevel Its old ticket level.
     * @param newLevel Its new ticket level.
     * @param chunk    The chunk, if it's in memory, and has been fully loaded.
     */
    public void onChunkLevelChanged(ServerLevel level, long pos, int oldLevel, int newLevel, @Nullable LevelChunk chunk) {
        var full = ChunkLevel.byStatus(ChunkStatus.FULL);
        boolean wasLoaded = oldLevel <= full, isLoaded = newLevel <= full;
        if (wasLoaded && !isLoaded) {
            if (chunk != null) {
                onChunkUnload(level, chunk);
            } else {
                var state = levels.get(level);
                if (state != null) state.loading.remove(pos);
            }
        } else if (!wasLoaded && isLoaded) {
            // It may not be loaded yet: it joins its networks once it is.
            get(level).loading.add(pos);
        }
    }

    public void tick() {
        // Joining a chunk may load others (and so add to the chunks loading, possibly in another level): see drain.
        for (var state : List.copyOf(levels.values())) drain(state.loading, pos -> join(state, pos));
        tickTrace();

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
                // Where the cable connects: where it may, and shows that it does. That's kept in its block state, so
                // it's still known while the block next to it is unloaded. (A cable placed next to one in a chunk which
                // isn't loaded is only joined to it once that chunk loads, as the other cable doesn't show it yet.)
                var state = blockEntity.getBlockState();
                for (var direction : DirectionUtil.FACINGS) {
                    if (CableBlock.canConnectIn(state, direction) && state.getValue(Nullability.assertNonNull(CableBlock.CONNECTIONS.get(direction)))) {
                        sides |= 1 << direction.get3DDataValue();
                    }
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
     * Start looking for wiring in the chunks which cables lead into, but which we know nothing of: neither loaded nor
     * remembered (they haven't been loaded since the wiring was first remembered). Each tick, one such chunk is loaded,
     * for a moment, which is enough for its wiring to be remembered, and cables are followed on through it. Once done,
     * networks crossing those chunks are whole, without anyone going there.
     *
     * @param level  The level.
     * @param report What to call with how it went, once it's done.
     * @return How many chunks there are to look at, to start with, or {@code -1} if a trace is running already.
     */
    public int startTrace(ServerLevel level, Consumer<Component> report) {
        if (trace != null) return -1;
        var state = get(level);
        var trace = new Trace(state, report);
        enqueue(trace, knownPorts(state));
        if (trace.queue.isEmpty()) return 0;
        this.trace = trace;
        return trace.queue.size();
    }

    /**
     * Stop looking for wiring in chunks we know nothing of.
     *
     * @return How many chunks the trace had looked at, or {@code -1} if none was running.
     */
    public int stopTrace() {
        var trace = this.trace;
        if (trace == null) return -1;
        this.trace = null;
        return trace.looked;
    }

    /**
     * Describe what we know of a level's wiring.
     *
     * @param level The level.
     * @return What we know.
     */
    public Status status(ServerLevel level) {
        var state = get(level);
        var unknown = DormantWiring.frontier(knownPorts(state), pos -> known(state, pos)).size();
        var trace = this.trace;
        return new Status(
            state.wiring.chunkCount(), unknown, trace == null ? 0 : trace.looked, trace == null ? 0 : trace.queue.size(), trace != null
        );
    }

    // The ports of every piece of wiring we know of: those we remember, and those of chunks which are loaded.
    private static List<DormantWiring.Ports> knownPorts(LevelWiring state) {
        var ports = new ArrayList<>(state.wiring.ports());
        var loaded = new LongOpenHashSet(state.live);
        loaded.addAll(state.loading);
        for (var it = loaded.iterator(); it.hasNext(); ) {
            var pos = it.nextLong();
            if (state.wiring.has(pos)) continue;
            var chunk = state.level.getChunkSource().getChunkNow(ChunkPos.getX(pos), ChunkPos.getZ(pos));
            if (chunk != null) ports.addAll(DormantWiring.findPieces(pos, wiredBlocks(chunk)));
        }
        return ports;
    }

    // Whether we know a chunk: it's loaded, or we remember its wiring.
    private static boolean known(LevelWiring state, long pos) {
        return state.wiring.has(pos) || state.level.hasChunk(ChunkPos.getX(pos), ChunkPos.getZ(pos));
    }

    private static void enqueue(Trace trace, Collection<DormantWiring.Ports> ports) {
        var frontier = DormantWiring.frontier(ports, pos -> trace.seen.contains(pos) || known(trace.state, pos));
        for (var it = frontier.iterator(); it.hasNext(); ) {
            var pos = it.nextLong();
            trace.seen.add(pos);
            trace.queue.enqueue(pos);
        }
    }

    // Look at the next chunk of the trace, if one is running.
    private void tickTrace() {
        var trace = this.trace;
        if (trace == null) return;
        var state = trace.state;
        var level = state.level;
        while (!trace.queue.isEmpty() && trace.looked < MAX_TRACE) {
            var pos = trace.queue.dequeueLong();
            // It may have loaded, or been remembered, since.
            if (known(state, pos)) continue;

            // This loads it for a moment only (the ticket lasts a tick), after which its wiring would be remembered.
            // Remember it now, so the cables can be followed on through it.
            trace.looked++;
            var chunk = level.getChunk(ChunkPos.getX(pos), ChunkPos.getZ(pos));
            var blocks = wiredBlocks(chunk);
            if (!blocks.isEmpty()) {
                trace.wired++;
                state.wiring.unload(pos, blocks, (other, side) -> liveNode(level, other, side));
                dirty = true;
                enqueue(trace, DormantWiring.findPieces(pos, blocks));
            }
            return;
        }

        this.trace = null;
        trace.report.accept(Component.translatable(
            trace.queue.isEmpty() ? "commands.computercraft.wiring.trace.done" : "commands.computercraft.wiring.trace.limit",
            trace.looked, trace.wired, trace.queue.size()
        ));
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

            // Read on to the end of the file, which checks it against its checksum. Wiring from a damaged file could
            // connect networks which aren't connected, so it must not be used.
            if (input.read() != -1) throw new IOException("There is more in the file than the wiring");
            return result;
        } catch (IOException | RuntimeException e) {
            LOG.error("Cannot read '{}', so wired networks will only reconnect as their chunks load.", file, e);
            return new HashMap<>();
        }
    }
}
