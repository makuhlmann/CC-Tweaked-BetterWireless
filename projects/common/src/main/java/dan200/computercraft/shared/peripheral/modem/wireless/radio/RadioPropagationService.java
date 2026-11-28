// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.core.util.ThreadUtils;
import net.minecraft.core.BlockPos;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.TickTask;
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
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Delivers wireless packets according to the {@linkplain PropagationModel propagation model}.
 * <p>
 * Computers transmit on their own threads, but the propagation model needs to read the world, which is only safe on
 * the server thread. Rather than block the computer thread while the server thread does this (which is what made the
 * original implementation so slow), transmissions are queued and then evaluated on the server thread: as soon as it has
 * time between ticks, and at the start of every tick.
 * <ul>
 *     <li>Evaluated links are cached for a few seconds, and are symmetric, so request/reply traffic (rednet, GPS) is
 *     evaluated once.</li>
 *     <li>A packet over a link which is cached doesn't wait for the server thread at all: it's delivered at once, on the
 *     thread which sent it, as the original wireless modems did. A link in use is traced again in the background shortly
 *     before it expires, so packets between radios which stay put keep arriving at once: only a link which hasn't been
 *     used for a while has to wait for the server thread. Packets from a sender which has some still waiting wait
 *     behind them, so a sender's packets arrive in the order it sent them.</li>
 *     <li>A packet between two radios whose link was traced a moment ago, and which have each moved no further than
 *     {@code move_tolerance} since, is delivered at once with that path, while the link where they are now is traced
 *     in the background (see {@link RecentLinks}). So a phone moving about doesn't wait for every block's link to be
 *     traced, nor does a link which is traced again because it was last traced a while ago.</li>
 *     <li>Work is limited to a fixed time budget each tick, and each time the server thread has time between ticks
 *     (but never into the next tick). Anything left over waits until then.</li>
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

    /** How long before the next tick is due a run between ticks must stop, in nanoseconds. */
    private static final long WAKE_MARGIN_NANOS = 1_000_000;

    private final ServerThread serverThread;
    private final Queue<Transmission> incoming = new ConcurrentLinkedQueue<>();

    /** Cached links in use which expire soon, to trace again on the server thread. */
    private final Queue<Renewal> renewals = new ConcurrentLinkedQueue<>();
    private final AtomicInteger queued = new AtomicInteger();

    /** Whether a run between ticks has been scheduled, and hasn't started yet. */
    private final AtomicBoolean wakeScheduled = new AtomicBoolean();

    /** The senders with packets queued, whose next packets queue behind them. */
    private final QueuedSenders queuedSenders = new QueuedSenders();

    /** The links we've traced. This is read on any thread. */
    private final LinkCache<LinkKey> links = new LinkCache<>(MAX_CACHED_LINKS);
    private final Map<LinkKey, Evaluation> evaluating = new HashMap<>();
    private final RecentLinks recent = new RecentLinks(MAX_CACHED_LINKS);
    private final ArrayDeque<Evaluation> pending = new ArrayDeque<>();
    private final Map<ResourceKey<Level>, LevelHeights> heights = new ConcurrentHashMap<>();
    private final ExecutorService worker = Executors.newSingleThreadExecutor(ThreadUtils.lowPriorityFactory("Radio-Terrain"));

    /** Written on the server thread, read by computer threads when transmitting. */
    private volatile RadioSettings settings = RadioSettings.fromConfig();

    /** Written on the server thread, read by computer threads to see whether a cached link has expired. */
    private volatile long tick;

    /** When the current tick started, from {@link System#nanoTime()}. This is only used on the server thread. */
    private long tickStarted;

    /** How many chunks' heights each level remembers. This is only used on the server thread. */
    private int heightCacheChunks = settings.heightCacheChunks();

    private volatile long lastErrorLog = Long.MIN_VALUE;

    /**
     * Run work on the server thread between ticks.
     */
    public interface ServerThread {
        /**
         * Run something on the server thread, as soon as it has time between ticks. This may be called from any
         * thread, the server thread too, and never runs the task at once.
         *
         * @param task The task.
         */
        void schedule(Runnable task);

        /**
         * How long a tick is meant to take.
         *
         * @return The length of a tick, in nanoseconds.
         */
        long nanosPerTick();

        /**
         * The server thread of a Minecraft server.
         * <p>
         * Vanilla runs its queued tasks while it waits for the next tick, waking up when one is added. If the server is
         * behind, so has no time to spare, a task waits until a few ticks have passed (or until the server catches up).
         *
         * @param server The server.
         * @return Its server thread.
         */
        static ServerThread of(MinecraftServer server) {
            return new ServerThread() {
                @Override
                public void schedule(Runnable task) {
                    // Not execute, which runs the task at once on the server thread.
                    server.schedule(new TickTask(server.getTickCount(), task));
                }

                @Override
                public long nanosPerTick() {
                    return server.tickRateManager().nanosecondsPerTick();
                }
            };
        }
    }

    /**
     * Make the service.
     *
     * @param serverThread The server thread, which links are traced on.
     */
    public RadioPropagationService(ServerThread serverThread) {
        this.serverThread = serverThread;
    }

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

    /**
     * A packet for one receiver.
     *
     * @param packet     The packet.
     * @param receiver   The receiver.
     * @param distance   How far the packet travels, for the receiver's {@code modem_message}.
     * @param thundering Whether it's thundering, which makes signals weaker.
     * @param frequency  The frequency it was sent at, in MHz.
     * @param power      The power it was sent with, in dBm.
     * @param batch      The other deliveries of the same transmission, if it was queued (see {@link Batch}).
     */
    private record Delivery(
        Packet packet, PacketReceiver receiver, double distance, boolean thundering, double frequency, double power,
        @Nullable Batch batch
    ) implements Waiting {
        @Override
        public double budget() {
            return power - RadioSettings.sensitivity(receiver);
        }
    }

    /**
     * The deliveries of a transmission which was queued, rather than delivered at once. Until all of them are made (or
     * dropped), the sender's packets are queued too, so that one over a link which has been cached since can't
     * overtake them. This is only used on the server thread.
     */
    private final class Batch {
        private final Object sender;

        /** How many deliveries are still to be made, and one more until they've all been made. */
        private int waiting = 1;

        Batch(Object sender) {
            this.sender = sender;
        }

        void add() {
            waiting++;
        }

        void done() {
            if (--waiting == 0) queuedSenders.remove(sender);
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

    /**
     * A cached link in use which expires soon, to trace again in the background, so packets over it carry on going at
     * once rather than waiting for the server thread when it expires.
     *
     * @param level  The level it's in.
     * @param key    The link.
     * @param ends   The two radios it's in use between.
     * @param budget How far to trace it.
     */
    private record Renewal(ServerLevel level, LinkKey key, Ends ends, double budget) {
    }

    /**
     * Two radios a link is traced for, and where each is: the path is remembered for them once it's traced. A link's
     * key is the same either way round, so each knows its own direction.
     *
     * @param sender   The radio sending.
     * @param from     Where its antenna is.
     * @param receiver The radio receiving.
     * @param to       Where its antenna is.
     */
    private record Ends(Object sender, Vec3 from, Object receiver, Vec3 to) {
        boolean between(Object a, Object b) {
            return (sender == a && receiver == b) || (sender == b && receiver == a);
        }
    }

    private static final class Evaluation {
        final LinkKey key;
        final ServerLevel level;
        final Vec3 from, to;
        /** When it started waiting for terrain, which it does for up to {@link RadioSettings#lookupTimeoutTicks()}. */
        long started;
        /** Whether this is for a packet from another dimension, whose links are remembered for longer. */
        final boolean crossDimension;
        final List<Waiting> deliveries = new ArrayList<>(1);
        /** The radios to remember the path for. */
        final List<Ends> ends = new ArrayList<>(1);
        @Nullable MissingChunks missing;
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
        var antenna = RadioAntenna.of(packet.sender(), origin);
        if (!crossDimension) {
            receivers = deliverCached(packet, level, origin, antenna, receivers, frequency, power);
            if (receivers.isEmpty()) return;
        }

        if (queued.addAndGet(receivers.size()) > MAX_QUEUED) {
            // Congestion: drop the packet, much like a real network would.
            queued.addAndGet(-receivers.size());
            return;
        }
        // The sender's next packets wait behind this one. This must happen before it's queued, so it can't be
        // delivered (and the sender released) first.
        if (!crossDimension) queuedSenders.add(packet.sender());
        incoming.add(new Transmission(packet, level, origin, antenna, receivers, crossDimension, frequency, power));
        wake();
    }

    /**
     * Deliver a packet at once to each receiver whose link to the sender is cached, on the thread which sent it, as the
     * original wireless modems did. The rest are left for the server thread.
     * <p>
     * If the sender has packets queued, this one waits behind them, so a sender's packets arrive in the order it sent
     * them.
     *
     * @param packet    The packet.
     * @param level     The level it was sent in.
     * @param origin    Where it was sent from.
     * @param antenna   Where the sender's antenna is.
     * @param receivers The receivers which might hear it.
     * @param frequency The frequency it was sent at, in MHz.
     * @param power     The power it was sent with, in dBm.
     * @return The receivers it wasn't delivered to, which must be queued.
     */
    private List<PacketReceiver> deliverCached(
        Packet packet, ServerLevel level, Vec3 origin, Vec3 antenna, List<PacketReceiver> receivers, double frequency, double power
    ) {
        if (queuedSenders.contains(packet.sender())) return receivers;

        var now = tick;
        List<PacketReceiver> rest = null;
        for (var i = 0; i < receivers.size(); i++) {
            var receiver = receivers.get(i);
            var position = receiver.getPosition();
            var delivery = new Delivery(
                packet, receiver, origin.distanceTo(position), level.isThundering(), frequency, power, null
            );
            if (receiver.getLevel() == level) {
                var to = RadioAntenna.of(receiver, position);
                var key = LinkKey.of(level, antenna, to);
                var cached = cachedLink(key, delivery, now);
                if (cached != null) {
                    deliver(delivery, cached.path().evaluate(frequency));
                    // It expires soon: trace it again in the background, so the next packet needn't wait for that.
                    if (cached.dueForRenewal(now)) {
                        renewals.add(new Renewal(level, key, new Ends(packet.sender(), antenna, receiver, to), delivery.budget()));
                    }
                    continue;
                }
            }

            if (rest == null) rest = new ArrayList<>(receivers.size() - i);
            rest.add(receiver);
        }
        return rest == null ? List.of() : rest;
    }

    /**
     * Find a cached link which serves something waiting for it. This may be called from any thread.
     *
     * @param key     The link.
     * @param waiting What's waiting for it.
     * @param now     The current tick.
     * @return The cached link, or {@code null} if it isn't cached, has expired, or wasn't traced far enough.
     */
    private LinkCache.@Nullable CachedLink cachedLink(LinkKey key, Waiting waiting, long now) {
        return links.get(key, waiting.frequency(), waiting.budget(), now);
    }

    /**
     * Run {@link #process} on the server thread as soon as it has time between ticks, unless that's already scheduled.
     * This may be called from any thread.
     */
    private void wake() {
        if (wakeScheduled.compareAndSet(false, true)) serverThread.schedule(this::onWake);
    }

    private void onWake() {
        wakeScheduled.set(false);
        var budget = wakeBudget(System.nanoTime(), settings.tickBudgetNanos(), tickStarted, serverThread.nanosPerTick());
        // Out of time, but there's more to do: carry on once the server has time again. If the next tick is due by
        // then, the next run has no time at all, and the work waits for the tick.
        if (budget > 0 && process(System.nanoTime() + budget)) wake();
    }

    /**
     * Work out how long a run between ticks may take: the tick budget, but stopping a little before the next tick is
     * due. If the server is behind, the next tick is due already, and there's no time at all.
     *
     * @param now          The time now, from {@link System#nanoTime()}.
     * @param budget       The tick budget, in nanoseconds.
     * @param tickStarted  When the current tick started, from {@link System#nanoTime()}.
     * @param nanosPerTick How long a tick is meant to take, in nanoseconds.
     * @return How long the run may take, in nanoseconds. This is zero or less if it mustn't run.
     */
    static long wakeBudget(long now, long budget, long tickStarted, long nanosPerTick) {
        var untilNextTick = tickStarted + nanosPerTick - WAKE_MARGIN_NANOS - now;
        return Math.min(budget, untilNextTick);
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
     * Evaluate queued links and deliver packets. This must be called on the server thread, at the start of each tick.
     */
    @SuppressWarnings("NonAtomicVolatileUpdate") // Only the server thread writes it.
    public void tick() {
        tick++;
        tickStarted = System.nanoTime();
        settings = RadioSettings.fromConfig();
        // Forget recent links which are too old to use, so modems which are gone aren't held.
        if (tick % Math.max(20, settings.cacheTicks()) == 0) recent.purge(tick - staleTicks());
        // The config may have been reloaded with another size for the heights we remember.
        if (settings.heightCacheChunks() != heightCacheChunks) {
            heightCacheChunks = settings.heightCacheChunks();
            for (var levelHeights : heights.values()) levelHeights.setCapacity(heightCacheChunks);
        }

        // Links left over carry on between ticks, if the server has time.
        if (process(tickStarted + settings.tickBudgetNanos())) wake();
    }

    /**
     * Deliver queued packets, and evaluate queued links until a deadline. This must be called on the server thread.
     *
     * @param deadline When to stop evaluating links, from {@link System#nanoTime()}.
     * @return Whether it stopped at the deadline, with links it hadn't looked at yet.
     */
    private boolean process(long deadline) {
        // Links in use which expire soon are traced again, in the background.
        Renewal renewal;
        while ((renewal = renewals.poll()) != null) {
            refresh(renewal.level(), renewal.key(), renewal.ends(), renewal.budget());
        }

        // Turn transmissions into evaluations, delivering immediately if we've seen this link recently.
        Transmission transmission;
        while ((transmission = incoming.poll()) != null) {
            queued.addAndGet(-transmission.receivers().size());
            if (transmission.crossDimension()) {
                for (var receiver : transmission.receivers()) queueCrossDimension(transmission, receiver);
                continue;
            }

            var level = transmission.level();
            var thundering = level.isThundering();
            var from = transmission.antenna();
            var batch = new Batch(transmission.packet().sender());
            for (var receiver : transmission.receivers()) {
                if (receiver.getLevel() != level) continue;
                var position = receiver.getPosition();
                var to = RadioAntenna.of(receiver, position);
                var delivery = new Delivery(
                    transmission.packet(), receiver, transmission.origin().distanceTo(position), thundering,
                    transmission.frequency(), transmission.power(), batch
                );
                batch.add();
                request(level, from, to, delivery, false);
            }
            batch.done();
        }

        // Then evaluate as many links as we have time for.
        var count = pending.size();
        for (var i = 0; i < count; i++) {
            if (System.nanoTime() >= deadline) return true;
            var evaluation = pending.poll();
            if (evaluation == null) break;

            boolean done;
            try {
                done = tryEvaluate(evaluation);
            } catch (RuntimeException e) {
                // This runs on the server thread, so must never throw. Drop the link instead.
                logError("Failed to evaluate radio link", e);
                evaluating.remove(evaluation.key);
                for (var ends : evaluation.ends) recent.refreshed(ends.sender(), ends.receiver(), evaluation);
                for (var waiting : evaluation.deliveries) complete(waiting, null);
                done = true;
            }
            if (!done) pending.add(evaluation);
        }
        return false;
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
        var cached = cachedLink(key, waiting, tick);
        if (cached != null) {
            complete(waiting, cached.path());
            // As in deliverCached. A link for a packet from another dimension is cached for longer, and isn't renewed.
            if (waiting instanceof Delivery delivery && cached.dueForRenewal(tick)) {
                refresh(level, key, new Ends(delivery.packet().sender(), from, delivery.receiver(), to), delivery.budget());
            }
            return;
        }

        // The same two radios had their link traced a moment ago, and have moved little since: deliver with that, and
        // trace the link where they are now in the background.
        var tolerance = settings.moveTolerance();
        if (waiting instanceof Delivery delivery && tolerance > 0) {
            var sender = delivery.packet().sender();
            var receiver = delivery.receiver();
            var path = recent.find(
                level, sender, from, receiver, to, tick, tolerance, staleTicks(), delivery.frequency(), delivery.budget()
            );
            if (path != null) {
                complete(waiting, path);
                refresh(level, key, new Ends(sender, from, receiver, to), delivery.budget());
                return;
            }
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
        if (waiting instanceof Delivery delivery) {
            addEnds(evaluation, new Ends(delivery.packet().sender(), from, delivery.receiver(), to));
        }
    }

    /**
     * How long ago a link between two radios may have been traced for a packet between them to use it, as they've
     * moved little since: twice as long as links are cached, so a link which is traced again because its cached path
     * expired is traced in the background too.
     *
     * @return The age, in ticks.
     */
    private long staleTicks() {
        return 2L * settings.cacheTicks();
    }

    private static void addEnds(Evaluation evaluation, Ends ends) {
        for (var existing : evaluation.ends) {
            if (existing.equals(ends)) return;
        }
        evaluation.ends.add(ends);
    }

    /**
     * Trace a link in the background, as a packet was delivered with the path between the same two radios a moment
     * ago. A trace still waiting to refresh the link between them is dropped, if nothing else needs it: they've moved
     * on since.
     *
     * @param level  The level the link is in.
     * @param key    The link.
     * @param ends   The two radios.
     * @param budget How far to trace it.
     */
    private void refresh(ServerLevel level, LinkKey key, Ends ends, double budget) {
        var evaluation = evaluating.get(key);
        var created = evaluation == null;
        if (evaluation == null) {
            // Too busy: the next packet between them will try again.
            if (pending.size() >= MAX_EVALUATIONS) return;
            evaluation = new Evaluation(key, level, ends.from(), ends.to(), tick, false, budget);
            evaluating.put(key, evaluation);
            pending.add(evaluation);
        }
        evaluation.budget = Math.max(evaluation.budget, budget);
        addEnds(evaluation, ends);

        if (recent.refreshing(ends.sender(), ends.receiver(), evaluation, tick) instanceof Evaluation previous
            && previous.deliveries.isEmpty() && previous.ends.stream().allMatch(e -> e.between(ends.sender(), ends.receiver()))) {
            evaluating.remove(previous.key, previous);
            pending.remove(previous);
        }

        // It waits for terrain no longer than the trace it replaced would have, so one is traced at least that
        // often, however often the two radios move and talk (see RecentLinks).
        if (created) evaluation.started = recent.refreshingSince(ends.sender(), ends.receiver(), tick);
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
            // Only once it's delivered, so the sender's next packet can't overtake it.
            var batch = delivery.batch();
            if (batch != null) batch.done();
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
        if (missing == null) evaluation.missing = missing = MissingChunks.between(evaluation.from, evaluation.to, env);

        var sources = heightSources();
        var complete = missing.update(
            chunk -> terrain.isKnown(ChunkPos.getX(chunk), ChunkPos.getZ(chunk)),
            chunk -> heights.request(chunk, sources, worker)
        );

        if (!complete && tick - evaluation.started < settings.lookupTimeoutTicks()) return false;

        var from = evaluation.from;
        var to = evaluation.to;

        // With some of its terrain missing, a link which was traced with everything known before keeps that path, and
        // either way it's traced again soon (see LinkCache). Links between dimensions are mostly between computers which
        // stay where they are, so are kept for longer.
        var cacheTicks = evaluation.crossDimension ? settings.crossCacheTicks() : settings.cacheTicks();
        var path = links.settle(
            evaluation.key, complete, p -> servesAll(p, evaluation), tick, cacheTicks,
            () -> PropagationModel.trace(from.x, from.y, from.z, to.x, to.y, to.z, evaluation.budget, env, terrain)
        );
        evaluating.remove(evaluation.key);
        for (var ends : evaluation.ends) {
            recent.record(level, ends.sender(), ends.from(), ends.receiver(), ends.to(), path, tick);
            recent.refreshed(ends.sender(), ends.receiver(), evaluation);
        }
        for (var waiting : evaluation.deliveries) complete(waiting, path);
        return true;
    }

    /**
     * Whether a path serves everything waiting for a link: it was traced as far as each needs.
     *
     * @param path       The path.
     * @param evaluation The link being evaluated.
     * @return Whether it serves them all.
     */
    private static boolean servesAll(LinkPath path, Evaluation evaluation) {
        for (var waiting : evaluation.deliveries) {
            if (!path.serves(waiting.frequency(), waiting.budget())) return false;
        }
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
        // Once a chunk's heights arrive, a link waiting for them can be traced, without waiting for the next tick.
        return heights.computeIfAbsent(level.dimension(), k -> new LevelHeights(level, settings.heightCacheChunks(), this::wake));
    }
}
