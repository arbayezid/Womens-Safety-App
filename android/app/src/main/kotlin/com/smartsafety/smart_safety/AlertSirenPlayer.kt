package com.smartsafety.smart_safety

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.PowerManager
import android.util.Log
import kotlin.math.roundToInt

/**
 * Loops the bundled siren on the ALARM stream, which keeps sounding in silent and vibrate mode,
 * until [stop] is called (alert opened, dismissed, or "Stop siren" tapped).
 */
object AlertSirenPlayer {
    private const val TAG = "WG/AlertSiren"

    private var player: MediaPlayer? = null
    private var restoreAlarmVolume: Int? = null
    private var focusRequest: AudioFocusRequest? = null
    private val legacyFocusListener = AudioManager.OnAudioFocusChangeListener { }

    /** Alert currently ringing, or null. */
    @Volatile
    var currentAlertId: String? = null
        private set

    private val alarmAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    @Synchronized
    fun start(context: Context, alertId: String) {
        val app = context.applicationContext
        if (player != null) {
            currentAlertId = alertId
            return
        }
        val audioManager = app.getSystemService(AudioManager::class.java)
        raiseAlarmVolume(audioManager)
        requestFocus(audioManager)
        try {
            val mp = MediaPlayer()
            mp.setAudioAttributes(alarmAttributes)
            app.resources.openRawResourceFd(R.raw.siren).use { afd ->
                mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            }
            mp.isLooping = true
            mp.setWakeMode(app, PowerManager.PARTIAL_WAKE_LOCK)
            mp.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "Siren playback error what=$what extra=$extra")
                stop(app)
                true
            }
            mp.prepare()
            mp.start()
            player = mp
            currentAlertId = alertId
            Log.i(TAG, "Siren started for alert $alertId")
        } catch (e: Exception) {
            Log.e(TAG, "Could not start siren", e)
            releaseAudio(audioManager)
        }
    }

    @Synchronized
    fun stop(context: Context) {
        val mp = player ?: return
        player = null
        Log.i(TAG, "Siren stopped for alert $currentAlertId")
        currentAlertId = null
        try {
            mp.stop()
        } catch (_: IllegalStateException) {
        }
        mp.release()
        releaseAudio(context.applicationContext.getSystemService(AudioManager::class.java))
    }

    private fun raiseAlarmVolume(audioManager: AudioManager?) {
        audioManager ?: return
        try {
            val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            val current = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
            val target = (max * 0.8).roundToInt().coerceAtLeast(1)
            if (current < target) {
                restoreAlarmVolume = current
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, target, 0)
            }
        } catch (e: SecurityException) {
            // Some Do Not Disturb configurations forbid volume changes; play at the current level.
            Log.w(TAG, "Alarm volume not adjustable", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(audioManager: AudioManager?) {
        audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(alarmAttributes)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            audioManager.requestAudioFocus(legacyFocusListener, AudioManager.STREAM_ALARM, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
    }

    @Suppress("DEPRECATION")
    private fun releaseAudio(audioManager: AudioManager?) {
        audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            audioManager.abandonAudioFocus(legacyFocusListener)
        }
        restoreAlarmVolume?.let {
            try {
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, it, 0)
            } catch (_: SecurityException) {
            }
        }
        restoreAlarmVolume = null
    }
}
