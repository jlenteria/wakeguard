package app.wakeguard

import org.junit.Assert.*
import org.junit.Test

class AlarmPolicyTest {
    @Test fun editingEightToNineRejectsTheOldBroadcast() {
        val eight = 8 * 60 * 60_000L
        val nine = 9 * 60 * 60_000L
        assertFalse(AlarmPolicy.acceptsPrimary(true, nine, eight, eight))
        assertFalse(AlarmPolicy.acceptsPrimary(true, nine, nine, eight))
        assertTrue(AlarmPolicy.acceptsPrimary(true, nine, nine, nine))
    }

    @Test fun dismissedOrReplacedSessionsCannotBeRestarted() {
        assertFalse(AlarmPolicy.acceptsSession("new", "old", "ringing", "ringing"))
        assertFalse(AlarmPolicy.acceptsSession("same", "same", "done", "ringing"))
        assertFalse(AlarmPolicy.acceptsSession("same", null, "ringing", "ringing"))
        assertTrue(AlarmPolicy.acceptsSession("same", "same", "ringing", "ringing"))
    }

    @Test fun followUpCannotCreateAnotherCheckIn() {
        assertTrue(AlarmPolicy.needsCheckIn(5, false))
        assertFalse(AlarmPolicy.needsCheckIn(5, true))
        assertFalse(AlarmPolicy.needsCheckIn(0, false))
    }

    @Test fun clockChangesDoNotExtendARunningSession() {
        assertEquals(60_000L, AlarmPolicy.elapsed(100_000L, 20_000L, 1, 1, 5_000L, 80_000L))
        assertEquals(60_000L, AlarmPolicy.elapsed(100_000L, 20_000L, 1, 2, 160_000L, 5_000L))
    }
}
