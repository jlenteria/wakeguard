package com.bling.wakeguard

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

    @Test fun slightlyEarlyDeliveryStillRingsButMuchEarlierIsRearmed() {
        val at = 8 * 60 * 60_000L
        assertTrue(AlarmPolicy.acceptsPrimary(true, at, at, at - 3_000L))
        assertFalse(AlarmPolicy.arrivedEarly(true, at, at, at - 3_000L))
        assertFalse(AlarmPolicy.acceptsPrimary(true, at, at, at - 60_000L))
        assertTrue(AlarmPolicy.arrivedEarly(true, at, at, at - 60_000L))
        // Stale or disabled broadcasts are never re-armed.
        assertFalse(AlarmPolicy.arrivedEarly(true, at + 1, at, at - 60_000L))
        assertFalse(AlarmPolicy.arrivedEarly(false, at, at, at - 60_000L))
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

    @Test fun editingAnAlarmKeepsItsInFlightSnoozeAndConfiguredCheckIn() {
        // A snoozed occurrence is still owed its ring, whatever the edit changes.
        assertTrue(AlarmPolicy.editKeepsSession("snoozed", 5))
        assertTrue(AlarmPolicy.editKeepsSession("snoozed", 0))
        // The check-in was promised when the occurrence was dismissed; an edit must re-arm it.
        assertTrue(AlarmPolicy.editKeepsSession("checkin", 5))
        // Turning Stay Awake off in the same edit retires the pending check-in.
        assertFalse(AlarmPolicy.editKeepsSession("checkin", 0))
        assertFalse(AlarmPolicy.editKeepsSession("ringing", 5))
        assertFalse(AlarmPolicy.editKeepsSession("queued", 5))
        assertFalse(AlarmPolicy.editKeepsSession("done", 5))
    }

    @Test fun clockChangesDoNotExtendARunningSession() {
        assertEquals(60_000L, AlarmPolicy.elapsed(100_000L, 20_000L, 1, 1, 5_000L, 80_000L))
        assertEquals(60_000L, AlarmPolicy.elapsed(100_000L, 20_000L, 1, 2, 160_000L, 5_000L))
    }
}
