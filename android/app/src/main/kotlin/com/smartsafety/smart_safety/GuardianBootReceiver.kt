package com.smartsafety.smart_safety

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Restarts the guardian alert listener after a reboot or an app update, only for a signed-in user. */
class GuardianBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!GuardianAlertService.isEnabled(context)) return
        Log.i("WG/GuardianBoot", "$action -> starting guardian alert listener")
        GuardianAlertService.start(context)
    }
}
