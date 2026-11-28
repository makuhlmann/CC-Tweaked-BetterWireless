// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class TerrainWorkersTest {
    private static final int AREA = 1 << TerrainWorkers.AREA_SHIFT;

    @Test
    void keepsAnAreaOnOneThread() {
        for (var count = 1; count <= 4; count++) {
            for (var x = 0; x < AREA; x += 7) {
                for (var z = 0; z < AREA; z += 5) {
                    assertEquals(TerrainWorkers.thread(0, 0, count), TerrainWorkers.thread(x, z, count));
                    assertEquals(TerrainWorkers.thread(-1, -1, count), TerrainWorkers.thread(-1 - x, -1 - z, count));
                }
            }
        }
    }

    @Test
    void givesNeighbouringAreasToDifferentThreads() {
        for (var count = 2; count <= 4; count++) {
            for (var ax = -3; ax <= 3; ax++) {
                for (var az = -3; az <= 3; az++) {
                    var here = TerrainWorkers.thread(ax * AREA, az * AREA, count);
                    assertNotEquals(here, TerrainWorkers.thread((ax + 1) * AREA, az * AREA, count));
                    assertNotEquals(here, TerrainWorkers.thread(ax * AREA, (az + 1) * AREA, count));
                }
            }
        }
    }

    @Test
    void sharesALinksAreasBetweenTheThreads() {
        // A 10km link, diagonally: its chunks, as they're asked for in order, use both threads about equally.
        var counts = new int[2];
        int last = -1, changes = 0;
        for (var i = 0; i <= 625; i++) {
            var thread = TerrainWorkers.thread(-300 + i, 40 + i * 2 / 3, 2);
            counts[thread]++;
            if (last != -1 && thread != last) changes++;
            last = thread;
        }
        assertTrue(Math.abs(counts[0] - counts[1]) < 160, counts[0] + " vs " + counts[1]);
        assertTrue(changes >= 10, "Changed thread " + changes + " times");
    }

    @Test
    void runsEachAreaOnItsThread() throws InterruptedException {
        var workers = new TerrainWorkers(2, Executors.defaultThreadFactory());
        assertEquals(2, workers.count());

        var threads = ConcurrentHashMap.<Thread>newKeySet();
        var done = new CountDownLatch(8);
        for (var i = 0; i < 4; i++) {
            workers.forChunk(i, 0).execute(() -> {
                threads.add(Thread.currentThread());
                done.countDown();
            });
            workers.forChunk(AREA + i, 0).execute(() -> {
                threads.add(Thread.currentThread());
                done.countDown();
            });
        }
        assertTrue(done.await(10, TimeUnit.SECONDS));
        assertEquals(2, threads.size(), "Two areas, two threads");

        assertTrue(workers.shutdownNow(10, TimeUnit.SECONDS));
        for (var thread : Set.copyOf(threads)) {
            thread.join(10_000);
            assertFalse(thread.isAlive());
        }
    }
}
