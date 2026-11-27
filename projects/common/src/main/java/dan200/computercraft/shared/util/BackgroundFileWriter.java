// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.util;

import dan200.computercraft.core.util.ThreadUtils;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Path;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Writes a file on a thread of its own, so a slow disk doesn't hold up the server thread.
 * <p>
 * A disk can stall for a while (a virtual disk whose host is busy, a network share, a backup). Writing on the server
 * thread then stops the whole server, and if it stalls for long enough, the watchdog crashes it. Vanilla writes the
 * world on threads of its own for the same reason.
 * <p>
 * Only the latest contents of the file matter: if they change again while the file is being written, the newest are
 * written next, and any in between are skipped. If the file can't be written, the contents are written again with the
 * next ones, or when this is closed, unless newer contents have replaced them by then.
 *
 * @param <T> The contents of the file. These are handed to another thread, so mustn't be changed once given.
 */
public final class BackgroundFileWriter<T> {
    private static final Logger LOG = LoggerFactory.getLogger(BackgroundFileWriter.class);

    private static final ThreadFactory THREADS = ThreadUtils.factory("Save");

    /**
     * Writes the contents to the file.
     *
     * @param <T> The contents of the file.
     */
    @FunctionalInterface
    public interface Write<T> {
        /**
         * Write the contents to the file. This is called on the writer's own thread, one at a time.
         *
         * @param contents The contents to write.
         * @return Whether they were written. If not, they're written again later.
         */
        boolean write(T contents);
    }

    private final Path file;
    private final Write<T> write;

    /**
     * Writes one at a time, in order. Its thread stops when it has had nothing to do for a while, so a writer which
     * isn't closed doesn't keep a thread forever.
     */
    private final ThreadPoolExecutor executor = new ThreadPoolExecutor(
        0, 1, 30, TimeUnit.SECONDS, new LinkedBlockingQueue<>(), THREADS
    );

    /** The contents to write next, if any. */
    private final AtomicReference<@Nullable T> queued = new AtomicReference<>(null);

    /** Whether a write is waiting to start. If so, it will write {@link #queued}, so there's no need for another. */
    private final AtomicBoolean scheduled = new AtomicBoolean(false);

    /**
     * Create a new writer.
     *
     * @param file  The file, only used to say which file couldn't be written.
     * @param write Writes the contents to the file.
     */
    public BackgroundFileWriter(Path file, Write<T> write) {
        this.file = file;
        this.write = write;
    }

    /**
     * Write new contents to the file soon, on the writer's own thread. This returns at once.
     * <p>
     * Contents given after {@link #close} are ignored.
     *
     * @param contents The new contents of the file.
     */
    public void write(T contents) {
        if (executor.isShutdown()) return;

        queued.set(contents);
        if (scheduled.compareAndSet(false, true)) executor.execute(this::writeQueued);
    }

    /**
     * Write anything still to be written, and wait for it to be written. Nothing is written after this.
     *
     * @param timeout How long to wait for.
     * @param unit    The unit of {@code timeout}.
     */
    public void close(long timeout, TimeUnit unit) {
        if (executor.isShutdown()) return;

        // Write anything which couldn't be written before, as nothing else will now.
        executor.execute(this::writeQueued);
        executor.shutdown();

        try {
            if (!executor.awaitTermination(timeout, unit)) {
                LOG.error("Gave up waiting for '{}' to be written. It may not be up to date.", file);
            }
        } catch (InterruptedException e) {
            LOG.error("Interrupted while waiting for '{}' to be written. It may not be up to date.", file, e);
            Thread.currentThread().interrupt();
        }
    }

    private void writeQueued() {
        // Contents given from here on need another write: this one may already have taken the earlier ones.
        scheduled.set(false);

        var contents = queued.getAndSet(null);
        if (contents == null) return;

        // Keep the contents to write again later, unless newer ones have been given meanwhile.
        if (!write.write(contents)) queued.compareAndSet(null, contents);
    }
}
