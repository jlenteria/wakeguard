package com.bling.wakeguard

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference

/** Open a ringing challenge from visible app UI; background launch stays with the full-screen notification. */
object AlarmChallengeLauncher {
    private val main = Handler(Looper.getMainLooper())
    private var visibleActivity = WeakReference<Activity>(null)
    private var pendingToken: String? = null

    fun onResumed(activity: Activity) {
        visibleActivity = WeakReference(activity)
        pendingToken = null
        AlarmSessions.active(activity)?.let { openIfVisible(activity, it) }
    }

    fun onPaused(activity: Activity) {
        if (visibleActivity.get() === activity) visibleActivity.clear()
    }

    fun openIfVisible(context: Context, session: AlarmSession) {
        val app = context.applicationContext
        main.post {
            val activity = visibleActivity.get() ?: return@post
            if (activity.isFinishing || activity.isDestroyed) return@post
            val current = AlarmSessions.get(app, session.alarm.id) ?: return@post
            if (current.token != session.token || current.phase != "ringing" ||
                current.elapsed(app) >= AlarmDefaults.MAX_RINGING_MS) return@post
            if (activity is AlarmRingActivity && activity.isShowingSession(current.token)) return@post
            if (pendingToken == current.token) return@post
            pendingToken = current.token
            runCatching { activity.startActivity(AlarmIntents.ringActivity(activity, current.alarm)) }
                .onFailure {
                    pendingToken = null
                    android.util.Log.w("WakeGuard", "Could not open the ringing challenge; notification remains available", it)
                }
        }
    }
}
