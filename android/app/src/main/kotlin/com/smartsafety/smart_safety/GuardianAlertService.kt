package com.smartsafety.smart_safety

import android.Manifest
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.QuerySnapshot
import java.util.Date

/**
 * Receives SOS alerts while the app is in the background, swiped away, or the screen is locked.
 *
 * There is no server on the Spark plan to send FCM pushes, so this foreground service keeps a
 * Firestore listener open on `sos_alerts` with the same two queries and eligibility rules as
 * NotificationService.startSosAlertStreamListener. New alerts get a high-priority full-screen
 * notification and a looping siren on the alarm stream.
 *
 * It uses the default Firestore instance without changing its settings; the Flutter plugin
 * applies default settings too, so both share one instance safely.
 */
class GuardianAlertService : Service() {
    companion object {
        private const val TAG = "WG/GuardianService"
        private const val PROTECTION_NOTIFICATION_ID = 7301
        const val ALERT_NOTIFICATION_ID = 7302
        private const val PREFS = "woman_guard_guardian_service"
        private const val KEY_ENABLED = "enabled"
        private const val STALE_ALERT_MS = 3 * 60 * 60 * 1000L
        private const val REATTACH_DELAY_MS = 15_000L

        @Volatile
        var isRunning = false
            private set

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, enabled).apply()
        }

        /** Enabled by the app after sign-in, disabled on sign-out; also requires a Firebase session. */
        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ENABLED, false) &&
                FirebaseAuth.getInstance().currentUser != null

        fun start(context: Context): Boolean {
            if (!isEnabled(context)) return false
            return try {
                ContextCompat.startForegroundService(context, Intent(context, GuardianAlertService::class.java))
                true
            } catch (e: Exception) {
                // Android 12+ refuses foreground-service starts from the background; the app restarts it on next open.
                Log.w(TAG, "Could not start guardian service", e)
                false
            }
        }

        fun stop(context: Context) {
            AlertSirenPlayer.stop(context)
            NotificationManagerCompat.from(context).cancel(ALERT_NOTIFICATION_ID)
            context.stopService(Intent(context, GuardianAlertService::class.java))
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val registrations = mutableListOf<ListenerRegistration>()
    private val docsBySource = mutableMapOf<String, List<DocumentSnapshot>>()
    private var listeningUid: String? = null
    private var listeningEmail: String = ""
    private var authListenerAdded = false
    private val reattach = Runnable { attachListenersForCurrentUser(force = true) }

    private val authListener = FirebaseAuth.AuthStateListener { auth ->
        if (auth.currentUser == null) {
            Log.i(TAG, "Signed out; stopping guardian service")
            stop(this)
        } else if (auth.currentUser?.uid != listeningUid) {
            attachListenersForCurrentUser(force = true)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        NotificationChannels.ensureCreated(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground() must run on every start command before the service may stop itself,
        // otherwise Android crashes the app ("did not then call Service.startForeground()").
        if (!enterForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!isEnabled(this)) {
            Log.i(TAG, "Guardian alerts disabled or signed out; stopping")
            stopSelf()
            return START_NOT_STICKY
        }
        isRunning = true
        if (!authListenerAdded) {
            FirebaseAuth.getInstance().addAuthStateListener(authListener)
            authListenerAdded = true
        }
        attachListenersForCurrentUser(force = false)
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        handler.removeCallbacks(reattach)
        if (authListenerAdded) FirebaseAuth.getInstance().removeAuthStateListener(authListener)
        detachListeners()
        super.onDestroy()
    }

    private fun enterForeground(): Boolean = try {
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, PROTECTION_NOTIFICATION_ID, buildProtectionNotification(), type)
        true
    } catch (e: Exception) {
        Log.e(TAG, "startForeground failed", e)
        false
    }

    private fun buildProtectionNotification() =
        NotificationCompat.Builder(this, NotificationChannels.GUARDIAN_PROTECTION)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Woman Guard is protecting you")
            .setContentText("Ready to receive emergency alerts from your contacts")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    PROTECTION_NOTIFICATION_ID,
                    Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
            .build()

    private fun attachListenersForCurrentUser(force: Boolean) {
        val user = FirebaseAuth.getInstance().currentUser ?: return
        if (!force && listeningUid == user.uid && registrations.isNotEmpty()) return
        detachListeners()
        listeningUid = user.uid
        listeningEmail = user.email?.lowercase()?.trim().orEmpty()
        Log.i(TAG, "Listening for SOS alerts addressed to ${user.uid}")

        val alerts = FirebaseFirestore.getInstance().collection("sos_alerts")
        registrations += alerts.whereArrayContains("recipientUids", user.uid)
            .addSnapshotListener { snap, err -> onSnapshot("uid", snap, err) }
        if (listeningEmail.isNotEmpty()) {
            registrations += alerts.whereArrayContains("recipientEmails", listeningEmail)
                .addSnapshotListener { snap, err -> onSnapshot("email", snap, err) }
        }
    }

    private fun detachListeners() {
        registrations.forEach { it.remove() }
        registrations.clear()
        docsBySource.clear()
    }

    private fun onSnapshot(source: String, snapshot: QuerySnapshot?, error: Exception?) {
        if (error != null) {
            Log.w(TAG, "Alert listener ($source) error, retrying", error)
            handler.removeCallbacks(reattach)
            handler.postDelayed(reattach, REATTACH_DELAY_MS)
            return
        }
        snapshot ?: return
        docsBySource[source] = snapshot.documents
        try {
            evaluate(fromCache = snapshot.metadata.isFromCache)
        } catch (e: Exception) {
            // Unexpected alert data must never take the service (and the app process) down.
            Log.e(TAG, "Failed to process SOS alerts", e)
        }
    }

    /** Type-tolerant field read: DocumentSnapshot.getString() throws on non-string values. */
    private fun str(doc: DocumentSnapshot, field: String): String? = doc.get(field)?.toString()

    private fun evaluate(fromCache: Boolean) {
        val uid = listeningUid ?: return
        val now = System.currentTimeMillis()
        val all = docsBySource.values.flatten().distinctBy { it.id }
        val eligible = all.filter { isEligible(it, uid, now) }

        // The ringing alert was resolved, dismissed or acknowledged elsewhere: silence it. While a
        // query is still (re)connecting, absence from the results proves nothing.
        val ringing = AlertSirenPlayer.currentAlertId
        val allSourcesReported = docsBySource.size >= registrations.size
        val ringingDoc = all.firstOrNull { it.id == ringing }
        val ringingEnded = ringing != null && eligible.none { it.id == ringing } &&
            (ringingDoc != null || allSourcesReported)
        if (ringingEnded) {
            Log.i(TAG, "Alert $ringing no longer active; stopping siren")
            AlertSirenPlayer.stop(this)
            NotificationManagerCompat.from(this).cancel(ALERT_NOTIFICATION_ID)
        }

        // Cached data may be stale (e.g. right after boot, offline); only ring on server data.
        if (fromCache) return

        val fresh = eligible.filter { !AlertRegistry.isClaimed(this, it.id) }
        if (fresh.isEmpty()) return
        val latest = fresh.maxByOrNull { alertTimeMillis(it) ?: now } ?: return
        val claimedLatest = AlertRegistry.tryClaim(this, latest.id)
        // Older alerts from the same burst must not ring later on their own.
        fresh.filter { it.id != latest.id }.forEach { AlertRegistry.tryClaim(this, it.id) }
        if (!claimedLatest) {
            Log.i(TAG, "Alert ${latest.id} already handled by the app UI")
            return
        }
        presentAlert(latest)
    }

    private fun isEligible(doc: DocumentSnapshot, uid: String, now: Long): Boolean {
        if (str(doc, "status")?.lowercase() != "active") return false
        val senderId = str(doc, "senderId") ?: str(doc, "sender_uid")
        if (senderId == uid) return false
        if (stringList(doc.get("dismissedBy")).contains(uid)) return false
        if (stringList(doc.get("acknowledgedBy")).contains(uid)) return false
        val time = alertTimeMillis(doc) ?: now
        return kotlin.math.abs(now - time) <= STALE_ALERT_MS
    }

    private fun stringList(value: Any?): List<String> = (value as? List<*>)?.map { it.toString() } ?: emptyList()

    private fun alertTimeMillis(doc: DocumentSnapshot): Long? {
        return when (val raw = doc.get("triggeredAt") ?: doc.get("timestamp")) {
            is Timestamp -> raw.toDate().time
            is Date -> raw.time
            is Number -> raw.toLong()
            is String -> raw.toLongOrNull() ?: try {
                java.time.OffsetDateTime.parse(raw).toInstant().toEpochMilli()
            } catch (_: Exception) {
                try {
                    java.time.LocalDateTime.parse(raw).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
                } catch (_: Exception) {
                    null
                }
            }
            else -> null
        }
    }

    private fun presentAlert(doc: DocumentSnapshot) {
        val alertId = doc.id
        val location = doc.get("location") as? Map<*, *>
        val senderName = (str(doc, "senderName") ?: str(doc, "sender_name"))
            ?.takeIf { it.isNotBlank() } ?: "Emergency Contact"
        val message = (doc.get("message") ?: doc.get("note"))?.toString()
            ?.takeIf { it.isNotBlank() } ?: "Emergency SOS Alert triggered!"
        val latitude = number(doc.get("latitude")) ?: number(doc.get("lat")) ?: number(location?.get("latitude"))
        val longitude = number(doc.get("longitude")) ?: number(doc.get("lng")) ?: number(location?.get("longitude"))
        val mapsUrl = (str(doc, "google_maps_url") ?: location?.get("googleMapsUrl")?.toString())
            ?.takeIf { it.isNotBlank() }
            ?: if (latitude != null && longitude != null) "https://maps.google.com/?q=$latitude,$longitude" else null
        val address = (location?.get("address") ?: doc.get("address"))?.toString()?.takeIf { it.isNotBlank() }

        Log.i(TAG, "🚨 Incoming SOS $alertId from $senderName")
        AlertSirenPlayer.start(this, alertId)

        val details = buildString {
            append(message)
            if (address != null) append("\n📍 ").append(address)
            append("\nLocation: ").append(mapsUrl ?: "unavailable")
        }

        val builder = NotificationCompat.Builder(this, NotificationChannels.GUARDIAN_ALERTS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("🚨 SOS ALERT: $senderName needs help!")
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(details))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(0xFFFF3B30.toInt())
            .setVibrate(longArrayOf(0, 1000, 500, 1000, 500, 1000))
            .setAutoCancel(true)
            .setContentIntent(alertActivityIntent(alertId, MainActivity.SOURCE_TAP, 1))
            .setFullScreenIntent(alertActivityIntent(alertId, MainActivity.SOURCE_FULL_SCREEN, 2), true)
            .setDeleteIntent(stopSirenIntent(3))
            .addAction(0, "Stop siren", stopSirenIntent(4))
        if (mapsUrl != null) {
            val mapIntent = Intent(Intent.ACTION_VIEW, Uri.parse(mapsUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.addAction(
                0,
                "Open map",
                PendingIntent.getActivity(this, ALERT_NOTIFICATION_ID * 10 + 5, mapIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        }

        val canPost = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!canPost) {
            Log.w(TAG, "Notification permission denied; alert $alertId is siren-only")
            return
        }
        try {
            NotificationManagerCompat.from(this).notify(ALERT_NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            Log.e(TAG, "Could not post alert notification", e)
        }
    }

    private fun number(value: Any?): Double? = when (value) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

    private fun alertActivityIntent(alertId: String, source: String, slot: Int): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_ALERT_ID, alertId)
            .putExtra(MainActivity.EXTRA_ALERT_SOURCE, source)
        return PendingIntent.getActivity(
            this,
            ALERT_NOTIFICATION_ID * 10 + slot,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun stopSirenIntent(slot: Int): PendingIntent = PendingIntent.getBroadcast(
        this,
        ALERT_NOTIFICATION_ID * 10 + slot,
        Intent(this, AlertActionReceiver::class.java).setAction(AlertActionReceiver.ACTION_STOP_SIREN),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}
