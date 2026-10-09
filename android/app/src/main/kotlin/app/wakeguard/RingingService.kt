package app.wakeguard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat as MediaNotificationCompat

/**
 * Rings the alarm and walks the escalation ladder.
 *
 * Reliability properties this service is built around:
 *
 *  * `START_REDELIVER_INTENT` so the OS restarts it after a kill, resuming the
 *    ladder from [KEY_ELAPSED_MS] rather than starting over.
 *  * A partial wake lock and full-volume playback from the first instant: a
 *    ramp that starts quiet buys a sleeper 45 seconds they never wake up in.
 *  * Audio focus is explicitly requested, so another app holding music focus
 *    cannot duck the alarm to silence.
 *  * The sound is bundled, never the system ringtone: `RingtoneManager` can
 *    return null or a silent file, which produced a completely silent alarm.
 *  * The alarm stream starts at 50% and the user may turn it down, but not off:
 *    if it stays at 0 for 5 seconds it is raised to 20%. The user's pre-alarm
 *    level is written back when the service stops.
 */
class RingingService : Service() {

    companion object {
        private const val CHANNEL_ID = "wakeguard.ringing.v2"
        private const val NOTIFICATION_ID_BASE = 0x5700
        private const val KEY_ELAPSED_MS = "elapsedMs"
        private const val KEY_ALARM_ID = "alarmId"

        /** The user's alarm-stream level from before the ring, restored after. */
        private const val KEY_PRE_ALARM_VOLUME = "preAlarmVolume"
        private const val PREFS = "wakeguard.ringing"

        /**
         * Offsets mirror EscalationPolicy.standard. The ladder no longer ramps
         * volume: playback is at 100% from the first instant, and the steps
         * exist only to refresh the ringing notification. The tone itself
         * never changes.
         */
        private val STEPS = listOf(
            0L,
            45_000L,
            2 * 60_000L,
            5 * 60_000L,
            10 * 60_000L,
        )

        /** How often the volume guard checks for silence. */
        private const val VOLUME_GUARD_INTERVAL_MS = 1_000L

        /** Share of the alarm stream's maximum used at the start of a ring (50%). */
        private const val ALARM_VOLUME_FRACTION = 0.5f

        /** How long the alarm may stay at volume 0 before it is raised again. */
        private const val MUTE_GRACE_MS = 5_000L

        /** Level the alarm is raised to after being muted for [MUTE_GRACE_MS] (20%). */
        private const val MUTE_RECOVERY_FRACTION = 0.2f

        fun start(context: Context, alarm: StoredAlarm, elapsedMs: Long) {
            val intent = Intent(context, RingingService::class.java).apply {
                putExtra(KEY_ALARM_ID, alarm.id)
                putExtra(NativeAlarmScheduler.EXTRA_LABEL, alarm.label)
                putExtra(NativeAlarmScheduler.EXTRA_QR, alarm.qrValue)
                putExtra(NativeAlarmScheduler.EXTRA_STEPS, alarm.stepCount)
                putExtra(NativeAlarmScheduler.EXTRA_SOUND, alarm.soundPack)
                putExtra(NativeAlarmScheduler.EXTRA_ESCAPES, NativeAlarmScheduler.escapesExtra(alarm))
                putExtra(NativeAlarmScheduler.EXTRA_SNOOZE, alarm.snoozeMinutes)
                putExtra(AlarmSessions.EXTRA_SESSION, AlarmSessions.get(context, alarm.id)?.token)
                putExtra(KEY_ELAPSED_MS, elapsedMs)
            }
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context, id: String? = null, token: String? = null) {
            if (RingingState.activeAlarm != null &&
                (id != RingingState.activeAlarm?.id || token != RingingState.sessionId)) return
            context.stopService(Intent(context, RingingService::class.java))
            context.createDeviceProtectedStorageContext().getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putLong(KEY_ELAPSED_MS, 0L)
                .apply()
            RingingState.activeAlarm = null
            RingingState.notifyStopped()
            RingingState.sessionId = null
        }

        /**
         * Posts the ringing notification without starting the service.
         *
         * Used when Android refuses the foreground-service start (API 31+, or a
         * vendor task killer): the alternative is an alarm that makes no sound
         * and shows nothing at all, which is the exact failure this app exists
         * to prevent. The full-screen intent still gives the user a way into
         * the challenge.
         */
        fun postFallbackNotification(context: Context, alarm: StoredAlarm) {
            createChannel(context)
            runCatching {
                context.getSystemService(NotificationManager::class.java)
                    ?.notify(fallbackNotificationId(alarm.id), buildNotification(context, alarm))
            }
        }

        fun cancelFallbackNotification(context: Context, alarmId: String?) {
            runCatching {
                context.getSystemService(NotificationManager::class.java)
                    ?.cancel(fallbackNotificationId(alarmId))
            }
        }

        private fun fallbackNotificationId(id: String?): Int =
            StoredAlarm.notificationIdFor("fallback:$id")

        /** A minimal, non-sticky notification for a start that is giving up. */
        private fun stopNotification(context: Context): Notification =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm)
                .setContentTitle(context.getString(R.string.app_name))
                .setContentText(context.getString(R.string.alarm_dismissed))
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setTimeoutAfter(5_000L)
                .build()

        fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ringing alarms",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Active WakeGuard alarms"
                // All audio comes from the MediaPlayer on the alarm stream, which
                // is routed independently of the channel. Leaving the channel
                // silent avoids a doubled or mis-routed second copy of the sound.
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 300, 500)
                enableLights(true)
                setShowBadge(false)
                // No setBypassDnd: that needs ACCESS_NOTIFICATION_POLICY, which
                // the app deliberately does not hold. The audio is on
                // STREAM_ALARM, which Do Not Disturb does not silence in its
                // usual modes; only the notification visibility is affected.
            }
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }

        /** Notification id for a ring, stable across process restarts. */
        fun notificationId(id: String?): Int =
            StoredAlarm.notificationIdFor("ring:$id")

        fun buildNotification(context: Context, alarm: StoredAlarm): Notification {
            val fullScreen = PendingIntent.getActivity(
                context,
                alarm.notificationId,
                AlarmIntents.ringActivity(context, alarm),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm)
                .setContentTitle(alarm.label)
                .setContentText(context.getString(R.string.ringing_prompt))
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setOngoing(true)
                .setAutoCancel(false)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setTimeoutAfter(AlarmDefaults.MAX_RINGING_MS)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .apply {
                    // Snoozing is per-alarm; an alarm configured with no snooze
                    // offers no way to surrender it.
                    if (alarm.snoozeMinutes > 0) {
                        addAction(
                            0,
                            context.getString(R.string.action_snooze),
                            snoozeIntent(context, alarm),
                        )
                    }
                }
                .setStyle(MediaNotificationCompat.MediaStyle())
                .build()
        }

        /** Blocking buttons matter: the full-screen intent can be denied on Android 14+. */
        private fun snoozeIntent(context: Context, alarm: StoredAlarm): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                alarm.notificationId + 7,
                Intent(context, SnoozeReceiver::class.java).apply {
                    data = android.net.Uri.parse("wakeguard://snooze/${alarm.id}")
                    putExtra(KEY_ALARM_ID, alarm.id)
                    putExtra(AlarmSessions.EXTRA_SESSION, AlarmSessions.get(context, alarm.id)?.token)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
    }

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Separate from [handler] because `scheduleEscalation` clears that one on
     * every (re)start, which would silently kill the guard.
     */
    private val volumeHandler = Handler(Looper.getMainLooper())

    /** The pack currently loaded in [player], so a watchdog restart is a no-op. */
    private var playingPack: String? = null
    private var preparing = false

    /** When the alarm stream was first seen at 0, or 0 while it is audible. */
    private var silentSinceMs = 0L

    /**
     * Watches for silence while ringing. The user may lower the volume freely;
     * this only steps in if the alarm has been muted for [MUTE_GRACE_MS].
     */
    private val volumeGuard = object : Runnable {
        override fun run() {
            enforceAlarmVolume()
            volumeHandler.postDelayed(this, VOLUME_GUARD_INTERVAL_MS)
        }
    }

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var alarmId: String? = null
    private var sessionId: String? = null
    private var stepCount: Int = 2
    private var qrValue: String = ""
    private var label: String = "Wake up"
    private var soundPack: String = AlarmSounds.DEFAULT_PACK

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val incomingId = intent?.getStringExtra(KEY_ALARM_ID)
        val incomingToken = intent?.getStringExtra(AlarmSessions.EXTRA_SESSION)
        val session = incomingId?.let { AlarmSessions.get(this, it) }
        if (session == null || session.token != incomingToken || session.phase != "ringing") {
            val current = RingingState.activeAlarm
            startForeground(notificationId(current?.id ?: incomingId),
                if (current != null) buildNotification(this, current) else stopNotification(this))
            if (current == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        // Every path out of here must answer startForegroundService() within
        // five seconds. An unanswered start is a crash on Android 12+, and a
        // crashed alarm service is strictly worse than one that stops at once.
        if (intent == null || incomingId == null) {
            startForeground(notificationId(incomingId), stopNotification(this))
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val elapsed = session.elapsed(this)
        if (elapsed >= AlarmDefaults.MAX_RINGING_MS) {
            // Give up rather than ring forever; the UI records it as missed.
            startForeground(notificationId(incomingId), stopNotification(this))
            AlarmSessions.expire(this, session)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        alarmId = incomingId
        sessionId = incomingToken
        label = intent.getStringExtra(NativeAlarmScheduler.EXTRA_LABEL) ?: "Wake up"
        qrValue = intent.getStringExtra(NativeAlarmScheduler.EXTRA_QR) ?: ""
        stepCount = intent.getIntExtra(NativeAlarmScheduler.EXTRA_STEPS, 2)
        soundPack = intent.getStringExtra(NativeAlarmScheduler.EXTRA_SOUND)
            ?: AlarmSounds.DEFAULT_PACK

        val alarm = session.alarm
        RingingState.activeAlarm = alarm
        RingingState.sessionId = session.token

        // Must be within five seconds of startForegroundService.
        startForeground(notificationId(alarmId), buildNotification(this, alarm))
        // If a fallback notification was posted because this service could not
        // start earlier, it is redundant now.
        cancelFallbackNotification(this, alarmId)

        persistElapsed(elapsed)
        acquireWakeLock()
        requestAudioFocus()
        enforceAlarmVolume()
        volumeHandler.removeCallbacks(volumeGuard)
        volumeHandler.post(volumeGuard)
        startPlayback()
        scheduleEscalation(elapsed)

        return START_REDELIVER_INTENT
    }

    /**
     * Walks the ladder, refreshing the notification at each step. The sound does
     * not change: the chosen tone plays unchanged for the whole ring.
     */
    private fun scheduleEscalation(fromElapsed: Long) {
        handler.removeCallbacksAndMessages(null)
        for (offset in STEPS) {
            if (offset <= fromElapsed) continue
            val delay = offset - fromElapsed
            handler.postDelayed({
                persistElapsed(offset)
                updateNotification()
            }, delay)
        }
        // Hard stop.
        handler.postDelayed({
            val current = alarmId?.let { AlarmSessions.get(this, it) }
            if (current != null && current.token == sessionId) AlarmSessions.expire(this, current)
            stopSelf()
        }, AlarmDefaults.MAX_RINGING_MS - fromElapsed)
    }

    /**
     * Loops the alarm's chosen tone. Re-entering with the pack that is already
     * playing is a no-op, so watchdog restarts do not cut the audio.
     */
    private fun startPlayback() {
        if (playingPack == soundPack && player != null && (preparing || runCatching { player?.isPlaying == true }.getOrDefault(false))) return
        releasePlayer()
        playingPack = soundPack
        val resId = AlarmSounds.resourceFor(this, soundPack)
        val candidate = MediaPlayer()
        preparing = true
        player = runCatching {
            candidate.apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(
                    this@RingingService,
                    android.net.Uri.parse("android.resource://$packageName/$resId"),
                )
                isLooping = true
                setOnPreparedListener { ready ->
                    if (player !== ready) return@setOnPreparedListener
                    preparing = false
                    val live = alarmId?.let { AlarmSessions.get(this@RingingService, it) }
                    if (live?.token == sessionId && live?.phase == "ringing") {
                        ready.setVolume(1f, 1f)
                        ready.start()
                    } else releasePlayer()
                }
                setOnErrorListener { failed, what, extra ->
                    android.util.Log.e("WakeGuard", "Alarm playback error $what/$extra")
                    if (player === failed) { releasePlayer(); playingPack = null }
                    true
                }
                prepareAsync()
            }
        }.onFailure {
            // Never let audio setup take down the ringing notification; a
            // silent alarm with a visible prompt is still recoverable, whereas
            // a crashed service is not.
            android.util.Log.e("WakeGuard", "Alarm audio failed to start", it)
            runCatching { candidate.release() }
            preparing = false
            null
        }.getOrNull()
    }

    private fun requestAudioFocus(): Boolean {
        val audioManager = getSystemService(AudioManager::class.java)
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .build(),
            )
            .setWillPauseWhenDucked(false)
            .build()
        focusRequest = request
        return audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WakeGuard:Ringing")
            .apply { acquire(AlarmDefaults.MAX_RINGING_MS + 60_000L) }
    }

    private fun updateNotification() {
        val alarm = RingingState.activeAlarm ?: return
        runCatching {
            getSystemService(NotificationManager::class.java)
                .notify(notificationId(alarmId), buildNotification(this, alarm))
        }
    }

    private fun persistElapsed(elapsed: Long) {
        createDeviceProtectedStorageContext().getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putLong(KEY_ELAPSED_MS, elapsed)
            .apply()
    }

    private fun releasePlayer() {
        preparing = false
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
    }

    /**
     * Volume policy while ringing.
     *
     *  * At the start of a ring STREAM_ALARM is set to 50% of its maximum
     *    ([ALARM_VOLUME_FRACTION]).
     *  * After that the user is free to turn it up or down: a blaring alarm
     *    must be something they can tame.
     *  * The one thing that is not allowed is silence. If the stream stays at 0
     *    for [MUTE_GRACE_MS], it is raised to [MUTE_RECOVERY_FRACTION] of the
     *    maximum. Muting again starts a fresh grace period.
     *
     * The user's level from before the alarm is written to prefs the first
     * time (only ever once per ring: [START_REDELIVER_INTENT] would otherwise
     * re-capture the ring's own level as the "original" after a service kill)
     * and written back in [onDestroy].
     */
    private fun enforceAlarmVolume() {
        val audioManager = getSystemService(AudioManager::class.java) ?: return
        val prefs = createDeviceProtectedStorageContext().getSharedPreferences(PREFS, MODE_PRIVATE)
        val firstPin = !prefs.contains(KEY_PRE_ALARM_VOLUME)
        if (firstPin) {
            val original = runCatching {
                audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
            }.getOrDefault(-1)
            if (original >= 0) {
                prefs.edit().putInt(KEY_PRE_ALARM_VOLUME, original).apply()
                android.util.Log.i("WakeGuard", "Alarm stream at $original, setting ring level")
            }
        }
        val max = runCatching { audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM) }
            .getOrDefault(0)
        if (max <= 0) return
        val current = runCatching { audioManager.getStreamVolume(AudioManager.STREAM_ALARM) }
            .getOrDefault(max)

        if (firstPin) {
            silentSinceMs = 0L
            setAlarmVolume(audioManager, current, fraction = ALARM_VOLUME_FRACTION, max = max)
            return
        }

        if (current > 0) {
            // Audible, at whatever level the user chose. Leave it alone.
            silentSinceMs = 0L
            return
        }

        // Silent. Give the user a moment, then bring the alarm back.
        val now = android.os.SystemClock.elapsedRealtime()
        if (silentSinceMs == 0L) {
            silentSinceMs = now
            return
        }
        if (now - silentSinceMs >= MUTE_GRACE_MS) {
            silentSinceMs = 0L
            setAlarmVolume(audioManager, current, fraction = MUTE_RECOVERY_FRACTION, max = max)
        }
    }

    private fun setAlarmVolume(audioManager: AudioManager, current: Int, fraction: Float, max: Int) {
        val target = Math.round(max * fraction).coerceIn(1, max)
        if (current == target) return
        runCatching { audioManager.setStreamVolume(AudioManager.STREAM_ALARM, target, 0) }
            .onFailure {
                // Never silent: a failed set is the exact bug this exists for.
                android.util.Log.w("WakeGuard", "Could not set alarm volume $current -> $target", it)
            }
    }

    /** Returns the alarm stream to whatever the user had it at before ringing. */
    private fun restoreStreamVolume() {
        val prefs = createDeviceProtectedStorageContext().getSharedPreferences(PREFS, MODE_PRIVATE)
        val original = prefs.getInt(KEY_PRE_ALARM_VOLUME, -1)
        if (original >= 0) {
            runCatching {
                getSystemService(AudioManager::class.java)
                    ?.setStreamVolume(AudioManager.STREAM_ALARM, original, 0)
            }.onFailure {
                android.util.Log.w("WakeGuard", "Could not restore alarm volume to $original", it)
            }
        }
        prefs.edit().remove(KEY_PRE_ALARM_VOLUME).apply()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        volumeHandler.removeCallbacks(volumeGuard)
        restoreStreamVolume()
        releasePlayer()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        focusRequest?.let {
            runCatching { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.cancel(notificationId(alarmId))
        if (RingingState.sessionId == sessionId) {
            RingingState.activeAlarm = null
            RingingState.notifyStopped()
            RingingState.sessionId = null
        }
        super.onDestroy()
    }
}

/** Process-local handle to the alarm currently ringing. */
object RingingState {
    @Volatile var sessionId: String? = null
    @Volatile
    var activeAlarm: StoredAlarm? = null

    /**
     * Set by [AlarmRingActivity] so a snooze arriving from the notification can
     * close the challenge screen. Both run in the same process, and a listener
     * is deliberately used instead of a broadcast because the activity must
     * close even when the process is one the platform will not let broadcast
     * to.
     */
    @Volatile
    var onStopped: (() -> Unit)? = null

    fun notifyStopped() {
        runCatching { onStopped?.invoke() }
    }
}
