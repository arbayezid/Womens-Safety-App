package com.smartsafety.smart_safety

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.provider.Settings
import android.util.Log

/**
 * Puts the whole phone into total silence while a duress (Silent Panic) alert is active, so no
 * call, SMS, WhatsApp, Messenger, imo or any other app can ring and give the user away, then
 * puts the user's own sound settings back when they leave duress with their real PIN.
 *
 * Total silence needs Do Not Disturb access, which the user grants once in Settings beforehand.
 * Without it Android only lets an app switch to vibrate, which is used as the fallback.
 *
 * The previous sound settings are saved on disk, so they are restored correctly even if the app
 * was killed and restarted while the phone was silenced.
 */
object PhoneSilencer {
    private const val TAG = "WG/PhoneSilencer"
    private const val PREFS = "wg_phone_silencer"
    private const val KEY_ACTIVE = "active"
    private const val KEY_PREV_RINGER = "prev_ringer"
    private const val KEY_PREV_FILTER = "prev_filter"

    /** Result of [silence]: how silent the phone actually became. */
    const val SILENT = "silent"
    const val VIBRATE = "vibrate"
    const val FAILED = "failed"

    fun hasAccess(context: Context): Boolean {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return false
        return nm.isNotificationPolicyAccessGranted
    }

    fun openAccessSettings(context: Context): Boolean = try {
        context.startActivity(
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (e: Exception) {
        Log.w(TAG, "Cannot open Do Not Disturb access settings", e)
        false
    }

    fun isActive(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ACTIVE, false)

    @Synchronized
    fun silence(context: Context): String {
        val app = context.applicationContext
        val am = app.getSystemService(AudioManager::class.java) ?: return FAILED
        val nm = app.getSystemService(NotificationManager::class.java) ?: return FAILED
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        // Save the user's settings only the first time, so a second duress entry never
        // overwrites them with the already-silenced state.
        if (!prefs.getBoolean(KEY_ACTIVE, false)) {
            prefs.edit()
                .putBoolean(KEY_ACTIVE, true)
                .putInt(KEY_PREV_RINGER, am.ringerMode)
                .putInt(KEY_PREV_FILTER, nm.currentInterruptionFilter)
                .commit()
        }

        if (nm.isNotificationPolicyAccessGranted) {
            return try {
                am.ringerMode = AudioManager.RINGER_MODE_SILENT
                // "Total silence": blocks calls, messages, every app's notifications, alarms and
                // vibration, including contacts and apps the user allowed through Do Not Disturb.
                nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE)
                SILENT
            } catch (e: Exception) {
                Log.w(TAG, "Total silence failed, falling back to vibrate", e)
                vibrateOnly(am)
            }
        }
        return vibrateOnly(am)
    }

    private fun vibrateOnly(am: AudioManager): String = try {
        am.ringerMode = AudioManager.RINGER_MODE_VIBRATE
        VIBRATE
    } catch (e: Exception) {
        Log.w(TAG, "Cannot change ringer mode", e)
        FAILED
    }

    @Synchronized
    fun restore(context: Context) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ACTIVE, false)) return
        val am = app.getSystemService(AudioManager::class.java)
        val nm = app.getSystemService(NotificationManager::class.java)
        val prevRinger = prefs.getInt(KEY_PREV_RINGER, AudioManager.RINGER_MODE_NORMAL)
        val prevFilter = prefs.getInt(KEY_PREV_FILTER, NotificationManager.INTERRUPTION_FILTER_ALL)

        try {
            if (nm != null && nm.isNotificationPolicyAccessGranted) {
                val filter =
                    if (prevFilter == NotificationManager.INTERRUPTION_FILTER_UNKNOWN) NotificationManager.INTERRUPTION_FILTER_ALL
                    else prevFilter
                nm.setInterruptionFilter(filter)
            }
            am?.ringerMode = prevRinger
        } catch (e: Exception) {
            Log.w(TAG, "Could not fully restore sound settings", e)
        }
        prefs.edit().clear().commit()
    }
}
