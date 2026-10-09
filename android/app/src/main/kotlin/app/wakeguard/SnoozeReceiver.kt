package app.wakeguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SnoozeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("alarmId") ?: return
        val session = AlarmSessions.get(context, id) ?: return
        if (session.token != intent.getStringExtra(AlarmSessions.EXTRA_SESSION) || session.phase != "ringing" || session.alarm.snoozeMinutes <= 0) return
        val at = System.currentTimeMillis() + session.alarm.snoozeMinutes * 60_000L
        val snoozed = session.copy(phase = "snoozed", snoozes = session.snoozes + 1, checkAt = at)
        // Arm before stopping: a failed snooze never silently dismisses the ring.
        runCatching {
            AlarmSessions.save(context, snoozed)
            NativeAlarmScheduler.armSnooze(context, snoozed, at)
        }.onFailure {
            AlarmSessions.save(context, session)
            android.util.Log.e("WakeGuard", "Snooze could not be armed", it)
            return
        }
        AlarmEvents.record(context, snoozed, "snoozed")
        AlarmSessions.finish(context, snoozed, "snoozed")
    }
}
