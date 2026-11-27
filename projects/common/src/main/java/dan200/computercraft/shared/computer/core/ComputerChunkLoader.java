// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.computer.core;

import com.google.common.annotations.VisibleForTesting;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.reflect.TypeToken;
import dan200.computercraft.shared.util.BackgroundFileWriter;
import it.unimi.dsi.fastutil.longs.Long2ObjectMaps;
import it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ChunkLevel;
import net.minecraft.server.level.FullChunkStatus;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.TicketType;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.TicketStorage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.Writer;
import java.lang.reflect.Type;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * Keeps computers running when nobody is nearby, for computers which asked to with {@code os.setKeepLoaded}.
 * <p>
 * While such a computer is on, it refreshes a chunk ticket every tick. The ticket keeps the computer's chunk ticking,
 * and the chunks around it loaded, so peripherals across a chunk border still work. Once the computer stops refreshing
 * it (it is turned off, broken, or no longer wants to be kept loaded), the ticket times out and the chunk unloads as
 * usual.
 * <p>
 * A turtle keeps a larger area loaded (see {@link #MOVING_RADIUS}), and takes its ticket with it when it moves (see
 * {@link #move}), so the chunk it left isn't kept loaded.
 * <p>
 * Computers should also come back when the server restarts. Vanilla can save tickets with the world, but if CC: Tweaked
 * was ever removed, the world would then fail to read any of its tickets, including those from {@code /forceload}.
 * Instead, we remember which computers were being kept loaded in a file of our own, and add tickets for them when the
 * server starts. The computers then turn themselves back on as their chunks load. The file is written at most once a
 * second (a moving turtle changes it with every move), and when the server stops. If the server crashes, a turtle may
 * have moved since, and its chunk is then not loaded again.
 * <p>
 * The file is written on a thread of its own (see {@link BackgroundFileWriter}), as a disk which stalls would otherwise
 * stop the server, and could get it crashed by the watchdog.
 */
public final class ComputerChunkLoader {
    private static final Logger LOG = LoggerFactory.getLogger(ComputerChunkLoader.class);

    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().create();
    private static final Type FILE_TYPE = new TypeToken<Map<String, List<int[]>>>() {
    }.getType();

    /** How long a ticket lasts without being refreshed, in ticks. */
    private static final int TIMEOUT = 100;

    /** How long a computer has to turn back on after the server starts before we forget about it, in ticks. */
    private static final int STARTUP_GRACE = 20 * 60;

    /**
     * How often we forget computers which stopped refreshing their ticket, and save the computers we keep loaded if they
     * changed, in ticks.
     */
    private static final int PURGE_INTERVAL = 20;

    /**
     * The radius of the ticket of a computer which stays put. The computer's own chunk ticks, and the chunks around it
     * are loaded (but don't tick), which is enough for peripherals in a neighbouring chunk.
     */
    public static final int RADIUS = 1;

    /**
     * The radius of the ticket of a computer which moves, such as a turtle. The computer's own chunk and the chunks
     * around it tick, and the chunks around those are loaded, as with {@code /forceload}.
     * <p>
     * A chunk only starts ticking once the chunks around it are loaded. With {@link #RADIUS}, the chunk a turtle moves
     * into is loaded, but the chunks beyond it aren't: the turtle would stop at each chunk border until they had been
     * loaded (or generated), and its computer would be shut down if that took too long. With this radius, each chunk
     * next to the turtle is ticking before the turtle moves into it.
     */
    public static final int MOVING_RADIUS = 2;

    /** How long to wait for the file to be written when the server stops, in seconds. */
    private static final int CLOSE_TIMEOUT = 30;

    /**
     * The chunk ticket. This is never saved with the world (see above), so doesn't need to be registered.
     */
    private static final TicketType TICKET = new TicketType(
        TIMEOUT, TicketType.FLAG_LOADING | TicketType.FLAG_SIMULATION | TicketType.FLAG_KEEP_DIMENSION_ACTIVE
    );

    private final Path file;
    private final Path newFile;
    private final BackgroundFileWriter<Map<String, List<int[]>>> writer;

    /** For each dimension, the position of each computer we keep loaded. */
    private final Map<ResourceKey<Level>, Long2ObjectOpenHashMap<Kept>> computers = new HashMap<>();

    /** Whether {@link #computers} has changed since we last saved it. */
    private boolean dirty = false;

    ComputerChunkLoader(Path file) {
        this.file = file;
        newFile = file.resolveSibling(file.getFileName() + ".new");
        writer = new BackgroundFileWriter<>(file, this::write);
    }

    /**
     * Load the chunks of computers which were kept loaded when the server last stopped, so they turn back on.
     *
     * @param server The server which has just started.
     */
    public void start(MinecraftServer server) {
        var expires = server.getTickCount() + STARTUP_GRACE;
        for (var entry : read().entrySet()) {
            var dimension = Identifier.tryParse(entry.getKey());
            var level = dimension == null ? null : server.getLevel(ResourceKey.create(Registries.DIMENSION, dimension));
            if (level == null) {
                LOG.warn("Cannot find dimension {}, so its computers will not be turned back on.", entry.getKey());
                continue;
            }

            var positions = computers(level.dimension());
            for (var position : entry.getValue()) {
                if (position == null || position.length != 3) continue;

                // This only needs to tick the computer's own chunk, so it turns back on. It then keeps itself loaded
                // with its own radius.
                var pos = new BlockPos(position[0], position[1], position[2]);
                positions.put(pos.asLong(), new Kept(expires, RADIUS));
                addTicket(level, pos, RADIUS);
            }
        }
    }

    /**
     * Keep a computer loaded for a little longer. This should be called every tick while the computer is on.
     *
     * @param level  The level the computer is in.
     * @param pos    The computer's position.
     * @param radius The radius of the computer's ticket, either {@link #RADIUS} or {@link #MOVING_RADIUS}.
     */
    public void keepLoaded(ServerLevel level, BlockPos pos, int radius) {
        addTicket(level, pos, radius);

        var expires = level.getServer().getTickCount() + TIMEOUT;
        var positions = computers(level.dimension());
        var kept = positions.get(pos.asLong());
        if (kept == null) {
            positions.put(pos.asLong(), new Kept(expires, radius));
            dirty = true;
        } else {
            kept.expires = expires;
            kept.radius = radius;
        }
    }

    /**
     * Move a computer which is kept loaded, such as a turtle which has just moved. Its ticket moves with it.
     * <p>
     * The computer's new chunk is kept loaded at once, rather than when the computer next ticks. Its old position is
     * forgotten, so it isn't looked for there if the server restarts, and its old ticket is removed, so the chunk it
     * left isn't kept loaded. Computers in the same chunk with the same radius share a ticket though, so if there's
     * another in the old chunk, the ticket is left for that computer to refresh (or to time out).
     * <p>
     * This does nothing if the computer wasn't being kept loaded.
     *
     * @param oldLevel The level the computer was in.
     * @param oldPos   The computer's old position.
     * @param level    The level the computer is in now.
     * @param pos      The computer's new position.
     * @param radius   The radius of the computer's ticket, as passed to {@link #keepLoaded}.
     */
    public void move(ServerLevel oldLevel, BlockPos oldPos, ServerLevel level, BlockPos pos, int radius) {
        if (oldLevel == level && oldPos.equals(pos)) return;

        var oldPositions = computers.get(oldLevel.dimension());
        if (oldPositions == null) return;
        var old = oldPositions.get(oldPos.asLong());
        if (old == null) return;

        // Keep the new chunk loaded before letting go of the old one, so the chunks around both stay loaded.
        keepLoaded(level, pos, radius);
        oldPositions.remove(oldPos.asLong());
        dirty = true;

        var oldChunk = ChunkPos.containing(oldPos);
        if (oldLevel == level && oldChunk.equals(ChunkPos.containing(pos))) return;
        if (sharesTicket(oldPositions, oldChunk, old.radius)) return;
        oldLevel.getChunkSource().removeTicketWithRadius(TICKET, oldChunk, old.radius);
    }

    /**
     * Stop keeping a computer loaded, because it no longer wants to be. It's forgotten at once, so it won't be turned
     * back on if the server restarts. Its ticket is left to time out, so its chunk doesn't unload while the computer is
     * still running.
     *
     * @param level The level the computer is in.
     * @param pos   The computer's position.
     */
    public void release(ServerLevel level, BlockPos pos) {
        var positions = computers.get(level.dimension());
        if (positions == null || positions.remove(pos.asLong()) == null) return;
        dirty = true;
    }

    /**
     * Forget every computer, and release the chunks loaded for them. The game tests use this, so computers left over
     * from an earlier run aren't turned back on.
     *
     * @param server The current server.
     */
    public void reset(MinecraftServer server) {
        for (var entry : computers.entrySet()) {
            var level = server.getLevel(entry.getKey());
            if (level == null) continue;

            for (var kept : Long2ObjectMaps.fastIterable(entry.getValue())) {
                var chunk = ChunkPos.containing(BlockPos.of(kept.getLongKey()));
                level.getChunkSource().removeTicketWithRadius(TICKET, chunk, kept.getValue().radius);
            }
        }
        computers.clear();
        save();
    }

    /**
     * Check whether a computer is being kept loaded.
     *
     * @param level The level the computer is in.
     * @param pos   The computer's position.
     * @return Whether the computer has been kept loaded recently.
     */
    public boolean isKeptLoaded(ServerLevel level, BlockPos pos) {
        var positions = computers.get(level.dimension());
        return positions != null && positions.containsKey(pos.asLong());
    }

    /**
     * Check whether a chunk has the ticket of a computer we keep loaded. The game tests use this.
     *
     * @param level  The level the chunk is in.
     * @param chunk  The chunk.
     * @param radius The radius of the ticket.
     * @return Whether the chunk has the ticket.
     */
    @VisibleForTesting
    public static boolean hasTicket(ServerLevel level, ChunkPos chunk, int radius) {
        var tickets = level.getDataStorage().get(TicketStorage.TYPE);
        if (tickets == null) return false;

        var ticketLevel = ChunkLevel.byStatus(FullChunkStatus.FULL) - radius;
        for (var ticket : tickets.getTickets(chunk.pack())) {
            if (ticket.getType() == TICKET && ticket.getTicketLevel() == ticketLevel) return true;
        }
        return false;
    }

    /**
     * Forget computers which have stopped asking to be kept loaded, and save the computers we keep loaded if they
     * changed.
     *
     * @param server The current server.
     */
    void tick(MinecraftServer server) {
        var now = server.getTickCount();
        if (now % PURGE_INTERVAL != 0) return;

        for (var positions : computers.values()) {
            if (positions.values().removeIf(kept -> kept.expires < now)) dirty = true;
        }
        if (dirty) save();
    }

    /**
     * Save the computers we keep loaded, if they changed since we last saved them, and wait for them to be written. This
     * is called when the server stops, and nothing is saved after it.
     */
    public void close() {
        if (dirty) save();
        writer.close(CLOSE_TIMEOUT, TimeUnit.SECONDS);
    }

    /**
     * Save the computers we keep loaded. This only takes a copy of them: the file is written on another thread.
     */
    private void save() {
        dirty = false;

        var result = new TreeMap<String, List<int[]>>();
        for (var entry : computers.entrySet()) {
            if (entry.getValue().isEmpty()) continue;

            var positions = new ArrayList<int[]>(entry.getValue().size());
            for (var key : entry.getValue().keySet()) {
                var pos = BlockPos.of(key);
                positions.add(new int[]{ pos.getX(), pos.getY(), pos.getZ() });
            }
            result.put(entry.getKey().identifier().toString(), positions);
        }

        writer.write(result);
    }

    private Long2ObjectOpenHashMap<Kept> computers(ResourceKey<Level> dimension) {
        return computers.computeIfAbsent(dimension, x -> new Long2ObjectOpenHashMap<>());
    }

    /**
     * Check whether a computer we keep loaded has a ticket in a chunk. Tickets are shared by type and level, so this
     * includes computers with the same radius.
     *
     * @param positions The computers in the chunk's level.
     * @param chunk     The chunk.
     * @param radius    The radius of the ticket.
     * @return Whether any of the computers have the ticket.
     */
    private static boolean sharesTicket(Long2ObjectOpenHashMap<Kept> positions, ChunkPos chunk, int radius) {
        for (var kept : Long2ObjectMaps.fastIterable(positions)) {
            if (kept.getValue().radius == radius && ChunkPos.pack(BlockPos.of(kept.getLongKey())) == chunk.pack()) {
                return true;
            }
        }
        return false;
    }

    private static void addTicket(ServerLevel level, BlockPos pos, int radius) {
        level.getChunkSource().addTicketWithRadius(TICKET, ChunkPos.containing(pos), radius);
    }

    /**
     * A computer we keep loaded.
     */
    private static final class Kept {
        /** The tick after which we forget this computer, unless it asks to be kept loaded again. */
        long expires;

        /** The radius of the computer's ticket. */
        int radius;

        Kept(long expires, int radius) {
            this.expires = expires;
            this.radius = radius;
        }
    }

    private Map<String, List<int[]>> read() {
        if (!Files.isRegularFile(file)) return Map.of();

        try (var reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
            Map<String, List<int[]>> result = GSON.fromJson(reader, FILE_TYPE);
            return result == null ? Map.of() : result;
        } catch (Exception e) {
            LOG.error("Cannot read '{}', so computers will not be turned back on.", file, e);
            return Map.of();
        }
    }

    /**
     * Write the computers we keep loaded to the file. This is called on the {@linkplain #writer writer's} own thread.
     *
     * @param result The position of each computer we keep loaded, by dimension.
     * @return Whether the file was written.
     */
    private boolean write(Map<String, List<int[]>> result) {
        // As with IDAssigner, write to a temporary file and then move it over the original, so we're less likely to
        // corrupt it if the game is stopped.
        try {
            Files.createDirectories(Objects.requireNonNull(file.getParent()));
            try (var channel = FileChannel.open(newFile, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE)) {
                Writer output = new BufferedWriter(Channels.newWriter(channel, StandardCharsets.UTF_8));
                GSON.toJson(result, FILE_TYPE, output);
                output.flush();
                channel.force(false);
            }

            try {
                Files.move(newFile, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException | UnsupportedOperationException e) {
                Files.move(newFile, file, StandardCopyOption.REPLACE_EXISTING);
            }
            return true;
        } catch (IOException e) {
            LOG.error("Cannot save '{}'", file, e);
            return false;
        }
    }
}
