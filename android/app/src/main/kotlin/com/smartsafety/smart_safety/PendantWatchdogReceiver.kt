package com.smartsafety.smart_safety

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Restarts [PendantLinkService] if Android or the phone's battery manager killed it while the
 * pendant link is enabled. Fires every [INTERVAL_MS], also in Doze; an exact while-idle alarm
 * lets the app start its foreground service from the background.
 */
class PendantWatchdogReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "WG/PendantWatchdog"
        const val ACTION_TICK = "com.smartsafety.smart_safety.PENDANT_WATCHDOG"
        const val INTERVAL_MS = 15 * 60 * 1000L
        private const val REQUEST_CODE = 7322

        private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            Intent(context, PendantWatchdogReceiver::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        /** (Re)arms the next tick; replaces any tick already scheduled. */
        fun schedule(context: Context, delayMs: Long = INTERVAL_MS) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            val triggerAt = System.currentTimeMillis() + delayMs
            val pending = pendingIntent(context)
            try {
                if (SafetyDeadlines.canScheduleExactAlarms(context)) {
                    manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
                } else {
                    manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "Exact alarm refused; using inexact pendant watchdog", e)
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
        }

        fun cancel(context: Context) {
            context.getSystemService(AlarmManager::class.java)?.cancel(pendingIntent(context))
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TICK) return
        if (PendantLink.savedAddress(context) == null || !PendantLink.isEnabled(context)) {
            Log.i(TAG, "Pendant link off; watchdog stops")
            return
        }
        // Arm the next tick first, so a refused start below never ends the chain.
        schedule(context)
        if (!PendantLinkService.isRunning) {
            Log.i(TAG, "Pendant service not running; restarting")
            PendantLinkService.ensureRunning(context)
        }
    }
}
