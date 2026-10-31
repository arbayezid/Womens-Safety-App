package com.smartsafety.smart_safety

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Receives the per-part sent / delivered results of messages sent by [SmsSender]. */
class SmsResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val key = intent.getStringExtra(SmsSender.EXTRA_TRACKING_KEY) ?: return
        SmsSender.onPartResult(action, key, resultCode)
    }
}
