package app.wakeguard

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import java.util.Calendar

/**
 * Wraps [AlarmManager] so every scheduling decision lives in one place.
 *
 * Uses `setAlarmClock` for the primary trigger because it is exempt from Doze
 * and App Standby, which is the single most important reliability property on
 * Android. Each non-zero escalation rung additionally arms an
 * `setExactAndAllowWhileIdle` watchdog so that a foreground service killed by
 * memory pressure or an OEM task killer is recovered rather than silently lost.
 */
object NativeAlarmScheduler {

    const val EXTRA_ALARM_ID = "id"
    const val EXTRA_LABEL = "label"
    const val EXTRA_QR = "qrValue"
    const val EXTRA_STEPS = "stepCount"
    const val EXTRA_SOUND = "soundPack"
    const val EXTRA_SNOOZE = "snoozeMinutes"
    const val EXTRA_ESCAPES = "escapes"
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
     * Converts the cross-platform weekday encoding to [Calendar.DAY_OF_WEEK].
     *
     * Dart's [DateTime.weekday] is 1=Monday..7=Sunday, whereas
     * [Calendar.DAY_OF_WEEK] is 1=Sunday..7=Saturday. Comparing the two encodings
     * directly is off by one day in both directions, which is why this
     * translation exists and why LadderScheduler.nextTrigger does the same.
     */
    private fun toCalendarDayOfWeek(weekday: Int): Int = when (weekday) {
        7 -> Calendar.SUNDAY
        else -> weekday + 1
    }

    /**
     * Next local wall-clock occurrence of [hour]:[minute] honouring [weekdays].
     *
     * [weekdays] uses the shared encoding of 1=Monday..7=Sunday, matching Dart
     * and the iOS scheduler. [toCalendarDayOfWeek] converts it for
     * [Calendar.DAY_OF_WEEK].
     *
     * Uses [Calendar] rather than millisecond arithmetic so DST transitions and
     * time-zone changes resolve to a local wall-clock time. On a
     * spring-forward gap the time normalises forward, which is the same choice
     * the Dart side makes.
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
        // Explicit cleanup also removes old watchdog/snooze identities. Android
        // replaces matching operations; occurrence checks reject already-delivered events.
        if (resetSession) AlarmSessions.invalidate(context, alarm.id)
        disarm(context, alarm.id)
        val at = if (triggerAt <= alarm.skipUntilMillis) {
            nextTrigger(alarm.hour, alarm.minute, alarm.weekdays, alarm.skipUntilMillis)
        } else triggerAt
        val scheduled = alarm.copy(nextTriggerAt = if (alarm.enabled) at else 0L)
        AlarmStore.put(context, scheduled)
        if (!alarm.enabled) return
        val manager = context.getSystemService(AlarmManager::class.java) ?: error("AlarmManager unavailable")
        val primary = triggerPendingIntent(context, scheduled)
        try {
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(at, showIntent(context, scheduled)), primary)
        } catch (failure: Exception) {
            AlarmStore.put(context, scheduled.copy(enabled = false, nextTriggerAt = 0L))
            throw failure
        }
        // Watchdogs exist only for a live session, never for a future alarm.
    }

    /**
     * Arms the recovery ladder for a ring that starts at [ringStartAt].
     *
     * The rungs are relative to the ring's start, not to some earlier
     * scheduling instant, which is why this is called again when the trigger
     * fires: a snooze or a watchdog restart begins a ring at a different time
     * than the one the original schedule assumed.
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
        // Absolute stop so a forgotten alarm eventually gives up and the
        // user is not woken at 3am by a stale rung.
        manager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            ringStartAt + AlarmDefaults.MAX_RINGING_MS,
            primaryPendingIntent(context, alarm, ESCALATION_OFFSETS_MS.size),
        )
    }

    /**
     * Arms only the primary trigger for [alarm]'s next occurrence.
     *
     * Called when an alarm fires rather than when it is dismissed. Re-arming
     * only on dismissal meant that anyone who slept through the full fifteen
     * minutes lost tomorrow's alarm: nothing ever ran to arm it again. The
     * watchdog rungs are deliberately untouched here, because cancelling them
     * would disarm the recovery ladder for the ring that is happening right
     * now.
     */
    fun armNextTrigger(context: Context, alarm: StoredAlarm) {
        if (!alarm.enabled) return
        if (!alarm.repeatDaily && alarm.weekdays.isEmpty()) {
            AlarmStore.put(context, alarm.copy(enabled = false, nextTriggerAt = 0L))
            return
        }
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val triggerAt = nextTrigger(alarm.hour, alarm.minute, alarm.weekdays, maxOf(System.currentTimeMillis(), alarm.skipUntilMillis))
        val next = alarm.copy(nextTriggerAt = triggerAt)
        AlarmStore.put(context, next)
        val primary = triggerPendingIntent(context, next)
        runCatching { manager.cancel(primary) }
        manager.setAlarmClock(
            AlarmManager.AlarmClockInfo(triggerAt, showIntent(context, alarm)),
            primary,
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
        // The trigger has its own identity, so cancelling only the rungs left
        // the main alarm armed: that is how a deleted alarm kept ringing.
        runCatching { manager.cancel(triggerPendingIntent(context, alarm)) }
        disarmRungs(context, id)
        runCatching { manager.cancel(snoozePendingIntent(context, id)) }
    }

    /**
     * Cancels only the watchdog rungs, leaving the trigger and any snooze
     * alone. Snoozing needs exactly this: the rungs of the ring being given up
     * must not restart it halfway through the snooze window, but tomorrow's
     * trigger was armed when the alarm fired and must survive.
     */
    fun disarmRungs(context: Context, id: String) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val alarm = AlarmStore.get(context, id) ?: stub(id)
        for (index in 0..ESCALATION_OFFSETS_MS.size) {
            runCatching { manager.cancel(primaryPendingIntent(context, alarm, index)) }
        }
    }

    fun cancel(context: Context, id: String) {
        AlarmSessions.invalidate(context, id)
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
            // The data URI makes each rung a distinct PendingIntent: extras do
            // not participate in PendingIntent equality, so without this every
            // rung would collapse into one and cancel() would leak alarms.
            data = android.net.Uri.parse("wakeguard://alarm/${alarm?.id ?: "?"}/$rung")
            putExtra(EXTRA_ALARM_ID, alarm?.id)
            putExtra(EXTRA_LABEL, alarm?.label)
            putExtra(EXTRA_QR, alarm?.qrValue)
            putExtra(EXTRA_STEPS, alarm?.stepCount)
            putExtra(EXTRA_SOUND, alarm?.soundPack)
            putExtra(EXTRA_SNOOZE, alarm?.snoozeMinutes ?: AlarmDefaults.DEFAULT_SNOOZE_MINUTES)
            putExtra(EXTRA_ESCAPES, escapesExtra(alarm))
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
        val operation = snoozePendingIntent(context, session.alarm.id)
        context.getSystemService(AlarmManager::class.java).setAlarmClock(
            AlarmManager.AlarmClockInfo(maxOf(System.currentTimeMillis() + 500L, at), showIntent(context, session.alarm)), operation)
    }

    private fun snoozePendingIntent(context: Context, id: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            StoredAlarm.notificationIdFor(id) + 7,
            Intent(context, AlarmReceiver::class.java).apply {
                data = android.net.Uri.parse("wakeguard://alarm/$id/snoozed")
                putExtra(EXTRA_ALARM_ID, id)
                putExtra(AlarmSessions.EXTRA_SESSION, AlarmSessions.get(context, id)?.token)
                putExtra("snoozed", true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
}
