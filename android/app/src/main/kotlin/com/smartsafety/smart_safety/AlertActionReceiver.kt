package com.smartsafety.smart_safety

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Handles the guardian alert notification actions: "Stop siren" (and swiping the notification
 * away), which only silence, and "Dismiss", which also records the dismissal in Firestore so the
 * alert does not come back on this device.
 */
class AlertActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_STOP_SIREN = "com.smartsafety.smart_safety.STOP_SIREN"
        const val ACTION_DISMISS = "com.smartsafety.smart_safety.ALERT_DISMISS"
        const val EXTRA_ALERT_ID = "alert_id"
        private const val TAG = "WG/AlertAction"
        private const val WRITE_TIMEOUT_MS = 8_000L
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_STOP_SIREN -> {
                Log.i(TAG, "Siren stopped from notification")
                AlertSirenPlayer.stop(context)
            }
            ACTION_DISMISS -> {
                AlertSirenPlayer.stop(context)
                NotificationManagerCompat.from(context).cancel(GuardianAlertService.ALERT_NOTIFICATION_ID)
                val alertId = intent.getStringExtra(EXTRA_ALERT_ID) ?: return
                val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
                Log.i(TAG, "Alert $alertId dismissed from notification")
                val pending = goAsync()
                // An offline write completes only when the device is back online (it stays queued),
                // so the broadcast is released after a short wait either way.
                val finished = AtomicBoolean(false)
                val finish = { if (finished.compareAndSet(false, true)) pending.finish() }
                Handler(Looper.getMainLooper()).postDelayed({ finish() }, WRITE_TIMEOUT_MS)
                FirebaseFirestore.getInstance().collection("sos_alerts").document(alertId)
                    .update("dismissedBy", FieldValue.arrayUnion(uid))
                    .addOnCompleteListener { task ->
                        if (!task.isSuccessful) Log.w(TAG, "Could not record dismissal of $alertId", task.exception)
                        finish()
                    }
            }
        }
    }
}
