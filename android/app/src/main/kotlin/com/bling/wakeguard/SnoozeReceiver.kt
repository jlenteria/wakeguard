package com.bling.wakeguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast

class SnoozeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Accept the old notification key as well as the shared alarm-id key.
        val id = intent.getStringExtra(NativeAlarmScheduler.EXTRA_ALARM_ID)
            ?: intent.getStringExtra("alarmId") ?: return
        AlarmSnooze.snooze(context, id, intent.getStringExtra(AlarmSessions.EXTRA_SESSION))
            .onSuccess { minutes ->
                Toast.makeText(context, context.getString(R.string.snoozed_for_minutes, minutes), Toast.LENGTH_SHORT).show()
            }
            .onFailure {
                Toast.makeText(context, context.getString(R.string.snooze_failed), Toast.LENGTH_LONG).show()
            }
    }
}

/** Token-checked scheduling for the notification's Snooze action. */
object AlarmSnooze {
    fun actionIntent(context: Context, id: String, token: String?): Intent =
        Intent(context, SnoozeReceiver::class.java).apply {
            data = android.net.Uri.parse("wakeguard://snooze/$id/$token")
            putExtra(NativeAlarmScheduler.EXTRA_ALARM_ID, id)
            putExtra(AlarmSessions.EXTRA_SESSION, token)
        }

    fun snooze(context: Context, id: String, token: String?): Result<Int> = runCatching {
        val session = checkNotNull(AlarmSessions.get(context, id)) { "Alarm session is no longer available" }
        check(token != null && session.token == token && session.phase == "ringing") { "This alarm is no longer ringing" }
        check(!session.followUp && session.alarm.snoozeMinutes > 0) { "Snooze is disabled for this alarm" }
        val at = System.currentTimeMillis() + session.alarm.snoozeMinutes * 60_000L
        val snoozed = session.copy(phase = "snoozed", snoozes = session.snoozes + 1, checkAt = at)
        // Arm before stopping: a failed snooze never silently dismisses the ring.
        try {
            AlarmSessions.save(context, snoozed)
            NativeAlarmScheduler.armSnooze(context, snoozed, at)
        } catch (failure: Exception) {
            runCatching { AlarmSessions.save(context, session) }
                .onFailure { android.util.Log.e("WakeGuard", "Snooze rollback failed", it) }
            throw failure
        }
        // An optional history write must not prevent stopping an already-armed snooze.
        runCatching { AlarmEvents.record(context, snoozed, "snoozed") }
            .onFailure { android.util.Log.e("WakeGuard", "Could not record snooze", it) }
        AlarmSessions.finish(context, snoozed, "snoozed")
        session.alarm.snoozeMinutes
    }.onFailure { android.util.Log.e("WakeGuard", "Snooze could not be completed", it) }
}
