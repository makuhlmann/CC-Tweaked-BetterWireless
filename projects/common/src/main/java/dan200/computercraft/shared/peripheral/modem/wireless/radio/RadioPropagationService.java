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
 * <p>
 * Packets from ender modems also cross into other dimensions, where only other ender modems hear them. The signal
 * appears at the {@linkplain DimensionMapping corresponding position} in the receiver's dimension and propagates from
 * there, like any other. The same link can be made the other way round, from the receiver's corresponding position in
 * the sender's dimension. Both are evaluated, and the better one counts, so a link is as good in both directions. Each
 * is an ordinary link within one dimension, so they share the cache and the tick budget with every other link.
 */
public final class RadioPropagationService {
    private static final Logger LOG = LoggerFactory.getLogger(RadioPropagationService.class);

    /** The maximum number of deliveries waiting to be processed. Anything beyond this is dropped. */
    private static final int MAX_QUEUED = 1 << 16;

    /** The maximum number of links waiting to be evaluated. Packets needing any more are dropped. */
    private static final int MAX_EVALUATIONS = 1 << 13;

    /** The maximum number of links to remember. */
    private static final int MAX_CACHED_LINKS = 1 << 14;

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

    /** Written on the server thread, read by computer threads when transmitting. */
    private volatile RadioSettings settings = RadioSettings.fromConfig();
    private long tick;
    private long lastErrorLog = Long.MIN_VALUE;

    /**
     * A packet waiting to be delivered.
     *
     * @param packet         The packet.
     * @param level          The level it was sent in.
     * @param origin         Where it was sent from.
     * @param antenna        Where the sender's antenna is.
     * @param receivers      The receivers which might hear it.
     * @param crossDimension Whether it's for receivers in other dimensions.
     * @param frequency      The frequency it was sent at, in MHz.
     * @param power          The power it was sent with, in dBm.
     */
    private record Transmission(
        Packet packet, ServerLevel level, Vec3 origin, Vec3 antenna, List<PacketReceiver> receivers, boolean crossDimension,
        double frequency, double power
    ) {
    }

    /**
     * Something which is waiting for a link to be evaluated.
     */
    private sealed interface Waiting permits Delivery, CrossDelivery {
        /**
         * The frequency the link is needed at.
         *
         * @return The frequency, in MHz.
         */
        double frequency();

        /**
         * How much the link may lose for this to be delivered: its power, less the weakest signal its receiver hears.
         *
         * @return The budget, in dB.
         */
        double budget();
    }

    private record Delivery(
        Packet packet, PacketReceiver receiver, double distance, boolean thundering, double frequency, double power
    ) implements Waiting {
        @Override
        public double budget() {
            return power - RadioSettings.sensitivity(receiver);
        }
    }

    /**
     * A packet for a receiver in another dimension, which waits for up to two links: the one in the receiver's
     * dimension, and the one in the sender's. It's delivered with the better of them.
     */
    private static final class CrossDelivery implements Waiting {
        final Packet packet;
        final PacketReceiver receiver;
        final boolean thundering;
        final double frequency;
        final double power;
        int waiting;
        double loss = Double.POSITIVE_INFINITY;

        CrossDelivery(Packet packet, PacketReceiver receiver, boolean thundering, double frequency, double power, int waiting) {
            this.packet = packet;
            this.receiver = receiver;
            this.thundering = thundering;
            this.frequency = frequency;
            this.power = power;
            this.waiting = waiting;
        }

        @Override
        public double frequency() {
            return frequency;
        }

        @Override
        public double budget() {
            return power - RadioSettings.sensitivity(receiver);
        }
    }

    /**
     * A link, by the blocks at each end. Links are reciprocal, and a {@link LinkPath} serves every frequency, so the
     * key is the same either way round, whatever the frequency.
     *
     * @param level  The level the link is in.
     * @param first  The packed position of the end with the smaller packed position.
     * @param second The packed position of the other end.
     */
    private record LinkKey(ResourceKey<Level> level, long first, long second) {
        static LinkKey of(ServerLevel level, Vec3 a, Vec3 b) {
            var x = BlockPos.asLong((int) Math.floor(a.x), (int) Math.floor(a.y), (int) Math.floor(a.z));
            var y = BlockPos.asLong((int) Math.floor(b.x), (int) Math.floor(b.y), (int) Math.floor(b.z));
            return new LinkKey(level.dimension(), Math.min(x, y), Math.max(x, y));
        }
    }

    private record CachedLink(LinkPath path, long expires) {
    }

    private static final class Evaluation {
        final LinkKey key;
        final ServerLevel level;
        final Vec3 from, to;
        final long started;
        /** Whether this is for a packet from another dimension, whose links are remembered for longer. */
        final boolean crossDimension;
        final List<Waiting> deliveries = new ArrayList<>(1);
        @Nullable LongSet missing;
        /** The largest budget of anything waiting for the link: how far to trace it. */
        double budget;

        Evaluation(LinkKey key, ServerLevel level, Vec3 from, Vec3 to, long started, boolean crossDimension, double budget) {
            this.key = key;
            this.level = level;
            this.from = from;
            this.to = to;
            this.started = started;
            this.crossDimension = crossDimension;
            this.budget = budget;
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
     * @param origin    Where the packet was sent from. This is used for the distance reported to the receiver.
     * @param receivers The receivers which might be able to hear it.
     * @param frequency The frequency the packet is sent at, in MHz.
     * @param power     The power the packet is sent with, in dBm.
     */
    public void submit(Packet packet, ServerLevel level, Vec3 origin, List<PacketReceiver> receivers, double frequency, double power) {
        submit(packet, level, origin, receivers, false, frequency, power);
    }

    /**
     * Queue a packet from an ender modem to be delivered to some receivers in other dimensions. This may be called from
     * any thread.
     *
     * @param packet    The packet to send.
     * @param level     The level the packet was sent in.
     * @param origin    Where the packet was sent from.
     * @param receivers The receivers which might be able to hear it. Those in the same level, or which aren't
     *                  inter-dimensional, are skipped.
     * @param frequency The frequency the packet is sent at, in MHz.
     * @param power     The power the packet is sent with, in dBm.
     */
    public void submitCrossDimension(Packet packet, ServerLevel level, Vec3 origin, List<PacketReceiver> receivers, double frequency, double power) {
        submit(packet, level, origin, receivers, true, frequency, power);
    }

    private void submit(
        Packet packet, ServerLevel level, Vec3 origin, List<PacketReceiver> receivers, boolean crossDimension, double frequency, double power
    ) {
        if (receivers.isEmpty()) return;
        if (queued.addAndGet(receivers.size()) > MAX_QUEUED) {
            // Congestion: drop the packet, much like a real network would.
            queued.addAndGet(-receivers.size());
            return;
        }
        incoming.add(new Transmission(
            packet, level, origin, RadioAntenna.of(packet.sender(), origin), receivers, crossDimension, frequency, power
        ));
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
            var from = transmission.antenna();

            for (var receiver : transmission.receivers()) {
                if (transmission.crossDimension()) {
                    queueCrossDimension(transmission, receiver);
                    continue;
                }

                if (receiver.getLevel() != level) continue;
                var position = receiver.getPosition();
                var to = RadioAntenna.of(receiver, position);
                var delivery = new Delivery(
                    transmission.packet(), receiver, transmission.origin().distanceTo(position), thundering,
                    transmission.frequency(), transmission.power()
                );
                request(level, from, to, delivery, false);
            }
        }

        // Then evaluate as many links as we have time for.
        var count = pending.size();
        for (var i = 0; i < count && System.nanoTime() < deadline; i++) {
            var evaluation = pending.poll();
            if (evaluation == null) break;

            boolean done;
            try {
                done = tryEvaluate(evaluation);
            } catch (RuntimeException e) {
                // This runs as part of the server tick, so must never throw. Drop the link instead.
                logError("Failed to evaluate radio link", e);
                evaluating.remove(evaluation.key);
                for (var waiting : evaluation.deliveries) complete(waiting, null);
                done = true;
            }
            if (!done) pending.add(evaluation);
        }
    }

    /**
     * Find how good a link is, and tell whatever is waiting for it: at once if we've seen the link recently, and
     * otherwise once it has been evaluated.
     *
     * @param level          The level the link is in.
     * @param from           One end of the link.
     * @param to             The other end.
     * @param waiting        What's waiting for the link.
     * @param crossDimension Whether this is for a packet from another dimension.
     */
    private void request(ServerLevel level, Vec3 from, Vec3 to, Waiting waiting, boolean crossDimension) {
        var key = LinkKey.of(level, from, to);
        var cached = links.get(key);
        // Links are only traced as far as what's waiting for them needs: a path traced for a weaker transmitter
        // serves a stronger one only if the link was within its budget. Otherwise, it's traced again, further.
        if (cached != null && cached.expires() > tick && cached.path().serves(waiting.frequency(), waiting.budget())) {
            complete(waiting, cached.path());
            return;
        }

        var evaluation = evaluating.get(key);
        if (evaluation == null) {
            // The server can't keep up with the number of distinct links, so drop the packet.
            if (pending.size() >= MAX_EVALUATIONS) {
                complete(waiting, null);
                return;
            }

            evaluation = new Evaluation(key, level, from, to, tick, crossDimension, waiting.budget());
            evaluating.put(key, evaluation);
            pending.add(evaluation);
        }
        evaluation.budget = Math.max(evaluation.budget, waiting.budget());
        evaluation.deliveries.add(waiting);
    }

    /**
     * Tell something which was waiting for a link how good the link is.
     *
     * @param waiting What was waiting.
     * @param path    The traced link, or {@code null} if it couldn't be traced.
     */
    private void complete(Waiting waiting, @Nullable LinkPath path) {
        if (waiting instanceof Delivery delivery) {
            if (path != null) deliver(delivery, path.evaluate(delivery.frequency()));
        } else if (waiting instanceof CrossDelivery delivery) {
            if (path != null) delivery.loss = Math.min(delivery.loss, path.evaluate(delivery.frequency).loss());
            if (--delivery.waiting == 0) deliverCrossDimension(delivery);
        }
    }

    /**
     * Queue a packet from an ender modem for a receiver in another dimension.
     * <p>
     * The link may be made in either dimension: from where the sender's signal appears in the receiver's dimension to
     * the receiver, or from the sender to where the receiver's signal would appear in the sender's dimension. We
     * evaluate whichever of those could possibly work, and the better one counts.
     *
     * @param transmission The transmission.
     * @param receiver     The receiver.
     */
    private void queueCrossDimension(Transmission transmission, PacketReceiver receiver) {
        var level = transmission.level();
        if (!receiver.isInterdimensional() || !(receiver.getLevel() instanceof ServerLevel other) || other == level) return;

        var packet = transmission.packet();
        var from = transmission.antenna();
        var to = RadioAntenna.of(receiver, receiver.getPosition());
        var heights = settings.dimensionHeights();
        var there = DimensionMapping.map(from, level, other, heights);
        var here = DimensionMapping.map(to, other, level, heights);

        // Ender modems are weak, so most are out of range whatever is in the way. Don't look at terrain for those.
        var frequency = transmission.frequency();
        var power = transmission.power();
        var sensitivity = RadioSettings.sensitivity(receiver);
        var throughTheirs = settings.isPossible(there.distanceTo(to), frequency, power, sensitivity);
        var throughOurs = settings.isPossible(from.distanceTo(here), frequency, power, sensitivity);
        if (!throughTheirs && !throughOurs) return;

        var delivery = new CrossDelivery(
            packet, receiver, other.isThundering(), frequency, power, (throughTheirs ? 1 : 0) + (throughOurs ? 1 : 0)
        );
        if (throughTheirs) request(other, there, to, delivery, true);
        if (throughOurs) request(level, from, here, delivery, true);
    }

    private void logError(String message, Exception e) {
        var now = System.currentTimeMillis();
        if (now - lastErrorLog < 60_000) return;
        lastErrorLog = now;
        LOG.error("{} (further errors in the next minute are suppressed)", message, e);
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
        var path = PropagationModel.trace(from.x, from.y, from.z, to.x, to.y, to.z, evaluation.budget, env, terrain);

        // Links evaluated with incomplete information are only cached briefly, so we try again once we know more.
        // Links between dimensions are mostly between computers which stay where they are, so are kept for longer.
        var cacheTicks = evaluation.crossDimension ? settings.crossCacheTicks() : settings.cacheTicks();
        if (!missing.isEmpty()) cacheTicks = Math.min(cacheTicks, 20);
        links.put(evaluation.key, new CachedLink(path, tick + cacheTicks));
        evaluating.remove(evaluation.key);
        for (var waiting : evaluation.deliveries) complete(waiting, path);
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

    private void deliver(Delivery delivery, LinkResult result) {
        var signal = delivery.power() - result.loss();
        var threshold = RadioSettings.sensitivity(delivery.receiver()) + (delivery.thundering() ? settings.stormPenalty() : 0);
        if (signal < threshold) return;

        try {
            delivery.receiver().receiveSameDimension(delivery.packet(), delivery.distance(), Math.round(signal * 10) / 10.0);
        } catch (RuntimeException e) {
            logError("Packet receiver " + delivery.receiver() + " failed to receive a packet", e);
        }
    }

    private void deliverCrossDimension(CrossDelivery delivery) {
        if (delivery.loss == Double.POSITIVE_INFINITY) return;

        var signal = delivery.power - delivery.loss;
        var threshold = RadioSettings.sensitivity(delivery.receiver) + (delivery.thundering ? settings.stormPenalty() : 0);
        if (signal < threshold) return;

        try {
            // There's no distance between dimensions: their coordinates don't line up, so it would only mislead GPS.
            delivery.receiver.receiveDifferentDimension(delivery.packet, Math.round(signal * 10) / 10.0);
        } catch (RuntimeException e) {
            logError("Packet receiver " + delivery.receiver + " failed to receive a packet", e);
        }
    }

    private LevelHeights getHeights(ServerLevel level) {
        return heights.computeIfAbsent(level.dimension(), k -> new LevelHeights(level));
    }
}
