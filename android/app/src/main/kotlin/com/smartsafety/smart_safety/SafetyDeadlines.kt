package com.smartsafety.smart_safety

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.max

/**
 * Persistent store and exact-alarm scheduler for sender-side safety deadlines (Safe Journey /
 * Followed Mode check-ins, ride overdue, SOS escalation stages).
 *
 * The Dart timers stay the primary path while the app runs. Each deadline here is a backstop
 * that survives the UI isolate dying, the app being swiped away, and reboots. When it fires,
 * [SafetyDeadlineService] runs the existing Dart pipeline (in the live app or a headless engine).
 *
 * States: armed (waiting for fireAt) -> prompting (a 60 s "are you safe?" check is running,
 * escalate at escalateAt) -> fired (claimed by whoever escalated; never fires again).
 * Cleared deadlines are removed. [claim] is the single de-duplication point: only its first
 * caller escalates.
 */
object SafetyDeadlines {
    private const val TAG = "WG/Deadlines"
    private const val PREFS = "woman_guard_safety_deadlines"

    const val STATE_ARMED = "armed"
    const val STATE_PROMPTING = "prompting"
    const val STATE_FIRED = "fired"

    /** Extra time after an in-app countdown ends before the native backstop escalates. */
    const val BACKSTOP_GRACE_MS = 20_000L
    const val RETRY_DELAY_MS = 90_000L
    const val MAX_ATTEMPTS = 3

    /** After "I'm safe" on a journey/followed check, the next check is due in 10 minutes (as in-app). */
    private const val NEXT_CHECK_AFTER_SAFE_MS = 10 * 60_000L
    private const val NEXT_CHECK_BACKSTOP_MS = 45_000L
    private const val FIRED_RETENTION_MS = 24 * 60 * 60_000L

    data class Deadline(
        val id: String,
        val kind: String,
        val refId: String,
        val uid: String,
        val fireAt: Long,
        val state: String,
        val escalateAt: Long,
        val promptSeconds: Int,
        val direct: Boolean,
        val title: String,
        val body: String,
        val attempts: Int,
        val updatedAt: Long,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("id", id).put("kind", kind).put("refId", refId).put("uid", uid)
            .put("fireAt", fireAt).put("state", state).put("escalateAt", escalateAt)
            .put("promptSeconds", promptSeconds).put("direct", direct)
            .put("title", title).put("body", body).put("attempts", attempts).put("updatedAt", updatedAt)

        fun toArgs(): Map<String, Any?> = mapOf(
            "id" to id, "kind" to kind, "refId" to refId, "uid" to uid, "fireAt" to fireAt,
            "state" to state, "escalateAt" to escalateAt, "promptSeconds" to promptSeconds,
            "direct" to direct, "title" to title, "body" to body, "attempts" to attempts,
        )

        val isJourneyCheck get() = kind == "journey"

        companion object {
            fun fromJson(o: JSONObject) = Deadline(
                id = o.optString("id"),
                kind = o.optString("kind"),
                refId = o.optString("refId"),
                uid = o.optString("uid"),
                fireAt = o.optLong("fireAt"),
                state = o.optString("state", STATE_ARMED),
                escalateAt = o.optLong("escalateAt"),
                promptSeconds = o.optInt("promptSeconds", 60),
                direct = o.optBoolean("direct", false),
                title = o.optString("title"),
                body = o.optString("body"),
                attempts = o.optInt("attempts", 0),
                updatedAt = o.optLong("updatedAt"),
            )

            fun fromArgs(a: Map<*, *>) = Deadline(
                id = a["id"]?.toString().orEmpty(),
                kind = a["kind"]?.toString().orEmpty(),
                refId = a["refId"]?.toString().orEmpty(),
                uid = a["uid"]?.toString().orEmpty(),
                fireAt = (a["fireAt"] as? Number)?.toLong() ?: 0L,
                state = STATE_ARMED,
                escalateAt = 0L,
                promptSeconds = (a["promptSeconds"] as? Number)?.toInt() ?: 60,
                direct = a["direct"] == true,
                title = a["title"]?.toString().orEmpty(),
                body = a["body"]?.toString().orEmpty(),
                attempts = 0,
                updatedAt = System.currentTimeMillis(),
            )
        }
    }

    // ── Store ─────────────────────────────────────────────────────────────────

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun get(context: Context, id: String): Deadline? =
        prefs(context).getString(id, null)?.let { runCatching { Deadline.fromJson(JSONObject(it)) }.getOrNull() }

    @Synchronized
    fun all(context: Context): List<Deadline> = prefs(context).all.values.mapNotNull { raw ->
        (raw as? String)?.let { runCatching { Deadline.fromJson(JSONObject(it)) }.getOrNull() }
    }

    @Synchronized
    private fun put(context: Context, d: Deadline) {
        prefs(context).edit().putString(d.id, d.copy(updatedAt = System.currentTimeMillis()).toJson().toString()).commit()
    }

    // ── Operations (called from Dart through the deadline channel and from native code) ────

    /**
     * Arms [d]. An existing prompting deadline is only replaced when [replace] is true (after the
     * user confirmed they are safe); a fired deadline is never re-armed.
     */
    @Synchronized
    fun arm(context: Context, d: Deadline, replace: Boolean): Boolean {
        pruneFired(context)
        val existing = get(context, d.id)
        if (existing?.state == STATE_FIRED) return false
        if (existing?.state == STATE_PROMPTING && !replace) return false
        if (existing != null && existing.state == STATE_ARMED && existing.fireAt == d.fireAt && !replace) {
            schedule(context, d.id, d.fireAt) // idempotent; also repairs a lost alarm
            return true
        }
        put(context, d.copy(state = STATE_ARMED, escalateAt = 0L, attempts = 0))
        schedule(context, d.id, d.fireAt)
        cancelPromptNotification(context, d.id)
        Log.i(TAG, "Armed ${d.id} for ${d.fireAt}")
        return true
    }

    /**
     * A 60 s "are you safe?" check is running. [byApp] = the app shows the check and counts down
     * itself, so the native alarm is only a backstop after [BACKSTOP_GRACE_MS].
     */
    @Synchronized
    fun prompt(context: Context, id: String, escalateAt: Long, byApp: Boolean): Boolean {
        val d = get(context, id) ?: return false
        if (d.state == STATE_FIRED) return false
        put(context, d.copy(state = STATE_PROMPTING, escalateAt = escalateAt))
        schedule(context, id, escalateAt + if (byApp) BACKSTOP_GRACE_MS else 0L)
        Log.i(TAG, "Prompting $id, escalate at $escalateAt (byApp=$byApp)")
        return true
    }

    @Synchronized
    fun clear(context: Context, id: String) {
        prefs(context).edit().remove(id).commit()
        cancelAlarm(context, id)
        cancelPromptNotification(context, id)
        Log.i(TAG, "Cleared $id")
    }

    /** Returns true exactly once per armed deadline; true as well when nothing is armed for [id]. */
    @Synchronized
    fun claim(context: Context, id: String): Boolean {
        val d = get(context, id) ?: return true
        if (d.state == STATE_FIRED) return false
        put(context, d.copy(state = STATE_FIRED))
        cancelAlarm(context, id)
        cancelPromptNotification(context, id)
        Log.i(TAG, "Claimed $id")
        return true
    }

    /** Records an escalation attempt and schedules a retry in case the Dart run never claims it. */
    @Synchronized
    fun markAttempt(context: Context, id: String): Deadline? {
        val d = get(context, id) ?: return null
        val updated = d.copy(attempts = d.attempts + 1)
        put(context, updated)
        if (updated.attempts < MAX_ATTEMPTS) schedule(context, id, System.currentTimeMillis() + RETRY_DELAY_MS)
        return updated
    }

    /** "I'm safe" tapped on the native prompt notification while the app was not running. */
    @Synchronized
    fun confirmSafeFromNotification(context: Context, id: String) {
        val d = get(context, id)
        cancelPromptNotification(context, id)
        if (d == null || d.state == STATE_FIRED) return
        if (d.isJourneyCheck) {
            val now = System.currentTimeMillis()
            put(context, d.copy(state = STATE_ARMED, fireAt = now + NEXT_CHECK_AFTER_SAFE_MS + NEXT_CHECK_BACKSTOP_MS, escalateAt = 0L, attempts = 0))
            schedule(context, id, now + NEXT_CHECK_AFTER_SAFE_MS + NEXT_CHECK_BACKSTOP_MS)
            // Same fields JourneyService.confirmSafe writes, so the app does not re-ask on next open.
            runCatching {
                FirebaseFirestore.getInstance().collection("journeys").document(d.refId).update(
                    mapOf("lastSafetyCheckAt" to FieldValue.serverTimestamp(), "lastUpdatedAt" to FieldValue.serverTimestamp())
                )
            }.onFailure { Log.w(TAG, "Could not record safety confirmation for ${d.refId}", it) }
        } else {
            clear(context, id)
        }
        Log.i(TAG, "User confirmed safe for $id from notification")
    }

    /** After reboot, app update or an exact-alarm permission change every alarm must be re-registered. */
    @Synchronized
    fun rescheduleAll(context: Context) {
        pruneFired(context)
        for (d in all(context)) {
            when (d.state) {
                STATE_ARMED -> schedule(context, d.id, d.fireAt)
                STATE_PROMPTING -> schedule(context, d.id, d.escalateAt)
            }
        }
    }

    private fun pruneFired(context: Context) {
        val cutoff = System.currentTimeMillis() - FIRED_RETENTION_MS
        val stale = all(context).filter { it.state == STATE_FIRED && it.updatedAt < cutoff }.map { it.id }
        if (stale.isEmpty()) return
        val edit = prefs(context).edit()
        stale.forEach { edit.remove(it) }
        edit.commit()
    }

    // ── Alarms ────────────────────────────────────────────────────────────────

    fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return context.getSystemService(AlarmManager::class.java)?.canScheduleExactAlarms() ?: false
    }

    private fun alarmIntent(context: Context, id: String): PendingIntent {
        val intent = Intent(context, SafetyDeadlineReceiver::class.java)
            .setAction(SafetyDeadlineReceiver.ACTION_FIRE)
            .setData(Uri.parse("woman-guard://deadline/" + Uri.encode(id)))
            .putExtra(SafetyDeadlineReceiver.EXTRA_ID, id)
        return PendingIntent.getBroadcast(context, requestCode(id), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun requestCode(id: String) = 40_000 + abs(id.hashCode() % 20_000)

    fun schedule(context: Context, id: String, at: Long) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val triggerAt = max(at, System.currentTimeMillis() + 2_000L)
        val pending = alarmIntent(context, id)
        try {
            if (canScheduleExactAlarms(context)) {
                // Alarm-clock alarms are exact, wake the device and are exempt from Doze and from the
                // background foreground-service start restriction.
                val show = PendingIntent.getActivity(
                    context, 39_999, Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                manager.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAt, show), pending)
            } else {
                // Without the exact-alarm permission Android may delay this in Doze.
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Exact alarm refused; using inexact alarm for $id", e)
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
        }
    }

    private fun cancelAlarm(context: Context, id: String) {
        context.getSystemService(AlarmManager::class.java)?.cancel(alarmIntent(context, id))
    }

    // ── Prompt notification (sender's own "are you safe?" check) ─────────────────

    fun promptNotificationId(id: String) = 7400 + abs(id.hashCode() % 500)

    fun cancelPromptNotification(context: Context, id: String) {
        NotificationManagerCompat.from(context).cancel(promptNotificationId(id))
    }

    fun postPromptNotification(context: Context, d: Deadline) {
        NotificationChannels.ensureCreated(context)
        val notificationId = promptNotificationId(d.id)
        val open = PendingIntent.getActivity(
            context, notificationId,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val safe = PendingIntent.getBroadcast(
            context, notificationId,
            Intent(context, SafetyDeadlineReceiver::class.java)
                .setAction(SafetyDeadlineReceiver.ACTION_IM_SAFE)
                .setData(Uri.parse("woman-guard://deadline-safe/" + Uri.encode(d.id)))
                .putExtra(SafetyDeadlineReceiver.EXTRA_ID, d.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val title = d.title.ifBlank { "⚠️ Safety check: are you OK?" }
        val body = (d.body.ifBlank { "Please confirm you are safe." }) +
            " SOS will be sent to your guardians automatically in ${d.promptSeconds} seconds."
        val notification = NotificationCompat.Builder(context, NotificationChannels.SAFETY_CHECKS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(true)
            .setTimeoutAfter((d.promptSeconds + 30) * 1000L)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
            .addAction(0, "I'm safe", safe)
            .build()
        val canPost = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!canPost) {
            Log.w(TAG, "Notification permission denied; prompt for ${d.id} not shown (escalation still runs)")
            return
        }
        try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
        } catch (e: SecurityException) {
            Log.e(TAG, "Could not post safety prompt", e)
        }
    }
}
