package com.smartsafety.smart_safety

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Handles the "Stop siren" notification action and dismissal of a guardian alert notification. */
class AlertActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_STOP_SIREN = "com.smartsafety.smart_safety.STOP_SIREN"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_STOP_SIREN) {
            Log.i("WG/AlertAction", "Siren stopped from notification")
            AlertSirenPlayer.stop(context)
        }
    }
}
