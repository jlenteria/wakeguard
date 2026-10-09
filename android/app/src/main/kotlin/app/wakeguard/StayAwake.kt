package app.wakeguard

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.provider.Settings
import androidx.core.app.NotificationCompat

/** Native check-ins: no Flutter isolate or long-running timer is required. */
object StayAwake {
    const val GRACE_MS = 60_000L
    // Channel sound is immutable; a new ID gives existing installs the audible default.
    private const val CHANNEL = "wakeguard.checkin.audible.v2"

    private fun operation(context: Context, session: AlarmSession, stage: String): PendingIntent =
        PendingIntent.getBroadcast(context, 0, Intent(context, CheckInReceiver::class.java).apply {
            data = android.net.Uri.parse("wakeguard://checkin/${session.token}/$stage")
            putExtra("id", session.alarm.id); putExtra(AlarmSessions.EXTRA_SESSION, session.token)
            putExtra("stage", stage)
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun schedule(context: Context, session: AlarmSession) {
        val waiting = session.copy(phase = "checkin", checkAt = System.currentTimeMillis() + session.alarm.checkInMinutes * 60_000L)
        AlarmSessions.save(context, waiting)
        restore(context, waiting)
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
        manager.setAlarmClock(AlarmManager.AlarmClockInfo(maxOf(now + 500L, session.checkAt), show), operation(context, session, "prompt"))
        manager.setAlarmClock(AlarmManager.AlarmClockInfo(maxOf(now + 1000L, session.checkAt + GRACE_MS), show), operation(context, session, "deadline"))
    }

    fun prompt(context: Context, session: AlarmSession) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val sound = Settings.System.DEFAULT_NOTIFICATION_URI
        val channel = NotificationChannel(CHANNEL, "Stay Awake check-ins", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "A short sound reminds you to confirm you are still awake."
            setSound(sound, AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build())
        }
        manager.createNotificationChannel(channel)
        manager.notify(session.alarm.notificationId xor 0x40000000,
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm).setContentTitle("Still up?")
                .setContentText("${session.alarm.label}: confirm within 1 minute. Otherwise one follow-up alarm will ring.")
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(false).setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setSound(sound).setOnlyAlertOnce(true)
                .setContentIntent(operation(context, session, "confirm"))
                .addAction(0, "I'm up", operation(context, session, "confirm")).build())
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
            "prompt" -> if (now >= session.checkAt) StayAwake.prompt(context, session)
            "confirm" -> {
                if (now < session.checkAt || now > session.checkAt + StayAwake.GRACE_MS) return
                StayAwake.cancel(context, session)
                AlarmSessions.save(context, session.copy(phase = "done"))
                AlarmEvents.record(context, session, "confirmed", "checkin")
            }
            "deadline" -> {
                if (now < session.checkAt + StayAwake.GRACE_MS) return
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
