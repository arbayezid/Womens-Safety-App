package com.smartsafety.smart_safety

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Exact-alarm callback for safety deadlines and the "I'm safe" action of the prompt notification. */
class SafetyDeadlineReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "WG/DeadlineReceiver"
        const val ACTION_FIRE = "com.smartsafety.smart_safety.DEADLINE_FIRE"
        const val ACTION_IM_SAFE = "com.smartsafety.smart_safety.DEADLINE_IM_SAFE"
        const val EXTRA_ID = "deadline_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        when (intent.action) {
            ACTION_FIRE -> {
                Log.i(TAG, "Deadline alarm fired: $id")
                if (!SafetyDeadlineService.start(context, id)) {
                    // Android refused a background foreground-service start (no exact-alarm permission and
                    // no battery-optimisation exemption). Show the check so the user can still respond,
                    // and retry the escalation through a later alarm.
                    val d = SafetyDeadlines.get(context, id) ?: return
                    if (d.state == SafetyDeadlines.STATE_ARMED && !d.direct) {
                        SafetyDeadlines.prompt(context, id, System.currentTimeMillis() + d.promptSeconds * 1000L, byApp = false)
                        SafetyDeadlines.postPromptNotification(context, d)
                    } else {
                        SafetyDeadlines.markAttempt(context, id)
                    }
                }
            }
            ACTION_IM_SAFE -> SafetyDeadlines.confirmSafeFromNotification(context, id)
        }
    }
}
