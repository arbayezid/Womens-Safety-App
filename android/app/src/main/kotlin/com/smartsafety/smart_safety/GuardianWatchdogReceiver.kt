package com.smartsafety.smart_safety

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Keeps the guardian alert listener alive and connected while the phone sits locked for hours.
 *
 * Without a server (Spark plan, no FCM) alerts only arrive over GuardianAlertService's Firestore
 * connection. Two things break that on an idle phone:
 *  - the OS or the vendor's battery manager kills the service, and nothing restarts it until the
 *    app is opened again;
 *  - while the CPU sleeps, the connection's keep-alive timers stop. The carrier/router drops the
 *    idle connection, the phone never notices, and new alerts never arrive.
 *
 * This alarm wakes the phone every [INTERVAL_MS], even in Doze. Each tick restarts the service if
 * it is gone, or makes it reconnect to Firestore so anything sent meanwhile is delivered. The
 * interval stays well under 30 minutes so Firestore resumes the listeners cheaply (only changed
 * documents are read).
 */
class GuardianWatchdogReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "WG/GuardianWatchdog"
        const val ACTION_TICK = "com.smartsafety.smart_safety.GUARDIAN_WATCHDOG"
        const val INTERVAL_MS = 10 * 60 * 1000L
        private const val REQUEST_CODE = 7310

        /** One-shot check for an active SOS whose sender's phone may have gone quiet. */
        const val ACTION_SIGNAL_CHECK = "com.smartsafety.smart_safety.GUARDIAN_SIGNAL_CHECK"
        private const val SIGNAL_REQUEST_CODE = 7311

        private fun signalPendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context,
            SIGNAL_REQUEST_CODE,
            Intent(context, GuardianWatchdogReceiver::class.java).setAction(ACTION_SIGNAL_CHECK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        /** (Re)arms the signal check for [triggerAt]; replaces any check already scheduled. */
        fun scheduleSignalCheck(context: Context, triggerAt: Long) {
            setWakeAlarm(context, triggerAt, signalPendingIntent(context))
        }

        fun cancelSignalCheck(context: Context) {
            context.getSystemService(AlarmManager::class.java)?.cancel(signalPendingIntent(context))
        }

        private fun setWakeAlarm(context: Context, triggerAt: Long, pending: PendingIntent) {
            val manager = context.getSystemService(AlarmManager::class.java) ?: return
            try {
                if (SafetyDeadlines.canScheduleExactAlarms(context)) {
                    manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
                } else {
                    manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "Exact alarm refused; using inexact alarm", e)
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
        }

        private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            Intent(context, GuardianWatchdogReceiver::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        /** (Re)arms the next tick; replaces any tick already scheduled. */
        fun schedule(context: Context, delayMs: Long = INTERVAL_MS) {
            // Exact while-idle alarms fire in Doze and let the app restart its foreground
            // service from the background. Not setAlarmClock: that would show an alarm icon.
            setWakeAlarm(context, System.currentTimeMillis() + delayMs, pendingIntent(context))
        }

        fun cancel(context: Context) {
            context.getSystemService(AlarmManager::class.java)?.cancel(pendingIntent(context))
            cancelSignalCheck(context)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_SIGNAL_CHECK) {
            if (GuardianAlertService.isEnabled(context) && GuardianAlertService.isProtecting(context)) {
                GuardianAlertService.onSignalCheckTick(context)
            }
            return
        }
        if (intent.action != ACTION_TICK) return
        if (!GuardianAlertService.isEnabled(context) || !GuardianAlertService.isProtecting(context)) {
            Log.i(TAG, "Guardian alerts off; watchdog stops")
            return
        }
        // Arm the next tick first, so a failure below never ends the chain.
        schedule(context)
        GuardianAlertService.onWatchdogTick(context)
    }
}
