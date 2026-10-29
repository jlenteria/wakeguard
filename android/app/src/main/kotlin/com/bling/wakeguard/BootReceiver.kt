package com.bling.wakeguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager

/**
 * Reschedules alarms after events that invalidate trigger times. LOCKED_BOOT_COMPLETED matters:
 * BOOT_COMPLETED only arrives after first unlock, so a locked overnight reboot would lose alarms.
 *
 * The re-arm commits several SharedPreferences per alarm and must never run in the broadcast
 * itself: the ~10s budget kills the process mid-reschedule, leaving alarms silently unarmed.
 * It moves to the serialized scheduler worker under a partial wake lock, and only then finishes
 * the broadcast.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            -> {
                val app = context.applicationContext
                val pending = goAsync()
                val wakeLock = runCatching {
                    app.getSystemService(PowerManager::class.java)
                        ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wakeguard:boot-reschedule")
                        ?.apply { acquire(10 * 60 * 1000L) }
                }.getOrNull()
                val catchUp = intent.action != Intent.ACTION_TIME_CHANGED &&
                    intent.action != Intent.ACTION_TIMEZONE_CHANGED
                NativeAlarmScheduler.submit(
                    block = { NativeAlarmScheduler.rescheduleAll(app, catchUp = catchUp) },
                    onDone = {
                        runCatching { wakeLock?.release() }
                        // Ensure the channel exists so a first-run alarm has the right
                        // importance/vibration, then release the broadcast.
                        RingingService.createChannel(app)
                        pending.finish()
                    },
                )
                return
            }

            else -> Unit
        }
        // Ensure the channel exists so a first-run alarm has the right importance/vibration.
        RingingService.createChannel(context)
    }
}
