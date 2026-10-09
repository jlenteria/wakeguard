package app.wakeguard

import android.content.Context

object AlarmDismissal {
    fun complete(context: Context, alarmId: String, method: String, token: String? = null) {
        val session = AlarmSessions.get(context, alarmId) ?: return
        if (session.phase != "ringing" || session.token != token) return
        AlarmEvents.record(context, session, "dismissed", method)
        AlarmSessions.finish(context, session)
        // Tomorrow's occurrence was armed at fire time; do not rewrite it on dismissal.
        if (AlarmPolicy.needsCheckIn(session.alarm.checkInMinutes, session.followUp)) {
            runCatching { StayAwake.schedule(context, session) }.onFailure {
                AlarmSessions.save(context, session.copy(phase = "done"))
                AlarmEvents.record(context, session, "checkin_failed")
                android.util.Log.e("WakeGuard", "Check-in could not be armed", it)
            }
        }
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
