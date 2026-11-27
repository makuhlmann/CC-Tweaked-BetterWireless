// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.junit.jupiter.api.Test;

import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Checks how long a run between ticks may take. Delivery itself is checked by {@code Modem_Test}, as it needs a level.
 */
class RadioPropagationServiceTest {
    private static final long TICK = ms(50);
    private static final long BUDGET = ms(2);
    private static final long STARTED = 1_000_000_000L;

    @Test
    void runsForTheBudgetJustAfterATick() {
        assertEquals(BUDGET, RadioPropagationService.wakeBudget(STARTED + ms(10), BUDGET, STARTED, TICK));
    }

    @Test
    void stopsBeforeTheNextTick() {
        assertEquals(ms(1), RadioPropagationService.wakeBudget(STARTED + ms(48), BUDGET, STARTED, TICK));
        assertEquals(ms(1), RadioPropagationService.wakeBudget(STARTED + ms(8), BUDGET, STARTED, ms(10)), "A faster tick rate leaves less time");
    }

    @Test
    void doesNotRunWhenTheNextTickIsDue() {
        assertTrue(RadioPropagationService.wakeBudget(STARTED + ms(49), BUDGET, STARTED, TICK) <= 0);
        assertTrue(RadioPropagationService.wakeBudget(STARTED + ms(70), BUDGET, STARTED, TICK) <= 0, "The server is behind");
        assertTrue(RadioPropagationService.wakeBudget(STARTED, BUDGET, 0, TICK) <= 0, "No tick has started yet");
    }

    @Test
    void copesWithTheClockWrapping() {
        assertEquals(BUDGET, RadioPropagationService.wakeBudget(Long.MIN_VALUE + ms(5), BUDGET, Long.MAX_VALUE - ms(5), TICK));
    }

    private static long ms(long millis) {
        return TimeUnit.MILLISECONDS.toNanos(millis);
    }
}
