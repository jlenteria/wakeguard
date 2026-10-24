package com.bling.wakeguard

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val readQueue = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var channelAlive = true

    /** The in-flight "pickCustomSound" call, answered from [onActivityResult]. */
    private var pendingSoundPick: MethodChannel.Result? = null

    private companion object {
        const val CHANNEL = "com.bling.wakeguard/alarm"
        const val REQUEST_PICK_SOUND = 4322

        /** Re-arming is once per process: later activities in the same process find it already done. */
        @Volatile var rearmed = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Queue the repair before Flutter starts so the first "alarms" read already sees it.
        rearmLostAlarms()
        super.onCreate(savedInstanceState)
    }

    /**
     * AlarmManager forgets a package's alarms when the OS or an OEM task cleaner force-stops it, and
     * only boot/package-replace broadcasts re-arm them. Without this, an alarm lost that way keeps a
     * past trigger ("rings now") and never fires again until the phone reboots.
     */
    private fun rearmLostAlarms() {
        if (rearmed) return
        rearmed = true
        val app = applicationContext
        runCatching {
            readQueue.execute {
                runCatching { NativeAlarmScheduler.rescheduleAll(app) }
                    .onFailure { android.util.Log.e("WakeGuard", "Could not re-arm alarms at startup", it) }
            }
        }.onFailure { rearmed = false }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RingingService.createChannel(this)
        StayAwake.createChannel(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "pickCustomSound") {
                    pickCustomSound(result)
                    return@setMethodCallHandler
                }
                // Preferences and system-service reads must not block Flutter's
                // platform thread during startup or a sheet transition.
                if (call.method in setOf("alarms", "health", "history", "capabilities", "objectTargetVerified", "pendingCheckIns", "listSystemSounds", "importSystemSound")) {
                    runCatching { readQueue.execute {
                        val outcome = runCatching { handle(call) }
                        mainHandler.post {
                            if (!channelAlive) return@post
                            outcome.onSuccess { result.success(it) }
                                .onFailure { result.error("NATIVE_ERROR", it.message, null) }
                        }
                    } }.onFailure { result.error("NATIVE_ERROR", "Alarm activity is closing. Retry.", null) }
                } else {
                    // Permission dialogs, navigation and playback stay on the UI thread.
                    runCatching { handle(call) }
                        .onSuccess { result.success(it) }
                        .onFailure { result.error("NATIVE_ERROR", it.message, null) }
                }
            }
    }

    /**
     * Uses the system document picker, so no storage permission is needed. The chosen file is copied
     * into private storage and validated off the UI thread; null means the user cancelled.
     */
    private fun pickCustomSound(result: MethodChannel.Result) {
        if (pendingSoundPick != null) {
            result.error("BUSY", "A sound is already being chosen.", null)
            return
        }
        val intent = android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(android.content.Intent.CATEGORY_OPENABLE)
            type = "audio/*"
        }
        pendingSoundPick = result
        runCatching {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_PICK_SOUND)
        }.onFailure {
            pendingSoundPick = null
            result.error("CUSTOM_SOUND", "No file picker is available on this device.", null)
        }
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_SOUND) return
        val result = pendingSoundPick ?: return
        pendingSoundPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        val app = applicationContext
        runCatching {
            readQueue.execute {
                val outcome = runCatching { CustomSounds.import(app, uri) }
                mainHandler.post {
                    if (!channelAlive) return@post
                    outcome.onSuccess { result.success(mapOf("id" to it.id, "name" to it.name)) }
                        .onFailure { result.error("CUSTOM_SOUND", it.message ?: "Could not use that file.", null) }
                }
            }
        }.onFailure { result.error("NATIVE_ERROR", "Alarm activity is closing. Retry.", null) }
    }

    /** Off the UI thread; recent picks are spared, so an open editor never loses its file. */
    private fun sweepCustomSounds() {
        val app = applicationContext
        runCatching { readQueue.execute { CustomSounds.sweep(app) } }
    }

    override fun onResume() {
        super.onResume()
        AlarmChallengeLauncher.onResumed(this)
    }

    override fun onPause() {
        AlarmChallengeLauncher.onPaused(this)
        super.onPause()
    }

    override fun onDestroy() {
        channelAlive = false
        mainHandler.removeCallbacksAndMessages(null)
        readQueue.shutdown()
        super.onDestroy()
    }

    private fun handle(call: MethodCall): Any? = when (call.method) {
        "capabilities" -> HealthChecker.capabilities(this)

        "health" -> HealthChecker.check(this)

        "schedule" -> {
            check(call.argument<Int>("contractVersion") == 2) { "Update the app: incompatible alarm contract" }
            val alarm = StoredAlarm(
                id = call.argument<String>("id")
                    ?: throw IllegalArgumentException("id is required"),
                hour = (call.argument<Int>("hour") ?: 7).coerceIn(0, 23),
                minute = (call.argument<Int>("minute") ?: 0).coerceIn(0, 59),
                label = call.argument<String>("label") ?: "Wake up",
                enabled = call.argument<Boolean>("enabled") ?: true,
                repeatDaily = call.argument<Boolean>("repeatDaily") ?: true,
                weekdays = (call.argument<List<Int>>("weekdays") ?: emptyList()).filter { it in 1..7 }.toSet(),
                qrValue = call.argument<String>("qrValue") ?: "",
                stepCount = difficultyToSteps(call.argument<String>("difficulty")),
                soundPack = call.argument<String>("soundPack")
                    ?: AlarmSounds.DEFAULT_PACK,
                snoozeMinutes = (call.argument<Int>("snoozeMinutes")
                    ?: AlarmDefaults.DEFAULT_SNOOZE_MINUTES).coerceIn(0, 60),
                escapes = AlarmDefaults.escapesFrom(call.argument<List<String>>("escapes")),
                checkInMinutes = (call.argument<Int>("checkInMinutes") ?: 0).takeIf { it in setOf(0, 3, 5, 10) } ?: 0,
                objectTarget = call.argument<String>("objectTarget") ?: "sink",
                objectVerified = ObjectTargets.verified(this, call.argument<String>("objectTarget") ?: "sink"),
                needsSetup = call.argument<Boolean>("needsSetup") ?: false,
                skipUntilMillis = call.argument<Number>("skipUntilMillis")?.toLong() ?: 0L,
                // A reference to a file that no longer exists is dropped, not kept: the bundled tone rings.
                customSound = call.argument<String>("customSoundId").orEmpty()
                    .takeIf { CustomSounds.fileFor(this, it) != null }.orEmpty(),
                customSoundName = call.argument<String>("customSoundName").orEmpty().take(80),
                vibrate = call.argument<Boolean>("vibrate") ?: true,
            )
            val triggerAt = (call.argument<Number>("triggerAtMillis"))?.toLong()
                ?: NativeAlarmScheduler.nextTrigger(alarm.hour, alarm.minute, alarm.weekdays)
            check(!alarm.needsSetup) { "Open this alarm and set up its new challenge before enabling it" }
            check(AlarmDefaults.ESCAPE_OBJECT !in alarm.escapes || ObjectTargets.verified(this, alarm.objectTarget)) {
                "Successfully practice scanning your ${ObjectTargets.title(alarm.objectTarget)} before enabling this alarm"
            }
            check((AlarmDefaults.ESCAPE_FACE !in alarm.escapes && AlarmDefaults.ESCAPE_OBJECT !in alarm.escapes && AlarmDefaults.ESCAPE_QR !in alarm.escapes) ||
                HealthChecker.hasCameraPermission(this)) {
                "Enable camera permission in Health before saving a camera challenge"
            }
            check(alarm.checkInMinutes <= 0 || StayAwake.notificationsAvailable(this)) {
                "Enable Stay Awake notifications in Health before saving a check-in alarm"
            }
            NativeAlarmScheduler.schedule(this, alarm, triggerAt)
            sweepCustomSounds()
            null
        }

        // Read the native store on every load: a one-shot that fired while the app was closed only
        // exists here, so a stale Dart mirror would keep offering an already-retired alarm.
        "alarms" -> AlarmStore.all(this).map { alarm ->
            mapOf(
                "id" to alarm.id,
                "hour" to alarm.hour,
                "minute" to alarm.minute,
                "label" to alarm.label,
                "enabled" to alarm.enabled,
                "repeatDaily" to alarm.repeatDaily,
                "weekdays" to alarm.weekdays.toList(),
                "qrValue" to alarm.qrValue,
                "difficulty" to stepsToDifficulty(alarm.stepCount),
                "soundPack" to alarm.soundPack,
                "snoozeMinutes" to alarm.snoozeMinutes,
                "escapes" to alarm.escapes.sorted(),
                "checkInMinutes" to alarm.checkInMinutes,
                "objectTarget" to alarm.objectTarget,
                "objectVerified" to ObjectTargets.verified(this, alarm.objectTarget),
                "needsSetup" to alarm.needsSetup,
                "skipUntilMillis" to alarm.skipUntilMillis,
                "nextTriggerAt" to alarm.nextTriggerAt,
                "customSoundId" to alarm.customSound,
                "customSoundName" to alarm.customSoundName,
                "vibrate" to alarm.vibrate,
            )
        }

        "cancel" -> {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("id is required")
            val customSound = AlarmStore.get(this, id)?.customSound
            NativeAlarmScheduler.cancel(this, id)
            // Not deleted outright: a switched-off alarm still owns its tone, and a deleted one
            // may be undone. The sweep removes it once no saved alarm uses it and the grace ends.
            CustomSounds.touch(this, customSound)
            sweepCustomSounds()
            null
        }

        "retainCustomSounds" -> {
            CustomSounds.retain(this, call.argument<List<String>>("ids").orEmpty())
            null
        }

        "dismiss" -> {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("id is required")
            check(AlarmDismissal.complete(this, id, call.argument<String>("method") ?: "settings", call.argument<String>("sessionId"))) {
                "This alarm session is no longer ringing, or this challenge is not selected"
            }
            null
        }

        "objectTargetVerified" -> ObjectTargets.verified(this, call.argument<String>("target") ?: "")

        "history" -> AlarmDismissal.history(this)
        "pendingCheckIns" -> AlarmSessions.all(this).filter {
            it.phase == "checkin" && StayAwake.windowOpen(it)
        }.sortedBy { it.promptedAt }.map {
            mapOf("id" to it.alarm.id, "sessionId" to it.token, "label" to it.alarm.label,
                "dueAt" to it.promptedAt, "expiresAt" to StayAwake.deadline(it))
        }
        "confirmCheckIn" -> StayAwake.confirm(this,
            call.argument<String>("id") ?: throw IllegalArgumentException("id is required"),
            call.argument<String>("sessionId"))
        "clearHistory" -> { AlarmEvents.clear(this); null }
        "practice" -> {
            check(AlarmSessions.active(this) == null) { "Finish the ringing alarm before practicing" }
            startActivity(android.content.Intent(this, AlarmRingActivity::class.java).apply {
                putExtra("practice", true)
                putExtra(NativeAlarmScheduler.EXTRA_LABEL, "Challenge practice — no alarm is scheduled")
                putExtra(NativeAlarmScheduler.EXTRA_STEPS, difficultyToSteps(call.argument<String>("difficulty")))
                putExtra(NativeAlarmScheduler.EXTRA_QR, call.argument<String>("qrValue") ?: "")
                putExtra(NativeAlarmScheduler.EXTRA_ESCAPES,
                    AlarmDefaults.escapesFrom(call.argument<List<String>>("escapes")).joinToString(","))
                putExtra(NativeAlarmScheduler.EXTRA_OBJECT_TARGET, call.argument<String>("objectTarget") ?: "sink")
            })
            null
        }

        "openFixAction" -> {
            // Returns null on success or a reason string; the Dart UI shows it so failures are visible.
            HealthChecker.openFix(
                this,
                call.argument<String>("action") ?: return null,
            )
        }

        "playAudibilitySample" -> {
            // Preview the picked tone before saving.
            AudibilityProbe.play(this, call.argument<String>("soundPack"), vibrate = call.argument<Boolean>("vibrate") ?: false)
            null
        }

        "previewCustomSound" -> {
            val file = CustomSounds.fileFor(this, call.argument<String>("id"))
            checkNotNull(file) { "That sound file is no longer available. Choose it again." }
            AudibilityProbe.play(this, file = file, vibrate = call.argument<Boolean>("vibrate") ?: false)
            null
        }

        "listSystemSounds" -> {
            // The device's own alarm tones, exactly like the stock Clock app's sound list.
            // Use the application Context, never the Activity: the Activity constructor makes Android
            // "manage" the cursor and re-query it on every restart (e.g. coming back from the file
            // picker), which crashes once the cursor below is closed.
            val context = applicationContext
            val manager = android.media.RingtoneManager(context).apply {
                setType(android.media.RingtoneManager.TYPE_ALARM)
            }
            val cursor = manager.cursor
            try {
                buildList {
                    while (cursor.moveToNext()) {
                        val uri = manager.getRingtoneUri(cursor.position) ?: continue
                        val name = manager.getRingtone(cursor.position)
                            ?.getTitle(context) ?: continue
                        add(mapOf("id" to uri.toString(), "name" to name))
                    }
                }
            } finally {
                cursor.close()
            }
        }

        "importSystemSound" -> {
            val uri = call.argument<String>("uri")
                ?: throw IllegalArgumentException("uri is required")
            val imported = CustomSounds.import(this, android.net.Uri.parse(uri))
            mapOf("id" to imported.id, "name" to imported.name)
        }

        "stopAudibilitySample" -> {
            AudibilityProbe.stop()
            null
        }

        "notificationsReady" -> buildList {
            if (!HealthChecker.hasNotificationPermission(this@MainActivity)) {
                add("notifications")
            }
            if (!HealthChecker.canScheduleExactAlarmsNow(this@MainActivity)) {
                add("exactAlarm")
            }
        }

        "requestPermissions" -> {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
                !HealthChecker.hasNotificationPermission(this)) {
                HealthChecker.requestNotificationPermission(this)
            } else if (!androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()) {
                val failure = HealthChecker.openFix(this, "notification_permission")
                check(failure == null) { failure ?: "Could not open notification settings" }
            }
            true
        }

        "launchDetails" -> mapOf(
            "ringing" to (RingingState.activeAlarm != null),
            "id" to RingingState.activeAlarm?.id,
            "label" to RingingState.activeAlarm?.label,
            "sessionId" to RingingState.sessionId,
            "contractVersion" to 2,
        )

        else -> throw IllegalArgumentException("Unknown alarm method: ${call.method}")
    }

    private fun difficultyToSteps(name: String?): Int = when (name) {
        "gentle" -> 1
        "strict" -> 3
        else -> 2
    }

    private fun stepsToDifficulty(steps: Int): String = when (steps) {
        1 -> "gentle"
        3 -> "strict"
        else -> "moderate"
    }
}

/**
 * Plays the real bundled tone through STREAM_ALARM so the user can confirm audibility before
 * trusting an alarm; a muted stream or Focus mode otherwise looks identical to a working alarm.
 */
object AudibilityProbe {

    private const val PREVIEW_MS = 10_000L

    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var vibrator: android.os.Vibrator? = null

    /**
     * Plays the exact file a real alarm uses, looped, at the current alarm volume: the preview never
     * changes system volume.
     */
    fun play(
        context: Context,
        pack: String? = null,
        file: java.io.File? = null,
        vibrate: Boolean = false,
    ) {
        stop()
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                if (file != null) {
                    // An uploaded tone previews exactly as it will ring.
                    setDataSource(file.absolutePath)
                } else {
                    val resId = AlarmSounds.resourceFor(context, pack)
                    setDataSource(
                        context,
                        android.net.Uri.parse("android.resource://${context.packageName}/$resId"),
                    )
                }
                // The real alarm loops, so the preview does too.
                isLooping = true
                setOnPreparedListener { ready ->
                    if (player === ready) {
                        ready.start()
                        // Same pulse as a real ring, and only when the alarm vibrates.
                        if (vibrate) startVibration(context)
                        handler.postDelayed({ stop() }, PREVIEW_MS)
                    }
                }
                setOnErrorListener { _, _, _ ->
                    stop()
                    android.widget.Toast.makeText(context, "Could not play the sound preview", android.widget.Toast.LENGTH_LONG).show()
                    true
                }
                prepareAsync()
            }
        }.onFailure {
            android.util.Log.e("WakeGuard", "Audibility probe failed", it)
        }.getOrNull()
        check(player != null) { "The alarm sound could not be opened" }
    }

    private fun startVibration(context: Context) {
        val manager = context.getSystemService(android.os.Vibrator::class.java) ?: return
        vibrator = manager
        val pattern = longArrayOf(0, 500, 300, 500)
        runCatching {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                manager.vibrate(android.os.VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                manager.vibrate(pattern, 0)
            }
        }.onFailure {
            android.util.Log.w("WakeGuard", "Could not start preview vibration", it)
        }
    }

    private fun releasePlayer() {
        runCatching { vibrator?.cancel() }
        vibrator = null
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        releasePlayer()
    }
}
