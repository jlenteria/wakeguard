package com.bling.wakeguard

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Native check-ins: no Flutter isolate or long-running timer is required. */
object StayAwake {
    const val GRACE_MS = 60_000L
    // Channel sound/vibration are immutable; migrate both defaults for existing installs.
    private const val CHANNEL = "wakeguard.checkin.audible.v4"
    private val NOTIFICATION_VIBRATION = longArrayOf(0, 500, 300, 500)

    private fun reminderSound(context: Context): Uri =
        Uri.parse("android.resource://${context.packageName}/raw/checkin_reminder")

    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(CHANNEL, "Stay Awake check-ins", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "A short sound reminds you to confirm you are still awake."
            setSound(reminderSound(context), AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true)
            vibrationPattern = NOTIFICATION_VIBRATION
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun notificationsAvailable(context: Context): Boolean {
        if (!HealthChecker.hasNotificationPermission(context) ||
            !NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        createChannel(context)
        return context.getSystemService(NotificationManager::class.java)
            .getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    fun remindersAudible(context: Context): Boolean {
        if (!notificationsAvailable(context)) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL)
        return channel != null && channel.importance >= NotificationManager.IMPORTANCE_DEFAULT &&
            channel.sound != null
    }

    fun settingsIntent(context: Context): Intent =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL)
            }
        } else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = android.net.Uri.parse("package:${context.packageName}")
        }

    private fun operation(context: Context, session: AlarmSession, stage: String): PendingIntent =
        PendingIntent.getBroadcast(context, 0, Intent(context, CheckInReceiver::class.java).apply {
            data = android.net.Uri.parse("wakeguard://checkin/${session.token}/$stage")
            putExtra("id", session.alarm.id); putExtra(AlarmSessions.EXTRA_SESSION, session.token)
            putExtra("stage", stage)
            // Background broadcast queues can hold the prompt for tens of seconds.
            addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun showApp(context: Context): PendingIntent =
        PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** The response window only exists once the prompt has actually been shown. */
    fun windowOpen(session: AlarmSession, now: Long = System.currentTimeMillis()) =
        session.promptedAt > 0L && now >= session.promptedAt && now < deadline(session)

    fun deadline(session: AlarmSession) = session.promptedAt + GRACE_MS

    fun schedule(context: Context, session: AlarmSession) {
        check(session.alarm.checkInMinutes > 0 && !session.followUp) { "Check-in is not enabled for this occurrence" }
        val waiting = session.copy(phase = "checkin", promptedAt = 0L,
            checkAt = System.currentTimeMillis() + session.alarm.checkInMinutes * 60_000L)
        AlarmSessions.save(context, waiting)
        restore(context, waiting)
        AlarmEvents.record(context, waiting, "checkin_scheduled")
        android.util.Log.i("WakeGuard", "Check-in armed for ${session.alarm.id} in ${session.alarm.checkInMinutes} minutes")
    }

    fun restore(context: Context, session: AlarmSession) {
        val now = System.currentTimeMillis()
        val windowStart = if (session.promptedAt > 0L) session.promptedAt else session.checkAt
        if (now > windowStart + GRACE_MS + AlarmDefaults.MAX_RINGING_MS) {
            AlarmEvents.record(context, session, "checkin_expired")
            AlarmSessions.save(context, session.copy(phase = "done"))
            cancel(context, session)
            return
        }
        val manager = context.getSystemService(AlarmManager::class.java)
        val show = showApp(context)
        // A one-minute response window must not compete with idle-alarm quotas.
        if (session.promptedAt == 0L) {
            // The deadline is armed only once the prompt is shown, so the countdown
            // never starts before the user can see it.
            manager.cancel(operation(context, session, "deadline"))
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(maxOf(now + 500L, session.checkAt), show), operation(context, session, "prompt"))
            return
        }
        // Do not show an already-expired prompt which cannot be confirmed.
        if (now < deadline(session)) {
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(now + 500L, show), operation(context, session, "prompt"))
        } else {
            manager.cancel(operation(context, session, "prompt"))
        }
        manager.setAlarmClock(AlarmManager.AlarmClockInfo(maxOf(now + 1000L, deadline(session)), show), operation(context, session, "deadline"))
    }

    /** Starts the response window now, persisting it before anything is shown. */
    fun open(context: Context, session: AlarmSession): AlarmSession {
        if (session.promptedAt > 0L) return session
        val opened = session.copy(promptedAt = System.currentTimeMillis())
        AlarmSessions.save(context, opened)
        context.getSystemService(AlarmManager::class.java).setAlarmClock(
            AlarmManager.AlarmClockInfo(deadline(opened), showApp(context)), operation(context, opened, "deadline"))
        return opened
    }

    fun prompt(context: Context, session: AlarmSession) {
        if (!notificationsAvailable(context)) {
            AlarmEvents.record(context, session, "checkin_notification_blocked")
            android.util.Log.w("WakeGuard", "Check-in notification is blocked for ${session.alarm.id}; deadline remains armed")
            return
        }
        val remainingSeconds = ((deadline(session) - System.currentTimeMillis() + 999L) / 1000L).coerceIn(1L, 60L)
        val manager = context.getSystemService(NotificationManager::class.java)
        val sound = reminderSound(context)
        createChannel(context)
        val openCheckIn = PendingIntent.getActivity(context, 0,
            Intent(context, StayAwakeActivity::class.java).apply {
                data = Uri.parse("wakeguard://checkin/${session.token}/view")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(NativeAlarmScheduler.EXTRA_ALARM_ID, session.alarm.id)
                putExtra(AlarmSessions.EXTRA_SESSION, session.token)
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(session.alarm.notificationId xor 0x40000000,
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm).setContentTitle("Still up?")
                .setContentText("${session.alarm.label}: confirm within $remainingSeconds seconds. Otherwise one follow-up alarm will ring.")
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(false).setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setSound(sound).setVibrate(NOTIFICATION_VIBRATION).setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setContentIntent(openCheckIn)
                .setFullScreenIntent(openCheckIn, true)
                .addAction(0, "I'm up", operation(context, session, "confirm")).build())
        AlarmEvents.record(context, session, "checkin_prompted")
    }

    fun cancel(context: Context, session: AlarmSession) {
        val manager = context.getSystemService(AlarmManager::class.java)
        for (stage in listOf("prompt", "deadline")) manager.cancel(operation(context, session, stage))
        context.getSystemService(NotificationManager::class.java).cancel(session.alarm.notificationId xor 0x40000000)
    }

    /** Both the notification and foreground card confirm the same persisted occurrence. */
    fun confirm(context: Context, id: String, token: String?): Boolean {
        val session = AlarmSessions.get(context, id) ?: return false
        if (session.phase != "checkin" || token == null || session.token != token) return false
        if (!windowOpen(session)) return false
        // Persist first: a failed write must leave the deadline armed for recovery.
        AlarmSessions.save(context, session.copy(phase = "done"))
        cancel(context, session)
        AlarmEvents.record(context, session, "confirmed", "checkin")
        return true
    }
}

class CheckInReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val session = AlarmSessions.get(context, id) ?: return
        if (session.token != intent.getStringExtra(AlarmSessions.EXTRA_SESSION) || session.phase != "checkin") return
        val now = System.currentTimeMillis()
        when (intent.getStringExtra("stage")) {
            "prompt" -> {
                if (now < session.checkAt) {
                    StayAwake.restore(context, session)
                    return
                }
                val opened = runCatching { StayAwake.open(context, session) }.getOrElse {
                    AlarmEvents.record(context, session, "checkin_failed")
                    android.util.Log.e("WakeGuard", "Check-in window could not be opened", it)
                    return
                }
                if (StayAwake.windowOpen(opened, System.currentTimeMillis())) {
                    runCatching { StayAwake.prompt(context, opened) }.onFailure {
                        AlarmEvents.record(context, opened, "checkin_notification_failed")
                        android.util.Log.e("WakeGuard", "Check-in prompt failed", it)
                    }
                }
            }
            "confirm" -> {
                StayAwake.confirm(context, id, session.token)
            }
            "deadline" -> {
                if (session.promptedAt == 0L || now < StayAwake.deadline(session)) {
                    StayAwake.restore(context, session)
                    return
                }
                StayAwake.cancel(context, session)
                if (now > StayAwake.deadline(session) + AlarmDefaults.MAX_RINGING_MS) {
                    AlarmEvents.record(context, session, "checkin_expired")
                    AlarmSessions.save(context, session.copy(phase = "done"))
                    return
                }
                AlarmEvents.record(context, session, "unanswered")
                val follow = AlarmSessions.restarted(context, session,
                    if (AlarmSessions.active(context) == null) "ringing" else "queued").copy(
                    followUp = true, alarm = session.alarm.copy(snoozeMinutes = 0))
                AlarmSessions.save(context, follow)
                AlarmSessions.play(context, follow)
            }
        }
    }
}
