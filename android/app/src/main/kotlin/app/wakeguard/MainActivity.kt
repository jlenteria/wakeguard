package app.wakeguard

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "app.wakeguard/alarm"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RingingService.createChannel(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                runCatching { handle(call) }
                    .onSuccess { result.success(it) }
                    .onFailure {
                        result.error("NATIVE_ERROR", it.message, null)
                    }
            }
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
                skipUntilMillis = call.argument<Number>("skipUntilMillis")?.toLong() ?: 0L,
            )
            val triggerAt = (call.argument<Number>("triggerAtMillis"))?.toLong()
                ?: NativeAlarmScheduler.nextTrigger(alarm.hour, alarm.minute, alarm.weekdays)
            check((AlarmDefaults.ESCAPE_FACE !in alarm.escapes && AlarmDefaults.ESCAPE_QR !in alarm.escapes) ||
                HealthChecker.hasCameraPermission(this)) {
                "Enable camera permission in Health before saving a Face/QR alarm"
            }
            NativeAlarmScheduler.schedule(this, alarm, triggerAt)
            null
        }

        // The native store is what actually decides whether an alarm rings, so
        // the Dart mirror reads it back on every load instead of trusting its
        // own copy: a one-shot that fired while the app was closed only exists
        // here, and a mirror that never heard about it kept offering a switch
        // for an alarm that had already retired.
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
            AlarmDismissal.complete(this, id, call.argument<String>("method") ?: "settings", call.argument<String>("sessionId"))
            null
        }

        "history" -> AlarmDismissal.history(this)
        "clearHistory" -> { AlarmEvents.clear(this); null }
        "practice" -> {
            check(AlarmSessions.active(this) == null) { "Finish the ringing alarm before practising" }
            startActivity(android.content.Intent(this, AlarmRingActivity::class.java).apply {
                putExtra("practice", true)
                putExtra(NativeAlarmScheduler.EXTRA_LABEL, "Challenge practice — no alarm is scheduled")
                putExtra(NativeAlarmScheduler.EXTRA_STEPS, difficultyToSteps(call.argument<String>("difficulty")))
                putExtra(NativeAlarmScheduler.EXTRA_QR, call.argument<String>("qrValue") ?: "")
                putExtra(NativeAlarmScheduler.EXTRA_ESCAPES,
                    AlarmDefaults.escapesFrom(call.argument<List<String>>("escapes")).joinToString(","))
            })
            null
        }

        "openFixAction" -> {
            // Returns null on success or a reason string on failure. Reporting it
            // over the channel lets the Dart UI show a message, so a fix that
            // cannot be applied is visible instead of silently doing nothing.
            HealthChecker.openFix(
                this,
                call.argument<String>("action") ?: return null,
            )
        }

        "playAudibilitySample" -> {
            // Preview the same tone the user just picked in the editor, so
            // "does this alarm sound right" is answerable before saving.
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
            // Must run on the activity thread and off the main looper queue.
            HealthChecker.requestNotificationPermission(this@MainActivity)
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
 * Plays the real bundled ladder through `STREAM_ALARM` so the user can confirm
 * audibility before trusting an alarm. This is the single most valuable check:
 * an alarm stream muted to zero, or a Focus mode swallowing the sound, looks
 * identical to a working alarm until the one morning it matters.
 */
object AudibilityProbe {

    private const val PREVIEW_MS = 10_000L

    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null

    /**
     * Plays the exact file a real alarm with this pack plays, looped like the
     * real thing. It plays at whatever level the phone's alarm volume is
     * currently set to: the preview never changes the system volume.
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
