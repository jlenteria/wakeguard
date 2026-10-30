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

    /**
     * Serializes every AlarmManager/store mutation. [rescheduleAll] runs on a background thread at
     * cold start and boot, while schedule/cancel/dismiss run on the platform thread and receivers
     * arm from the main thread; without one shared lock, a save seconds after opening the app could
     * be overwritten by rescheduleAll's stale snapshot (or have its rungs cancelled). Reentrant, so
     * the nested calls inside [schedule]/[rescheduleAll] on one thread are safe.
     */
    private val mutationLock = Any()

    /**
     * Single background worker for the long re-arms ([rescheduleAll]): a broadcast has a ~10s budget
     * and the platform thread must not stall behind minutes of preference commits. Work here still
     * takes [mutationLock], so background and foreground mutations stay serialized.
     */
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "WakeGuardScheduler").apply { isDaemon = true }
    }

    /**
     * Runs [block] on [worker] and always calls [onDone] afterwards, even when the executor is shut
     * down (then inline, so a boot re-arm is lost never silently).
     */
    fun submit(block: () -> Unit, onDone: () -> Unit = {}) {
        val queued = runCatching { worker.execute {
            runCatching(block).onFailure { android.util.Log.e("WakeGuard", "Scheduled work failed", it) }
            runCatching(onDone).onFailure { android.util.Log.e("WakeGuard", "Completion callback failed", it) }
        } }.isSuccess
        if (queued) return
        runCatching(block).onFailure { android.util.Log.e("WakeGuard", "Inline work failed", it) }
        runCatching(onDone)
    }

    /** Comma-joined escape names; extras are flat, so the set travels as text. */
    fun escapesExtra(alarm: StoredAlarm?): String =
        (alarm?.escapes ?: AlarmDefaults.ALL_ESCAPES).sorted().joinToString(",")

    /** Mirrors EscalationPolicy.standard in Dart. Keep the two in step. */
    val ESCALATION_OFFSETS_MS = longArrayOf(
        45_000L,
        2 * 60_000L,
        5 * 60_000L,
        10 * 60_000L,
    )

    /** Lead for a catch-up/next-occurrence re-arm so it is never delivered in the past. */
    const val PRIMARY_OFFSET_MS = 1_000L

    /** Bounded retry ladder for a next-occurrence arm that failed: 5s, 20s, 60s. */
    val WATCHDOG_RUNG_OFFSETS_MS = longArrayOf(5_000L, 20_000L, 60_000L)

    /** Request-code base for next-occurrence retries, clear of rungs (+0..4) and snooze (+7). */
    private const val RETRY_REQUEST_BASE = 100

    /** Request-code base for queued-occurrence promotion triggers, clear of every code above. */
    private const val QUEUE_REQUEST_BASE = 200

    /** How long a queued occurrence waits for the ringing alarm ahead of it before checking again. */
    const val QUEUE_WATCHDOG_MS = 20_000L

    private fun schedulePrefs(context: android.content.Context) =
        context.createDeviceProtectedStorageContext()
            .getSharedPreferences("wakeguard.schedule.v1", android.content.Context.MODE_PRIVATE)

    /** Counts consecutive next-occurrence arm failures per alarm, so a transient error is not fatal. */
    fun noteNextScheduleFailure(context: android.content.Context, alarm: StoredAlarm): Int {
        val p = schedulePrefs(context)
        val previous = if (p.getString("nextFailId", null) == alarm.id) p.getInt("nextFailCount", 0) else 0
        val count = previous + 1
        p.edit().putString("nextFailId", alarm.id).putInt("nextFailCount", count).commit()
        return count
    }

    fun clearNextScheduleFailures(context: android.content.Context, alarm: StoredAlarm) {
        val p = schedulePrefs(context)
        if (p.getString("nextFailId", null) == alarm.id)
            p.edit().remove("nextFailId").remove("nextFailCount").apply()
    }

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
        synchronized(mutationLock) {
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
                rollbackAfterFailedSchedule(context, alarm.id, manager, primary, previous)
                // Surface the rejection: the caller (Dart save) must not believe the edit succeeded.
                throw failure
            }
            // Undo brings the deleted occurrence back instead of starting over. The held session is
            // read before the disarm below and resumed afterwards, so arming it is not undone.
            val held = if (resetSession) AlarmSessions.takeHeld(context, alarm.id) else null
            // An edit re-arms a snoozed or check-in occurrence against the new settings: it is
            // already in flight, and cancelling it would drop the ring or safety check it promised.
            val inFlight = if (resetSession && held == null && alarm.enabled)
                AlarmSessions.get(context, alarm.id)
                    ?.takeIf { AlarmPolicy.editKeepsSession(it.phase, scheduled.checkInMinutes) }
            else null
            if (resetSession && held == null && inFlight == null) AlarmSessions.invalidate(context, alarm.id)
            disarmRungs(context, alarm.id)
            runCatching { manager.cancel(snoozePendingIntent(context, alarm.id)) }
            // A fresh schedule supersedes any corrective retry and its failure count.
            runCatching {
                for (attempt in WATCHDOG_RUNG_OFFSETS_MS.indices)
                    manager.cancel(nextRetryPendingIntent(context, scheduled, attempt + 1, false))
            }
            clearNextScheduleFailures(context, alarm)
            // A disabled alarm must not keep promoting a queued occurrence either.
            if (!alarm.enabled) runCatching {
                AlarmSessions.get(context, alarm.id)?.let { manager.cancel(queuePendingIntent(context, it)) }
            }
            // Resuming an occurrence must not fail the schedule: the alarm itself is armed.
            held?.let { runCatching { resume(context, it, scheduled) }
                .onFailure { error -> android.util.Log.e("WakeGuard", "Could not resume held session", error) } }
            inFlight?.let { runCatching { resume(context, it, scheduled) }
                .onFailure { error -> android.util.Log.e("WakeGuard", "Could not re-arm in-flight occurrence", error) } }
            // Watchdogs exist only for a live session, never for a future alarm.
        }
    }

    /**
     * Restores the previously armed occurrence after a rejected edit, leaving the stored record
     * truthful: only ever claims [StoredAlarm.enabled] when the trigger is genuinely armed. A failed
     * re-arm disables the alarm (never a lying enabled record) and arms a corrective retry, so the
     * next boot/open re-arms it rather than silently losing the alarm.
     */
    private fun rollbackAfterFailedSchedule(
        context: Context,
        id: String,
        manager: AlarmManager,
        primary: PendingIntent,
        previous: StoredAlarm?,
    ) {
        val restored = runCatching {
            // Retire the failed occurrence first; it must not ring with a half-written record.
            runCatching { manager.cancel(primary) }
            when {
                previous == null -> {
                    AlarmStore.remove(context, id)
                    true
                }
                previous.enabled && previous.nextTriggerAt > System.currentTimeMillis() -> {
                    manager.setAlarmClock(
                        AlarmManager.AlarmClockInfo(previous.nextTriggerAt, showIntent(context, previous)),
                        triggerPendingIntent(context, previous),
                    )
                    AlarmStore.put(context, previous)
                    true
                }
                else -> {
                    // Nothing to re-arm (already past, or the prior record was disabled). Persist it
                    // as-is; it was never armed by us, so it stays a faithful mirror.
                    AlarmStore.put(context, previous)
                    !previous.enabled
                }
            }
        }.getOrDefault(false)
        if (restored) return
        // Rollback itself failed. Never claim the alarm is armed: disable truthfully, log, and arm a
        // corrective retry so the alarm is re-armed on the next boot/open rather than silently lost.
        val truth = previous?.copy(enabled = false, nextTriggerAt = 0L)
        runCatching {
            if (truth != null) AlarmStore.put(context, truth) else AlarmStore.remove(context, id)
        }.onFailure {
            android.util.Log.e("WakeGuard", "Could not mark alarm $id disabled after failed rollback", it)
        }
        android.util.Log.e("WakeGuard", "Schedule and rollback both failed for $id; disarmed to avoid a lying record")
        if (previous != null) {
            // The record says disabled, which is the truth right now. A forced rung re-arms tomorrow's
            // occurrence and only then restores [StoredAlarm.enabled].
            runCatching { armNextRetry(context, previous, 1, force = true) }
                .onFailure { android.util.Log.e("WakeGuard", "Corrective reschedule retry could not be armed", it) }
        }
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
        synchronized(mutationLock) {
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
    }

    /**
     * Arms only the primary trigger for the next occurrence, called at fire time so a slept-through
     * ring does not lose tomorrow's alarm. Watchdog rungs are left untouched.
     */
    fun armNextTrigger(context: Context, alarm: StoredAlarm) {
        synchronized(mutationLock) {
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
            // The record is written first: a trigger armed against a value the store does not have
            // would be rejected by the receiver as stale, which is a silently lost alarm.
            AlarmStore.put(context, next)
            val primary = triggerPendingIntent(context, next)
            runCatching { manager.cancel(primary) }
            try {
                manager.setAlarmClock(
                    AlarmManager.AlarmClockInfo(triggerAt, showIntent(context, alarm)),
                    primary,
                )
            } catch (failure: Exception) {
                // Put the previous record back so the store only ever describes a real arm, then let
                // the caller count the failure and schedule a bounded retry.
                runCatching { AlarmStore.put(context, alarm) }
                    .onFailure { android.util.Log.e("WakeGuard", "Could not restore record for ${alarm.id}", it) }
                throw failure
            }
        }
    }

    /**
     * Called when arming tomorrow's trigger failed. A transient rejection must not kill the alarm:
     * the failure is counted, an event recorded, and a bounded retry rung armed. Only after the whole
     * ladder fails is the alarm disabled, so the user sees a dead alarm rather than a silent one.
     * [force] re-arms an alarm this pass had to disable (a failed rollback leaves nothing armed).
     */
    fun handleNextTriggerFailure(context: Context, alarm: StoredAlarm, force: Boolean = false) {
        synchronized(mutationLock) {
            val failures = noteNextScheduleFailure(context, alarm)
            android.util.Log.e("WakeGuard", "Next-occurrence arm failed for ${alarm.id} (consecutive $failures)")
            AlarmEvents.record(context, eventSession(alarm, "next_schedule_failed"), "next_schedule_failed")
            if (failures <= WATCHDOG_RUNG_OFFSETS_MS.size) {
                runCatching { armNextRetry(context, alarm.copy(enabled = true), failures, force) }
                    .onFailure { android.util.Log.e("WakeGuard", "Corrective retry rung could not be armed", it) }
                return
            }
            clearNextScheduleFailures(context, alarm)
            runCatching { AlarmStore.put(context, alarm.copy(enabled = false, nextTriggerAt = 0L)) }
                .onFailure { android.util.Log.e("WakeGuard", "Could not disable ${alarm.id} after repeated failures", it) }
            AlarmEvents.record(context, eventSession(alarm, "next_schedule_gave_up"), "next_schedule_gave_up")
        }
    }

    /**
     * Handles a retry rung: re-arms tomorrow's trigger, restoring the truthful stored record if the
     * attempt fails again so the ladder, not a lie, decides whether the alarm stays enabled.
     */
    fun retryNextTrigger(context: Context, id: String, attempt: Int, force: Boolean) {
        synchronized(mutationLock) {
            val stored = AlarmStore.get(context, id) ?: return
            val target = if (force && !stored.enabled) stored.copy(enabled = true) else stored
            // The user disabled it in the meantime (which cancels these rungs): nothing to restore.
            if (!target.enabled) return
            val armed = runCatching { armNextTrigger(context, target) }
            if (armed.isSuccess) {
                clearNextScheduleFailures(context, target)
                android.util.Log.i("WakeGuard", "Corrective reschedule armed the next occurrence of $id")
                return
            }
            // armNextTrigger restored [target], which [force] had re-enabled; put the record back.
            if (force && !stored.enabled) runCatching { AlarmStore.put(context, stored) }
            handleNextTriggerFailure(context, stored, force)
        }
    }

    /** A session-shaped record so scheduler-level failures still reach the event history. */
    private fun eventSession(alarm: StoredAlarm, phase: String): AlarmSession = AlarmSession(
        token = "scheduler-${alarm.id}-${System.currentTimeMillis()}",
        alarm = alarm,
        scheduledAt = alarm.nextTriggerAt,
        startedAt = System.currentTimeMillis(),
        phase = phase,
    )


    /** Re-arms the saved occurrence unchanged, for a primary delivery that came before its time. */
    fun rearmPrimary(context: Context, alarm: StoredAlarm) {
        synchronized(mutationLock) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            manager.setAlarmClock(
                AlarmManager.AlarmClockInfo(alarm.nextTriggerAt, showIntent(context, alarm)),
                triggerPendingIntent(context, alarm),
            )
        }
    }

    /**
     * Arms a bounded watchdog rung that retries arming tomorrow's trigger, so one transient failure
     * (a lost store commit, a rejected exact alarm) does not permanently drop the next occurrence.
     * The rung carries [alarm]'s id and next trigger so the receiver can call [armNextTrigger] again.
     */
    fun armNextRetry(context: Context, alarm: StoredAlarm, attempt: Int, force: Boolean = false) {
        synchronized(mutationLock) {
            if (!alarm.enabled && !force) return
            val offset = WATCHDOG_RUNG_OFFSETS_MS.getOrNull(attempt - 1) ?: return
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            val at = System.currentTimeMillis() + offset
            val operation = nextRetryPendingIntent(context, alarm, attempt, force)
            runCatching { manager.cancel(operation) }
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, operation)
        }
    }

    private fun nextRetryPendingIntent(
        context: Context,
        alarm: StoredAlarm,
        attempt: Int,
        force: Boolean,
    ): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            alarm.notificationId + RETRY_REQUEST_BASE + attempt,
            Intent(context, AlarmReceiver::class.java).apply {
                data = android.net.Uri.parse("wakeguard://nextretry/${alarm.id}/$attempt")
                putExtra(EXTRA_ALARM_ID, alarm.id)
                putExtra(EXTRA_TRIGGER_AT, alarm.nextTriggerAt)
                putExtra("next_retry", attempt)
                putExtra("next_retry_force", force)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * Arms a short trigger that promotes a queued occurrence once the alarm ahead of it finishes.
     * The in-process handler in [AlarmSessions] is only the fast path: without this rung, a process
     * death mid-queue would strand every later alarm.
     */
    fun armQueueWatchdog(context: Context, session: AlarmSession) {
        synchronized(mutationLock) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            val operation = queuePendingIntent(context, session)
            runCatching { manager.cancel(operation) }
            manager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + QUEUE_WATCHDOG_MS,
                operation,
            )
        }
    }

    fun cancelQueueWatchdog(context: Context, session: AlarmSession) {
        synchronized(mutationLock) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            runCatching { manager.cancel(queuePendingIntent(context, session)) }
        }
    }

    private fun queuePendingIntent(context: Context, session: AlarmSession): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            session.alarm.notificationId + QUEUE_REQUEST_BASE,
            Intent(context, AlarmReceiver::class.java).apply {
                data = android.net.Uri.parse("wakeguard://queue/${session.alarm.id}/${session.token}")
                putExtra(EXTRA_ALARM_ID, session.alarm.id)
                putExtra(AlarmSessions.EXTRA_SESSION, session.token)
                putExtra("queue_watchdog", true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )


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
        synchronized(mutationLock) {
            // Heal a volume left boosted by a ring whose process was killed before it could restore.
            RingingService.healStaleVolume(context)
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
                            schedule(context, alarm, now + PRIMARY_OFFSET_MS, resetSession = false)
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
                }.onFailure { error ->
                    // A boot/startup re-arm that fails silently is the exact Xiaomi silent-loss class:
                    // surface and record every failure so the alarm is not quietly gone.
                    android.util.Log.e("WakeGuard", "Boot/startup re-arm failed for ${alarm.id}", error)
                    runCatching { AlarmEvents.record(context, eventSession(alarm, "reschedule_failed"), "reschedule_failed") }
                        .onFailure { android.util.Log.e("WakeGuard", "Could not record re-arm failure", it) }
                }
            }
            AlarmSessions.restore(context)
        }
    }

    /** Cancels every PendingIntent belonging to [id] but keeps the record. */
    fun disarm(context: Context, id: String) {
        synchronized(mutationLock) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            val alarm = AlarmStore.get(context, id) ?: stub(id)
            // Cancel the trigger too: cancelling only rungs once left a deleted alarm ringing.
            runCatching { manager.cancel(triggerPendingIntent(context, alarm)) }
            disarmRungs(context, id)
            runCatching { manager.cancel(snoozePendingIntent(context, id)) }
            // A queued occurrence of this alarm must not keep promoting itself afterwards.
            runCatching { AlarmSessions.get(context, id)?.let { manager.cancel(queuePendingIntent(context, it)) } }
            runCatching {
                for (attempt in WATCHDOG_RUNG_OFFSETS_MS.indices)
                    manager.cancel(nextRetryPendingIntent(context, alarm, attempt + 1, false))
            }
        }
    }

    /**
     * Cancels only the watchdog rungs, leaving the trigger and snooze alone: snoozing must not let
     * the rungs restart the ring, but tomorrow's trigger must survive.
     */
    fun disarmRungs(context: Context, id: String) {
        synchronized(mutationLock) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            val alarm = AlarmStore.get(context, id) ?: stub(id)
            for (index in 0..ESCALATION_OFFSETS_MS.size) {
                runCatching { manager.cancel(primaryPendingIntent(context, alarm, index)) }
            }
        }
    }

    fun cancel(context: Context, id: String) {
        synchronized(mutationLock) {
            // The occurrence is held rather than ended: Undo re-arms this same session.
            AlarmSessions.hold(context, id)
            disarm(context, id)
            AlarmStore.remove(context, id)
        }
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
        synchronized(mutationLock) {
            val operation = PendingIntent.getBroadcast(context, 0, Intent(context, AlarmReceiver::class.java).apply {
                data = android.net.Uri.parse("wakeguard://recovery/${session.token}")
                putExtra(EXTRA_ALARM_ID, session.alarm.id)
                putExtra(AlarmSessions.EXTRA_SESSION, session.token)
                putExtra("recovery", true)
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            context.getSystemService(AlarmManager::class.java).setAlarmClock(
                AlarmManager.AlarmClockInfo(System.currentTimeMillis() + PRIMARY_OFFSET_MS, showIntent(context, session.alarm)), operation)
        }
    }

    fun armSnooze(context: Context, session: AlarmSession, at: Long) {
        synchronized(mutationLock) {
            // Use the session being armed, rather than rereading mutable stored extras.
            val operation = snoozePendingIntent(context, session.alarm.id, session.token)
            context.getSystemService(AlarmManager::class.java).setAlarmClock(
                AlarmManager.AlarmClockInfo(maxOf(System.currentTimeMillis() + 500L, at), showIntent(context, session.alarm)), operation)
        }
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
