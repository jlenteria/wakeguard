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
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun schedule(context: Context, session: AlarmSession) {
        check(session.alarm.checkInMinutes > 0 && !session.followUp) { "Check-in is not enabled for this occurrence" }
        val waiting = session.copy(phase = "checkin", checkAt = System.currentTimeMillis() + session.alarm.checkInMinutes * 60_000L)
        AlarmSessions.save(context, waiting)
        restore(context, waiting)
        AlarmEvents.record(context, waiting, "checkin_scheduled")
        android.util.Log.i("WakeGuard", "Check-in armed for ${session.alarm.id} in ${session.alarm.checkInMinutes} minutes")
    }

    fun restore(context: Context, session: AlarmSession) {
        val now = System.currentTimeMillis()
        if (now > session.checkAt + GRACE_MS + AlarmDefaults.MAX_RINGING_MS) {
            AlarmEvents.record(context, session, "checkin_expired")
            AlarmSessions.save(context, session.copy(phase = "done"))
            cancel(context, session)
            return
        }
        val manager = context.getSystemService(AlarmManager::class.java)
        val show = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        // A one-minute response window must not compete with idle-alarm quotas.
        // Do not show an already-expired prompt which cannot be confirmed.
        if (now < session.checkAt + GRACE_MS) {
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(maxOf(now + 500L, session.checkAt), show), operation(context, session, "prompt"))
        } else {
            manager.cancel(operation(context, session, "prompt"))
        }
        manager.setAlarmClock(AlarmManager.AlarmClockInfo(maxOf(now + 1000L, session.checkAt + GRACE_MS), show), operation(context, session, "deadline"))
    }

    fun prompt(context: Context, session: AlarmSession) {
        if (!notificationsAvailable(context)) {
            AlarmEvents.record(context, session, "checkin_notification_blocked")
            android.util.Log.w("WakeGuard", "Check-in notification is blocked for ${session.alarm.id}; deadline remains armed")
            return
        }
        val remainingSeconds = ((session.checkAt + GRACE_MS - System.currentTimeMillis()) / 1000L).coerceIn(1L, 60L)
        val manager = context.getSystemService(NotificationManager::class.java)
        val sound = reminderSound(context)
        createChannel(context)
        manager.notify(session.alarm.notificationId xor 0x40000000,
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm).setContentTitle("Still up?")
                .setContentText("${session.alarm.label}: confirm within $remainingSeconds seconds. Otherwise one follow-up alarm will ring.")
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(false).setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setSound(sound).setVibrate(NOTIFICATION_VIBRATION).setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setContentIntent(operation(context, session, "confirm"))
                .addAction(0, "I'm up", operation(context, session, "confirm")).build())
        AlarmEvents.record(context, session, "checkin_prompted")
    }

    fun cancel(context: Context, session: AlarmSession) {
        val manager = context.getSystemService(AlarmManager::class.java)
        for (stage in listOf("prompt", "deadline")) manager.cancel(operation(context, session, stage))
        context.getSystemService(NotificationManager::class.java).cancel(session.alarm.notificationId xor 0x40000000)
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
                } else if (now < session.checkAt + StayAwake.GRACE_MS) {
                    runCatching { StayAwake.prompt(context, session) }.onFailure {
                        AlarmEvents.record(context, session, "checkin_notification_failed")
                        android.util.Log.e("WakeGuard", "Check-in prompt failed", it)
                    }
                }
            }
            "confirm" -> {
                if (now < session.checkAt || now > session.checkAt + StayAwake.GRACE_MS) return
                StayAwake.cancel(context, session)
                AlarmSessions.save(context, session.copy(phase = "done"))
                AlarmEvents.record(context, session, "confirmed", "checkin")
            }
            "deadline" -> {
                if (now < session.checkAt + StayAwake.GRACE_MS) {
                    StayAwake.restore(context, session)
                    return
                }
                StayAwake.cancel(context, session)
                if (now > session.checkAt + StayAwake.GRACE_MS + AlarmDefaults.MAX_RINGING_MS) {
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
