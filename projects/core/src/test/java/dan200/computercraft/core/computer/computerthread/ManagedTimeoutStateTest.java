// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.computer.computerthread;

import dan200.computercraft.core.computer.TimeoutState;
import org.junit.jupiter.api.Test;

import java.util.concurrent.TimeUnit;

import static org.hamcrest.MatcherAssert.assertThat;
import static org.hamcrest.Matchers.*;

/**
 * How waits on the disk count towards a computer's timeout.
 */
public class ManagedTimeoutStateTest {
    private static final long SECOND = TimeUnit.SECONDS.toNanos(1);
    private static final long MS = TimeUnit.MILLISECONDS.toNanos(1);

    private static ManagedTimeoutState started() {
        var timeout = new ManagedTimeoutState() {
            @Override
            protected boolean shouldPause() {
                return false;
            }
        };
        timeout.startTimer(TimeoutState.TIMEOUT);
        timeout.setRemainingTime(SECOND);
        return timeout;
    }

    @Test
    public void testRunningCounts() throws InterruptedException {
        var timeout = started();
        Thread.sleep(200);
        assertThat(timeout.getRemainingTime(), lessThanOrEqualTo(SECOND - 200 * MS));
    }

    @Test
    public void testOnlyTheAllowanceOfAWaitCounts() throws InterruptedException {
        var timeout = started();
        timeout.startBlocking();
        Thread.sleep(300);
        // While waiting...
        assertThat(timeout.getRemainingTime(), greaterThanOrEqualTo(SECOND - TimeoutState.BLOCKING_ALLOWANCE - 50 * MS));
        timeout.stopBlocking();
        // ...and after.
        var left = timeout.getRemainingTime();
        assertThat(left, greaterThanOrEqualTo(SECOND - TimeoutState.BLOCKING_ALLOWANCE - 50 * MS));
        assertThat(left, lessThanOrEqualTo(SECOND - TimeoutState.BLOCKING_ALLOWANCE));

        // Time after the wait counts again.
        Thread.sleep(200);
        assertThat(timeout.getRemainingTime(), lessThanOrEqualTo(left - 200 * MS));
    }

    @Test
    public void testNestedWaitsCountOnce() throws InterruptedException {
        var timeout = started();
        timeout.startBlocking();
        timeout.startBlocking();
        Thread.sleep(100);
        timeout.stopBlocking();
        // Still in the outer wait: this doesn't count.
        Thread.sleep(200);
        timeout.stopBlocking();
        assertThat(timeout.getRemainingTime(), greaterThanOrEqualTo(SECOND - TimeoutState.BLOCKING_ALLOWANCE - 50 * MS));

        // Stopping more often than started is ignored.
        timeout.stopBlocking();
        Thread.sleep(200);
        assertThat(timeout.getRemainingTime(), lessThanOrEqualTo(SECOND - TimeoutState.BLOCKING_ALLOWANCE - 200 * MS));
    }

    @Test
    public void testWaitDoesNotAbort() throws InterruptedException {
        var timeout = started();
        timeout.setRemainingTime(100 * MS);
        timeout.startBlocking();
        Thread.sleep(400);
        timeout.refresh();
        assertThat("Not soft aborted while waiting", timeout.isSoftAborted(), is(false));
        timeout.stopBlocking();

        Thread.sleep(200);
        timeout.refresh();
        assertThat("Soft aborted once running past the time left", timeout.isSoftAborted(), is(true));
    }

    @Test
    public void testNewRunForgetsWaits() throws InterruptedException {
        var timeout = started();
        timeout.startBlocking();
        Thread.sleep(200);
        timeout.stopBlocking();

        timeout.startTimer(TimeoutState.TIMEOUT);
        timeout.setRemainingTime(SECOND);
        Thread.sleep(200);
        assertThat(timeout.getRemainingTime(), lessThanOrEqualTo(SECOND - 200 * MS));
    }
}
