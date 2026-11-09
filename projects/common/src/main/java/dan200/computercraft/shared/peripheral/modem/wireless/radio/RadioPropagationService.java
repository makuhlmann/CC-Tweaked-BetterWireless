// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.core.util.ThreadUtils;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import net.minecraft.core.BlockPos;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.phys.Vec3;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Delivers wireless packets according to the {@linkplain PropagationModel propagation model}.
 * <p>
 * Computers transmit on their own threads, but the propagation model needs to read the world, which is only safe on
 * the server thread. Rather than block the computer thread while the server thread does this (which is what made the
 * original implementation so slow), transmissions are queued and then evaluated at the start of the next server tick.
 * <ul>
 *     <li>Evaluated links are cached for a few seconds, and are symmetric, so request/reply traffic (rednet, GPS) is
 *     evaluated once.</li>
 *     <li>Work is limited to a fixed time budget each tick. Anything left over waits until the next tick.</li>
 *     <li>Chunks are never loaded. If a link crosses chunks we know nothing about, we ask the
 *     {@linkplain HeightSource height sources} in the background and evaluate the link once they reply, or guess
 *     after a timeout.</li>
 * </ul>
 */
public final class RadioPropagationService {
    private static final Logger LOG = LoggerFactory.getLogger(RadioPropagationService.class);

    /** The maximum number of deliveries waiting to be processed. Anything beyond this is dropped. */
    private static final int MAX_QUEUED = 1 << 16;

    /** The maximum number of links waiting to be evaluated. Packets needing any more are dropped. */
    private static final int MAX_EVALUATIONS = 1 << 13;

    /** The maximum number of links to remember. */
    private static final int MAX_CACHED_LINKS = 1 << 14;

    /** The antenna sits on top of the modem, not in the middle of it. */
    private static final double ANTENNA_OFFSET = 0.5;

    private final Queue<Transmission> incoming = new ConcurrentLinkedQueue<>();
    private final AtomicInteger queued = new AtomicInteger();

    private final Map<LinkKey, CachedLink> links = new LinkedHashMap<>(256, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<LinkKey, CachedLink> eldest) {
            return size() > MAX_CACHED_LINKS;
        }
    };
    private final Map<LinkKey, Evaluation> evaluating = new HashMap<>();
    private final ArrayDeque<Evaluation> pending = new ArrayDeque<>();
    private final Map<ResourceKey<Level>, LevelHeights> heights = new ConcurrentHashMap<>();
    private final ExecutorService worker = Executors.newSingleThreadExecutor(ThreadUtils.lowPriorityFactory("Radio-Terrain"));

    private RadioSettings settings = RadioSettings.fromConfig();
    private long tick;

    private record Transmission(Packet packet, ServerLevel level, Vec3 origin, List<PacketReceiver> receivers) {
    }

    private record Delivery(Packet packet, PacketReceiver receiver, double distance, boolean thundering) {
    }

    private record LinkKey(ResourceKey<Level> level, long first, long second, int band) {
        static LinkKey of(ServerLevel level, Vec3 a, Vec3 b, RadioBand band) {
            var x = BlockPos.asLong((int) Math.floor(a.x), (int) Math.floor(a.y), (int) Math.floor(a.z));
            var y = BlockPos.asLong((int) Math.floor(b.x), (int) Math.floor(b.y), (int) Math.floor(b.z));
            return new LinkKey(level.dimension(), Math.min(x, y), Math.max(x, y), band.id());
        }
    }

    private record CachedLink(LinkResult result, long expires) {
    }

    private static final class Evaluation {
        final LinkKey key;
        final ServerLevel level;
        final Vec3 from, to;
        final RadioBand band;
        final long started;
        final List<Delivery> deliveries = new ArrayList<>(1);
        @Nullable LongSet missing;

        Evaluation(LinkKey key, ServerLevel level, Vec3 from, Vec3 to, RadioBand band, long started) {
            this.key = key;
            this.level = level;
            this.from = from;
            this.to = to;
            this.band = band;
            this.started = started;
        }
    }

    public RadioSettings settings() {
        return settings;
    }

    /**
     * Queue a packet to be delivered to some receivers. This may be called from any thread.
     *
     * @param packet    The packet to send.
     * @param level     The level the packet was sent in.
     * @param origin    Where the packet was sent from.
     * @param receivers The receivers which might be able to hear it.
     */
    public void submit(Packet packet, ServerLevel level, Vec3 origin, List<PacketReceiver> receivers) {
        if (receivers.isEmpty()) return;
        if (queued.addAndGet(receivers.size()) > MAX_QUEUED) {
            // Congestion: drop the packet, much like a real network would.
            queued.addAndGet(-receivers.size());
            return;
        }
        incoming.add(new Transmission(packet, level, origin, receivers));
    }

    /**
     * Remember the heights of a chunk before it unloads, so we don't need to look them up again.
     *
     * @param chunk The chunk which is being unloaded.
     */
    public void onChunkUnload(LevelChunk chunk) {
        if (!(chunk.getLevel() instanceof ServerLevel level)) return;
        getHeights(level).put(chunk.getPos().pack(), ChunkHeights.of(chunk));
    }

    public void close() {
        worker.shutdownNow();
        try {
            if (!worker.awaitTermination(1, TimeUnit.SECONDS)) LOG.warn("Radio terrain worker did not stop in time.");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /**
     * Evaluate queued links and deliver packets. This must be called on the server thread.
     */
    public void tick() {
        tick++;
        settings = RadioSettings.fromConfig();
        var deadline = System.nanoTime() + settings.tickBudgetNanos();

        // Turn transmissions into evaluations, delivering immediately if we've seen this link recently.
        Transmission transmission;
        while ((transmission = incoming.poll()) != null) {
            queued.addAndGet(-transmission.receivers().size());
            var level = transmission.level();
            var thundering = level.isThundering();
            var band = settings.band(transmission.packet().channel());
            var from = transmission.origin().add(0, ANTENNA_OFFSET, 0);

            for (var receiver : transmission.receivers()) {
                if (receiver.getLevel() != level) continue;
                var to = receiver.getPosition().add(0, ANTENNA_OFFSET, 0);
                var delivery = new Delivery(transmission.packet(), receiver, transmission.origin().distanceTo(receiver.getPosition()), thundering);

                var key = LinkKey.of(level, from, to, band);
                var cached = links.get(key);
                if (cached != null && cached.expires() > tick) {
                    deliver(delivery, band, cached.result());
                    continue;
                }

                var evaluation = evaluating.get(key);
                if (evaluation == null) {
                    // The server can't keep up with the number of distinct links, so drop the packet.
                    if (pending.size() >= MAX_EVALUATIONS) continue;

                    evaluation = new Evaluation(key, level, from, to, band, tick);
                    evaluating.put(key, evaluation);
                    pending.add(evaluation);
                }
                evaluation.deliveries.add(delivery);
            }
        }

        // Then evaluate as many links as we have time for.
        var count = pending.size();
        for (var i = 0; i < count && System.nanoTime() < deadline; i++) {
            var evaluation = pending.poll();
            if (evaluation == null) break;
            if (!tryEvaluate(evaluation)) pending.add(evaluation);
        }
    }

    private boolean tryEvaluate(Evaluation evaluation) {
        var level = evaluation.level;
        var heights = getHeights(level);
        var terrain = new LevelTerrainView(level, heights);
        var env = settings.environment();

        // Work out which chunks we need, and request any we don't know about.
        var missing = evaluation.missing;
        if (missing == null) {
            var chunks = new LongOpenHashSet();
            PropagationModel.forEachSample(evaluation.from.x, evaluation.from.z, evaluation.to.x, evaluation.to.z, env.maxProfileSamples(),
                (i, x, z) -> chunks.add(ChunkPos.pack(x >> 4, z >> 4)));
            evaluation.missing = missing = chunks;
        }

        var sources = heightSources();
        missing.removeIf((long chunk) -> {
            if (terrain.isKnown(ChunkPos.getX(chunk), ChunkPos.getZ(chunk))) return true;
            if (!heights.isFetching(chunk)) heights.request(chunk, sources, worker);
            return false;
        });

        if (!missing.isEmpty() && tick - evaluation.started < settings.lookupTimeoutTicks()) return false;

        var from = evaluation.from;
        var to = evaluation.to;
        var band = evaluation.band;
        var result = PropagationModel.evaluate(from.x, from.y, from.z, to.x, to.y, to.z, band.frequencyMHz(), band.linkBudget(), env, terrain);

        // Links evaluated with incomplete information are only cached briefly, so we try again once we know more.
        var cacheTicks = missing.isEmpty() ? settings.cacheTicks() : Math.min(settings.cacheTicks(), 20);
        links.put(evaluation.key, new CachedLink(result, tick + cacheTicks));
        evaluating.remove(evaluation.key);
        for (var delivery : evaluation.deliveries) deliver(delivery, band, result);
        return true;
    }

    private List<HeightSource> heightSources() {
        var sources = new ArrayList<HeightSource>(3);
        sources.add(HeightSource.DISK);
        if (settings.useDistantHorizons()) {
            var distantHorizons = DistantHorizonsHeights.get();
            if (distantHorizons != null) sources.add(distantHorizons);
        }
        if (settings.useGenerator()) sources.add(HeightSource.GENERATOR);
        return sources;
    }

    private void deliver(Delivery delivery, RadioBand band, LinkResult result) {
        var signal = band.transmitPower() - result.loss();
        var threshold = RadioBand.SENSITIVITY + (delivery.thundering() ? settings.stormPenalty() : 0);
        if (signal < threshold) return;

        delivery.receiver().receiveSameDimension(delivery.packet(), delivery.distance(), Math.round(signal * 10) / 10.0);
    }

    private LevelHeights getHeights(ServerLevel level) {
        return heights.computeIfAbsent(level.dimension(), k -> new LevelHeights(level));
    }
}
