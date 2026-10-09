package app.wakeguard

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.UUID

/** A persisted occurrence, separate from the user's recurring configuration. */
data class AlarmSession(
    val token: String,
    val alarm: StoredAlarm,
    val scheduledAt: Long,
    val startedAt: Long,
    val phase: String,
    val snoozes: Int = 0,
    val followUp: Boolean = false,
    val checkAt: Long = 0L,
    val startedElapsed: Long = android.os.SystemClock.elapsedRealtime(),
    val bootCount: Int = -1,
    val occurrenceStartedAt: Long = startedAt,
    val occurrenceElapsed: Long = startedElapsed,
    val occurrenceBoot: Int = bootCount,
) {
    fun json() = JSONObject().apply {
        put("token", token); put("alarm", alarm.toJson())
        put("scheduledAt", scheduledAt); put("startedAt", startedAt)
        put("phase", phase); put("snoozes", snoozes)
        put("followUp", followUp); put("checkAt", checkAt)
        put("startedElapsed", startedElapsed); put("bootCount", bootCount)
        put("occurrenceStartedAt", occurrenceStartedAt); put("occurrenceElapsed", occurrenceElapsed)
        put("occurrenceBoot", occurrenceBoot)
    }.toString()

    fun elapsed(context: Context): Long = AlarmPolicy.elapsed(startedAt, startedElapsed, bootCount,
        runCatching { android.provider.Settings.Global.getInt(context.contentResolver, "boot_count", 0) }.getOrDefault(0),
        System.currentTimeMillis(), android.os.SystemClock.elapsedRealtime())
}

object AlarmSessions {
    const val EXTRA_SESSION = "sessionId"
    private fun prefs(context: Context) =
        context.createDeviceProtectedStorageContext().getSharedPreferences("wakeguard.sessions.v1", Context.MODE_PRIVATE)

    fun all(context: Context): List<AlarmSession> = prefs(context).all.values
        .filterIsInstance<String>().mapNotNull { raw -> runCatching {
            val j = JSONObject(raw)
            AlarmSession(j.getString("token"), StoredAlarm.fromJson(j.getJSONObject("alarm").toString())!!,
                j.getLong("scheduledAt"), j.getLong("startedAt"), j.getString("phase"),
                j.optInt("snoozes"), j.optBoolean("followUp"), j.optLong("checkAt"), j.optLong("startedElapsed"), j.optInt("bootCount", -1),
                j.optLong("occurrenceStartedAt", j.getLong("startedAt")), j.optLong("occurrenceElapsed"), j.optInt("occurrenceBoot", -1))
        }.getOrNull() }

    fun get(context: Context, id: String): AlarmSession? {
        val raw = prefs(context).getString(id, null) ?: return null
        return runCatching {
            val j = JSONObject(raw)
            AlarmSession(j.getString("token"), StoredAlarm.fromJson(j.getJSONObject("alarm").toString())!!,
                j.getLong("scheduledAt"), j.getLong("startedAt"), j.getString("phase"),
                j.optInt("snoozes"), j.optBoolean("followUp"), j.optLong("checkAt"), j.optLong("startedElapsed"), j.optInt("bootCount", -1),
                j.optLong("occurrenceStartedAt", j.getLong("startedAt")), j.optLong("occurrenceElapsed"), j.optInt("occurrenceBoot", -1))
        }.getOrNull()
    }
    fun active(context: Context) = all(context).firstOrNull { it.phase == "ringing" }
    fun matches(context: Context, id: String, token: String?) =
        token != null && get(context, id)?.token == token

    fun save(context: Context, session: AlarmSession) {
        check(prefs(context).edit().putString(session.alarm.id, session.json()).commit()) { "Could not persist alarm session" }
    }

    fun begin(context: Context, alarm: StoredAlarm, scheduledAt: Long, recordStart: Boolean = true): AlarmSession {
        if (get(context, alarm.id)?.phase != "done") invalidate(context, alarm.id)
        val queued = active(context) != null
        val session = AlarmSession(UUID.randomUUID().toString(), alarm, scheduledAt,
            System.currentTimeMillis(), if (queued) "queued" else "ringing", bootCount = currentBoot(context))
        save(context, session)
        if (recordStart) AlarmEvents.record(context, session, "started")
        return session
    }

    fun play(context: Context, session: AlarmSession) {
        if (session.phase != "ringing") return
        val elapsed = session.elapsed(context)
        if (elapsed >= AlarmDefaults.MAX_RINGING_MS) { expire(context, session); return }
        runCatching { NativeAlarmScheduler.armWatchdogs(context, session.alarm, System.currentTimeMillis() - elapsed) }
            .onFailure { android.util.Log.e("WakeGuard", "Watchdog recovery could not be armed", it) }
        runCatching { RingingService.start(context, session.alarm, elapsed) }
            .onFailure { RingingService.postFallbackNotification(context, session.alarm) }
    }

    fun expire(context: Context, session: AlarmSession) {
        if (!matches(context, session.alarm.id, session.token) || get(context, session.alarm.id)?.phase != "ringing") return
        AlarmEvents.record(context, session, "missed")
        finish(context, session)
    }

    fun finish(context: Context, session: AlarmSession, phase: String = "done") {
        // Storage errors must never prevent the unconditional escape stopping audio.
        runCatching { save(context, session.copy(phase = phase)) }
            .onFailure { android.util.Log.e("WakeGuard", "Could not persist stopped session", it) }
        NativeAlarmScheduler.disarmRungs(context, session.alarm.id)
        RingingService.stop(context, session.alarm.id, session.token)
        RingingService.cancelFallbackNotification(context, session.alarm.id)
        // Let the old service release its player, volume and wake lock first.
        Handler(Looper.getMainLooper()).postDelayed({ drain(context.applicationContext) }, 150L)
    }

    fun drain(context: Context) {
        if (active(context) != null) return
        val next = all(context).filter { it.phase == "queued" }.minByOrNull { it.scheduledAt } ?: return
        if (next.elapsed(context) >= AlarmDefaults.MAX_RINGING_MS) {
            AlarmEvents.record(context, next, "missed")
            save(context, next.copy(phase = "done"))
            drain(context)
            return
        }
        val ringing = restarted(context, next, "ringing")
        save(context, ringing)
        runCatching { NativeAlarmScheduler.armRecovery(context, ringing) }
            .onFailure { RingingService.postFallbackNotification(context, ringing.alarm) }
    }

    fun invalidate(context: Context, id: String) {
        val old = get(context, id) ?: return
        StayAwake.cancel(context, old)
        if (old.phase == "ringing") finish(context, old) else save(context, old.copy(phase = "done"))
        prefs(context).edit().remove(id).commit()
    }

    fun currentBoot(context: Context): Int = runCatching {
        android.provider.Settings.Global.getInt(context.contentResolver, "boot_count", 0)
    }.getOrDefault(0)

    fun restarted(context: Context, session: AlarmSession, phase: String): AlarmSession = session.copy(
        phase = phase, startedAt = System.currentTimeMillis(), startedElapsed = android.os.SystemClock.elapsedRealtime(),
        bootCount = currentBoot(context))

    fun restore(context: Context) {
        for (session in all(context)) runCatching { when (session.phase) {
            "checkin" -> StayAwake.restore(context, session)
            "snoozed" -> NativeAlarmScheduler.armSnooze(context, session, session.checkAt)
            "ringing" -> NativeAlarmScheduler.armRecovery(context, session)
            else -> Unit
        } }.onFailure { android.util.Log.e("WakeGuard", "Session restore failed", it) }
        drain(context)
    }
}

object AlarmEvents {
    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext()
        .getSharedPreferences("wakeguard.events.v1", Context.MODE_PRIVATE)

    @Synchronized fun record(context: Context, session: AlarmSession, event: String, method: String = "") {
        val p = prefs(context)
        val list = runCatching { org.json.JSONArray(p.getString("entries", "[]")) }.getOrDefault(org.json.JSONArray())
        list.put(JSONObject().apply {
            put("at", System.currentTimeMillis()); put("event", event); put("method", method)
            put("alarmId", session.alarm.id); put("label", session.alarm.label); put("sessionId", session.token)
            put("scheduledAt", session.scheduledAt)
            put("durationMs", AlarmPolicy.elapsed(session.occurrenceStartedAt, session.occurrenceElapsed,
                session.occurrenceBoot, AlarmSessions.currentBoot(context), System.currentTimeMillis(), android.os.SystemClock.elapsedRealtime()))
            put("snoozes", session.snoozes); put("followUp", session.followUp)
            put("checkInMinutes", session.alarm.checkInMinutes)
        })
        while (list.length() > 500) list.remove(0)
        p.edit().putString("entries", list.toString()).commit()
    }

    fun history(context: Context): List<Map<String, Any?>> {
        val list = runCatching { org.json.JSONArray(prefs(context).getString("entries", "[]")) }.getOrDefault(org.json.JSONArray())
        return (list.length() - 1 downTo 0).map { i ->
            val j = list.getJSONObject(i)
            j.keys().asSequence().associateWith { key -> j.get(key) }
        }
    }

    fun clear(context: Context) {
        check(prefs(context).edit().clear().commit()) { "Could not clear history" }
        context.getSharedPreferences("wakeguard.history", Context.MODE_PRIVATE).edit().clear().apply()
    }
}
