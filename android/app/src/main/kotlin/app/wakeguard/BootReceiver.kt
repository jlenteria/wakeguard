package app.wakeguard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Reschedules every alarm after events that invalidate previously computed
 * trigger times.
 *
 * `LOCKED_BOOT_COMPLETED` is the important addition: `BOOT_COMPLETED` is only
 * delivered after the first unlock, so a phone that reboots overnight and stays
 * locked would silently lose every alarm. The receiver is `directBootAware` and
 * reads device-protected storage for that reason.
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
        // Always make sure the channel exists so a first-run alarm has the
        // right importance and vibration behaviour.
        RingingService.createChannel(context)
    }
}
