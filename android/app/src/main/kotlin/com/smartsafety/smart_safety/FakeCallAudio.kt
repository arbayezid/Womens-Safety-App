package com.smartsafety.smart_safety

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
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
 * silent and vibrate mode, plus vibration. Conversation: the user's own recording or a bundled voice
 * clip if present, otherwise on-device text-to-speech, on the media stream through the loudspeaker
 * at an audible volume (default), or through the earpiece after [setSpeaker] (false).
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

    /** A recorded clip: an asset ([assetPath]) or a local file ([filePath]). */
    private data class VoiceClip(val assetPath: String, val filePath: String, val loopGapMs: Long)

    /** Clip of the current conversation, so it can be restarted on the other output route. */
    private var currentClip: VoiceClip? = null
    private var currentScript: List<String> = emptyList()

    /** Loudspeaker (default, the original behaviour) or earpiece. */
    private var speakerOn = true

    /** Audio mode before the earpiece switched to communication mode; null when not switched. */
    private var savedAudioMode: Int? = null

    private val ringAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private val speechAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** Earpiece output: a voice-call style stream, routed to the receiver in communication mode. */
    private val earpieceAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    private fun voiceAttributes() = if (speakerOn) speechAttributes else earpieceAttributes

    private fun voiceStream() = if (speakerOn) AudioManager.STREAM_MUSIC else AudioManager.STREAM_VOICE_CALL

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
     * Stops ringing and starts the "other side" of the call: the local recording [filePath] if
     * given, else the clip [assetPath], else text-to-speech of [script]. Reports "file", "asset",
     * "tts" or "unavailable" through [onResult] (exactly once).
     *
     * [loopGapMs] > 0 replays a clip after that much silence; 0 loops it seamlessly (original
     * behaviour). [speaker] false starts on the earpiece.
     */
    fun startConversation(
        assetPath: String,
        script: List<String>,
        filePath: String = "",
        loopGapMs: Long = 0,
        speaker: Boolean = true,
        onResult: (String) -> Unit,
    ) {
        stopRinging()
        val current = ++session
        speakerOn = speaker
        applyRoute()
        ensureVolume(voiceStream())
        requestFocus(voiceAttributes(), voiceStream())
        currentScript = script

        val report = onceCallback { mode ->
            pendingResult = null
            Log.i(TAG, "Conversation audio mode: $mode")
            onResult(mode)
        }
        pendingResult = report

        if (filePath.isNotEmpty() && playVoice(VoiceClip("", filePath, loopGapMs), current, 0, report)) return
        if (assetPath.isNotEmpty() && playVoice(VoiceClip(assetPath, "", loopGapMs), current, 0, report)) return
        if (script.isEmpty()) {
            report("unavailable")
            return
        }
        startTts(listOf(null, GOOGLE_TTS, SAMSUNG_TTS), 0, current, script, report)
    }

    /**
     * Moves the caller's voice to the loudspeaker ([on] true) or the earpiece. A clip continues
     * from the same position; text-to-speech restarts its script on the new output.
     */
    fun setSpeaker(on: Boolean) {
        if (speakerOn == on) return
        speakerOn = on
        val current = session
        applyRoute()
        ensureVolume(voiceStream())
        requestFocus(voiceAttributes(), voiceStream())

        val player = voicePlayer
        val clip = currentClip
        if (player != null && clip != null) {
            val position = try {
                if (player.isPlaying) player.currentPosition else 0
            } catch (_: IllegalStateException) {
                0
            }
            voicePlayer = null
            try {
                player.stop()
            } catch (_: IllegalStateException) {
            }
            player.release()
            playVoice(clip, current, position) { }
        }

        tts?.let { engine ->
            engine.setAudioAttributes(voiceAttributes())
            engine.stop()
            queueScript(engine, currentScript)
        }
        Log.i(TAG, "Voice output: ${if (on) "speaker" else "earpiece"}")
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
        currentClip = null
        tts?.let {
            it.stop()
            it.shutdown()
        }
        tts = null
        handler.removeCallbacksAndMessages(null)
        releaseFocus()
        leaveCommunicationMode()
        speakerOn = true
        restoreVolumes()
    }

    /** Earpiece needs communication mode with the receiver selected; speaker is the normal mode. */
    @Suppress("DEPRECATION")
    private fun applyRoute() {
        val am = audioManager ?: return
        if (speakerOn) {
            leaveCommunicationMode()
            return
        }
        try {
            if (savedAudioMode == null) savedAudioMode = am.mode
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val earpiece = am.availableCommunicationDevices
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                if (earpiece != null) am.setCommunicationDevice(earpiece)
            } else {
                am.isSpeakerphoneOn = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not route to earpiece", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun leaveCommunicationMode() {
        val am = audioManager ?: return
        val previous = savedAudioMode ?: return
        savedAudioMode = null
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) am.clearCommunicationDevice()
            am.mode = previous
        } catch (e: Exception) {
            Log.w(TAG, "Could not restore audio mode", e)
        }
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

    /** Plays [clip] from [startAtMs]; returns false (nothing playing) if it cannot be opened. */
    private fun playVoice(
        clip: VoiceClip,
        current: Int,
        startAtMs: Int,
        onResult: (String) -> Unit,
    ): Boolean {
        val label = if (clip.filePath.isNotEmpty()) "recording ${clip.filePath}" else "clip ${clip.assetPath}"
        var player: MediaPlayer? = null
        return try {
            val mp = MediaPlayer()
            player = mp
            mp.setAudioAttributes(voiceAttributes())
            if (clip.filePath.isNotEmpty()) {
                mp.setDataSource(clip.filePath)
            } else {
                val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(clip.assetPath)
                context.assets.openFd(key).use { afd ->
                    mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                }
            }
            if (clip.loopGapMs <= 0) {
                mp.isLooping = true
            } else {
                // Replay after a pause, like a caller who waits for an answer, instead of a hard loop.
                mp.setOnCompletionListener { done ->
                    handler.postDelayed({
                        if (current == session && voicePlayer === done) {
                            try {
                                done.seekTo(0)
                                done.start()
                            } catch (e: IllegalStateException) {
                                Log.w(TAG, "Clip replay failed", e)
                            }
                        }
                    }, clip.loopGapMs)
                }
            }
            mp.setOnErrorListener { failed, what, extra ->
                Log.e(TAG, "Voice $label playback error what=$what extra=$extra; switching to text-to-speech")
                failed.release()
                if (voicePlayer === failed) {
                    voicePlayer = null
                    currentClip = null
                }
                if (current == session) startTts(listOf(null, GOOGLE_TTS, SAMSUNG_TTS), 0, current, currentScript) { }
                true
            }
            mp.prepare()
            if (startAtMs > 0) mp.seekTo(startAtMs)
            mp.setVolume(1f, 1f)
            mp.start()
            voicePlayer = mp
            currentClip = clip
            Log.i(TAG, "Playing conversation $label")
            onResult(if (clip.filePath.isNotEmpty()) "file" else "asset")
            true
        } catch (e: java.io.FileNotFoundException) {
            player?.release()
            Log.i(TAG, "No conversation $label; using the next voice source")
            false
        } catch (e: Exception) {
            player?.release()
            Log.e(TAG, "Conversation $label failed; using the next voice source", e)
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
        engine.setAudioAttributes(voiceAttributes())
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
