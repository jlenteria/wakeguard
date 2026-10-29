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

    /**
     * Wall clock at the start of the current boot. Unlike the hidden `boot_count` global — which is
     * absent on many OEM builds and then reads as the same 0 forever — this changes on every reboot,
     * so it is the reliable signal that a session's monotonic clock belongs to another boot.
     */
    fun bootWallClock(nowMillis: Long, elapsedRealtime: Long): Long = nowMillis - elapsedRealtime

    /** Slack for clock sync/NTP adjustment inside one boot; anything larger is a reboot. */
    const val REBOOT_TOLERANCE_MS = 30_000L

    /**
     * True when [savedBootWallClock] and [currentBootWallClock] cannot belong to the same boot. A
     * missing (zero) stamp cannot be compared, so it defers to the boot counter and the clock going
     * backwards, which is itself proof of a reboot.
     */
    fun rebooted(savedBoot: Int, currentBoot: Int, savedBootWallClock: Long, currentBootWallClock: Long,
                 savedElapsed: Long, elapsedNow: Long): Boolean =
        savedBoot != currentBoot ||
            (savedBootWallClock != 0L && currentBootWallClock != 0L &&
                kotlin.math.abs(savedBootWallClock - currentBootWallClock) > REBOOT_TOLERANCE_MS) ||
            (savedElapsed > 0L && elapsedNow < savedElapsed)

    /**
     * How long a session has been running. Elapsed-realtime is exact but only valid within one boot;
     * across a reboot it is compared with wall-clock time, otherwise an orphaned session would look
     * seconds old forever and re-ring at an arbitrary time.
     */
    fun elapsed(startedAt: Long, startedElapsed: Long, savedBoot: Int, currentBoot: Int,
                now: Long, elapsedNow: Long,
                savedBootWallClock: Long = 0L, currentBootWallClock: Long =
                    bootWallClock(now, elapsedNow)): Long =
        (if (!rebooted(savedBoot, currentBoot, savedBootWallClock, currentBootWallClock,
                    startedElapsed, elapsedNow) && startedElapsed > 0L)
            elapsedNow - startedElapsed else now - startedAt).coerceAtLeast(0L)
}
