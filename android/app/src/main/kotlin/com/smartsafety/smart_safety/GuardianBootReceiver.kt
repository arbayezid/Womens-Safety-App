package com.smartsafety.smart_safety

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * After a reboot or an app update: re-registers safety-deadline alarms (Android drops all alarms)
 * and restarts the guardian alert listener for a signed-in user who protects someone.
 */
class GuardianBootReceiver : BroadcastReceiver() {
    companion object {
        private const val ACTION_EXACT_ALARM_PERMISSION_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != ACTION_EXACT_ALARM_PERMISSION_CHANGED
        ) return

        Log.i("WG/GuardianBoot", "$action -> rescheduling safety deadlines")
        SafetyDeadlines.rescheduleAll(context)
        if (action == ACTION_EXACT_ALARM_PERMISSION_CHANGED) return

        if (!GuardianAlertService.isEnabled(context)) return
        Log.i("WG/GuardianBoot", "$action -> starting guardian alert listener")
        // The watchdog retries if this start is refused, and keeps the listener alive afterwards.
        if (GuardianAlertService.isProtecting(context)) GuardianWatchdogReceiver.schedule(context, 60_000L)
        GuardianAlertService.start(context)
    }
}
