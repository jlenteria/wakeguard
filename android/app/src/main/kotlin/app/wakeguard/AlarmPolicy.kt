package app.wakeguard

/** Pure rules shared by receivers and covered without Android services. */
object AlarmPolicy {
    fun acceptsPrimary(enabled: Boolean, savedAt: Long, incomingAt: Long, now: Long): Boolean =
        enabled && incomingAt > 0L && incomingAt == savedAt && now >= incomingAt

    fun acceptsSession(savedToken: String, incomingToken: String?, phase: String, expectedPhase: String): Boolean =
        savedToken == incomingToken && phase == expectedPhase

    fun needsCheckIn(minutes: Int, followUp: Boolean): Boolean = minutes > 0 && !followUp

    fun elapsed(startedAt: Long, startedElapsed: Long, savedBoot: Int, currentBoot: Int,
                now: Long, elapsedNow: Long): Long =
        (if (savedBoot == currentBoot && startedElapsed > 0L) elapsedNow - startedElapsed else now - startedAt).coerceAtLeast(0L)
}
