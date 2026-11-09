// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.computer.core;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.reflect.TypeToken;
import it.unimi.dsi.fastutil.longs.Long2LongOpenHashMap;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.TicketType;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
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

/**
 * Keeps computers running when nobody is nearby, for computers which asked to with {@code os.setKeepLoaded}.
 * <p>
 * While such a computer is on, it refreshes a chunk ticket every tick. The ticket keeps the computer's chunk ticking,
 * and the chunks around it loaded, so peripherals across a chunk border still work. Once the computer stops refreshing
 * it (it is turned off, broken, or no longer wants to be kept loaded), the ticket times out and the chunk unloads as
 * usual.
 * <p>
 * Computers should also come back when the server restarts. Vanilla can save tickets with the world, but if CC: Tweaked
 * was ever removed, the world would then fail to read any of its tickets, including those from {@code /forceload}.
 * Instead, we remember which computers were being kept loaded in a file of our own, and add tickets for them when the
 * server starts. The computers then turn themselves back on as their chunks load.
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

    /** How often we forget computers which stopped refreshing their ticket, in ticks. */
    private static final int PURGE_INTERVAL = 20;

    /**
     * The radius of the ticket. The computer's own chunk ticks, and the chunks around it are loaded (but don't tick),
     * which is enough for peripherals in a neighbouring chunk.
     */
    private static final int RADIUS = 1;

    /**
     * The chunk ticket. This is never saved with the world (see above), so doesn't need to be registered.
     */
    private static final TicketType TICKET = new TicketType(
        TIMEOUT, TicketType.FLAG_LOADING | TicketType.FLAG_SIMULATION | TicketType.FLAG_KEEP_DIMENSION_ACTIVE
    );

    private final Path file;
    private final Path newFile;

    /** For each dimension, the position of each computer we keep loaded, and the tick after which we forget it. */
    private final Map<ResourceKey<Level>, Long2LongOpenHashMap> computers = new HashMap<>();

    ComputerChunkLoader(Path file) {
        this.file = file;
        newFile = file.resolveSibling(file.getFileName() + ".new");
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

                var pos = new BlockPos(position[0], position[1], position[2]);
                positions.put(pos.asLong(), expires);
                addTicket(level, pos);
            }
        }
    }

    /**
     * Keep a computer loaded for a little longer. This should be called every tick while the computer is on.
     *
     * @param level The level the computer is in.
     * @param pos   The computer's position.
     */
    public void keepLoaded(ServerLevel level, BlockPos pos) {
        addTicket(level, pos);

        var positions = computers(level.dimension());
        var key = pos.asLong();
        var added = !positions.containsKey(key);
        positions.put(key, level.getServer().getTickCount() + TIMEOUT);
        if (added) save();
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
     * Forget computers which have stopped asking to be kept loaded.
     *
     * @param server The current server.
     */
    void tick(MinecraftServer server) {
        var now = server.getTickCount();
        if (now % PURGE_INTERVAL != 0) return;

        var changed = false;
        for (var positions : computers.values()) {
            if (positions.long2LongEntrySet().removeIf(entry -> entry.getLongValue() < now)) changed = true;
        }
        if (changed) save();
    }

    private Long2LongOpenHashMap computers(ResourceKey<Level> dimension) {
        return computers.computeIfAbsent(dimension, x -> new Long2LongOpenHashMap());
    }

    private static void addTicket(ServerLevel level, BlockPos pos) {
        level.getChunkSource().addTicketWithRadius(TICKET, ChunkPos.containing(pos), RADIUS);
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

    private void save() {
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

        // As with IDAssigner, write to a temporary file and then move it over the original, so we're less likely to
        // corrupt it if the game is stopped.
        try {
            Files.createDirectories(Objects.requireNonNull(file.getParent()));
            try (var channel = FileChannel.open(newFile, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE)) {
                Writer writer = new BufferedWriter(Channels.newWriter(channel, StandardCharsets.UTF_8));
                GSON.toJson(result, FILE_TYPE, writer);
                writer.flush();
                channel.force(false);
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
}
