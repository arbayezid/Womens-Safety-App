package com.smartsafety.smart_safety

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Color
import android.os.Build

/** Creates every notification channel the native layer posts to. Safe to call repeatedly. */
object NotificationChannels {
    /**
     * Channel used by flutter_background_service for its foreground notification and by
     * NotificationService.showStatusNotification. It must exist before the service calls
     * startForeground(), otherwise Android kills the whole app with
     * "Bad notification for startForeground: invalid channel for service notification".
     */
    const val SOS_STATUS = "sos_emergency_channel"

    /** Persistent, low-priority notification of the guardian alert listener service. */
    const val GUARDIAN_PROTECTION = "guardian_protection_channel"

    /** Incoming SOS alerts from people who added this user as a guardian. */
    const val GUARDIAN_ALERTS = "guardian_emergency_alerts_channel"

    fun ensureCreated(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return

        // Same name/importance NotificationService.showStatusNotification would create on its own,
        // so existing status notifications keep behaving exactly as before.
        if (manager.getNotificationChannel(SOS_STATUS) == null) {
            manager.createNotificationChannel(
                NotificationChannel(SOS_STATUS, "SOS Emergency Alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Emergency status notifications"
                }
            )
        }

        manager.createNotificationChannel(
            NotificationChannel(GUARDIAN_PROTECTION, "Woman Guard Protection", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Keeps emergency alert reception active in the background."
                setShowBadge(false)
            }
        )

        manager.createNotificationChannel(
            NotificationChannel(GUARDIAN_ALERTS, "Emergency Alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Incoming SOS alerts from people who added you as their guardian."
                // The siren is played by AlertSirenPlayer on the alarm stream, so the channel itself stays
                // silent to avoid two overlapping sounds.
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 1000, 500, 1000, 500, 1000)
                enableLights(true)
                lightColor = Color.RED
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                // Only honoured when the user grants Do Not Disturb access; ignored otherwise.
                setBypassDnd(true)
            }
        )
    }
}
