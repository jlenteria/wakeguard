package com.bling.wakeguard

/** Pure rules shared by receivers and covered without Android services. */
object AlarmPolicy {
    /** Vendor clocks can deliver an exact alarm a few seconds early; that is still the right alarm. */
    const val EARLY_TOLERANCE_MS = 5_000L

    fun acceptsPrimary(enabled: Boolean, savedAt: Long, incomingAt: Long, now: Long): Boolean =
        enabled && incomingAt > 0L && incomingAt == savedAt && now + EARLY_TOLERANCE_MS >= incomingAt

    /**
     * The saved occurrence arriving well before its time. Dropping it would consume the only
     * wake-up for that day, so the caller re-arms it instead of ignoring it.
     */
    fun arrivedEarly(enabled: Boolean, savedAt: Long, incomingAt: Long, now: Long): Boolean =
        enabled && incomingAt > 0L && incomingAt == savedAt && now + EARLY_TOLERANCE_MS < incomingAt

    fun acceptsSession(savedToken: String, incomingToken: String?, phase: String, expectedPhase: String): Boolean =
        savedToken == incomingToken && phase == expectedPhase

    fun needsCheckIn(minutes: Int, followUp: Boolean): Boolean = minutes > 0 && !followUp

    fun elapsed(startedAt: Long, startedElapsed: Long, savedBoot: Int, currentBoot: Int,
                now: Long, elapsedNow: Long): Long =
        (if (savedBoot == currentBoot && startedElapsed > 0L) elapsedNow - startedElapsed else now - startedAt).coerceAtLeast(0L)
}
