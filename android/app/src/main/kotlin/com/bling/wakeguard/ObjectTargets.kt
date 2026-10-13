package com.bling.wakeguard

import android.content.Context
import com.google.mlkit.vision.label.ImageLabel

/** Exact labels from ML Kit's bundled image-labeling model. No cloud inference. */
object ObjectTargets {
    val names = setOf("sink", "cup")
    // Retain lower-confidence Sink detections only after a clear initial match.
    const val MODEL_CONFIDENCE = 0.60f

    fun title(target: String): String = when (target) {
        "cup" -> "cup"
        else -> "sink"
    }

    fun matches(target: String, labels: List<ImageLabel>, maintaining: Boolean = false): Boolean {
        return labels.any { matchesObjectLabel(target, it.index, it.confidence, maintaining) }
    }

    private fun prefs(context: Context) = context.getSharedPreferences("wakeguard.object.practice.v1", Context.MODE_PRIVATE)

    fun verified(context: Context, target: String): Boolean = target in names && prefs(context).getBoolean(target, false)

    fun recordPractice(context: Context, target: String) {
        check(target in names)
        check(prefs(context).edit().putBoolean(target, true).commit()) { "Could not save successful object practice" }
    }
}
