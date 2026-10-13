package com.bling.wakeguard

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
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

    private companion object {
        const val CHANNEL = "com.bling.wakeguard/alarm"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RingingService.createChannel(this)
        StayAwake.createChannel(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // Preferences and system-service reads must not block Flutter's
                // platform thread during startup or a sheet transition.
                if (call.method in setOf("alarms", "health", "history", "capabilities", "objectTargetVerified")) {
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
            )
        }

        "cancel" -> {
            val id = call.argument<String>("id")
                ?: throw IllegalArgumentException("id is required")
            NativeAlarmScheduler.cancel(this, id)
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
            AudibilityProbe.play(this, call.argument<String>("soundPack"))
            null
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

    /**
     * Plays the exact file a real alarm uses, looped, at the current alarm volume: the preview never
     * changes system volume.
     */
    fun play(context: Context, pack: String? = null) {
        stop()
        val resId = AlarmSounds.resourceFor(context, pack)
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(
                    context,
                    android.net.Uri.parse("android.resource://${context.packageName}/$resId"),
                )
                // The real alarm loops, so the preview does too.
                isLooping = true
                setOnPreparedListener { ready ->
                    if (player === ready) {
                        ready.start()
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

    private fun releasePlayer() {
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        releasePlayer()
    }
}
