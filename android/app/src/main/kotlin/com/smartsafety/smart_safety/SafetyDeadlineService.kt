package com.smartsafety.smart_safety

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore

/**
 * Short-lived foreground service started by a deadline alarm. Keeps the process alive while the
 * existing Dart pipeline prompts the user or escalates (SMS + cloud SOS + guardian alert), then
 * stops itself. Started from an exact-alarm callback, which Android allows from the background.
 */
class SafetyDeadlineService : Service() {
    companion object {
        private const val TAG = "WG/DeadlineService"
        private const val NOTIFICATION_ID = 7303
        private const val FAILURE_NOTIFICATION_ID = 7304
        private const val JOB_TIMEOUT_MS = 4 * 60_000L
        private const val VALIDATE_TIMEOUT_MS = 10_000L
        private const val EARLY_TOLERANCE_MS = 5_000L

        fun start(context: Context, id: String): Boolean = try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, SafetyDeadlineService::class.java).putExtra(SafetyDeadlineReceiver.EXTRA_ID, id),
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "Could not start deadline service", e)
            false
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val jobs = mutableSetOf<String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!enterForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra(SafetyDeadlineReceiver.EXTRA_ID)
        if (id == null || id in jobs) {
            stopIfIdle()
            return START_NOT_STICKY
        }
        jobs += id
        handler.postDelayed({ finish(id) }, JOB_TIMEOUT_MS)
        process(id)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        DeadlineDartRunner.destroyHeadless()
        super.onDestroy()
    }

    private fun enterForeground(): Boolean = try {
        NotificationChannels.ensureCreated(this)
        val notification = NotificationCompat.Builder(this, NotificationChannels.GUARDIAN_PROTECTION)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Woman Guard safety check")
            .setContentText("Checking an active safety timer")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        true
    } catch (e: Exception) {
        Log.e(TAG, "startForeground failed", e)
        false
    }

    private fun process(id: String) {
        val d = SafetyDeadlines.get(this, id) ?: return finish(id)
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null || (d.uid.isNotEmpty() && user.uid != d.uid)) {
            Log.i(TAG, "Deadline $id belongs to a signed-out account; clearing")
            SafetyDeadlines.clear(this, id)
            return finish(id)
        }
        val now = System.currentTimeMillis()
        when (d.state) {
            SafetyDeadlines.STATE_FIRED -> finish(id)
            SafetyDeadlines.STATE_ARMED -> {
                if (now < d.fireAt - EARLY_TOLERANCE_MS) {
                    SafetyDeadlines.schedule(this, id, d.fireAt)
                    finish(id)
                } else if (d.direct) {
                    escalate(d)
                } else {
                    validateStillActive(d) { active -> if (active) prompt(d) else finish(id) }
                }
            }
            SafetyDeadlines.STATE_PROMPTING -> {
                if (now < d.escalateAt - EARLY_TOLERANCE_MS) {
                    SafetyDeadlines.schedule(this, id, d.escalateAt)
                    finish(id)
                } else {
                    escalate(d)
                }
            }
            else -> finish(id)
        }
    }

    /** Journey/ride checks are only shown while the journey or ride is still running. */
    private fun validateStillActive(d: SafetyDeadlines.Deadline, onResult: (Boolean) -> Unit) {
        val (collection, okStates) = when (d.kind) {
            "journey" -> "journeys" to setOf("active")
            "ride" -> "ride_checkins" to setOf("active", "overdue")
            else -> return onResult(true)
        }
        var answered = false
        val answer = { active: Boolean ->
            if (!answered) {
                answered = true
                if (!active) {
                    Log.i(TAG, "${d.id}: ${d.kind} ${d.refId} is no longer running; clearing")
                    SafetyDeadlines.clear(this, d.id)
                }
                onResult(active)
            }
        }
        // Offline or slow: err on the side of safety and ask the user.
        handler.postDelayed({ answer(true) }, VALIDATE_TIMEOUT_MS)
        FirebaseFirestore.getInstance().collection(collection).document(d.refId).get()
            .addOnSuccessListener { snap ->
                val status = snap.getString("status")
                answer(!snap.exists() || status == null || status in okStates)
            }
            .addOnFailureListener { answer(true) }
    }

    private fun prompt(d: SafetyDeadlines.Deadline) {
        val showNative = {
            val current = SafetyDeadlines.get(this, d.id)
            if (current != null && current.state == SafetyDeadlines.STATE_ARMED) {
                SafetyDeadlines.prompt(this, d.id, System.currentTimeMillis() + d.promptSeconds * 1000L, byApp = false)
                SafetyDeadlines.postPromptNotification(this, current)
            }
        }
        // The live app shows its own in-app check; ride checks also need Dart for the overdue SMS.
        if (DeadlineDartRunner.mainMessenger != null || d.kind == "ride") {
            DeadlineDartRunner.run(this, "deadlinePrompt", d.toArgs()) { result ->
                if (result != "prompted" && result != "none") showNative()
                finish(d.id)
            }
        } else {
            showNative()
            finish(d.id)
        }
    }

    private fun escalate(d: SafetyDeadlines.Deadline) {
        if (d.attempts >= SafetyDeadlines.MAX_ATTEMPTS) {
            Log.e(TAG, "Escalation for ${d.id} failed ${d.attempts} times; giving up")
            SafetyDeadlines.clear(this, d.id)
            postFailureNotification()
            return finish(d.id)
        }
        SafetyDeadlines.markAttempt(this, d.id)
        Log.i(TAG, "Escalating ${d.id} through the app's SOS pipeline")
        DeadlineDartRunner.run(this, "deadlineFired", d.toArgs()) { result ->
            Log.i(TAG, "Escalation ${d.id} result: $result")
            finish(d.id)
        }
    }

    private fun postFailureNotification() {
        val open = PendingIntent.getActivity(
            this, FAILURE_NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(this, NotificationChannels.SAFETY_CHECKS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Automatic SOS could not be sent")
            .setContentText("Open Woman Guard and press SOS if you need help.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(this).notify(FAILURE_NOTIFICATION_ID, n) }
    }

    private fun finish(id: String) {
        if (jobs.remove(id)) stopIfIdle()
    }

    private fun stopIfIdle() {
        if (jobs.isNotEmpty()) return
        DeadlineDartRunner.destroyHeadless()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
}
