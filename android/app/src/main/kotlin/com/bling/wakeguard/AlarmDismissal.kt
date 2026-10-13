package com.bling.wakeguard

import android.content.Context

object AlarmDismissal {
    fun complete(context: Context, alarmId: String, method: String, token: String? = null): Boolean {
        val session = AlarmSessions.get(context, alarmId) ?: return false
        if (session.phase != "ringing" || session.token != token || method !in session.alarm.escapes) return false
        AlarmEvents.record(context, session, "dismissed", method)
        AlarmSessions.finish(context, session)
        // Tomorrow's occurrence was armed at fire time; do not rewrite it on dismissal.
        // A check-in is purely a function of the alarm's setting, whatever the
        // selected challenge used.
        if (AlarmPolicy.needsCheckIn(session.alarm.checkInMinutes, session.followUp)) {
            runCatching { StayAwake.schedule(context, session) }.onFailure {
                runCatching { StayAwake.cancel(context, session) }
                AlarmSessions.save(context, session.copy(phase = "done"))
                AlarmEvents.record(context, session, "checkin_failed")
                android.util.Log.e("WakeGuard", "Check-in could not be armed", it)
            }
        }
        return true
    }

    fun history(context: Context): List<Map<String, Any?>> {
        val legacy = runCatching {
            val p = context.getSharedPreferences("wakeguard.history", Context.MODE_PRIVATE)
            val a = org.json.JSONArray(p.getString("entries", "[]"))
            (a.length() - 1 downTo 0).map { i ->
                val j = a.getJSONObject(i)
                mapOf<String, Any?>("at" to j.optLong("at"), "method" to j.optString("method"), "event" to "dismissed")
            }
        }.getOrDefault(emptyList())
        return (AlarmEvents.history(context) + legacy).sortedByDescending { (it["at"] as? Number)?.toLong() ?: 0L }
    }
}
