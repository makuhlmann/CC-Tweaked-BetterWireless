// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.util;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Writing a file on a thread of its own: the server thread never waits for the disk, except when closing.
 */
public class BackgroundFileWriterTest {
    private static final Path FILE = Path.of("test.json");

    /** Contents each write was given, in order, whether or not it succeeded. */
    private final List<String> written = new CopyOnWriteArrayList<>();

    /** Counted down as each write starts. */
    private final CountDownLatch started = new CountDownLatch(1);

    /** Writes wait for this, as they would for a disk which stalls. */
    private final CountDownLatch release = new CountDownLatch(1);

    private static void await(CountDownLatch latch) {
        try {
            if (!latch.await(5, TimeUnit.SECONDS)) throw new AssertionError("Timed out");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new AssertionError(e);
        }
    }

    /**
     * Create a writer whose writes wait for {@link #release}, and succeed.
     *
     * @return The writer.
     */
    private BackgroundFileWriter<String> stalling() {
        return new BackgroundFileWriter<>(FILE, contents -> {
            started.countDown();
            await(release);
            written.add(contents);
            return true;
        });
    }

    @Test
    public void writeReturnsWhileTheDiskStalls() {
        var writer = stalling();

        // If this waited for the write, it'd never return, as the write waits for us.
        assertTimeoutPreemptively(Duration.ofSeconds(5), () -> writer.write("a"));
        await(started);
        assertEquals(List.of(), written);

        release.countDown();
        writer.close(5, TimeUnit.SECONDS);
        assertEquals(List.of("a"), written);
    }

    @Test
    public void writesOnlyTheNewestContents() {
        var writer = stalling();

        writer.write("a");
        await(started);
        writer.write("b");
        writer.write("c");

        release.countDown();
        writer.close(5, TimeUnit.SECONDS);
        assertEquals(List.of("a", "c"), written);
    }

    @Test
    public void closeWaitsForTheWrite() {
        var writer = new BackgroundFileWriter<String>(FILE, contents -> {
            try {
                Thread.sleep(200);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
            written.add(contents);
            return true;
        });

        writer.write("a");
        writer.close(5, TimeUnit.SECONDS);
        assertEquals(List.of("a"), written);
    }

    @Test
    public void failedContentsAreWrittenAgainOnClose() {
        var attempts = new AtomicInteger();
        var writer = new BackgroundFileWriter<String>(FILE, contents -> {
            written.add(contents);
            return attempts.incrementAndGet() > 1;
        });

        writer.write("a");
        writer.close(5, TimeUnit.SECONDS);
        assertEquals(List.of("a", "a"), written);
    }

    @Test
    public void newerContentsReplaceFailedOnes() {
        var writer = new BackgroundFileWriter<String>(FILE, contents -> {
            written.add(contents);
            started.countDown();
            return !contents.equals("a");
        });

        writer.write("a");
        await(started);
        writer.write("b");
        writer.close(5, TimeUnit.SECONDS);
        assertEquals(List.of("a", "b"), written);
    }

    @Test
    public void ignoresContentsAfterClose() {
        var writer = stalling();
        release.countDown();
        writer.close(5, TimeUnit.SECONDS);

        writer.write("a");
        assertEquals(List.of(), written);
    }
}
