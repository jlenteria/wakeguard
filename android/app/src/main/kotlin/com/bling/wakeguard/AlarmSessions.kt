package com.bling.wakeguard

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
    /** Wall clock at the start of this boot, so a reboot is detectable without the hidden boot_count. */
    val bootWallClock: Long = AlarmPolicy.bootWallClock(System.currentTimeMillis(),
        android.os.SystemClock.elapsedRealtime()),
    /** When the check-in prompt was actually shown; the response window starts here. */
    val promptedAt: Long = 0L,
) {
    fun json() = JSONObject().apply {
        put("token", token); put("alarm", alarm.toJson())
        put("scheduledAt", scheduledAt); put("startedAt", startedAt)
        put("phase", phase); put("snoozes", snoozes)
        put("followUp", followUp); put("checkAt", checkAt)
        put("startedElapsed", startedElapsed); put("bootCount", bootCount)
        put("occurrenceStartedAt", occurrenceStartedAt); put("occurrenceElapsed", occurrenceElapsed)
        put("occurrenceBoot", occurrenceBoot); put("promptedAt", promptedAt)
        put("bootWallClock", bootWallClock)
    }.toString()

    fun elapsed(context: Context): Long = AlarmPolicy.elapsed(startedAt, startedElapsed, bootCount,
        runCatching { android.provider.Settings.Global.getInt(context.contentResolver, "boot_count", 0) }.getOrDefault(0),
        System.currentTimeMillis(), android.os.SystemClock.elapsedRealtime(),
        savedBootWallClock = bootWallClock)
}

object AlarmSessions {
    const val EXTRA_SESSION = "sessionId"

    /** How long a deleted alarm's occurrence is kept, so Undo can resume it. */
    const val HOLD_MS = 10L * 60_000L

    private fun prefs(context: Context) =
        context.createDeviceProtectedStorageContext().getSharedPreferences("wakeguard.sessions.v1", Context.MODE_PRIVATE)

    private fun heldPrefs(context: Context) =
        context.createDeviceProtectedStorageContext().getSharedPreferences("wakeguard.sessions.held.v1", Context.MODE_PRIVATE)

    private fun decode(raw: String): AlarmSession? = runCatching {
        val j = JSONObject(raw)
        AlarmSession(j.getString("token"), StoredAlarm.fromJson(j.getJSONObject("alarm").toString())!!,
            j.getLong("scheduledAt"), j.getLong("startedAt"), j.getString("phase"),
            j.optInt("snoozes"), j.optBoolean("followUp"), j.optLong("checkAt"), j.optLong("startedElapsed"), j.optInt("bootCount", -1),
            j.optLong("occurrenceStartedAt", j.getLong("startedAt")), j.optLong("occurrenceElapsed"), j.optInt("occurrenceBoot", -1),
            j.optLong("bootWallClock", AlarmPolicy.bootWallClock(
                System.currentTimeMillis(), android.os.SystemClock.elapsedRealtime())),
            promptedAt = j.optLong("promptedAt"))
    }.getOrNull()

    fun all(context: Context): List<AlarmSession> = prefs(context).all.values
        .filterIsInstance<String>().mapNotNull(::decode)

    fun get(context: Context, id: String): AlarmSession? =
        prefs(context).getString(id, null)?.let(::decode)

    /**
     * Stops a deleted alarm's timers but keeps its occurrence for [HOLD_MS], so Undo resumes the
     * same ring, snooze or check-in with the values it had, rather than a fresh schedule.
     */
    fun hold(context: Context, id: String) {
        val session = get(context, id) ?: return
        StayAwake.cancel(context, session)
        NativeAlarmScheduler.disarmRungs(context, id)
        val ringing = session.phase == "ringing"
        if (ringing) {
            RingingService.stop(context, id, session.token)
            RingingService.cancelFallbackNotification(context, id)
        }
        if (session.phase != "done") {
            val stored = JSONObject(session.json()).put("heldAt", System.currentTimeMillis()).toString()
            heldPrefs(context).edit().putString(id, stored).commit()
        }
        prefs(context).edit().remove(id).commit()
        // A deleted ring gives the queue back to the next alarm.
        if (ringing) Handler(Looper.getMainLooper()).postDelayed({ drain(context.applicationContext) }, 150L)
    }

    /** Takes the held occurrence for [id] once, so only a single schedule can resume it. */
    fun takeHeld(context: Context, id: String): AlarmSession? {
        val raw = heldPrefs(context).getString(id, null) ?: return null
        heldPrefs(context).edit().remove(id).commit()
        val heldAt = runCatching { JSONObject(raw).optLong("heldAt") }.getOrDefault(0L)
        if (System.currentTimeMillis() - heldAt > HOLD_MS) return null
        return decode(raw)
    }

    /** Forgets held occurrences whose undo window has closed. */
    fun sweepHeld(context: Context) {
        val cutoff = System.currentTimeMillis() - HOLD_MS
        val p = heldPrefs(context)
        for ((key, raw) in p.all) {
            val heldAt = runCatching { JSONObject(raw as String).optLong("heldAt") }.getOrDefault(0L)
            if (heldAt < cutoff) p.edit().remove(key).commit()
        }
    }

    fun active(context: Context) = all(context).firstOrNull { it.phase == "ringing" && !isStale(context, it) }

    /**
     * A ringing session past the ring window is dead: the service and watchdog that would have
     * expired it were killed with the process. Left "active", it queues every later alarm silently.
     */
    private fun isStale(context: Context, session: AlarmSession) =
        session.phase == "ringing" && session.elapsed(context) >= AlarmDefaults.MAX_RINGING_MS

    /** Retires dead ringing sessions so they cannot hold back the alarms behind them. */
    fun expireStale(context: Context) {
        for (session in all(context)) {
            if (!isStale(context, session)) continue
            android.util.Log.w("WakeGuard", "Expiring orphaned ringing session for ${session.alarm.id}")
            runCatching { expire(context, session) }
                .onFailure { android.util.Log.e("WakeGuard", "Could not expire orphaned session", it) }
        }
    }
    fun matches(context: Context, id: String, token: String?) =
        token != null && get(context, id)?.token == token

    fun save(context: Context, session: AlarmSession) {
        check(prefs(context).edit().putString(session.alarm.id, session.json()).commit()) { "Could not persist alarm session" }
    }

    fun begin(context: Context, alarm: StoredAlarm, scheduledAt: Long, recordStart: Boolean = true): AlarmSession {
        expireStale(context)
        if (get(context, alarm.id)?.phase != "done") invalidate(context, alarm.id)
        val queued = active(context) != null
        val session = AlarmSession(UUID.randomUUID().toString(), alarm, scheduledAt,
            System.currentTimeMillis(), if (queued) "queued" else "ringing", bootCount = currentBoot(context))
        save(context, session)
        if (queued) {
            // The in-process drain below is only the fast path: a real trigger promotes this
            // occurrence even if the process dies while it waits behind the alarm ahead of it.
            runCatching { NativeAlarmScheduler.armQueueWatchdog(context, session) }
                .onFailure { android.util.Log.e("WakeGuard", "Queue watchdog could not be armed", it) }
        }
        if (recordStart) AlarmEvents.record(context, session, "started")
        return session
    }

    fun play(context: Context, session: AlarmSession) {
        if (session.phase != "ringing") return
        val elapsed = session.elapsed(context)
        if (elapsed >= AlarmDefaults.MAX_RINGING_MS) { expire(context, session); return }
        runCatching { NativeAlarmScheduler.armWatchdogs(context, session.alarm, System.currentTimeMillis() - elapsed) }
            .onFailure { android.util.Log.e("WakeGuard", "Watchdog recovery could not be armed", it) }
        runCatching { RingingService.start(context, session.alarm) }
            .onFailure { RingingService.postFallbackNotification(context, session.alarm) }
        AlarmChallengeLauncher.openIfVisible(context, session)
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
        // This drain owns the promotion now; the standalone trigger would only double-fire it.
        runCatching { NativeAlarmScheduler.cancelQueueWatchdog(context, next) }
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
        // Even if recovery arming failed, try playback and establish its bounded
        // watchdogs now rather than leaving an apparently active queue stranded.
        play(context, ringing)
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
        bootCount = currentBoot(context),
        bootWallClock = AlarmPolicy.bootWallClock(System.currentTimeMillis(),
            android.os.SystemClock.elapsedRealtime()))

    fun restore(context: Context) {
        for (session in all(context)) restore(context, session)
        drain(context)
    }

    /** Re-arms the timers one persisted occurrence still needs. */
    fun restore(context: Context, session: AlarmSession) {
        runCatching {
            if (session.alarm.needsSetup && session.phase in setOf("ringing", "snoozed", "queued")) {
                AlarmEvents.record(context, session, "challenge_setup_required")
                StayAwake.cancel(context, session)
                finish(context, session)
                return@runCatching
            }
            when (session.phase) {
                "checkin" -> StayAwake.restore(context, session)
                "snoozed" -> NativeAlarmScheduler.armSnooze(context, session, session.checkAt)
                "ringing" -> NativeAlarmScheduler.armRecovery(context, session)
                else -> Unit
            }
        }.onFailure { android.util.Log.e("WakeGuard", "Session restore failed", it) }
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
                session.occurrenceBoot, AlarmSessions.currentBoot(context), System.currentTimeMillis(), android.os.SystemClock.elapsedRealtime(),
                savedBootWallClock = session.bootWallClock))
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
