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
 * It uses the default Firestore instance without changing its settings. This is only safe
 * because the Dart side also leaves Firestore settings at their defaults on Android (see
 * AuthService.initialize). Firestore's settings are fixed by whoever touches it first; if Dart
 * ever sets custom settings again, every Dart Firestore call fails with "FirebaseFirestore has
 * already been started and its settings can no longer be changed" once this service is running.
 */
class GuardianAlertService : Service() {
    companion object {
        private const val TAG = "WG/GuardianService"
        private const val PROTECTION_NOTIFICATION_ID = 7301
        const val ALERT_NOTIFICATION_ID = 7302
        private const val PREFS = "woman_guard_guardian_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_PROTECTING = "protecting"
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

        /**
         * Whether this user protects at least one person (an accepted guardian request addressed to
         * them). Unknown counts as true, so the service starts once and verifies it from the server.
         */
        fun setProtecting(context: Context, protecting: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_PROTECTING, protecting).apply()
        }

        fun isProtecting(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_PROTECTING, true)

        /** Runs only for a signed-in user who protects someone (also used at boot). */
        fun start(context: Context): Boolean {
            if (!isEnabled(context) || !isProtecting(context)) return false
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
    private val rideRegistrations = mutableListOf<ListenerRegistration>()
    private val notifiedRideKeys = mutableSetOf<String>()
    private val docsBySource = mutableMapOf<String, List<DocumentSnapshot>>()
    private var listeningUid: String? = null
    private var listeningEmail: String = ""
    private var requestsRegistration: ListenerRegistration? = null
    private var presentedAlertId: String? = null
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
        if (!isEnabled(this) || !isProtecting(this)) {
            Log.i(TAG, "Guardian alerts disabled, signed out or protecting nobody; stopping")
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

    private fun buildProtectionNotification(protectedCount: Int = 0) =
        NotificationCompat.Builder(this, NotificationChannels.GUARDIAN_PROTECTION)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Woman Guard is active for your protected contacts")
            .setContentText(
                if (protectedCount > 0) "You will be alerted if any of the $protectedCount people you protect needs help"
                else "You will be alerted if someone you protect needs help"
            )
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

        val rides = FirebaseFirestore.getInstance().collection("ride_checkins")
        rideRegistrations += rides.whereArrayContains("guardianIds", user.uid)
            .addSnapshotListener { snap, err -> onRideSnapshot("uid", snap, err) }
        if (listeningEmail.isNotEmpty()) {
            rideRegistrations += rides.whereArrayContains("guardianEmails", listeningEmail)
                .addSnapshotListener { snap, err -> onRideSnapshot("email", snap, err) }
        }

        // Accepted guardian requests addressed to this user = the people they protect. Accepting
        // always records the receiver's uid, so one query covers email-addressed requests too.
        requestsRegistration = FirebaseFirestore.getInstance().collection("connection_requests")
            .whereEqualTo("receiverId", user.uid)
            .addSnapshotListener { snap, err -> onProtectedPeople(snap, err) }
    }

    private fun onProtectedPeople(snapshot: QuerySnapshot?, error: Exception?) {
        if (error != null) {
            Log.w(TAG, "Protected-people listener error (keeping service running)", error)
            return
        }
        // Only trust the server: a cold cache could look empty.
        if (snapshot == null || snapshot.metadata.isFromCache) return
        val uid = listeningUid ?: return
        val count = snapshot.documents.count { doc ->
            str(doc, "status") == "accepted" && (str(doc, "senderId") ?: str(doc, "sender_uid")) != uid
        }
        if (count == 0) {
            Log.i(TAG, "User protects nobody; stopping guardian service")
            setProtecting(this, false)
            stop(this)
            return
        }
        setProtecting(this, true)
        try {
            NotificationManagerCompat.from(this).notify(PROTECTION_NOTIFICATION_ID, buildProtectionNotification(count))
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not update protection notification", e)
        }
    }

    private fun detachListeners() {
        registrations.forEach { it.remove() }
        registrations.clear()
        rideRegistrations.forEach { it.remove() }
        rideRegistrations.clear()
        docsBySource.clear()
        requestsRegistration?.remove()
        requestsRegistration = null
    }

    private fun onRideSnapshot(source: String, snapshot: QuerySnapshot?, error: Exception?) {
        if (error != null) {
            Log.w(TAG, "Ride check-in listener ($source) error", error)
            return
        }
        if (snapshot == null || snapshot.metadata.isFromCache) return
        val uid = listeningUid ?: return
        val now = System.currentTimeMillis()

        for (doc in snapshot.documents) {
            try {
                val rideId = doc.id
                val senderId = str(doc, "userId")
                if (senderId == uid) continue // Skip own rides

                val status = str(doc, "status")?.lowercase() ?: ""
                val travelerName = str(doc, "userName") ?: "Traveler"
                val rideType = str(doc, "rideType") ?: "Ride"
                val plate = str(doc, "plateFormatted") ?: "Vehicle Plate"

                val time = when (val raw = doc.get("lastUpdatedAt") ?: doc.get("createdAt")) {
                    is Timestamp -> raw.toDate().time
                    is Date -> raw.time
                    else -> now
                }
                // Do not notify for stale rides (older than 2 hours)
                if (kotlin.math.abs(now - time) > 2 * 60 * 60 * 1000L && status != "active") continue

                val key = "${rideId}_$status"
                if (notifiedRideKeys.contains(key)) continue
                notifiedRideKeys.add(key)

                // If this is an initial cold snapshot and the ride is not active and older than 10 mins, don't spam
                if (status != "active" && kotlin.math.abs(now - time) > 10 * 60 * 1000L) continue

                val notifId = (rideId.hashCode() and 0x7FFFFFFF) % 100000 + 8000
                val title: String
                val body: String

                when (status) {
                    "active" -> {
                        title = "🚗 $travelerName started a $rideType ride — $plate"
                        body = "Vehicle: $plate. Tap to view live location & driver details."
                    }
                    "arrived" -> {
                        title = "✅ $travelerName arrived safely"
                        body = "The ride in vehicle $plate has completed safely."
                    }
                    "overdue" -> {
                        title = "⚠️ Ride Overdue: $travelerName"
                        body = "Ride in vehicle $plate is overdue by 10+ minutes."
                    }
                    else -> continue
                }

                presentRideNotification(notifId, rideId, title, body)
            } catch (e: Exception) {
                Log.e(TAG, "Error processing ride check-in notification", e)
            }
        }
    }

    private fun presentRideNotification(notifId: Int, rideId: String, title: String, body: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("ride_id", rideId)
            putExtra("action", "VIEW_RIDE")
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            notifId,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(this, NotificationChannels.RIDE_ALERTS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setDefaults(NotificationCompat.DEFAULT_SOUND or NotificationCompat.DEFAULT_VIBRATE or NotificationCompat.DEFAULT_LIGHTS)
            .build()

        try {
            NotificationManagerCompat.from(this).notify(notifId, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification permission not granted for ride alert", e)
        }
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
            if (presentedAlertId == ringing) presentedAlertId = null
        }

        // The siren may already be silenced; the alert notification must still go once the alert
        // is resolved, acknowledged or dismissed.
        val presented = presentedAlertId
        if (presented != null && eligible.none { it.id == presented } &&
            (all.any { it.id == presented } || allSourcesReported)
        ) {
            Log.i(TAG, "Alert $presented no longer active; removing its notification")
            NotificationManagerCompat.from(this).cancel(ALERT_NOTIFICATION_ID)
            presentedAlertId = null
        }

        // Cached data may be stale (e.g. right after boot, offline); only ring on server data.
        if (fromCache) return

        // One ring per ring key (alertId#ringSeq): the same alert rings again only when the sender
        // deliberately presses SOS again.
        val fresh = eligible.filter { !AlertRegistry.isClaimed(this, ringKey(it)) }
        if (fresh.isEmpty()) return
        val latest = fresh.maxByOrNull { alertTimeMillis(it) ?: now } ?: return
        val claimedLatest = AlertRegistry.tryClaim(this, ringKey(latest))
        // Older alerts from the same burst must not ring later on their own.
        fresh.filter { it.id != latest.id }.forEach { AlertRegistry.tryClaim(this, ringKey(it)) }
        if (!claimedLatest) {
            Log.i(TAG, "Alert ${ringKey(latest)} already handled by the app UI")
            return
        }
        presentAlert(latest)
    }

    /** Ring key shared with the Dart listener: alert ID plus ring sequence (missing = 0). */
    private fun ringKey(doc: DocumentSnapshot): String {
        val seq = when (val raw = doc.get("ringSeq")) {
            is Number -> raw.toLong()
            is String -> raw.toLongOrNull() ?: 0L
            else -> 0L
        }
        return "${doc.id}#$seq"
    }

    /** Same rules as NotificationService.sosAlertTimeIfEligible on the Dart side. */
    private fun isEligible(doc: DocumentSnapshot, uid: String, now: Long): Boolean {
        if (str(doc, "status")?.lowercase() != "active") return false
        val senderId = str(doc, "senderId") ?: str(doc, "sender_uid")
        if (senderId == uid) return false
        if (stringList(doc.get("dismissedBy")).contains(uid)) return false
        if (stringList(doc.get("acknowledgedBy")).contains(uid)) return false
        val expiresAt = when (val raw = doc.get("expiresAt")) {
            is Timestamp -> raw.toDate().time
            is Date -> raw.time
            is Number -> raw.toLong()
            else -> null
        }
        if (expiresAt != null && expiresAt < now) return false
        val time = alertTimeMillis(doc) ?: return false
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
        presentedAlertId = alertId

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
            .addAction(0, "Dismiss", dismissIntent(alertId, 6))
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

    /** "Dismiss": silences, removes the notification and records dismissedBy, even with the app closed. */
    private fun dismissIntent(alertId: String, slot: Int): PendingIntent = PendingIntent.getBroadcast(
        this,
        ALERT_NOTIFICATION_ID * 10 + slot,
        Intent(this, AlertActionReceiver::class.java)
            .setAction(AlertActionReceiver.ACTION_DISMISS)
            .putExtra(AlertActionReceiver.EXTRA_ALERT_ID, alertId),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun stopSirenIntent(slot: Int): PendingIntent = PendingIntent.getBroadcast(
        this,
        ALERT_NOTIFICATION_ID * 10 + slot,
        Intent(this, AlertActionReceiver::class.java).setAction(AlertActionReceiver.ACTION_STOP_SIREN),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}
