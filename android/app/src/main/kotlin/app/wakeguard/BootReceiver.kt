package app.wakeguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Reschedules alarms after events that invalidate trigger times. LOCKED_BOOT_COMPLETED matters:
 * BOOT_COMPLETED only arrives after first unlock, so a locked overnight reboot would lose alarms.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            -> NativeAlarmScheduler.rescheduleAll(context,
                catchUp = intent.action != Intent.ACTION_TIME_CHANGED && intent.action != Intent.ACTION_TIMEZONE_CHANGED)

            else -> Unit
        }
        // Ensure the channel exists so a first-run alarm has the right importance/vibration.
        RingingService.createChannel(context)
    }
}
