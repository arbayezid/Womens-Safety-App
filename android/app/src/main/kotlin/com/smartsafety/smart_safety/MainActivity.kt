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
        const val EXTRA_JOURNEY_ID = "journey_id"
        /** Opens the in-app notification inbox (bell), e.g. from a late/missed alert notification. */
        const val EXTRA_OPEN_INBOX = "open_inbox"

        private const val GUARDIAN_CHANNEL = "com.smartsafety.smart_safety/guardian"
        private const val FAKE_CALL_CHANNEL = "com.smartsafety.smart_safety/fake_call"

        @Volatile
        private var resumedActivity: WeakReference<Activity>? = null

        @Volatile
        var pendingRideId: String? = null

        /** Safe Journey opened from its notification before the Flutter engine was ready. */
        @Volatile
        var pendingJourneyId: String? = null

        /** Alert opened from its notification before the Flutter engine was ready. */
        @Volatile
        var pendingAlertId: String? = null

        /** Inbox requested from a notification before the Flutter engine was ready. */
        @Volatile
        var pendingOpenInbox: Boolean = false

        /** The visible activity, or null when the app is in the background. */
        fun foregroundActivity(): Activity? = resumedActivity?.get()
    }

    private var fakeCallAudio: FakeCallAudio? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        handleAlertIntent(intent)
        handleRideIntent(intent)
        handleJourneyIntent(intent)
        handleInboxIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAlertIntent(intent)
        handleRideIntent(intent)
        handleJourneyIntent(intent)
        handleInboxIntent(intent)
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
        // Device + SMS handlers are shared with the headless engine that runs safety deadlines.
        AppChannels.registerShared(messenger, this)
        AppChannels.registerDeadline(messenger, this)
        DeadlineDartRunner.mainMessenger = messenger
        MethodChannel(messenger, GUARDIAN_CHANNEL).setMethodCallHandler(::onGuardianCall)
        // Keeps the app's siren button in step with the native alert siren (e.g. its 2-minute end).
        AlertSirenPlayer.stateListener = { playing ->
            DeadlineDartRunner.mainMessenger?.let {
                MethodChannel(it, GUARDIAN_CHANNEL).invokeMethod("onSirenStateChanged", playing)
            }
        }

        val audio = FakeCallAudio(applicationContext)
        fakeCallAudio = audio
        MethodChannel(messenger, FAKE_CALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRinging" -> result.success(audio.startRinging())
                "startConversation" -> audio.startConversation(
                    assetPath = call.argument<String>("assetPath") ?: "",
                    script = call.argument<List<String>>("script") ?: emptyList(),
                    filePath = call.argument<String>("filePath") ?: "",
                    loopGapMs = (call.argument<Number>("loopGapMs") ?: 0).toLong(),
                    speaker = call.argument<Boolean>("speaker") ?: true,
                ) { mode -> runOnUiThread { result.success(mode) } }
                "setSpeaker" -> {
                    audio.setSpeaker(call.argument<Boolean>("speaker") ?: true)
                    result.success(null)
                }
                "stop" -> {
                    audio.stopAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (DeadlineDartRunner.mainMessenger === flutterEngine.dartExecutor.binaryMessenger) {
            DeadlineDartRunner.mainMessenger = null
        }
        fakeCallAudio?.stopAll()
        fakeCallAudio = null
        AlertSirenPlayer.stateListener = null
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
            "setProtecting" -> {
                val protecting = call.argument<Boolean>("value") ?: true
                GuardianAlertService.setProtecting(this, protecting)
                if (protecting) GuardianAlertService.start(this) else GuardianAlertService.stop(this)
                result.success(null)
            }
            "isRunning" -> result.success(GuardianAlertService.isRunning)
            "claimAlert" -> result.success(AlertRegistry.tryClaim(this, call.argument<String>("alertId") ?: ""))
            "stopSiren" -> {
                AlertSirenPlayer.stop(this)
                result.success(null)
            }
            // Incoming live alert while the app is open: same alarm-stream siren, 2-minute cap.
            "startAlertSiren" -> {
                val alertId = call.argument<String>("alertId") ?: ""
                if (alertId.isNotEmpty()) AlertSirenPlayer.start(this, alertId)
                result.success(AlertSirenPlayer.isPlaying)
            }
            "stopAlertSiren" -> {
                AlertSirenPlayer.stopIfAlert(this, call.argument<String>("alertId") ?: "")
                result.success(null)
            }
            "isSirenPlaying" -> result.success(AlertSirenPlayer.isPlaying)
            "getPendingOpenInbox" -> {
                val open = pendingOpenInbox
                pendingOpenInbox = false
                result.success(open)
            }
            "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
            "openFullScreenIntentSettings" -> result.success(openFullScreenIntentSettings())
            "getPendingRideId" -> {
                val id = pendingRideId
                pendingRideId = null
                result.success(id)
            }
            "getPendingJourneyId" -> {
                val id = pendingJourneyId
                pendingJourneyId = null
                result.success(id)
            }
            "getPendingAlertId" -> {
                val id = pendingAlertId
                pendingAlertId = null
                result.success(id)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleRideIntent(intent: Intent?) {
        val rideId = intent?.getStringExtra("ride_id") ?: return
        pendingRideId = rideId
        DeadlineDartRunner.mainMessenger?.let {
            MethodChannel(it, GUARDIAN_CHANNEL).invokeMethod("onRideTapped", rideId)
        }
        intent.removeExtra("ride_id")
    }

    private fun handleJourneyIntent(intent: Intent?) {
        val journeyId = intent?.getStringExtra(EXTRA_JOURNEY_ID) ?: return
        pendingJourneyId = journeyId
        DeadlineDartRunner.mainMessenger?.let {
            MethodChannel(it, GUARDIAN_CHANNEL).invokeMethod("onJourneyTapped", journeyId)
        }
        intent.removeExtra(EXTRA_JOURNEY_ID)
    }

    private fun handleInboxIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN_INBOX, false) != true) return
        val messenger = DeadlineDartRunner.mainMessenger
        if (messenger != null) {
            MethodChannel(messenger, GUARDIAN_CHANNEL).invokeMethod("onOpenInbox", null)
        } else {
            pendingOpenInbox = true
        }
        intent.removeExtra(EXTRA_OPEN_INBOX)
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
        // Let Dart open the alert silently (no siren from the dialog). Before the engine is ready
        // the ID waits for GuardianAlertService (Dart) to ask for it.
        val messenger = DeadlineDartRunner.mainMessenger
        if (messenger != null) {
            MethodChannel(messenger, GUARDIAN_CHANNEL).invokeMethod("onAlertOpened", alertId)
        } else {
            pendingAlertId = alertId
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
