package com.bling.wakeguard

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

/**
 * Rings the alarm and walks the escalation ladder. START_REDELIVER_INTENT resumes after a kill;
 * playback is full-volume with audio focus on a bundled tone, and muting is undone after 5 s.
 */
class RingingService : Service() {

    companion object {
        // Sound/vibration settings are immutable after a channel is created.
        private const val CHANNEL_ID = "wakeguard.ringing.silent.v4"

        /**
         * A separate channel that DOES carry the alarm sound, used only when the foreground service
         * start is rejected (Android 12/14 ForegroundServiceStartNotAllowedException): the silent
         * ringing channel cannot be given a sound later, so the audible fallback gets its own.
         */
        private const val AUDIBLE_CHANNEL_ID = "wakeguard.ringing.audible.v1"
        private val NOTIFICATION_VIBRATION = longArrayOf(0, 500, 300, 500)
        private const val KEY_ALARM_ID = "alarmId"

        /** The user's alarm-stream level from before the ring, restored after. */
        private const val KEY_PRE_ALARM_VOLUME = "preAlarmVolume"
        internal const val PREFS = "wakeguard.ringing"

        /**
         * Mirrors EscalationPolicy.standard; steps only refresh the notification, the tone never
         * changes, and playback is at 100% from the first instant.
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
        private const val PREPARE_TIMEOUT_MS = 5_000L
        private val PLAYBACK_RETRY_DELAYS_MS = longArrayOf(1_000L, 2_000L, 4_000L)

        /**
         * Starts the ring. Elapsed time is never carried in the intent: the persisted session is the
         * only authority, so a redelivered or replayed intent cannot restart an old occurrence.
         */
        fun start(context: Context, alarm: StoredAlarm) {
            val intent = Intent(context, RingingService::class.java).apply {
                putExtra(KEY_ALARM_ID, alarm.id)
                putExtra(NativeAlarmScheduler.EXTRA_LABEL, alarm.label)
                putExtra(NativeAlarmScheduler.EXTRA_QR, alarm.qrValue)
                putExtra(NativeAlarmScheduler.EXTRA_STEPS, alarm.stepCount)
                putExtra(NativeAlarmScheduler.EXTRA_SOUND, alarm.soundPack)
                putExtra(NativeAlarmScheduler.EXTRA_ESCAPES, NativeAlarmScheduler.escapesExtra(alarm))
                putExtra(NativeAlarmScheduler.EXTRA_SNOOZE, alarm.snoozeMinutes)
                putExtra(AlarmSessions.EXTRA_SESSION, AlarmSessions.get(context, alarm.id)?.token)
            }
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context, id: String? = null, token: String? = null) {
            if (RingingState.activeAlarm != null &&
                (id != RingingState.activeAlarm?.id || token != RingingState.sessionId)) return
            context.stopService(Intent(context, RingingService::class.java))
            // The audible path lives in the process, not the service, so it must be told to stop here.
            AudibleFallback.stop(context, id)
            RingingState.activeAlarm = null
            RingingState.notifyStopped()
            RingingState.sessionId = null
        }

        /**
         * Posts the notification without starting the service, for when Android refuses the foreground
         * start (Android 12/14 ForegroundServiceStartNotAllowedException, or a start from a context
         * that may not launch one). Sound is the whole point of an alarm, so this is never merely a
         * notification: the channel carries the alarm tone and the process also loops the tone itself
         * through [AudibleFallback]. The escalation rungs armed before the attempt retry the real
         * service later, and the full-screen intent still opens the challenge.
         */
        fun postFallbackNotification(context: Context, alarm: StoredAlarm) {
            createChannel(context)
            AudibleFallback.start(context, alarm)
            runCatching {
                context.getSystemService(NotificationManager::class.java)
                    ?.notify(fallbackNotificationId(alarm.id), buildFallbackNotification(context, alarm))
            }.onFailure { android.util.Log.e("WakeGuard", "Fallback alarm notification could not be posted", it) }
        }

        /** The challenge screen, so a refused foreground start still lets the user stop the alarm. */
        private fun fullScreenIntent(context: Context, alarm: StoredAlarm): PendingIntent =
            PendingIntent.getActivity(
                context,
                alarm.notificationId,
                AlarmIntents.ringActivity(context, alarm),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** Notification shown when the ring itself is degraded: same challenge, audible channel. */
        private fun buildFallbackNotification(context: Context, alarm: StoredAlarm): Notification {
            val prompt = if (alarm.snoozeMinutes > 0)
                context.getString(R.string.ringing_prompt_with_snooze, alarm.snoozeMinutes)
                else context.getString(R.string.ringing_prompt)
            val fullScreen = fullScreenIntent(context, alarm)
            return NotificationCompat.Builder(context, AUDIBLE_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm)
                .setContentTitle(alarm.label)
                .setContentText(prompt)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVibrate(NOTIFICATION_VIBRATION)
                .setOngoing(true)
                .setAutoCancel(false)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .setStyle(NotificationCompat.BigTextStyle().bigText(prompt))
                .build()
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
                .setSound(null)
                .setVibrate(NOTIFICATION_VIBRATION)
                .setOnlyAlertOnce(true)
                .setAutoCancel(true)
                .build()

        fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ringing alarms",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Active WakeGuard alarms"
                // Only Stay Awake notifications play a chime. Ringing audio is
                // handled separately by MediaPlayer using the selected alarm tone.
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                vibrationPattern = NOTIFICATION_VIBRATION
                enableLights(true)
                setShowBadge(false)
                // DND behavior remains controlled by the user's alarm policy.
            }
            manager.createNotificationChannel(channel)
            // Channels cannot gain sound after creation, so the degraded path needs its own.
            val audible = NotificationChannel(
                AUDIBLE_CHANNEL_ID,
                "Ringing alarms (fallback)",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alarms shown when the ringing service could not start"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                vibrationPattern = NOTIFICATION_VIBRATION
                setShowBadge(false)
                setSound(audibleToneUri(context), AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
            }
            manager.createNotificationChannel(audible)
        }

        /**
         * The bundled tone as a raw resource URI. A notification is played by the system process,
         * which cannot read this app's private files, so a custom upload is not used here: an
         * approximate bundled tone still wakes the user, silence would not.
         */
        private fun audibleToneUri(context: Context): android.net.Uri =
            android.net.Uri.parse(
                "android.resource://${context.packageName}/${AlarmSounds.resourceFor(context, null)}")

        /** Notification id for a ring, stable across process restarts. */
        fun notificationId(id: String?): Int =
            StoredAlarm.notificationIdFor("ring:$id")

        internal fun prefsFor(context: Context) =
            context.createDeviceProtectedStorageContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /**
         * Captures the user's alarm-stream level once per ring and returns true when this call did it
         * (i.e. the ring is starting fresh). Device-protected storage, because a ring can outlive the
         * unlock state, and direct-boot storage is the only kind readable before the first unlock.
         */
        internal fun capturePreVolume(context: Context, audioManager: AudioManager): Boolean {
            val prefs = prefsFor(context)
            if (prefs.contains(KEY_PRE_ALARM_VOLUME)) return false
            val original = runCatching { audioManager.getStreamVolume(AudioManager.STREAM_ALARM) }.getOrDefault(-1)
            if (original < 0) return false
            prefs.edit().putInt(KEY_PRE_ALARM_VOLUME, original).commit()
            android.util.Log.i("WakeGuard", "Alarm stream at $original, setting ring level")
            return true
        }

        /** Raises the alarm stream to [fraction] of its maximum; never leaves it at zero. */
        internal fun raiseAlarmVolume(context: Context, audioManager: AudioManager, fraction: Float) {
            val max = runCatching { audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM) }.getOrDefault(0)
            if (max <= 0) return
            val target = Math.round(max * fraction).coerceIn(1, max)
            val current = runCatching { audioManager.getStreamVolume(AudioManager.STREAM_ALARM) }.getOrDefault(target)
            if (current == target) return
            runCatching { audioManager.setStreamVolume(AudioManager.STREAM_ALARM, target, 0) }
                .onFailure {
                    // Never silent: a failed set is the exact bug this exists for.
                    android.util.Log.w("WakeGuard", "Could not set alarm volume $current -> $target", it)
                }
        }

        /** Returns the alarm stream to whatever the user had it at before ringing. */
        internal fun restoreStreamVolume(context: Context) {
            val prefs = prefsFor(context)
            val original = prefs.getInt(KEY_PRE_ALARM_VOLUME, -1)
            if (original >= 0) {
                runCatching {
                    context.getSystemService(AudioManager::class.java)
                        ?.setStreamVolume(AudioManager.STREAM_ALARM, original, 0)
                }.onFailure {
                    android.util.Log.w("WakeGuard", "Could not restore alarm volume to $original", it)
                }
            }
            prefs.edit().remove(KEY_PRE_ALARM_VOLUME).apply()
        }

        /**
         * MIUI/OEM killers can end a ring mid-flight without [onDestroy] ever running, leaving the
         * alarm stream pinned at the ring level and [KEY_PRE_ALARM_VOLUME] behind. The next ring would
         * then see the key, skip its own pin, and wake the user at the lowered level. Restores it.
         * Skipped while a ring is live in this process, since the key belongs to it.
         */
        fun healStaleVolume(context: Context) {
            if (RingingState.activeAlarm != null) return
            val prefs = prefsFor(context)
            val original = prefs.getInt(KEY_PRE_ALARM_VOLUME, -1)
            if (original < 0) return
            android.util.Log.w("WakeGuard", "Healing alarm volume left pinned by a killed ring: $original")
            runCatching {
                context.getSystemService(AudioManager::class.java)
                    ?.setStreamVolume(AudioManager.STREAM_ALARM, original, 0)
            }.onFailure { android.util.Log.w("WakeGuard", "Could not heal alarm volume", it) }
            prefs.edit().remove(KEY_PRE_ALARM_VOLUME).apply()
        }

        /**
         * Calls [Service.startForeground], which on Android 12/14 throws
         * [android.app.ForegroundServiceStartNotAllowedException] when the start is not permitted.
         * Letting that escape kills the ring, so it is caught here and the caller degrades audibly.
         */
        private fun startForegroundSafe(service: Service, id: Int, notification: Notification): Boolean =
            try {
                service.startForeground(id, notification)
                true
            } catch (rejected: Exception) {
                android.util.Log.e("WakeGuard", "Foreground service start refused", rejected)
                false
            }

        fun buildNotification(context: Context, alarm: StoredAlarm): Notification {
            val prompt = if (alarm.snoozeMinutes > 0)
                context.getString(R.string.ringing_prompt_with_snooze, alarm.snoozeMinutes)
                else context.getString(R.string.ringing_prompt)
            val fullScreen = fullScreenIntent(context, alarm)
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_wakeguard_alarm)
                .setContentTitle(alarm.label)
                .setContentText(prompt)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setSound(null)
                .setVibrate(NOTIFICATION_VIBRATION)
                // Recovery refreshes should not repeat vibration over the looping tone.
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setAutoCancel(false)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                // No setTimeoutAfter: this notification is the foreground service's only proof of
                // life, and hiding it while the service still runs both breaks the contract and
                // leaves the user with an un-dismissable invisible ring. The hard stop comes from the
                // MAX_RINGING_MS rung, which always ends the service.
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .apply {
                    // Snooze is per-alarm; no snooze configured means no way to surrender it.
                    if (alarm.snoozeMinutes > 0) {
                        addAction(
                            android.R.drawable.ic_lock_idle_alarm,
                            context.getString(R.string.snooze_for_minutes, alarm.snoozeMinutes),
                            snoozeIntent(context, alarm),
                        )
                    }
                }
                // Standard actions show a labeled Snooze button when expanded;
                // MediaStyle renders compact actions as icons without the label.
                .setStyle(NotificationCompat.BigTextStyle().bigText(prompt))
                .build()
        }

        /** Blocking buttons matter: the full-screen intent can be denied on Android 14+. */
        private fun snoozeIntent(context: Context, alarm: StoredAlarm): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                alarm.notificationId + 7,
                AlarmSnooze.actionIntent(context, alarm.id, AlarmSessions.get(context, alarm.id)?.token),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
    }

    private val handler = Handler(Looper.getMainLooper())

    /** Separate from [handler]: scheduleEscalation clears that one on every (re)start. */
    private val volumeHandler = Handler(Looper.getMainLooper())

    /** The pack currently loaded in [player], so a watchdog restart is a no-op. */
    private var playingPack: String? = null
    private var preparing = false
    // Kept separate: escalation refreshes must not cancel playback recovery.
    private val playbackHandler = Handler(Looper.getMainLooper())
    private var playbackRetries = 0
    private var playbackRetryPending = false
    private var destroyed = false

    /** When the alarm stream was first seen at 0, or 0 while it is audible. */
    private var silentSinceMs = 0L

    /** Watches for silence; the user may lower volume freely, but not mute it for [MUTE_GRACE_MS]. */
    private val volumeGuard = object : Runnable {
        override fun run() {
            enforceAlarmVolume(raise = false)
            volumeHandler.postDelayed(this, VOLUME_GUARD_INTERVAL_MS)
        }
    }

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null

    /** Whether [focusListener]'s request is currently held, so it is only ever abandoned once. */
    private var focusHeld = false

    /**
     * Attached to both the legacy and the modern focus request. An alarm must keep ringing: losing
     * focus (a call, another app ducking) is answered by re-claiming it and restarting the tone, never
     * by stopping. Without a listener the request was granted and then silently dropped.
     */
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_GAIN) return@OnAudioFocusChangeListener
        android.util.Log.w("WakeGuard", "Audio focus changed during a ring: $change")
        playbackHandler.post {
            if (!canPlay()) return@post
            requestAudioFocus()
            enforceAlarmVolume(raise = true)
            startPlayback()
        }
    }
    private var alarmId: String? = null
    private var sessionId: String? = null
    private var stepCount: Int = 2
    private var qrValue: String = ""
    private var label: String = "Wake up"
    private var soundPack: String = AlarmSounds.DEFAULT_PACK

    /** Whether this alarm vibrates while it rings, read from the session's stored record. */
    private var vibrateEnabled = true
    private var vibrator: android.os.Vibrator? = null

    /** The alarm's uploaded tone, and whether it already failed this ring (then the bundled pack plays). */
    private var customSoundId: String = ""
    private var customFailed = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val incomingId = intent?.getStringExtra(KEY_ALARM_ID)
        val incomingToken = intent?.getStringExtra(AlarmSessions.EXTRA_SESSION)
        // A ring started in a fresh process after an OEM kill must undo that kill's pinned volume
        // before pinning its own, or the alarm would wake the user at the leftover level.
        healStaleVolume(this)
        val session = incomingId?.let { AlarmSessions.get(this, it) }
        if (session == null || session.token != incomingToken || session.phase != "ringing") {
            // Nothing to ring. The notification only satisfies the foreground contract for this start;
            // a live service instance must always stop, or its stale notification outlives the alarm.
            val current = RingingState.activeAlarm
            beginForeground(notificationId(current?.id ?: incomingId),
                if (current != null) buildNotification(this, current) else stopNotification(this))
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val elapsed = session.elapsed(this)
        if (elapsed >= AlarmDefaults.MAX_RINGING_MS) {
            // Give up rather than ring forever; the UI records it as missed.
            beginForeground(notificationId(incomingId), stopNotification(this))
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
        customSoundId = alarm.customSound
        vibrateEnabled = alarm.vibrate
        val newSession = RingingState.sessionId != session.token
        if (newSession) {
            playbackHandler.removeCallbacksAndMessages(null)
            playbackRetryPending = false
            playbackRetries = 0
            customFailed = false
            playingPack = null
            releasePlayer()
        }
        RingingState.activeAlarm = alarm
        RingingState.sessionId = session.token

        // Must be within five seconds of startForegroundService; a crash here would be worse than a
        // refused start, which is caught and degrades to an audible notification + direct playback.
        if (!beginForeground(notificationId(alarmId), buildNotification(this, alarm))) {
            postFallbackNotification(this, alarm)
            AlarmChallengeLauncher.openIfVisible(this, session)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // If a fallback notification and its direct playback were posted earlier, they are redundant.
        cancelFallbackNotification(this, alarmId)
        AudibleFallback.stop(this, alarmId)

        acquireWakeLock()
        if (!requestAudioFocus()) {
            // Refused focus must not mute the alarm: the alarm stream plays regardless of focus on
            // most devices, and the guard below re-claims it shortly anyway.
            android.util.Log.w("WakeGuard", "Audio focus not granted for $alarmId; ringing on the alarm stream anyway")
            playbackHandler.postDelayed({ if (canPlay()) { requestAudioFocus(); startPlayback() } }, 1_000L)
        }
        enforceAlarmVolume(raise = true)
        volumeHandler.removeCallbacks(volumeGuard)
        volumeHandler.post(volumeGuard)
        startPlayback()
        startVibration()
        scheduleEscalation(elapsed)
        if (newSession) AlarmChallengeLauncher.openIfVisible(this, session)

        return START_REDELIVER_INTENT
    }

    /**
     * Walks the ladder, refreshing the notification; the chosen tone never changes.
     */
    private fun scheduleEscalation(fromElapsed: Long) {
        handler.removeCallbacksAndMessages(null)
        for (offset in STEPS) {
            if (offset <= fromElapsed) continue
            val delay = offset - fromElapsed
            handler.postDelayed({
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
     * Loops the chosen tone; re-entering with the pack already playing is a no-op.
     */
    private fun startPlayback() {
        if (!canPlay() || playbackRetryPending) return
        // The uploaded file wins while it exists and has not failed this ring.
        val custom = if (customFailed) null else CustomSounds.fileFor(this, customSoundId)
        val playbackKey = custom?.let { "custom:${it.name}" } ?: soundPack
        if (playingPack == playbackKey && player != null && (preparing || runCatching { player?.isPlaying == true }.getOrDefault(false))) return
        releasePlayer()
        playingPack = playbackKey
        runCatching {
            val candidate = MediaPlayer()
            player = candidate
            preparing = true
            candidate.apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                if (custom != null) {
                    setDataSource(custom.absolutePath)
                } else {
                    val resId = AlarmSounds.resourceFor(this@RingingService, soundPack)
                    setDataSource(
                        this@RingingService,
                        android.net.Uri.parse("android.resource://$packageName/$resId"),
                    )
                }
                isLooping = true
                setOnPreparedListener { ready ->
                    if (player !== ready) return@setOnPreparedListener
                    playbackHandler.removeCallbacksAndMessages(null)
                    preparing = false
                    if (canPlay()) {
                        runCatching {
                            ready.setVolume(1f, 1f)
                            ready.start()
                        }.onFailure { playbackFailed(it) }
                    } else releasePlayer()
                }
                setOnErrorListener { failed, what, extra ->
                    android.util.Log.e("WakeGuard", "Alarm playback error $what/$extra")
                    if (player === failed) playbackFailed()
                    true
                }
                prepareAsync()
            }
            playbackHandler.postDelayed({
                if (player === candidate && preparing) {
                    playbackFailed(IllegalStateException("Alarm audio preparation timed out"))
                }
            }, PREPARE_TIMEOUT_MS)
        }.onFailure {
            playbackFailed(it)
        }
    }

    /**
     * Vibrates in a repeating pulse while the alarm rings, so a phone face-down or in a pocket still
     * wakes the sleeper even if the tone is hard to hear. Honors the per-alarm [vibrateEnabled] flag.
     */
    private fun startVibration() {
        if (!vibrateEnabled) return
        val manager = getSystemService(android.os.Vibrator::class.java) ?: return
        vibrator = manager
        val pattern = longArrayOf(0, 500, 300, 500)
        runCatching {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                manager.vibrate(
                    android.os.VibrationEffect.createWaveform(pattern, 0),
                )
            } else {
                @Suppress("DEPRECATION")
                manager.vibrate(pattern, 0)
            }
        }.onFailure {
            android.util.Log.w("WakeGuard", "Could not start alarm vibration", it)
        }
    }

    private fun stopVibration() {
        runCatching { vibrator?.cancel() }
        vibrator = null
    }

    private fun canPlay(): Boolean {
        if (destroyed) return false
        val live = alarmId?.let { AlarmSessions.get(this, it) } ?: return false
        return live.token == sessionId && live.phase == "ringing" &&
            live.elapsed(this) < AlarmDefaults.MAX_RINGING_MS
    }

    private fun playbackFailed(error: Throwable? = null) {
        val usingCustom = !customFailed && CustomSounds.fileFor(this, customSoundId) != null
        android.util.Log.e("WakeGuard", "Alarm audio failed; attempting bounded recovery", error)
        playbackHandler.removeCallbacksAndMessages(null)
        releasePlayer()
        playingPack = null
        playbackRetryPending = false
        if (usingCustom) {
            // A bad upload must never mean a silent alarm: switch to the bundled tone right away.
            customFailed = true
            android.util.Log.w("WakeGuard", "Custom alarm sound failed; using the bundled tone")
            startPlayback()
            return
        }
        if (!canPlay() || playbackRetries >= PLAYBACK_RETRY_DELAYS_MS.size) return
        val delay = PLAYBACK_RETRY_DELAYS_MS[playbackRetries++]
        playbackRetryPending = true
        val expectedToken = sessionId
        playbackHandler.postDelayed({
            playbackRetryPending = false
            if (sessionId == expectedToken && canPlay()) startPlayback()
        }, delay)
    }

    private fun requestAudioFocus(): Boolean {
        val audioManager = getSystemService(AudioManager::class.java) ?: return false
        val granted = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusListener,
                AudioManager.STREAM_ALARM, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        focusHeld = granted
        return granted
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

    /** Never throws: a refused foreground start degrades the ring instead of crashing it. */
    private fun beginForeground(id: Int, notification: Notification): Boolean =
        startForegroundSafe(this, id, notification)

    private fun releasePlayer() {
        preparing = false
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
    }

    /**
     * Volume policy: every ring start raises the alarm stream to [ALARM_VOLUME_FRACTION] (a watchdog
     * restart must not inherit a level some earlier OEM kill left behind), the user may turn it down
     * but not mute it — silence for [MUTE_GRACE_MS] raises it to [MUTE_RECOVERY_FRACTION]. The
     * pre-alarm level is captured on the first pin and restored in [onDestroy].
     */
    private fun enforceAlarmVolume(raise: Boolean) {
        val audioManager = getSystemService(AudioManager::class.java) ?: return
        val firstPin = capturePreVolume(this, audioManager)
        val max = runCatching { audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM) }
            .getOrDefault(0)
        if (max <= 0) return
        val current = runCatching { audioManager.getStreamVolume(AudioManager.STREAM_ALARM) }
            .getOrDefault(max)

        if (firstPin || raise) {
            silentSinceMs = 0L
            raiseAlarmVolume(this, audioManager, ALARM_VOLUME_FRACTION)
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
            raiseAlarmVolume(this, audioManager, MUTE_RECOVERY_FRACTION)
        }
    }

    /**
     * Focus and volume belong to the audible fallback while it rings: this service was refused
     * foreground status, so releasing the pin here would mute the very alarm it replaced.
     */
    private fun fallbackOwnsRing(): Boolean = AudibleFallback.isRingingFor(alarmId)

    override fun onDestroy() {
        destroyed = true
        playbackHandler.removeCallbacksAndMessages(null)
        playbackRetryPending = false
        handler.removeCallbacksAndMessages(null)
        volumeHandler.removeCallbacks(volumeGuard)
        val handOff = fallbackOwnsRing()
        if (!handOff) {
            restoreStreamVolume(this)
            stopVibration()
            if (focusHeld) abandonAudioFocus()
        }
        releasePlayer()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        val manager = getSystemService(NotificationManager::class.java)
        manager.cancel(notificationId(alarmId))
        // While the audible fallback owns the ring the alarm really is still ringing, so the
        // process-local handle stays set: dismissal and the challenge screen rely on it matching.
        if (!handOff && RingingState.sessionId == sessionId) {
            RingingState.activeAlarm = null
            RingingState.notifyStopped()
            RingingState.sessionId = null
        }
        super.onDestroy()
    }

    private fun abandonAudioFocus() {
        val audioManager = getSystemService(AudioManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let {
                runCatching { audioManager.abandonAudioFocusRequest(it) }
                    .onFailure { android.util.Log.w("WakeGuard", "Could not abandon audio focus", it) }
            }
        } else {
            @Suppress("DEPRECATION")
            runCatching { audioManager.abandonAudioFocus(focusListener) }
                .onFailure { android.util.Log.w("WakeGuard", "Could not abandon audio focus", it) }
        }
        focusRequest = null
        focusHeld = false
    }
}

/**
 * Rings an alarm when Android refuses the foreground service, using whatever the process is still
 * allowed to do: loop the tone on the alarm stream, vibrate, and pin the volume. It is a degradation,
 * not a substitute — the notification posted alongside it carries the same sound and the full-screen
 * challenge, and the watchdog rungs keep trying to start the real service.
 */
object AudibleFallback {
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var vibrator: android.os.Vibrator? = null

    /** The alarm this fallback is ringing for, or null when it is quiet. */
    @Volatile private var ownerId: String? = null

    /** Notification posted alongside the ring, cancelled again on [stop] with the same id. */
    private var fallbackNotificationId = 0

    fun isRingingFor(id: String?): Boolean = id != null && ownerId == id && player != null

    fun start(context: Context, alarm: StoredAlarm) {
        val app = context.applicationContext
        if (ownerId == alarm.id && player != null) return
        stop(app, null)
        ownerId = alarm.id
        fallbackNotificationId = StoredAlarm.notificationIdFor("fallback:${alarm.id}")
        val audioManager = app.getSystemService(AudioManager::class.java)
        if (audioManager != null) {
            RingingService.capturePreVolume(app, audioManager)
            RingingService.raiseAlarmVolume(app, audioManager, 0.5f)
        }
        runCatching {
            val candidate = MediaPlayer()
            player = candidate
            candidate.apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                val file = CustomSounds.fileFor(app, alarm.customSound)
                if (file != null) setDataSource(file.absolutePath)
                else setDataSource(app, android.net.Uri.parse(
                    "android.resource://${app.packageName}/${AlarmSounds.resourceFor(app, alarm.soundPack)}"))
                isLooping = true
                setVolume(1f, 1f)
                setOnErrorListener { _, _, _ -> true }
                prepareAsync()
                setOnPreparedListener { ready -> if (player === ready) runCatching { ready.start() }
                    .onFailure { android.util.Log.e("WakeGuard", "Fallback alarm could not start", it) } }
            }
        }.onFailure {
            android.util.Log.e("WakeGuard", "Fallback alarm playback could not be created", it)
        }
        if (alarm.vibrate) {
            runCatching {
                val manager = app.getSystemService(android.os.Vibrator::class.java)
                vibrator = manager
                val pattern = longArrayOf(0, 500, 300, 500)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    manager?.vibrate(android.os.VibrationEffect.createWaveform(pattern, 0))
                else @Suppress("DEPRECATION") manager?.vibrate(pattern, 0)
            }.onFailure { android.util.Log.w("WakeGuard", "Fallback alarm vibration failed", it) }
        }
        // Bounded like a real ring, so a degraded alarm still ends by itself.
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ stop(app, alarm.id) }, AlarmDefaults.MAX_RINGING_MS)
    }

    /** Stops the fallback; [id] limits it to the alarm it owns so a later ring is never cut short. */
    fun stop(context: Context, id: String?) {
        if (id != null && ownerId != null && ownerId != id) return
        val app = context.applicationContext
        ownerId = null
        handler.removeCallbacksAndMessages(null)
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
        runCatching { vibrator?.cancel() }
        vibrator = null
        RingingService.restoreStreamVolume(app)
        if (fallbackNotificationId != 0) runCatching {
            app.getSystemService(NotificationManager::class.java)?.cancel(fallbackNotificationId)
        }
    }
}

/** Process-local handle to the alarm currently ringing. */
object RingingState {
    @Volatile var sessionId: String? = null
    @Volatile
    var activeAlarm: StoredAlarm? = null

    /**
     * Set by [AlarmRingActivity] so a notification snooze can close the challenge screen. A
     * listener rather than a broadcast, since the process may reject broadcasts.
     */
    @Volatile
    var onStopped: (() -> Unit)? = null

    fun notifyStopped() {
        runCatching { onStopped?.invoke() }
    }
}
