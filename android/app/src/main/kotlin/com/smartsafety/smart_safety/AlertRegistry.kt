package com.smartsafety.smart_safety

import android.content.Context

/**
 * Process-wide record of SOS alert IDs that already rang on this device.
 *
 * Both the native GuardianAlertService and the Flutter UI listener see the same alert; whichever
 * claims it first plays the siren, so an alert never rings twice (also across restarts).
 */
object AlertRegistry {
    private const val PREFS = "woman_guard_guardian_alerts"
    private const val KEY_CLAIMED = "claimed_alert_ids"
    private const val MAX_ENTRIES = 300

    /** Returns true exactly once per alert ID. */
    @Synchronized
    fun tryClaim(context: Context, alertId: String): Boolean {
        if (alertId.isBlank()) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val ids = load(context)
        if (alertId in ids) return false
        ids += alertId
        while (ids.size > MAX_ENTRIES) ids.removeAt(0)
        prefs.edit().putString(KEY_CLAIMED, ids.joinToString("\n")).commit()
        return true
    }

    @Synchronized
    fun isClaimed(context: Context, alertId: String): Boolean = alertId in load(context)

    private fun load(context: Context): MutableList<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_CLAIMED, "")
            .orEmpty()
            .split('\n')
            .filter { it.isNotEmpty() }
            .toMutableList()
}
