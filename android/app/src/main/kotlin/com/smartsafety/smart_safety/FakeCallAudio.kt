package com.smartsafety.smart_safety

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.FlutterInjector
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Audio for the Fake Call screen.
 *
 * Ringing: the device ringtone (or a ring tone fallback) on the ALARM stream, so it is heard in
 * silent and vibrate mode, plus vibration. Conversation: a bundled voice clip if present, otherwise
 * on-device text-to-speech, on the media stream through the loudspeaker at an audible volume.
 */
class FakeCallAudio(private val context: Context) {
    companion object {
        private const val TAG = "WG/FakeCallAudio"
        private const val PAUSE_BETWEEN_LINES_MS = 3000L
        private const val TTS_START_TIMEOUT_MS = 6000L
        private const val GOOGLE_TTS = "com.google.android.tts"
        private const val SAMSUNG_TTS = "com.samsung.SMT"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)

    /** Incremented on every start/stop so late callbacks of an ended call are ignored. */
    private var session = 0
    private var ringtone: Ringtone? = null
    private var toneGenerator: ToneGenerator? = null
    private var vibrator: Vibrator? = null
    private var voicePlayer: MediaPlayer? = null
    private var tts: TextToSpeech? = null
    private var focusRequest: AudioFocusRequest? = null
    private val legacyFocusListener = AudioManager.OnAudioFocusChangeListener { }
    private val restoreVolumes = mutableMapOf<Int, Int>()

    /** Result callback of a conversation that has not reported its mode yet. */
    private var pendingResult: ((String) -> Unit)? = null

    private val ringAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private val speechAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** Returns "ringtone", "tone" or "failed". */
    fun startRinging(): String {
        stopAll()
        session++
        ensureVolume(AudioManager.STREAM_ALARM)
        requestFocus(ringAttributes, AudioManager.STREAM_ALARM)
        startVibration()

        val uri = RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE)
        if (uri != null) {
            try {
                val tone = RingtoneManager.getRingtone(context, uri)
                if (tone != null) {
                    tone.audioAttributes = ringAttributes
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) tone.isLooping = true
                    tone.play()
                    ringtone = tone
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) keepRingtoneLooping(session)
                    Log.i(TAG, "Ringing with device ringtone")
                    return "ringtone"
                }
            } catch (e: Exception) {
                Log.w(TAG, "Device ringtone unavailable, using ring tone", e)
            }
        }
        return try {
            toneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100).also {
                it.startTone(ToneGenerator.TONE_SUP_RINGTONE)
            }
            Log.i(TAG, "Ringing with generated ring tone")
            "tone"
        } catch (e: Exception) {
            Log.e(TAG, "No ringing sound available", e)
            "failed"
        }
    }

    /**
     * Stops ringing and starts the "other side" of the call. Reports "asset", "tts" or
     * "unavailable" through [onResult] (exactly once).
     */
    fun startConversation(assetPath: String, script: List<String>, onResult: (String) -> Unit) {
        stopRinging()
        val current = ++session
        ensureVolume(AudioManager.STREAM_MUSIC)
        requestFocus(speechAttributes, AudioManager.STREAM_MUSIC)

        val report = onceCallback { mode ->
            pendingResult = null
            Log.i(TAG, "Conversation audio mode: $mode")
            onResult(mode)
        }
        pendingResult = report

        if (assetPath.isNotEmpty() && playVoiceAsset(assetPath, current, script, report)) return
        if (script.isEmpty()) {
            report("unavailable")
            return
        }
        startTts(listOf(null, GOOGLE_TTS, SAMSUNG_TTS), 0, current, script, report)
    }

    fun stopAll() {
        pendingResult?.invoke("stopped")
        session++
        stopRinging()
        voicePlayer?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        voicePlayer = null
        tts?.let {
            it.stop()
            it.shutdown()
        }
        tts = null
        handler.removeCallbacksAndMessages(null)
        releaseFocus()
        restoreVolumes()
    }

    private fun stopRinging() {
        ringtone?.stop()
        ringtone = null
        toneGenerator?.let {
            it.stopTone()
            it.release()
        }
        toneGenerator = null
        vibrator?.cancel()
        vibrator = null
    }

    private fun keepRingtoneLooping(ringSession: Int) {
        handler.postDelayed({
            val tone = ringtone ?: return@postDelayed
            if (ringSession != session) return@postDelayed
            if (!tone.isPlaying) tone.play()
            keepRingtoneLooping(ringSession)
        }, 1000)
    }

    @Suppress("DEPRECATION")
    private fun startVibration() {
        val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            context.getSystemService(Vibrator::class.java)
        } ?: return
        if (!v.hasVibrator()) return
        val pattern = longArrayOf(0, 1000, 1000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            v.vibrate(VibrationEffect.createWaveform(pattern, 0), ringAttributes)
        } else {
            v.vibrate(pattern, 0, ringAttributes)
        }
        vibrator = v
    }

    private fun playVoiceAsset(
        assetPath: String,
        current: Int,
        script: List<String>,
        onResult: (String) -> Unit,
    ): Boolean {
        return try {
            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetPath)
            val player = MediaPlayer()
            player.setAudioAttributes(speechAttributes)
            context.assets.openFd(key).use { afd ->
                player.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            }
            player.isLooping = true
            player.setOnErrorListener { mp, what, extra ->
                Log.e(TAG, "Voice clip playback error what=$what extra=$extra; switching to text-to-speech")
                mp.release()
                if (voicePlayer === mp) voicePlayer = null
                if (current == session) startTts(listOf(null, GOOGLE_TTS, SAMSUNG_TTS), 0, current, script) { }
                true
            }
            player.prepare()
            player.setVolume(1f, 1f)
            player.start()
            voicePlayer = player
            Log.i(TAG, "Playing conversation clip $assetPath")
            onResult("asset")
            true
        } catch (e: java.io.FileNotFoundException) {
            Log.i(TAG, "No bundled conversation clip ($assetPath); using text-to-speech")
            false
        } catch (e: Exception) {
            Log.e(TAG, "Conversation clip failed; using text-to-speech", e)
            false
        }
    }

    private fun onceCallback(onResult: (String) -> Unit): (String) -> Unit {
        var delivered = false
        return { mode ->
            if (!delivered) {
                delivered = true
                onResult(mode)
            }
        }
    }

    /** Tries each engine in turn (default first): Samsung's engine often has no voice data installed. */
    private fun startTts(
        engines: List<String?>,
        index: Int,
        current: Int,
        script: List<String>,
        onResult: (String) -> Unit,
    ) {
        if (current != session) return
        if (index >= engines.size) {
            Log.e(TAG, "No usable text-to-speech engine with an English voice")
            onResult("unavailable")
            return
        }
        val engine = engines[index]
        var instance: TextToSpeech? = null
        val listener = TextToSpeech.OnInitListener { status ->
            handler.post {
                val engineInstance = instance ?: return@post
                if (current != session) {
                    engineInstance.shutdown()
                    return@post
                }
                if (status != TextToSpeech.SUCCESS || !selectEnglishVoice(engineInstance)) {
                    Log.w(TAG, "TTS engine ${engine ?: "default"} unusable (status=$status)")
                    engineInstance.shutdown()
                    startTts(engines, index + 1, current, script, onResult)
                    return@post
                }
                Log.i(TAG, "Speaking conversation with TTS engine ${engineInstance.defaultEngine}")
                tts = engineInstance
                speakScript(engineInstance, current, script, onResult)
            }
        }
        instance = try {
            if (engine == null) TextToSpeech(context, listener) else TextToSpeech(context, listener, engine)
        } catch (e: Exception) {
            Log.w(TAG, "TTS engine ${engine ?: "default"} failed to bind", e)
            null
        }
        if (instance == null) startTts(engines, index + 1, current, script, onResult)
    }

    private fun selectEnglishVoice(engine: TextToSpeech): Boolean {
        for (locale in listOf(Locale.US, Locale.UK, Locale.ENGLISH)) {
            val availability = engine.isLanguageAvailable(locale)
            if (availability == TextToSpeech.LANG_MISSING_DATA || availability == TextToSpeech.LANG_NOT_SUPPORTED) continue
            val result = engine.setLanguage(locale)
            if (result != TextToSpeech.LANG_MISSING_DATA && result != TextToSpeech.LANG_NOT_SUPPORTED) return true
        }
        return false
    }

    private fun speakScript(engine: TextToSpeech, current: Int, script: List<String>, onResult: (String) -> Unit) {
        engine.setAudioAttributes(speechAttributes)
        engine.setSpeechRate(0.95f)
        val lastId = "line_${script.size - 1}"
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                handler.post { onResult("tts") }
            }

            override fun onDone(utteranceId: String?) {
                // Repeat the script so the call never goes quiet while it is on screen.
                if (utteranceId == lastId) handler.post { if (current == session) queueScript(engine, script) }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                Log.e(TAG, "TTS error for $utteranceId")
                handler.post { onResult("unavailable") }
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                Log.e(TAG, "TTS error $errorCode for $utteranceId")
                handler.post { onResult("unavailable") }
            }
        })
        queueScript(engine, script)
        // Engine accepted the text but never started (e.g. voice download pending): report it.
        handler.postDelayed({ if (current == session) onResult("unavailable") }, TTS_START_TIMEOUT_MS)
    }

    private fun queueScript(engine: TextToSpeech, script: List<String>) {
        script.forEachIndexed { i, line ->
            engine.speak(line, TextToSpeech.QUEUE_ADD, null, "line_$i")
            engine.playSilentUtterance(PAUSE_BETWEEN_LINES_MS, TextToSpeech.QUEUE_ADD, "pause_$i")
        }
    }

    /** Raises a stream to an audible level for the call; the user's level is restored afterwards. */
    private fun ensureVolume(stream: Int) {
        val am = audioManager ?: return
        try {
            val max = am.getStreamMaxVolume(stream)
            val current = am.getStreamVolume(stream)
            val target = (max * 0.7).roundToInt().coerceAtLeast(1)
            if (current < target) {
                if (!restoreVolumes.containsKey(stream)) restoreVolumes[stream] = current
                am.setStreamVolume(stream, target, 0)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Volume of stream $stream not adjustable", e)
        }
    }

    private fun restoreVolumes() {
        val am = audioManager ?: return
        restoreVolumes.forEach { (stream, volume) ->
            try {
                am.setStreamVolume(stream, volume, 0)
            } catch (_: SecurityException) {
            }
        }
        restoreVolumes.clear()
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(attributes: AudioAttributes, legacyStream: Int) {
        val am = audioManager ?: return
        releaseFocus()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .build()
            focusRequest = request
            am.requestAudioFocus(request)
        } else {
            am.requestAudioFocus(legacyFocusListener, legacyStream, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
    }

    @Suppress("DEPRECATION")
    private fun releaseFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            am.abandonAudioFocus(legacyFocusListener)
        }
    }
}
