package com.bling.wakeguard

/** Exact offline-model labels; unrelated bathroom labels never count as a Sink. */
internal fun matchesObjectLabel(target: String, index: Int, confidence: Float, maintaining: Boolean): Boolean =
    when (target) {
        "sink" -> index == 7 && confidence >= (if (maintaining) 0.60f else 0.70f)
        "cup" -> index == 315 && confidence >= 0.80f
        else -> false
    }

/** Brief Sink dropouts pause progress; only consecutive positive frames add time. */
class ObjectRecognitionProgress {
    private var lastFrame: Long? = null
    private var lastMatch: Long? = null
    private var previousMatched = false
    private var confirmedMs = 0L
    private var matches = 0

    companion object {
        const val REQUIRED_MS = 3_000L
        private const val MAX_FRAME_GAP_MS = 700L
        private const val DROPOUT_GRACE_MS = 600L
    }

    fun reset() {
        lastFrame = null; lastMatch = null; previousMatched = false
        confirmedMs = 0L; matches = 0
    }

    fun isTracking(now: Long): Boolean = lastMatch?.let { now - it in 0..DROPOUT_GRACE_MS } == true

    private fun progress(): Float {
        val amount = (confirmedMs.toFloat() / REQUIRED_MS).coerceIn(0f, 1f)
        return if (matches >= 8) amount else amount.coerceAtMost(0.95f)
    }

    fun update(matched: Boolean, now: Long, tolerateBriefMisses: Boolean = false): Float {
        lastFrame?.let { if (now < it || now - it > MAX_FRAME_GAP_MS) reset() }
        if (!matched) {
            if (!tolerateBriefMisses || !isTracking(now)) { reset(); return 0f }
            lastFrame = now
            previousMatched = false
            return progress().let { if (it >= 1f) 0.999f else it }
        }
        if (!previousMatched && lastMatch != null && !isTracking(now)) reset()
        if (previousMatched) confirmedMs += now - (lastFrame ?: now)
        lastFrame = now; lastMatch = now; previousMatched = true; matches++
        return progress()
    }
}
