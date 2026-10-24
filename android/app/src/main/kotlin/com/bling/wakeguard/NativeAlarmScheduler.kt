package com.bling.wakeguard

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import java.util.Calendar

/**
 * Wraps [AlarmManager] in one place. setAlarmClock for the primary trigger (exempt from Doze);
 * each rung also arms a setExactAndAllowWhileIdle watchdog to recover a killed service.
 */
object NativeAlarmScheduler {

    const val EXTRA_ALARM_ID = "id"
    const val EXTRA_LABEL = "label"
    const val EXTRA_QR = "qrValue"
    const val EXTRA_STEPS = "stepCount"
    const val EXTRA_SOUND = "soundPack"
    const val EXTRA_SNOOZE = "snoozeMinutes"
    const val EXTRA_ESCAPES = "escapes"
    const val EXTRA_OBJECT_TARGET = "objectTarget"
    const val EXTRA_TRIGGER_AT = "triggerAtMillis"

    /** Comma-joined escape names; extras are flat, so the set travels as text. */
    fun escapesExtra(alarm: StoredAlarm?): String =
        (alarm?.escapes ?: AlarmDefaults.ALL_ESCAPES).sorted().joinToString(",")

    /** Mirrors EscalationPolicy.standard in Dart. Keep the two in step. */
    private val ESCALATION_OFFSETS_MS = longArrayOf(
        45_000L,
        2 * 60_000L,
        5 * 60_000L,
        10 * 60_000L,
    )

    /**
     * Dart weekday is 1=Mon..7=Sun; [Calendar.DAY_OF_WEEK] is 1=Sun..7=Sat. Comparing them directly
     * is off by a day, so translate (as LadderScheduler.nextTrigger does).
     */
    private fun toCalendarDayOfWeek(weekday: Int): Int = when (weekday) {
        7 -> Calendar.SUNDAY
        else -> weekday + 1
    }

    /**
     * Next local occurrence of [hour]:[minute] honouring [weekdays] (1=Mon..7=Sun). Uses [Calendar]
     * so DST/zone changes resolve to wall-clock time; matches the Dart side.
     */
    fun nextTrigger(hour: Int, minute: Int, weekdays: Set<Int>, after: Long = System.currentTimeMillis()): Long {
        val calendar = Calendar.getInstance()
        calendar.timeInMillis = after
        calendar.set(Calendar.HOUR_OF_DAY, hour)
        calendar.set(Calendar.MINUTE, minute)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        if (calendar.timeInMillis <= after) {
            calendar.add(Calendar.DAY_OF_YEAR, 1)
        }
        // Walk forward until the weekday matches; at most 7 iterations.
        val wantedDays = weekdays.map(::toCalendarDayOfWeek).toSet()
        repeat(7) {
            if (wantedDays.isEmpty() || wantedDays.contains(calendar.get(Calendar.DAY_OF_WEEK))) {
                return calendar.timeInMillis
            }
            calendar.add(Calendar.DAY_OF_YEAR, 1)
        }
        return calendar.timeInMillis
    }

    fun schedule(context: Context, alarm: StoredAlarm, triggerAt: Long, resetSession: Boolean = true) {
        val previous = AlarmStore.get(context, alarm.id)
        val at = if (triggerAt <= alarm.skipUntilMillis) {
            nextTrigger(alarm.hour, alarm.minute, alarm.weekdays, alarm.skipUntilMillis)
        } else triggerAt
        val scheduled = alarm.copy(nextTriggerAt = if (alarm.enabled) at else 0L)
        val manager = context.getSystemService(AlarmManager::class.java) ?: error("AlarmManager unavailable")
        val primary = triggerPendingIntent(context, scheduled)
        try {
            // Replace the primary delivery before retiring the old occurrence.
            // A rejected edit must not destroy a working alarm or pending check-in.
            if (alarm.enabled) {
                manager.setAlarmClock(AlarmManager.AlarmClockInfo(at, showIntent(context, scheduled)), primary)
            } else {
                manager.cancel(primary)
            }
            AlarmStore.put(context, scheduled)
        } catch (failure: Exception) {
            runCatching {
                manager.cancel(primary)
                if (previous != null) {
                    if (previous.enabled && previous.nextTriggerAt > System.currentTimeMillis()) {
                        manager.setAlarmClock(AlarmManager.AlarmClockInfo(previous.nextTriggerAt,
                            showIntent(context, previous)), triggerPendingIntent(context, previous))
                    }
                    AlarmStore.put(context, previous)
                } else AlarmStore.remove(context, alarm.id)
            }.onFailure {
                // If the system rejects rollback too, never claim it is armed.
                previous?.let { old -> AlarmStore.put(context, old.copy(enabled = false, nextTriggerAt = 0L)) }
                android.util.Log.e("WakeGuard", "Could not restore previous alarm", it)
            }
            throw failure
        }
        // Undo brings the deleted occurrence back instead of starting over. The held session is
        // read before the disarm below and resumed afterwards, so arming it is not undone.
        val held = if (resetSession) AlarmSessions.takeHeld(context, alarm.id) else null
        if (resetSession && held == null) AlarmSessions.invalidate(context, alarm.id)
        disarmRungs(context, alarm.id)
        runCatching { manager.cancel(snoozePendingIntent(context, alarm.id)) }
        // Resuming an occurrence must not fail the schedule: the alarm itself is armed.
        held?.let { runCatching { resume(context, it, scheduled) }
            .onFailure { error -> android.util.Log.e("WakeGuard", "Could not resume held session", error) } }
        // Watchdogs exist only for a live session, never for a future alarm.
    }

    /**
     * Puts a held occurrence back under its alarm with the current settings, then re-arms the
     * timers its phase needs. A held ring resumes; a check-in keeps its original window.
     */
    private fun resume(context: Context, held: AlarmSession, alarm: StoredAlarm) {
        val session = held.copy(alarm = alarm)
        AlarmSessions.save(context, session)
        AlarmSessions.restore(context, session)
        if (session.phase == "ringing") AlarmSessions.play(context, session)
        if (session.phase == "queued") AlarmSessions.drain(context)
    }

    /**
     * Arms the recovery ladder for a ring starting at [ringStartAt]. Rungs are relative to the ring
     * start, so this is re-called on trigger/snooze/watchdog restarts.
     */
    fun armWatchdogs(context: Context, alarm: StoredAlarm, ringStartAt: Long) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        // Cancel any earlier recovery ladder before restoring this live ring.
        disarmRungs(context, alarm.id)
        for ((index, offset) in ESCALATION_OFFSETS_MS.withIndex()) {
            if (ringStartAt + offset <= System.currentTimeMillis()) continue
            manager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                ringStartAt + offset,
                primaryPendingIntent(context, alarm, index),
            )
        }
        // Absolute stop so a forgotten alarm gives up; no stale rung wakes the user at 3am.
        manager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            ringStartAt + AlarmDefaults.MAX_RINGING_MS,
            primaryPendingIntent(context, alarm, ESCALATION_OFFSETS_MS.size),
        )
    }

    /**
     * Arms only the primary trigger for the next occurrence, called at fire time so a slept-through
     * ring does not lose tomorrow's alarm. Watchdog rungs are left untouched.
     */
    fun armNextTrigger(context: Context, alarm: StoredAlarm) {
        if (!alarm.enabled) return
        if (!alarm.repeatDaily && alarm.weekdays.isEmpty()) {
            AlarmStore.put(context, alarm.copy(enabled = false, nextTriggerAt = 0L))
            return
        }
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        // Include the occurrence just handled: if it was delivered a moment early, "now" is still
        // before it and the next trigger would land on the same minute, ringing twice.
        val triggerAt = nextTrigger(alarm.hour, alarm.minute, alarm.weekdays,
            maxOf(System.currentTimeMillis(), alarm.skipUntilMillis, alarm.nextTriggerAt))
        val next = alarm.copy(nextTriggerAt = triggerAt)
        AlarmStore.put(context, next)
        val primary = triggerPendingIntent(context, next)
        runCatching { manager.cancel(primary) }
        manager.setAlarmClock(
            AlarmManager.AlarmClockInfo(triggerAt, showIntent(context, alarm)),
            primary,
        )
    }

    /** Re-arms the saved occurrence unchanged, for a primary delivery that came before its time. */
    fun rearmPrimary(context: Context, alarm: StoredAlarm) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        manager.setAlarmClock(
            AlarmManager.AlarmClockInfo(alarm.nextTriggerAt, showIntent(context, alarm)),
            triggerPendingIntent(context, alarm),
        )
    }

    private fun showIntent(context: Context, alarm: StoredAlarm): PendingIntent =
        PendingIntent.getActivity(
            context,
            alarm.notificationId,
            Intent(context, MainActivity::class.java).apply {
                data = android.net.Uri.parse("wakeguard://scheduled/${alarm.id}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    fun rescheduleAll(context: Context, catchUp: Boolean = true) {
        AlarmSessions.expireStale(context)
        AlarmSessions.sweepHeld(context)
        for (alarm in AlarmStore.all(context)) {
            if (!alarm.enabled) continue
            runCatching {
                val now = System.currentTimeMillis()
                val overdue = alarm.nextTriggerAt > 0L && alarm.nextTriggerAt <= now &&
                    AlarmSessions.get(context, alarm.id)?.scheduledAt != alarm.nextTriggerAt
                if (catchUp && overdue) {
                    if (now - alarm.nextTriggerAt < AlarmDefaults.MAX_RINGING_MS) {
                        // Schedule a user-facing exact delivery rather than starting
                        // a media foreground service directly from a boot receiver.
                        schedule(context, alarm, now + 1000L, resetSession = false)
                        return@runCatching
                    }
                    val missed = AlarmSessions.begin(context, alarm, alarm.nextTriggerAt, recordStart = false)
                    AlarmEvents.record(context, missed, "missed")
                    AlarmSessions.finish(context, missed)
                    if (!alarm.repeatDaily && alarm.weekdays.isEmpty()) {
                        disarm(context, alarm.id)
                        AlarmStore.put(context, alarm.copy(enabled = false, nextTriggerAt = 0L))
                        return@runCatching
                    }
                }
                val at = if (catchUp && alarm.nextTriggerAt > now) alarm.nextTriggerAt else
                    nextTrigger(alarm.hour, alarm.minute, alarm.weekdays, maxOf(now, alarm.skipUntilMillis))
                schedule(context, alarm, at, resetSession = false)
            }
        }
        AlarmSessions.restore(context)
    }

    /** Cancels every PendingIntent belonging to [id] but keeps the record. */
    fun disarm(context: Context, id: String) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val alarm = AlarmStore.get(context, id) ?: stub(id)
        // Cancel the trigger too: cancelling only rungs once left a deleted alarm ringing.
        runCatching { manager.cancel(triggerPendingIntent(context, alarm)) }
        disarmRungs(context, id)
        runCatching { manager.cancel(snoozePendingIntent(context, id)) }
    }

    /**
     * Cancels only the watchdog rungs, leaving the trigger and snooze alone: snoozing must not let
     * the rungs restart the ring, but tomorrow's trigger must survive.
     */
    fun disarmRungs(context: Context, id: String) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val alarm = AlarmStore.get(context, id) ?: stub(id)
        for (index in 0..ESCALATION_OFFSETS_MS.size) {
            runCatching { manager.cancel(primaryPendingIntent(context, alarm, index)) }
        }
    }

    fun cancel(context: Context, id: String) {
        // The occurrence is held rather than ended: Undo re-arms this same session.
        AlarmSessions.hold(context, id)
        disarm(context, id)
        AlarmStore.remove(context, id)
    }

    /** Minimal record used only to rebuild PendingIntent identities. */
    private fun stub(id: String): StoredAlarm = StoredAlarm(
        id = id,
        hour = 0,
        minute = 0,
        label = "",
        enabled = false,
        repeatDaily = true,
        weekdays = emptySet(),
        qrValue = "",
        stepCount = 0,
    )

    private fun primaryPendingIntent(context: Context, alarm: StoredAlarm?, rung: Int): PendingIntent {
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            // A distinct data URI per rung; extras do not count for PendingIntent equality.
            data = android.net.Uri.parse("wakeguard://alarm/${alarm?.id ?: "?"}/$rung")
            putExtra(EXTRA_ALARM_ID, alarm?.id)
            putExtra(EXTRA_LABEL, alarm?.label)
            putExtra(EXTRA_QR, alarm?.qrValue)
            putExtra(EXTRA_STEPS, alarm?.stepCount)
            putExtra(EXTRA_SOUND, alarm?.soundPack)
            putExtra(EXTRA_SNOOZE, alarm?.snoozeMinutes ?: AlarmDefaults.DEFAULT_SNOOZE_MINUTES)
            putExtra(EXTRA_ESCAPES, escapesExtra(alarm))
            putExtra(EXTRA_OBJECT_TARGET, alarm?.objectTarget ?: "sink")
            putExtra("rung", rung)
            putExtra(AlarmSessions.EXTRA_SESSION, alarm?.id?.let { AlarmSessions.get(context, it)?.token })
        }
        return PendingIntent.getBroadcast(
            context,
            StoredAlarm.notificationIdFor(alarm?.id ?: "?") + rung,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun triggerPendingIntent(context: Context, alarm: StoredAlarm): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            alarm.notificationId,
            Intent(context, AlarmReceiver::class.java).apply {
                data = android.net.Uri.parse("wakeguard://alarm/${alarm.id}/trigger")
                putExtra(EXTRA_ALARM_ID, alarm.id)
                putExtra(EXTRA_LABEL, alarm.label)
                putExtra(EXTRA_QR, alarm.qrValue)
                putExtra(EXTRA_STEPS, alarm.stepCount)
                putExtra(EXTRA_SOUND, alarm.soundPack)
                putExtra(EXTRA_SNOOZE, alarm.snoozeMinutes)
                putExtra(EXTRA_ESCAPES, escapesExtra(alarm))
                putExtra(EXTRA_OBJECT_TARGET, alarm.objectTarget)
                putExtra(EXTRA_TRIGGER_AT, alarm.nextTriggerAt)
                putExtra("rung", -1)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** Identity matches the snooze alarm [SnoozeReceiver] schedules. */
    fun armRecovery(context: Context, session: AlarmSession) {
        val operation = PendingIntent.getBroadcast(context, 0, Intent(context, AlarmReceiver::class.java).apply {
            data = android.net.Uri.parse("wakeguard://recovery/${session.token}")
            putExtra(EXTRA_ALARM_ID, session.alarm.id)
            putExtra(AlarmSessions.EXTRA_SESSION, session.token)
            putExtra("recovery", true)
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        context.getSystemService(AlarmManager::class.java).setAlarmClock(
            AlarmManager.AlarmClockInfo(System.currentTimeMillis() + 1000L, showIntent(context, session.alarm)), operation)
    }

    fun armSnooze(context: Context, session: AlarmSession, at: Long) {
        // Use the session being armed, rather than rereading mutable stored extras.
        val operation = snoozePendingIntent(context, session.alarm.id, session.token)
        context.getSystemService(AlarmManager::class.java).setAlarmClock(
            AlarmManager.AlarmClockInfo(maxOf(System.currentTimeMillis() + 500L, at), showIntent(context, session.alarm)), operation)
    }

    private fun snoozePendingIntent(context: Context, id: String, token: String? = null): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            StoredAlarm.notificationIdFor(id) + 7,
            Intent(context, AlarmReceiver::class.java).apply {
                data = android.net.Uri.parse("wakeguard://alarm/$id/snoozed")
                putExtra(EXTRA_ALARM_ID, id)
                putExtra(AlarmSessions.EXTRA_SESSION, token)
                putExtra("snoozed", true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
}
