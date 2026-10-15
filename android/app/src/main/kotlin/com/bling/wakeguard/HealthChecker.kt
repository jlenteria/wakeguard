package com.bling.wakeguard

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
                label = "Alarms & reminders",
                passing = canScheduleExactAlarms(context),
                ok = "WakeGuard is allowed to ring at the time you choose, even with the screen off.",
                bad = "Allow WakeGuard under Alarms & reminders in your phone’s settings so alarms can ring on time.",
                action = "exact_alarm",
            ),
        )

        add(
            health(
                id = "alarm_volume",
                label = "Alarm volume",
                passing = alarmStreamVolume(context) > 0,
                ok = "Alarm volume is above zero. Play a test to check that it is loud enough.",
                bad = "Alarm volume is set to zero. Raise Alarm volume in your phone’s sound settings.",
                action = "alarm_volume",
            ),
        )

        add(
            health(
                id = "full_screen",
                label = "Full-screen alarm",
                passing = canUseFullScreenIntent(context),
                ok = "Full-screen permission is enabled. Test an alarm with your phone locked. While unlocked outside WakeGuard, Android may show a notification instead of opening the challenge.",
                bad = "Allow full-screen alerts for WakeGuard in your phone’s settings. Without this access, you may need to tap the ringing notification to open the challenge.",
                action = "full_screen",
                // The alarm rings either way; only presentation changes, so do not block saving.
                severity = HealthSeverityValue.warning,
            ),
        )

        // Report the real permission before saving; Dart checks the draft's escapes to block.
        val faceUsed = AlarmStore.all(context).any { it.enabled &&
            (AlarmDefaults.ESCAPE_FACE in it.escapes || AlarmDefaults.ESCAPE_OBJECT in it.escapes ||
                (AlarmDefaults.ESCAPE_QR in it.escapes && it.qrValue.isNotBlank())) }
        add(
            health(
                id = "camera",
                label = "Camera permission",
                passing = hasCameraPermission(context),
                ok = if (faceUsed) {
                    "Face, Object and QR challenges are available."
                } else {
                    "No enabled alarm needs the camera."
                },
                bad = "Allow Camera access to use Face, Find an object or QR challenges. Tap to stop does not need the camera.",
                action = "camera",
                // Globally advisory; blocking only for a Face/QR draft.
                severity = HealthSeverityValue.warning,
            ),
        )

        add(
            health(
                id = "notification_permission",
                label = "Notification permission",
                passing = hasNotificationPermission(context) && androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled(),
                ok = "WakeGuard can show the alarm notification.",
                bad = "Allow WakeGuard notifications in your phone’s settings to see ringing alarms and open their challenges.",
                action = "notification_permission",
            ),
        )

        add(health(
            id = "checkin_notification",
            label = "Stay Awake notifications",
            passing = StayAwake.notificationsAvailable(context),
            ok = "WakeGuard can ask if you’re still up and show the I'm up button.",
            bad = "Allow Stay Awake reminders in WakeGuard’s notification settings before turning on check-ins.",
            action = "checkin_notification",
            severity = HealthSeverityValue.warning,
        ))
        add(health(
            id = "checkin_sound",
            label = "Stay Awake reminder sound",
            passing = StayAwake.remindersAudible(context),
            ok = "Stay Awake reminders have a notification sound. Check notification volume and Do Not Disturb too.",
            bad = "Turn on sound for Stay Awake reminders in WakeGuard’s notification settings. You have 1 minute to respond.",
            action = "checkin_notification",
            severity = HealthSeverityValue.warning,
        ))

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
        val preferences = activity.getSharedPreferences("wakeguard.permissions", Context.MODE_PRIVATE)
        if (preferences.getBoolean("notificationsRequested", false) &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, android.Manifest.permission.POST_NOTIFICATIONS)) {
            val failure = openFix(activity, "notification_permission")
            check(failure == null) { failure ?: "Could not open notification settings" }
            return
        }
        preferences.edit().putBoolean("notificationsRequested", true).apply()
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

            // Health is the recovery path, including permanently denied permissions.
            // Onboarding uses requestNotificationPermission for the initial dialog.
            "notification_permission" ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    }
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:${context.packageName}")
                    }
                }

            "checkin_notification" -> StayAwake.settingsIntent(context)

            "full_screen" -> Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${context.packageName}")
            }

            "alarm_volume" -> Intent(Settings.ACTION_SOUND_SETTINGS)

            "camera" ->
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${context.packageName}")
                }

            else -> return "This setting cannot be opened here. Open WakeGuard’s settings on your phone."
        }

        // NEW_TASK is required from an application context, but breaks an Activity's back stack.
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        return try {
            if (intent.resolveActivity(context.packageManager) == null &&
                action != "notification_permission"
            ) {
                "Open your phone’s Settings and find WakeGuard to change this setting."
            } else {
                context.startActivity(intent)
                null
            }
        } catch (error: SecurityException) {
            // Almost always a missing permission; name it so the failure is diagnosable.
            "Your phone did not allow this settings page to open. Open Settings and find WakeGuard instead."
        } catch (error: ActivityNotFoundException) {
            "This settings page is not available on your phone. Open Settings and find WakeGuard instead."
        }
    }
}
