package com.bling.wakeguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Reject stale operations before they can start sound or change tomorrow's alarm. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(NativeAlarmScheduler.EXTRA_ALARM_ID) ?: return
        val now = System.currentTimeMillis()
        val rung = intent.getIntExtra("rung", PRIMARY_TRIGGER)
        if (intent.getBooleanExtra("recovery", false)) {
            val session = AlarmSessions.get(context, id) ?: return
            if (!AlarmPolicy.acceptsSession(session.token, intent.getStringExtra(AlarmSessions.EXTRA_SESSION), session.phase, "ringing")) return
            AlarmSessions.play(context, session)
            return
        }
        if (intent.getBooleanExtra("snoozed", false)) {
            val session = AlarmSessions.get(context, id) ?: return
            if (session.token != intent.getStringExtra(AlarmSessions.EXTRA_SESSION) || session.phase != "snoozed") return
            // Do not consume the only wake-up if a vendor delivers it a little early.
            if (now < session.checkAt) {
                runCatching { NativeAlarmScheduler.armSnooze(context, session, session.checkAt) }
                    .onFailure { android.util.Log.e("WakeGuard", "Early snooze delivery could not be re-armed", it) }
                return
            }
            if (now - session.checkAt >= AlarmDefaults.MAX_RINGING_MS) {
                AlarmEvents.record(context, session, "missed")
                AlarmSessions.finish(context, session)
                return
            }
            val resumed = AlarmSessions.restarted(context, session, if (AlarmSessions.active(context) == null) "ringing" else "queued")
            AlarmSessions.save(context, resumed)
            AlarmSessions.play(context, resumed)
            return
        }
        if (rung != PRIMARY_TRIGGER) {
            val session = AlarmSessions.get(context, id) ?: return
            if (!AlarmPolicy.acceptsSession(session.token, intent.getStringExtra(AlarmSessions.EXTRA_SESSION), session.phase, "ringing")) return
            val elapsed = session.elapsed(context)
            val minimum = when (rung) { 0 -> 45_000L; 1 -> 120_000L; 2 -> 300_000L; 3 -> 600_000L; 4 -> AlarmDefaults.MAX_RINGING_MS; else -> return }
            if (elapsed < minimum) return
            if (elapsed >= AlarmDefaults.MAX_RINGING_MS) {
                AlarmSessions.expire(context, session)
            } else {
                runCatching { RingingService.start(context, session.alarm, elapsed) }
                    .onFailure { RingingService.postFallbackNotification(context, session.alarm) }
            }
            return
        }
        val alarm = AlarmStore.get(context, id) ?: return
        val expected = intent.getLongExtra(NativeAlarmScheduler.EXTRA_TRIGGER_AT, 0L)
        if (!AlarmPolicy.acceptsPrimary(alarm.enabled, alarm.nextTriggerAt, expected, now)) return
        if (AlarmSessions.get(context, id)?.scheduledAt == expected) return
        // More than a ring window late is a missed occurrence, not a surprise alarm.
        val session = AlarmSessions.begin(context, alarm, expected, recordStart = now - expected < AlarmDefaults.MAX_RINGING_MS)
        runCatching { NativeAlarmScheduler.armNextTrigger(context, alarm) }
            .onFailure {
                AlarmStore.put(context, alarm.copy(enabled = false, nextTriggerAt = 0L))
                AlarmEvents.record(context, session, "next_schedule_failed")
                android.util.Log.e("WakeGuard", "Next occurrence could not be armed", it)
            }
        if (now - expected >= AlarmDefaults.MAX_RINGING_MS) {
            AlarmEvents.record(context, session, "missed")
            AlarmSessions.finish(context, session)
        } else AlarmSessions.play(context, session)
    }

    companion object {
        const val MAX_WATCHDOG_RUNGS = 4
        const val PRIMARY_TRIGGER = -1
    }
}
