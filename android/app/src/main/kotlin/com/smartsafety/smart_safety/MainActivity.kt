package com.smartsafety.smart_safety

import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "WG/MainActivity"

        const val EXTRA_ALERT_ID = "guardian_alert_id"
        const val EXTRA_ALERT_SOURCE = "guardian_alert_source"
        const val SOURCE_TAP = "tap"
        const val SOURCE_FULL_SCREEN = "full_screen"

        private const val DEVICE_CHANNEL = "com.smartsafety.smart_safety/device"
        private const val GUARDIAN_CHANNEL = "com.smartsafety.smart_safety/guardian"
        private const val SMS_CHANNEL = "com.smartsafety.smart_safety/sms"
        private const val FAKE_CALL_CHANNEL = "com.smartsafety.smart_safety/fake_call"

        @Volatile
        private var resumedActivity: WeakReference<Activity>? = null

        /** The visible activity, or null when the app is in the background. */
        fun foregroundActivity(): Activity? = resumedActivity?.get()
    }

    private var fakeCallAudio: FakeCallAudio? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        handleAlertIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAlertIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        resumedActivity = WeakReference(this)
    }

    override fun onPause() {
        if (resumedActivity?.get() === this) resumedActivity = null
        super.onPause()
    }

    override fun onStop() {
        super.onStop()
        // Only an incoming alert may show the app above the lock screen, and only while it is visible.
        setShowOverLockScreen(false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Runs before any Dart code, so the channels exist before a foreground service can start.
        NotificationChannels.ensureCreated(this)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "getManufacturer" -> result.success(Build.MANUFACTURER ?: "")
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, GUARDIAN_CHANNEL).setMethodCallHandler(::onGuardianCall)
        MethodChannel(messenger, SMS_CHANNEL).setMethodCallHandler(::onSmsCall)

        val audio = FakeCallAudio(applicationContext)
        fakeCallAudio = audio
        MethodChannel(messenger, FAKE_CALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRinging" -> result.success(audio.startRinging())
                "startConversation" -> audio.startConversation(
                    assetPath = call.argument<String>("assetPath") ?: "",
                    script = call.argument<List<String>>("script") ?: emptyList(),
                ) { mode -> runOnUiThread { result.success(mode) } }
                "stop" -> {
                    audio.stopAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        fakeCallAudio?.stopAll()
        fakeCallAudio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun onGuardianCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                GuardianAlertService.setEnabled(this, true)
                result.success(GuardianAlertService.start(this))
            }
            "stop" -> {
                GuardianAlertService.setEnabled(this, false)
                GuardianAlertService.stop(this)
                result.success(null)
            }
            "isRunning" -> result.success(GuardianAlertService.isRunning)
            "claimAlert" -> result.success(AlertRegistry.tryClaim(this, call.argument<String>("alertId") ?: ""))
            "stopSiren" -> {
                AlertSirenPlayer.stop(this)
                result.success(null)
            }
            "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
            "openFullScreenIntentSettings" -> result.success(openFullScreenIntentSettings())
            else -> result.notImplemented()
        }
    }

    private fun onSmsCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sendSms" -> {
                val recipients = call.argument<List<String>>("recipients") ?: emptyList()
                val message = call.argument<String>("message") ?: ""
                val timeoutMs = (call.argument<Number>("timeoutMs") ?: 20000).toLong()
                SmsSender.sendAsync(applicationContext, recipients, message, timeoutMs) { results ->
                    runOnUiThread { result.success(results) }
                }
            }
            "openComposer" -> {
                val recipients = call.argument<List<String>>("recipients") ?: emptyList()
                val message = call.argument<String>("message") ?: ""
                result.success(SmsSender.openComposer(applicationContext, recipients, message))
            }
            else -> result.notImplemented()
        }
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        return getSystemService(NotificationManager::class.java)?.canUseFullScreenIntent() ?: false
    }

    private fun openFullScreenIntentSettings(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        return try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "Full-screen intent settings unavailable", e)
            false
        }
    }

    /**
     * Launched from a guardian alert notification. A tap counts as "opening" the alert and silences
     * the siren; a full-screen launch over the lock screen keeps it sounding until the user reacts.
     */
    private fun handleAlertIntent(intent: Intent?) {
        val alertId = intent?.getStringExtra(EXTRA_ALERT_ID) ?: return
        setShowOverLockScreen(true)
        if (intent.getStringExtra(EXTRA_ALERT_SOURCE) == SOURCE_TAP) {
            Log.i(TAG, "Alert $alertId opened from notification; stopping siren")
            AlertSirenPlayer.stop(this)
        }
        // Consume the extra so a configuration change or later resume does not replay it.
        intent.removeExtra(EXTRA_ALERT_ID)
    }

    private fun setShowOverLockScreen(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(enabled)
            setTurnScreenOn(enabled)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (enabled) window.addFlags(flags) else window.clearFlags(flags)
        }
    }
}
