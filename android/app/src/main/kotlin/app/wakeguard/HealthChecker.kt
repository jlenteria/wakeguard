package app.wakeguard

import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Translates platform config into user-facing health checks. The usual reason an alarm "did not
 * ring" is an OEM killer, mute, DND, or full-screen permission — surfaced here with a one-tap fix.
 */
object HealthChecker {

    fun capabilities(context: Context): Map<String, Any?> = mapOf(
        "contractVersion" to 2,
        "canPractice" to true,
        "canCheckIn" to true,
        "canLoopWhileBackgrounded" to true,
        "canLockScreenTakeover" to true,
        "canUseCameraInBackground" to true,
        // STREAM_ALARM is independent of silent/vibrate mode. DND can still block alarms
        // if the user disables them in its settings; this is not a DND-bypass capability.
        "canBypassSilentSwitch" to true,
        // Android has no equivalent to iOS's 64-pending-notification cap.
        "pendingSlotCap" to null,
    )

    fun check(context: Context): List<Map<String, Any?>> = buildList {
        add(
            health(
                id = "exact_alarm",
                label = "Exact alarms",
                passing = canScheduleExactAlarms(context),
                ok = "Alarms fire to the minute, even while the screen is off.",
                bad = "Without this, Android may delay your alarm by minutes.",
                action = "exact_alarm",
            ),
        )

        add(
            health(
                id = "alarm_volume",
                label = "Alarm volume",
                passing = alarmStreamVolume(context) > 0,
                ok = "The alarm stream is audible.",
                bad = "The alarm stream is at zero. Your alarm will be silent.",
                action = "alarm_volume",
            ),
        )

        add(
            health(
                id = "full_screen",
                label = "Full-screen alarm",
                passing = canUseFullScreenIntent(context),
                ok = "The wake challenge appears over the lock screen.",
                bad = "The challenge may appear as a plain notification instead.",
                action = "full_screen",
                // The alarm rings either way; only presentation changes, so do not block saving.
                severity = HealthSeverityValue.warning,
            ),
        )

        // Report the real permission before saving; Dart checks the draft's escapes to block.
        val faceUsed = AlarmStore.all(context).any { it.enabled &&
            (AlarmDefaults.ESCAPE_FACE in it.escapes || (AlarmDefaults.ESCAPE_QR in it.escapes && it.qrValue.isNotBlank())) }
        add(
            health(
                id = "camera",
                label = "Camera permission",
                passing = hasCameraPermission(context),
                ok = if (faceUsed) {
                    "Face and QR challenges are available."
                } else {
                    "No enabled alarm needs the camera."
                },
                bad = "Enable Camera in app permissions before saving or enabling Face/QR alarms. Pattern and Tap alarms do not need it.",
                action = "camera",
                // Globally advisory; blocking only for a Face/QR draft.
                severity = HealthSeverityValue.warning,
            ),
        )

        add(
            health(
                id = "notification_permission",
                label = "Notification permission",
                passing = hasNotificationPermission(context),
                ok = "WakeGuard can show the alarm notification.",
                bad = "Blocked since Android 13. The alarm would ring silently " +
                    "with no visible notification.",
                action = "notification_permission",
            ),
        )

    }

    /** Severities mirror the Dart `HealthSeverity` enum; keep the names in step. */
    private enum class HealthSeverityValue { ok, warning, blocking }

    private fun health(
        id: String,
        label: String,
        passing: Boolean,
        ok: String,
        bad: String,
        action: String,
        severity: HealthSeverityValue = HealthSeverityValue.blocking,
    ): Map<String, Any?> = mapOf(
        "id" to id,
        "label" to label,
        "detail" to if (passing) ok else bad,
        "severity" to if (passing) "ok" else severity.name,
        "action" to if (passing) null else action,
    )

    // region probes

    private fun canScheduleExactAlarms(context: Context): Boolean =
        canScheduleExactAlarmsNow(context)

    fun canScheduleExactAlarmsNow(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.getSystemService(AlarmManager::class.java)
            ?.canScheduleExactAlarms() == true
    }

    private fun alarmStreamVolume(context: Context): Int = runCatching {
        context.getSystemService(AudioManager::class.java)
            ?.getStreamVolume(AudioManager.STREAM_ALARM) ?: 0
    }.getOrDefault(0)

    /**
     * Runtime notification permission (Android 13+). Without it the service still starts but the
     * notification is invisible and the full-screen intent is suppressed, looking like a silent fail.
     */
    fun hasNotificationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.POST_NOTIFICATIONS,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    /** Requests POST_NOTIFICATIONS on Android 13+. No-op on older releases. */
    fun requestNotificationPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (hasNotificationPermission(activity)) return
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    private const val REQUEST_POST_NOTIFICATIONS = 4101

    private fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        return context.getSystemService(NotificationManager::class.java)
            ?.canUseFullScreenIntent() == true
    }

    fun hasCameraPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    // endregion

    /**
     * Opens the settings screen that fixes [action], returning null on success or a readable reason
     * on failure. Failures are surfaced rather than swallowed so a dead button is diagnosable.
     */
    fun openFix(context: Context, action: String): String? {
        val intent: Intent = when (action) {
            "exact_alarm" -> Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = Uri.parse("package:${context.packageName}")
            }

            // Android 13+ can grant inline via the system dialog; older releases open app settings.
            "notification_permission" ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    context is Activity
                ) {
                    requestNotificationPermission(context)
                    return null
                } else {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    }
                }

            "full_screen" -> Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${context.packageName}")
            }

            "alarm_volume" -> Intent(Settings.ACTION_SOUND_SETTINGS)

            "camera" ->
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${context.packageName}")
                }

            else -> return "Unknown fix action: $action"
        }

        // NEW_TASK is required from an application context, but breaks an Activity's back stack.
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        return try {
            if (intent.resolveActivity(context.packageManager) == null &&
                action != "notification_permission"
            ) {
                "No settings screen on this device handles $action"
            } else {
                context.startActivity(intent)
                null
            }
        } catch (error: SecurityException) {
            // Almost always a missing permission; name it so the failure is diagnosable.
            "Permission denied opening $action: ${error.message}"
        } catch (error: ActivityNotFoundException) {
            "This device has no screen for $action"
        }
    }
}
