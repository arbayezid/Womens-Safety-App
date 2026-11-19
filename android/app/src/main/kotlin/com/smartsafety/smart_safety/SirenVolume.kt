package com.smartsafety.smart_safety

import android.content.Context
import android.media.AudioManager
import android.util.Log

/**
 * Turns the ALARM stream up to its maximum while the app's own Loud Siren plays, whatever the
 * user had set, and puts the previous level back when the siren stops.
 */
object SirenVolume {
    private const val TAG = "WG/SirenVolume"

    private var restoreLevel: Int? = null

    @Synchronized
    fun raise(context: Context): Boolean {
        val am = context.applicationContext.getSystemService(AudioManager::class.java) ?: return false
        return try {
            val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            val current = am.getStreamVolume(AudioManager.STREAM_ALARM)
            if (current < max) {
                if (restoreLevel == null) restoreLevel = current
                am.setStreamVolume(AudioManager.STREAM_ALARM, max, 0)
            }
            true
        } catch (e: SecurityException) {
            // Some Do Not Disturb configurations forbid volume changes; play at the current level.
            Log.w(TAG, "Alarm volume not adjustable", e)
            false
        }
    }

    @Synchronized
    fun restore(context: Context) {
        val level = restoreLevel ?: return
        restoreLevel = null
        val am = context.applicationContext.getSystemService(AudioManager::class.java) ?: return
        try {
            am.setStreamVolume(AudioManager.STREAM_ALARM, level, 0)
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not restore alarm volume", e)
        }
    }
}
