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
import android.os.PowerManager
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
import com.google.firebase.firestore.MetadataChanges
import com.google.firebase.firestore.QuerySnapshot
import com.google.firebase.firestore.Source
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
        private const val MISSED_NOTIFICATION_ID = 7303
        /**
         * An active alert (re)pressed at most this long ago is live: full-screen alert + siren.
         * Older active alerts and ended ones only get an ordinary notification and the inbox.
         * Same window as sosLiveWindow in notification_service.dart; keep the two in step.
         */
        private const val LIVE_ALERT_MS = 30 * 60 * 1000L
        /** Not-live alerts this old or newer that never rang here are reported once. */
        private const val MISSED_ALERT_WINDOW_MS = 24 * 60 * 60 * 1000L
        /** Longest the CPU is kept awake for listeners to catch up with the server. */
        private const val SYNC_WAKE_MS = 30_000L
        /** Retry delay after the service was killed or the app swiped away. */
        private const val RESTART_DELAY_MS = 60_000L
        /**
         * An active SOS with no location update for this long: the sender's phone has gone quiet
         * (switched off, taken, out of network). The sender writes at least every 2 minutes.
         * Same as sosSignalLostAfter in signal_lost_banner.dart; keep the two in step.
         */
        private const val SIGNAL_LOST_MS = 4 * 60 * 1000L
        /** Next try when this phone could not reach the server to confirm the silence. */
        private const val SIGNAL_RETRY_MS = 2 * 60 * 1000L
        /** Longest the CPU is kept awake for the server check. */
        private const val SIGNAL_WAKE_MS = 20_000L
        private const val SIGNAL_NOTIFICATION_BASE = 7400
        private const val TAG_SIGNAL_LOST = "sos_signal_lost"
        private const val TAG_SIGNAL_BACK = "sos_signal_back"

        /**
         * Signal-check alarm: confirm with the server which active alerts went quiet. A killed
         * service is restarted instead; its first server snapshot runs the same check.
         */
        fun onSignalCheckTick(context: Context) {
            val service = instance
            if (service != null && isRunning) {
                service.checkSilentAlerts()
            } else {
                context.getSystemService(PowerManager::class.java)
                    ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WomanGuard:GuardianRestart")
                    ?.acquire(15_000L)
                start(context)
            }
        }

        @Volatile
        var isRunning = false
            private set

        @Volatile
        private var instance: GuardianAlertService? = null

        /**
         * Watchdog alarm: restart the service if it was killed, otherwise reconnect it. Runs on the
         * main thread inside the alarm's onReceive, so the work starts before the alarm's wake lock
         * ends; from there the service keeps the CPU awake itself.
         */
        fun onWatchdogTick(context: Context) {
            val service = instance
            if (service != null && isRunning) {
                service.refreshConnection()
            } else {
                Log.i(TAG, "Watchdog: guardian service not running; restarting")
                // Bridge until the restarted service takes its own wake lock in onStartCommand.
                context.getSystemService(PowerManager::class.java)
                    ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WomanGuard:GuardianRestart")
                    ?.acquire(15_000L)
                start(context)
            }
        }

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
            GuardianWatchdogReceiver.cancel(context)
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

    /** Names of the attached SOS alert listeners ("uid", "email"). */
    private val alertSources = mutableListOf<String>()
    /** Alert listeners that have not yet delivered server data since the last (re)connect. */
    private val pendingSync = mutableSetOf<String>()
    private var syncWakeLock: PowerManager.WakeLock? = null
    private var signalWakeLock: PowerManager.WakeLock? = null
    /** Alerts with a signal-lost notification posted by this service instance (pre-API 23 fallback). */
    private val signalLostShown = mutableSetOf<String>()
    private var signalCheckRunning = false

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
        instance = this
        GuardianWatchdogReceiver.schedule(this)
        if (!authListenerAdded) {
            FirebaseAuth.getInstance().addAuthStateListener(authListener)
            authListenerAdded = true
        }
        attachListenersForCurrentUser(force = false)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Some vendors kill the whole process shortly after the app is swiped away.
        if (isEnabled(this) && isProtecting(this)) GuardianWatchdogReceiver.schedule(this, RESTART_DELAY_MS)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        if (instance === this) instance = null
        handler.removeCallbacks(reattach)
        if (authListenerAdded) FirebaseAuth.getInstance().removeAuthStateListener(authListener)
        detachListeners()
        releaseSyncWakeLock()
        signalWakeLock?.let { if (it.isHeld) it.release() }
        // Destroyed while still wanted (killed by the system, not signed out / stopped): come back soon.
        if (isEnabled(this) && isProtecting(this)) GuardianWatchdogReceiver.schedule(this, RESTART_DELAY_MS)
        super.onDestroy()
    }

    /**
     * Forces a fresh Firestore connection. While the screen is off the CPU sleeps, so the
     * connection's keep-alives stop and the network silently drops it; Firestore then waits for
     * data that never comes. Reconnecting resumes every listener and delivers what was missed.
     */
    private fun refreshConnection() {
        if (listeningUid == null || registrations.isEmpty()) {
            attachListenersForCurrentUser(force = true)
            return
        }
        // In use and healthy while the app is on screen; never disturb a ringing alert.
        if (MainActivity.foregroundActivity() != null || AlertSirenPlayer.currentAlertId != null) return
        Log.i(TAG, "Watchdog: reconnecting to Firestore")
        holdAwakeUntilSynced()
        val db = FirebaseFirestore.getInstance()
        db.disableNetwork()
            .continueWithTask { db.enableNetwork() }
            .addOnFailureListener { e ->
                Log.w(TAG, "Firestore reconnect failed", e)
                releaseSyncWakeLock()
            }
    }

    /** Keeps the CPU awake (at most [SYNC_WAKE_MS]) until every alert listener has server data. */
    private fun holdAwakeUntilSynced() {
        pendingSync.clear()
        pendingSync.addAll(alertSources)
        if (pendingSync.isEmpty()) return
        val lock = syncWakeLock
            ?: getSystemService(PowerManager::class.java)
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WomanGuard:GuardianSync")
                ?.apply { setReferenceCounted(false) }
                ?.also { syncWakeLock = it }
            ?: return
        lock.acquire(SYNC_WAKE_MS)
    }

    private fun releaseSyncWakeLock() {
        pendingSync.clear()
        syncWakeLock?.let { if (it.isHeld) it.release() }
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

        // Metadata changes included: the switch from cached to server data must be seen even when
        // no document changed, both to ring for alerts first seen in the cache and to know when a
        // reconnect has caught up.
        val alerts = FirebaseFirestore.getInstance().collection("sos_alerts")
        registrations += alerts.whereArrayContains("recipientUids", user.uid)
            .addSnapshotListener(MetadataChanges.INCLUDE) { snap, err -> onSnapshot("uid", snap, err) }
        alertSources += "uid"
        if (listeningEmail.isNotEmpty()) {
            registrations += alerts.whereArrayContains("recipientEmails", listeningEmail)
                .addSnapshotListener(MetadataChanges.INCLUDE) { snap, err -> onSnapshot("email", snap, err) }
            alertSources += "email"
        }
        holdAwakeUntilSynced()

        val rides = FirebaseFirestore.getInstance().collection("ride_checkins")
        rideRegistrations += rides.whereArrayContains("guardianIds", user.uid)
            .addSnapshotListener { snap, err -> onRideSnapshot("uid", snap, err) }
        if (listeningEmail.isNotEmpty()) {
            rideRegistrations += rides.whereArrayContains("guardianEmails", listeningEmail)
                .addSnapshotListener { snap, err -> onRideSnapshot("email", snap, err) }
        }

        val journeys = FirebaseFirestore.getInstance().collection("journeys")
        rideRegistrations += journeys.whereArrayContains("guardianUids", user.uid)
            .addSnapshotListener { snap, err -> onJourneySnapshot("uid", snap, err) }
        if (listeningEmail.isNotEmpty()) {
            rideRegistrations += journeys.whereArrayContains("guardianEmails", listeningEmail)
                .addSnapshotListener { snap, err -> onJourneySnapshot("email", snap, err) }
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
        alertSources.clear()
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

    /**
     * Safe Journey updates from people this user protects. Same rules as journeyGuardianEvent in
     * lib/services/journey_guardian_alerts.dart; keep the two in step. Each update is claimed in
     * AlertRegistry, which the in-app Dart listener shares, so it is shown once per device, also
     * across restarts.
     */
    private fun onJourneySnapshot(source: String, snapshot: QuerySnapshot?, error: Exception?) {
        if (error != null) {
            Log.w(TAG, "Journey listener ($source) error", error)
            return
        }
        if (snapshot == null || snapshot.metadata.isFromCache) return
        val uid = listeningUid ?: return
        val now = System.currentTimeMillis()
        for (doc in snapshot.documents) {
            try {
                val event = journeyEvent(doc, uid, now) ?: continue
                if (!AlertRegistry.tryClaim(this, event.first)) continue
                presentJourneyNotification(doc.id, event.second, event.third)
            } catch (e: Exception) {
                Log.e(TAG, "Error processing Safe Journey notification", e)
            }
        }
    }

    private fun millis(value: Any?): Long? = when (value) {
        is Timestamp -> value.toDate().time
        is Date -> value.time
        is Number -> value.toLong()
        else -> null
    }

    /** (claim key, title, body) for this journey, or null when there is nothing to tell. */
    private fun journeyEvent(doc: DocumentSnapshot, uid: String, now: Long): Triple<String, String, String>? {
        val ownerId = str(doc, "ownerId") ?: str(doc, "owner_uid") ?: return null
        if (ownerId == uid) return null
        val status = str(doc, "status")?.lowercase().orEmpty()
        val name = str(doc, "ownerName")?.trim()?.takeIf { it.isNotEmpty() } ?: "Your contact"
        val destination = doc.get("destination") as? Map<*, *>
        val destLabel = destination?.get("label")?.toString()?.trim()?.takeIf { it.isNotEmpty() } ?: "their destination"
        val followed = str(doc, "mode") == "followed"
        val startedAt = millis(doc.get("startedAt"))
        val updatedAt = millis(doc.get("lastUpdatedAt")) ?: startedAt
        fun within(t: Long?, windowMs: Long) = t != null && kotlin.math.abs(now - t) <= windowMs

        val key = "journey:${doc.id}_$status"
        return when (status) {
            "active" -> {
                if (!within(startedAt, 6 * 60 * 60 * 1000L)) return null
                if (followed) {
                    Triple(key, "⚠️ $name thinks they are being followed",
                        "They are sharing their live location with you. Tap to track them now.")
                } else {
                    val eta = millis(doc.get("expectedArrivalAt"))?.let {
                        " · ETA " + java.text.SimpleDateFormat("H:mm", java.util.Locale.getDefault()).format(Date(it))
                    }.orEmpty()
                    Triple(key, "🚶 $name started a Safe Journey",
                        "Heading to $destLabel$eta. Tap to follow their live location.")
                }
            }
            "arrived" -> {
                if (!within(updatedAt, 20 * 60 * 1000L)) return null
                Triple(key, if (followed) "✅ $name is safe" else "✅ $name arrived safely",
                    if (followed) "Followed Mode has ended." else "They reached $destLabel.")
            }
            "alert" -> {
                // Taken over by an SOS: the SOS alert itself already reached this guardian
                if (!str(doc, "linkedSosAlertId").isNullOrEmpty()) return null
                if (!within(updatedAt, 3 * 60 * 60 * 1000L)) return null
                Triple(key,
                    if (followed) "🚨 $name missed a Followed Mode check-in" else "🚨 $name's Safe Journey raised an alert",
                    "A safety check went unanswered. Tap to see their live location.")
            }
            "cancelled" -> {
                if (str(doc, "endReason") == "expired") return null
                if (!within(updatedAt, 20 * 60 * 1000L)) return null
                Triple(key, "$name ended their Safe Journey",
                    if (followed) "Followed Mode was turned off." else "Ended before reaching $destLabel.")
            }
            else -> null
        }
    }

    private fun presentJourneyNotification(journeyId: String, title: String, body: String) {
        // One notification per journey: "arrived" replaces "started".
        val notifId = 200000 + (journeyId.hashCode() and 0xFFFF)
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_JOURNEY_ID, journeyId)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            notifId,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(this, NotificationChannels.JOURNEY_ALERTS)
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
            Log.w(TAG, "Notification permission not granted for Safe Journey alert", e)
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
        val fromCache = snapshot.metadata.isFromCache
        try {
            evaluate(fromCache)
        } catch (e: Exception) {
            // Unexpected alert data must never take the service (and the app process) down.
            Log.e(TAG, "Failed to process SOS alerts", e)
        } finally {
            // Caught up with the server (the siren holds its own wake lock): let the CPU sleep again.
            if (!fromCache && pendingSync.remove(source) && pendingSync.isEmpty()) releaseSyncWakeLock()
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

        // Covers dismissed and acknowledged alerts too: a silent phone is new information.
        reviewSignals(all, uid, now)

        // Live alerts ring; everything else (ended, or still active but older than the live window)
        // only gets an ordinary notification, never the full-screen alert or the siren.
        val live = eligible.filter { now - lastRingMillis(it, now) <= LIVE_ALERT_MS }
        val liveIds = live.mapTo(mutableSetOf()) { it.id }
        notifyEarlierAlerts(all.filter { it.id !in liveIds }, uid, now)

        // One ring per ring key (alertId#ringSeq): the same alert rings again only when the sender
        // deliberately presses SOS again.
        val fresh = live.filter { !AlertRegistry.isClaimed(this, ringKey(it)) }
        if (fresh.isEmpty()) return
        val latest = fresh.maxByOrNull { lastRingMillis(it, now) } ?: return
        val claimedLatest = AlertRegistry.tryClaim(this, ringKey(latest))
        // Older alerts from the same burst must not ring later on their own.
        fresh.filter { it.id != latest.id }.forEach { AlertRegistry.tryClaim(this, ringKey(it)) }
        if (!claimedLatest) {
            Log.i(TAG, "Alert ${ringKey(latest)} already handled by the app UI")
            return
        }
        presentAlert(latest)
    }

    /**
     * Alerts that are no longer live when this phone first sees them: ended (resolved, expired)
     * or still active but pressed more than [LIVE_ALERT_MS] ago, e.g. because the phone was
     * offline or asleep. They must not ring, but the guardian still has to know. Each is reported
     * once with an ordinary notification; alerts that rang here, that the guardian dismissed or
     * answered, or that the sender marked as a false alarm are skipped.
     */
    private fun notifyEarlierAlerts(notLive: List<DocumentSnapshot>, uid: String, now: Long) {
        val missed = notLive.filter { doc ->
            val senderId = str(doc, "senderId") ?: str(doc, "sender_uid")
            if (senderId == uid) return@filter false
            if (doc.get("falseAlarm") == true || str(doc, "status")?.lowercase()?.startsWith("false") == true) {
                return@filter false
            }
            if (stringList(doc.get("dismissedBy")).contains(uid)) return@filter false
            if (acknowledgedCurrentRing(doc, uid)) return@filter false
            val time = alertTimeMillis(doc) ?: return@filter false
            if (now - time > MISSED_ALERT_WINDOW_MS || time - now > STALE_ALERT_MS) return@filter false
            !AlertRegistry.anyRingClaimed(this, doc.id) && !AlertRegistry.isClaimed(this, missedKey(doc.id))
        }
        val claimed = missed.filter { AlertRegistry.tryClaim(this, missedKey(it.id)) }
        if (claimed.isEmpty()) return
        presentEarlierAlerts(claimed.sortedByDescending { alertTimeMillis(it) ?: 0L }, uid, now)
    }

    private fun missedKey(alertId: String) = "missed:$alertId"

    private fun senderName(doc: DocumentSnapshot): String =
        (str(doc, "senderName") ?: str(doc, "sender_name"))?.takeIf { it.isNotBlank() } ?: "Your contact"

    private fun presentEarlierAlerts(docs: List<DocumentSnapshot>, uid: String, now: Long) {
        val format = java.text.SimpleDateFormat("MMM d, h:mm a", java.util.Locale.getDefault())
        fun sentAt(doc: DocumentSnapshot) = alertTimeMillis(doc)?.let { format.format(Date(it)) } ?: "earlier"
        fun stillActive(doc: DocumentSnapshot) = isEligible(doc, uid, now)
        Log.i(TAG, "Earlier SOS alerts (no longer live when they reached this phone): ${docs.map { it.id }}")

        val builder = NotificationCompat.Builder(this, NotificationChannels.MISSED_ALERTS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(0xFFFF3B30.toInt())
            .setAutoCancel(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    MISSED_NOTIFICATION_ID,
                    Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        .putExtra(MainActivity.EXTRA_OPEN_INBOX, true),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
        if (docs.size == 1) {
            val doc = docs.first()
            val location = doc.get("location") as? Map<*, *>
            val address = (location?.get("address") ?: doc.get("address"))?.toString()?.takeIf { it.isNotBlank() }
            val active = stillActive(doc)
            val body = if (active) {
                "Sent ${sentAt(doc)} and still active, but your phone received it late. " +
                    "Tap to see their live location."
            } else {
                "Sent ${sentAt(doc)}, but your phone could not receive it in time. " +
                    "The alert has ended. Check that they are safe."
            }
            builder.setContentTitle(
                if (active) "🚨 SOS from ${senderName(doc)} is still active" else "⚠️ Missed SOS from ${senderName(doc)}"
            )
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body + (address?.let { "\n📍 $it" } ?: "")))
        } else {
            val inbox = NotificationCompat.InboxStyle()
            docs.take(6).forEach {
                inbox.addLine("${senderName(it)} · ${sentAt(it)} · ${if (stillActive(it)) "still active" else "ended"}")
            }
            builder.setContentTitle("⚠️ ${docs.size} SOS alerts reached you late")
                .setContentText("Your phone could not receive them in time. Tap to see them all.")
                .setStyle(inbox)
        }
        if (!canPostNotifications()) {
            Log.w(TAG, "Notification permission denied; cannot report missed alerts")
            return
        }
        try {
            NotificationManagerCompat.from(this).notify(MISSED_NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            Log.e(TAG, "Could not post missed-alert notification", e)
        }
    }

    private fun canPostNotifications(): Boolean = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /** Ring key shared with the Dart listener: alert ID plus ring sequence (missing = 0). */
    private fun ringKey(doc: DocumentSnapshot): String {
        val seq = when (val raw = doc.get("ringSeq")) {
            is Number -> raw.toLong()
            is String -> raw.toLongOrNull() ?: 0L
            else -> 0L
        }
        return "${doc.id}#$seq"
    }

    /**
     * True when [uid] answered "I'm Responding" for the alert's current ring. `acknowledgedBy` is
     * never cleared, so an acknowledgement only covers rings up to its own time: a deliberate
     * re-press later (`ringAt` after my `acknowledgedAt`) rings again. Unknown acknowledgement time
     * with a re-ring present rings too (ring keys still stop repeats). Same rule as
     * NotificationService.acknowledgedCurrentRing on the Dart side.
     */
    private fun acknowledgedCurrentRing(doc: DocumentSnapshot, uid: String): Boolean {
        if (!stringList(doc.get("acknowledgedBy")).contains(uid)) return false
        val ringAt = millis(doc.get("ringAt")) ?: return true
        val ackAt = millis((doc.get("acknowledgedAt") as? Map<*, *>)?.get(uid)) ?: return false
        return ringAt <= ackAt
    }

    /** Same rules as NotificationService.sosAlertTimeIfEligible on the Dart side. */
    private fun isEligible(doc: DocumentSnapshot, uid: String, now: Long): Boolean {
        if (str(doc, "status")?.lowercase() != "active") return false
        val senderId = str(doc, "senderId") ?: str(doc, "sender_uid")
        if (senderId == uid) return false
        if (stringList(doc.get("dismissedBy")).contains(uid)) return false
        if (acknowledgedCurrentRing(doc, uid)) return false
        val expiresAt = when (val raw = doc.get("expiresAt")) {
            is Timestamp -> raw.toDate().time
            is Date -> raw.time
            is Number -> raw.toLong()
            else -> null
        }
        if (expiresAt != null && expiresAt < now) return false
        if (alertTimeMillis(doc) == null) return false
        return kotlin.math.abs(now - lastRingMillis(doc, now)) <= STALE_ALERT_MS
    }

    /**
     * When the alert last rang on purpose: its trigger time, or `ringAt` of the sender's latest
     * re-press if later. (Not lastUpdatedAt: live location updates move that every few seconds.)
     */
    private fun lastRingMillis(doc: DocumentSnapshot, now: Long): Long {
        val triggered = alertTimeMillis(doc) ?: now
        val rung = millis(doc.get("ringAt")) ?: return triggered
        return maxOf(triggered, rung)
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
        val source = str(doc, "source")?.takeIf { it.isNotBlank() }
        val origin = str(doc, "origin")
        // Lets guardians tell an unanswered automatic check from a button press
        val automaticLabel = if (origin == "automatic") {
            "Automatic alert: no response to a safety check" + (source?.let { " ($it)" } ?: "")
        } else null
        val baseMessage = (doc.get("message") ?: doc.get("note"))?.toString()
            ?.takeIf { it.isNotBlank() } ?: "Emergency SOS Alert triggered!"
        val message = if (automaticLabel != null) "$automaticLabel\n$baseMessage" else baseMessage
        val latitude = number(doc.get("latitude")) ?: number(doc.get("lat")) ?: number(location?.get("latitude"))
        val longitude = number(doc.get("longitude")) ?: number(doc.get("lng")) ?: number(location?.get("longitude"))
        val mapsUrl = (str(doc, "google_maps_url") ?: location?.get("googleMapsUrl")?.toString())
            ?.takeIf { it.isNotBlank() }
            ?: if (latitude != null && longitude != null) "https://maps.google.com/?q=$latitude,$longitude" else null
        val address = (location?.get("address") ?: doc.get("address"))?.toString()?.takeIf { it.isNotBlank() }

        Log.i(TAG, "🚨 Incoming SOS ${ringKey(doc)} from $senderName (source: $source, origin: $origin)")
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
            .setContentText(automaticLabel ?: message)
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

        if (!canPostNotifications()) {
            Log.w(TAG, "Notification permission denied; alert $alertId is siren-only")
            return
        }
        try {
            NotificationManagerCompat.from(this).notify(ALERT_NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            Log.e(TAG, "Could not post alert notification", e)
        }
    }

    // ── Signal lost: the sender's phone stopped reporting during an active SOS ──────────────────
    //
    // A phone that is switched off sends nothing, so no snapshot ever announces it. Instead an
    // alarm is armed for the moment each active alert would count as silent; when it fires the
    // alert is re-read from the server (this phone's own listener may be stale) and, if it is
    // still silent, the guardian is notified once per silence. Dismissing an alert only stops its
    // siren; this warning still comes.

    /** Active alert addressed to this guardian whose signal is worth watching. */
    private fun isSignalWatched(doc: DocumentSnapshot, uid: String, now: Long): Boolean {
        if (str(doc, "status")?.lowercase() != "active") return false
        val senderId = str(doc, "senderId") ?: str(doc, "sender_uid")
        if (senderId == uid) return false
        if (doc.get("falseAlarm") == true) return false
        val expiresAt = millis(doc.get("expiresAt"))
        if (expiresAt != null && expiresAt < now) return false
        return kotlin.math.abs(now - lastRingMillis(doc, now)) <= STALE_ALERT_MS
    }

    /** Last location write from the sender's phone, or the trigger time if tracking never wrote. */
    private fun lastSignalMillis(doc: DocumentSnapshot): Long? =
        millis(doc.get("liveUpdatedAt")) ?: alertTimeMillis(doc)

    /** One report per silence: a phone that comes back and goes quiet again is reported again. */
    private fun signalKey(alertId: String, lastSignal: Long) = "signal:$alertId:$lastSignal"

    private fun signalNotificationId(alertId: String) = SIGNAL_NOTIFICATION_BASE + (alertId.hashCode() and 0x3FF)

    private fun isSignalLostShown(alertId: String): Boolean {
        if (Build.VERSION.SDK_INT < 23) return alertId in signalLostShown
        val id = signalNotificationId(alertId)
        return getSystemService(android.app.NotificationManager::class.java)
            ?.activeNotifications?.any { it.tag == TAG_SIGNAL_LOST && it.id == id } == true
    }

    private fun isSilent(doc: DocumentSnapshot, uid: String, now: Long): Boolean {
        if (!isSignalWatched(doc, uid, now)) return false
        val last = lastSignalMillis(doc) ?: return false
        return now - last >= SIGNAL_LOST_MS && !AlertRegistry.isClaimed(this, signalKey(doc.id, last))
    }

    /** Earliest moment one of [docs] turns silent, or null when none is pending. */
    private fun nextSilenceDue(docs: List<DocumentSnapshot>, uid: String, now: Long): Long? =
        docs.filter { isSignalWatched(it, uid, now) }
            .mapNotNull { lastSignalMillis(it)?.plus(SIGNAL_LOST_MS) }
            .filter { it > now }
            .minOrNull()

    private fun armSignalCheck(at: Long?) {
        if (at == null) GuardianWatchdogReceiver.cancelSignalCheck(this)
        else GuardianWatchdogReceiver.scheduleSignalCheck(this, at)
    }

    /** Runs on every server snapshot: tidies earlier warnings and arms (or runs) the next check. */
    private fun reviewSignals(all: List<DocumentSnapshot>, uid: String, now: Long) {
        for (doc in all) {
            if (!isSignalLostShown(doc.id)) continue
            val last = lastSignalMillis(doc)
            when {
                !isSignalWatched(doc, uid, now) -> cancelSignalLost(doc.id) // alert ended
                last != null && now - last < SIGNAL_LOST_MS -> presentSignalBack(doc)
            }
        }
        if (all.any { isSilent(it, uid, now) }) checkSilentAlerts() else armSignalCheck(nextSilenceDue(all, uid, now))
    }

    /** Confirms with the server which watched alerts went quiet, and reports them. */
    fun checkSilentAlerts() {
        val uid = listeningUid ?: return
        if (signalCheckRunning) return
        val now = System.currentTimeMillis()
        val all = docsBySource.values.flatten().distinctBy { it.id }
        val suspects = all.filter { isSilent(it, uid, now) }
        if (suspects.isEmpty()) {
            armSignalCheck(nextSilenceDue(all, uid, now))
            return
        }

        signalCheckRunning = true
        val lock = signalWakeLock
            ?: getSystemService(PowerManager::class.java)
                ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WomanGuard:SignalCheck")
                ?.apply { setReferenceCounted(false) }
                ?.also { signalWakeLock = it }
        lock?.acquire(SIGNAL_WAKE_MS)

        val suspectIds = suspects.mapTo(mutableSetOf()) { it.id }
        val freshDue = mutableListOf<Long>()
        var pending = suspects.size
        var failed = false
        val alerts = FirebaseFirestore.getInstance().collection("sos_alerts")
        suspects.forEach { cached ->
            alerts.document(cached.id).get(Source.SERVER)
                .addOnSuccessListener { fresh ->
                    val checkedAt = System.currentTimeMillis()
                    if (isSilent(fresh, uid, checkedAt)) {
                        val last = lastSignalMillis(fresh) ?: return@addOnSuccessListener
                        if (AlertRegistry.tryClaim(this, signalKey(fresh.id, last))) presentSignalLost(fresh, last, checkedAt)
                    } else {
                        // Still reporting after all (this phone's listener was behind)
                        nextSilenceDue(listOf(fresh), uid, checkedAt)?.let { freshDue += it }
                    }
                }
                .addOnFailureListener { e ->
                    // This phone is offline: it cannot tell a silent sender from its own lost connection.
                    Log.w(TAG, "Signal check for ${cached.id} could not reach the server", e)
                    failed = true
                }
                .addOnCompleteListener {
                    pending--
                    if (pending > 0) return@addOnCompleteListener
                    signalCheckRunning = false
                    val doneAt = System.currentTimeMillis()
                    val others = docsBySource.values.flatten().distinctBy { it.id }.filter { it.id !in suspectIds }
                    val candidates = listOfNotNull(
                        nextSilenceDue(others, uid, doneAt),
                        freshDue.minOrNull(),
                        if (failed) doneAt + SIGNAL_RETRY_MS else null,
                    )
                    armSignalCheck(candidates.minOrNull())
                    signalWakeLock?.let { if (it.isHeld) it.release() }
                }
        }
    }

    private fun lastLocation(doc: DocumentSnapshot): Triple<String?, Double?, Double?> {
        val location = doc.get("liveLocation") as? Map<*, *> ?: doc.get("location") as? Map<*, *>
        val address = (location?.get("address") ?: doc.get("address"))?.toString()
            ?.takeIf { it.isNotBlank() && it != "Live Coordinates" && it != "Live GPS Coordinates Available" }
        val latitude = number(location?.get("latitude")) ?: number(doc.get("latitude")) ?: number(doc.get("lat"))
        val longitude = number(location?.get("longitude")) ?: number(doc.get("longitude")) ?: number(doc.get("lng"))
        return Triple(address, latitude, longitude)
    }

    private fun openInboxIntent(requestCode: Int): PendingIntent = PendingIntent.getActivity(
        this,
        requestCode,
        Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_OPEN_INBOX, true),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun presentSignalLost(doc: DocumentSnapshot, lastSignal: Long, now: Long) {
        val name = senderName(doc)
        val minutes = ((now - lastSignal) / 60_000L).coerceAtLeast(1)
        val (address, latitude, longitude) = lastLocation(doc)
        val notifId = signalNotificationId(doc.id)
        Log.i(TAG, "Signal lost for SOS ${doc.id}: no location update for $minutes min")

        val body = "No location update for $minutes min during an active SOS. Their phone may be off or out of network."
        val details = buildString {
            append(body)
            if (address != null) append("\nLast location: ").append(address)
            append("\nCall them, or call 999 if you cannot reach them.")
        }
        val builder = NotificationCompat.Builder(this, NotificationChannels.SIGNAL_LOST)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Signal lost: $name")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(details))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(0xFFFF3B30.toInt())
            .setAutoCancel(true)
            .setContentIntent(openInboxIntent(notifId * 10 + 1))
            .addAction(
                0,
                "Call 999",
                PendingIntent.getActivity(
                    this,
                    notifId * 10 + 2,
                    Intent(Intent.ACTION_DIAL, Uri.parse("tel:999")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        if (latitude != null && longitude != null) {
            val mapIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://maps.google.com/?q=$latitude,$longitude"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.addAction(
                0,
                "Last location",
                PendingIntent.getActivity(this, notifId * 10 + 3, mapIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        }
        if (!canPostNotifications()) {
            Log.w(TAG, "Notification permission denied; cannot report lost signal")
            return
        }
        try {
            val manager = NotificationManagerCompat.from(this)
            manager.cancel(TAG_SIGNAL_BACK, notifId)
            manager.notify(TAG_SIGNAL_LOST, notifId, builder.build())
            signalLostShown += doc.id
        } catch (e: SecurityException) {
            Log.e(TAG, "Could not post signal-lost notification", e)
        }
    }

    /** The sender's phone reports again: replace the warning so the guardian is not left worried. */
    private fun presentSignalBack(doc: DocumentSnapshot) {
        val notifId = signalNotificationId(doc.id)
        cancelSignalLost(doc.id)
        Log.i(TAG, "Signal back for SOS ${doc.id}")
        val address = lastLocation(doc).first
        val body = "Their location is updating again. The SOS is still active."
        val notification = NotificationCompat.Builder(this, NotificationChannels.SIGNAL_LOST)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("${senderName(doc)}'s phone is back online")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body + (address?.let { "\nLocation: $it" } ?: "")))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setColor(0xFFFF3B30.toInt())
            .setAutoCancel(true)
            .setContentIntent(openInboxIntent(notifId * 10 + 4))
            .build()
        if (!canPostNotifications()) return
        try {
            NotificationManagerCompat.from(this).notify(TAG_SIGNAL_BACK, notifId, notification)
        } catch (e: SecurityException) {
            Log.e(TAG, "Could not post signal-back notification", e)
        }
    }

    private fun cancelSignalLost(alertId: String) {
        NotificationManagerCompat.from(this).cancel(TAG_SIGNAL_LOST, signalNotificationId(alertId))
        signalLostShown -= alertId
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
