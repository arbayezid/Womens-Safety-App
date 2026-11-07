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

    /** Returns true exactly once per ring key (`alertId#ringSeq`). */
    @Synchronized
    fun tryClaim(context: Context, alertId: String): Boolean {
        if (alertId.isBlank()) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val ids = load(context)
        if (claimedIn(ids, alertId)) return false
        ids += alertId
        while (ids.size > MAX_ENTRIES) ids.removeAt(0)
        prefs.edit().putString(KEY_CLAIMED, ids.joinToString("\n")).commit()
        return true
    }

    @Synchronized
    fun isClaimed(context: Context, alertId: String): Boolean = claimedIn(load(context), alertId)

    /** Whether any ring of [alertId] (any ring sequence) already rang on this device. */
    @Synchronized
    fun anyRingClaimed(context: Context, alertId: String): Boolean =
        alertId.isNotBlank() && load(context).any { it == alertId || it.startsWith("$alertId#") }

    /** Entries claimed before ring keys existed are bare alert IDs; they stand for ring 0. */
    private fun claimedIn(ids: List<String>, key: String): Boolean =
        key in ids || (key.endsWith("#0") && key.removeSuffix("#0") in ids)

    private fun load(context: Context): MutableList<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_CLAIMED, "")
            .orEmpty()
            .split('\n')
            .filter { it.isNotEmpty() }
            .toMutableList()
}
