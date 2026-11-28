// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import java.util.concurrent.Executor;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * The threads which look up terrain heights the slow way, from the world generator. Each thread takes its own areas of
 * the world.
 * <p>
 * Taking turns from one queue, several threads would mostly wait for each other. A Tellus world's generator works out
 * the rivers and lakes of a whole area before it answers for any column in it, which can take seconds (and is then
 * remembered), and only one thread works out each area: the others asking about it wait. A link's chunks are asked for
 * in order along it, so the chunks queued next are usually in the same area. Instead, chunks in the same area go to the
 * same thread, and neighbouring areas to different ones, so the areas along a link are worked out side by side.
 * <p>
 * A thread which has had nothing to do for a while stops, and starts again when it's given something. So a set of
 * threads which is replaced (the config asks for another number of them) needn't be stopped: lookups already given to it
 * carry on, and then its threads stop on their own.
 */
final class TerrainWorkers {
    /** How many chunks wide an area is, as a power of two: 64 chunks, or 1024 blocks. */
    static final int AREA_SHIFT = 6;

    /** How long a thread with nothing to do waits before stopping, in seconds. */
    private static final long IDLE_SECONDS = 60;

    private final ThreadPoolExecutor[] threads;

    /**
     * Start some threads.
     *
     * @param count   How many threads.
     * @param factory Makes the threads.
     */
    TerrainWorkers(int count, ThreadFactory factory) {
        threads = new ThreadPoolExecutor[count];
        for (var i = 0; i < count; i++) {
            var thread = new ThreadPoolExecutor(1, 1, IDLE_SECONDS, TimeUnit.SECONDS, new LinkedBlockingQueue<>(), factory);
            thread.allowCoreThreadTimeOut(true);
            threads[i] = thread;
        }
    }

    /**
     * How many threads there are.
     *
     * @return How many.
     */
    int count() {
        return threads.length;
    }

    /**
     * The thread to look up a chunk with.
     *
     * @param chunkX The chunk's X coordinate.
     * @param chunkZ The chunk's Z coordinate.
     * @return The thread, as an executor.
     */
    Executor forChunk(int chunkX, int chunkZ) {
        return threads[thread(chunkX, chunkZ, threads.length)];
    }

    /**
     * Which thread looks up a chunk. With more than one, moving to a neighbouring area along either axis always changes
     * the thread, and a line crosses from area to neighbouring area, so a link's areas take turns between them.
     *
     * @param chunkX The chunk's X coordinate.
     * @param chunkZ The chunk's Z coordinate.
     * @param count  How many threads there are.
     * @return The thread's index.
     */
    static int thread(int chunkX, int chunkZ, int count) {
        return Math.floorMod((chunkX >> AREA_SHIFT) + (chunkZ >> AREA_SHIFT), count);
    }

    /**
     * Stop the threads, without finishing what they've been given.
     *
     * @param timeout How long to wait for them to stop.
     * @param unit    The unit of {@code timeout}.
     * @return Whether they all stopped in time.
     * @throws InterruptedException If interrupted while waiting.
     */
    boolean shutdownNow(long timeout, TimeUnit unit) throws InterruptedException {
        for (var thread : threads) thread.shutdownNow();
        var deadline = System.nanoTime() + unit.toNanos(timeout);
        for (var thread : threads) {
            if (!thread.awaitTermination(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS)) return false;
        }
        return true;
    }
}
