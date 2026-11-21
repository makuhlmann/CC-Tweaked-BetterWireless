// SPDX-FileCopyrightText: 2019 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.computer.computerthread;

import com.google.errorprone.annotations.concurrent.GuardedBy;
import dan200.computercraft.core.computer.TimeoutState;

/**
 * A basic {@link TimeoutState} implementation, for use by {@link ComputerScheduler} implementations.
 * <p>
 * While almost all {@link TimeoutState} implementations will be derived from this class, the two are intentionally kept
 * separate. This class is intended for the {@link ComputerScheduler} (which is responsible for controlling the
 * timeout), and not for the main computer logic, which only needs to check timeout flags.
 * <p>
 * This class tracks the time a computer was started (and thus {@linkplain #getExecutionTime()} how long it has been
 * running for), as well as the deadline for when a computer should be soft aborted and paused.
 */
public abstract class ManagedTimeoutState extends TimeoutState {
    /**
     * When execution of this computer started.
     *
     * @see #getExecutionTime()
     */
    private long startTime;

    /**
     * The time when this computer should be aborted.
     *
     * @see #getRemainingTime()
     * @see #setRemainingTime(long)
     */
    private long abortDeadline;

    /**
     * The time when this computer should be paused if {@link ComputerThread#hasPendingWork()} is set.
     */
    private long pauseDeadline;

    /**
     * How many waits on the disk are under way. They may nest, and come from other threads (closing a computer's files
     * as a disk is ejected).
     *
     * @see #startBlocking()
     */
    private int blocking;

    /**
     * When the outermost wait on the disk under way started.
     */
    private long blockingStart;

    /**
     * How much of the waits on the disk which have finished since this computer started running doesn't count towards
     * its timeout.
     */
    private long blocked;

    @Override
    public final synchronized void refresh() {
        // Important: The weird arithmetic here is important, as nanoTime may return negative values, and so we
        // need to handle overflow.
        var now = System.nanoTime();
        // Waits on the disk past their allowance don't count towards the timeout. (Pausing is about sharing the
        // threads with other computers, so it goes by the time taken.)
        var counted = now - blockedAt(now);
        var changed = false;
        if (!paused && Long.compareUnsigned(now, pauseDeadline) >= 0 && shouldPause()) { // now >= currentDeadline
            paused = true;
            changed = true;
        }
        if (!softAbort && Long.compareUnsigned(counted, abortDeadline) >= 0) { // counted >= currentAbort
            softAbort = true;
            changed = true;
        }
        if (softAbort && !hardAbort && Long.compareUnsigned(counted, abortDeadline + ABORT_TIMEOUT) >= 0) { // counted >= currentAbort + ABORT_TIMEOUT.
            hardAbort = true;
            changed = true;
        }

        if (changed) updateListeners();
    }

    @Override
    public final synchronized void startBlocking() {
        if (blocking++ == 0) blockingStart = System.nanoTime();
    }

    @Override
    public final synchronized void stopBlocking() {
        if (blocking == 0) return;
        if (blocking == 1) blocked = blockedAt(System.nanoTime());
        blocking--;
    }

    /**
     * How much time spent waiting on the disk doesn't count towards the timeout, up to now.
     *
     * @param now The time now, from {@link System#nanoTime()}.
     * @return The time left out, in nanoseconds.
     */
    @GuardedBy("this")
    private long blockedAt(long now) {
        var total = blocked;
        if (blocking > 0) total += Math.max(0, now - blockingStart - BLOCKING_ALLOWANCE);
        return Math.min(total, MAX_BLOCKED);
    }

    /**
     * Get how long this computer has been executing for.
     *
     * @return How long the computer has been running for in nanoseconds.
     */
    public final long getExecutionTime() {
        return System.nanoTime() - startTime;
    }

    /**
     * Get how long this computer is permitted to run before being aborted. Time spent waiting on the disk past its
     * allowance doesn't count (see {@link #startBlocking()}).
     *
     * @return The remaining time, in nanoseconds.
     * @see ComputerScheduler.Executor#getRemainingTime()
     */
    public final synchronized long getRemainingTime() {
        var now = System.nanoTime();
        return abortDeadline - (now - blockedAt(now));
    }

    /**
     * Set how long this computer is permitted to run before being aborted.
     *
     * @param time The remaining time, in nanoseconds.
     * @see ComputerScheduler.Executor#setRemainingTime(long)
     */
    public final void setRemainingTime(long time) {
        abortDeadline = startTime + time;
    }

    /**
     * Set the hard-abort flag immediately.
     */
    public final void hardAbort() {
        softAbort = hardAbort = true;
        synchronized (this) {
            updateListeners();
        }
    }

    /**
     * Start this timer, recording the current start time, and deadline before a computer may be paused.
     *
     * @param pauseTimeout The minimum time this computer can run before potentially being paused.
     */
    public final synchronized void startTimer(long pauseTimeout) {
        var now = System.nanoTime();
        startTime = now;
        abortDeadline = now + BASE_TIMEOUT;
        pauseDeadline = now + pauseTimeout;
        blocked = 0;
        if (blocking > 0) blockingStart = now;
    }

    /**
     * Clear the paused and abort flags.
     */
    public final synchronized void reset() {
        paused = softAbort = hardAbort = false;
        updateListeners();
    }

    /**
     * Determine if this computer should be paused, as other computers are contending for work.
     *
     * @return If this computer should be paused.
     */
    protected abstract boolean shouldPause();
}
