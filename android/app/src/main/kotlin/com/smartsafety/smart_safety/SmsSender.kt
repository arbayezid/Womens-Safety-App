package com.smartsafety.smart_safety

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sends SOS text messages from the user's own SIM and reports the real radio result per recipient.
 *
 * - Picks the SMS subscription explicitly: SmsManager.getDefault() fails silently on dual-SIM phones
 *   set to "Ask every time" (common on Samsung). A recipient that fails on one SIM is retried on the next.
 * - Long or Unicode text is split with divideMessage() and sent as a multipart message.
 * - Every part has its own sent/delivered PendingIntent, so "sent" means the network accepted it.
 */
object SmsSender {
    private const val TAG = "WG/SmsSender"
    const val ACTION_SENT = "com.smartsafety.smart_safety.SMS_SENT"
    const val ACTION_DELIVERED = "com.smartsafety.smart_safety.SMS_DELIVERED"
    const val EXTRA_TRACKING_KEY = "tracking_key"
    private const val COMPOSER_NOTIFICATION_ID = 7310

    private val requestCodes = AtomicInteger(5000)
    private val executor = Executors.newSingleThreadExecutor()
    private val pending = ConcurrentHashMap<String, Tracker>()

    private class Tracker(parts: Int) {
        val latch = CountDownLatch(parts)
        val codes: MutableList<Int> = Collections.synchronizedList(mutableListOf())
    }

    private sealed class Dispatch {
        class Started(val key: String, val tracker: Tracker) : Dispatch()
        class Error(val reason: String) : Dispatch()
    }

    private class Outcome(val status: String, val error: String?, val subscriptionId: Int)

    /** Sends on a worker thread; [callback] receives one map per recipient (recipient, status, error). */
    fun sendAsync(
        context: Context,
        recipients: List<String>,
        message: String,
        timeoutMs: Long,
        callback: (List<Map<String, Any?>>) -> Unit,
    ) {
        val app = context.applicationContext
        executor.execute {
            val results = try {
                send(app, recipients, message, timeoutMs)
            } catch (e: Exception) {
                Log.e(TAG, "SMS dispatch crashed", e)
                recipients.map { resultMap(it, Outcome("failed", e.message ?: e.javaClass.simpleName, -1)) }
            }
            callback(results)
        }
    }

    /** Called by [SmsResultReceiver] for every sent / delivered part. */
    fun onPartResult(action: String, key: String, resultCode: Int) {
        if (action == ACTION_DELIVERED) {
            Log.i(TAG, "Delivery report $key -> ${describe(resultCode)}")
            return
        }
        Log.i(TAG, "Sent report $key -> ${describe(resultCode)}")
        pending[key]?.let {
            it.codes.add(resultCode)
            it.latch.countDown()
        }
    }

    private fun send(context: Context, recipients: List<String>, message: String, timeoutMs: Long): List<Map<String, Any?>> {
        val unique = recipients.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "SEND_SMS not granted")
            return unique.map { resultMap(it, Outcome("permission_denied", "SEND_SMS permission not granted", -1)) }
        }

        val outcomes = LinkedHashMap<String, Outcome>()
        var remaining = unique
        val subscriptions = candidateSubscriptions(context)
        Log.i(TAG, "Sending SOS SMS to ${unique.size} recipient(s), SIM candidates: $subscriptions, ${message.length} chars")

        for (subscriptionId in subscriptions) {
            if (remaining.isEmpty()) break
            val dispatches = remaining.associateWith { dispatch(context, it, message, subscriptionId) }
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            val failed = mutableListOf<String>()

            for ((recipient, dispatch) in dispatches) {
                when (dispatch) {
                    is Dispatch.Error -> {
                        outcomes[recipient] = Outcome("failed", dispatch.reason, subscriptionId)
                        failed += recipient
                    }
                    is Dispatch.Started -> {
                        val waitMs = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0)
                        val completed = dispatch.tracker.latch.await(waitMs, TimeUnit.MILLISECONDS)
                        pending.remove(dispatch.key)
                        val codes = dispatch.tracker.codes.toList()
                        val firstError = codes.firstOrNull { it != Activity.RESULT_OK }
                        when {
                            firstError != null -> {
                                outcomes[recipient] = Outcome("failed", describe(firstError), subscriptionId)
                                failed += recipient
                            }
                            completed -> outcomes[recipient] = Outcome("sent", null, subscriptionId)
                            // Handed to the radio but not confirmed yet (weak signal); Android keeps retrying it.
                            else -> outcomes[recipient] = Outcome("pending", "No network confirmation yet", subscriptionId)
                        }
                    }
                }
                Log.i(TAG, "SMS to $recipient via SIM $subscriptionId: ${outcomes[recipient]?.status} ${outcomes[recipient]?.error ?: ""}")
            }
            remaining = failed
        }
        return unique.map { resultMap(it, outcomes[it] ?: Outcome("failed", "Not attempted", -1)) }
    }

    private fun dispatch(context: Context, recipient: String, message: String, subscriptionId: Int): Dispatch {
        var key: String? = null
        return try {
            val manager = smsManagerFor(context, subscriptionId)
                ?: return Dispatch.Error("SMS is not supported on this device")
            val parts = manager.divideMessage(message)
            val trackingKey = "${SystemClock.elapsedRealtimeNanos()}_${requestCodes.incrementAndGet()}"
            key = trackingKey
            val tracker = Tracker(parts.size)
            pending[trackingKey] = tracker

            val sentIntents = ArrayList<PendingIntent>(parts.size)
            val deliveredIntents = ArrayList<PendingIntent>(parts.size)
            repeat(parts.size) {
                sentIntents += resultIntent(context, ACTION_SENT, trackingKey)
                deliveredIntents += resultIntent(context, ACTION_DELIVERED, trackingKey)
            }
            if (parts.size > 1) {
                manager.sendMultipartTextMessage(recipient, null, parts, sentIntents, deliveredIntents)
            } else {
                manager.sendTextMessage(recipient, null, message, sentIntents[0], deliveredIntents[0])
            }
            Dispatch.Started(trackingKey, tracker)
        } catch (e: Exception) {
            key?.let { pending.remove(it) }
            Log.e(TAG, "SmsManager rejected message to $recipient", e)
            Dispatch.Error(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun resultIntent(context: Context, action: String, key: String): PendingIntent {
        val intent = Intent(context, SmsResultReceiver::class.java)
            .setAction(action)
            .putExtra(EXTRA_TRACKING_KEY, key)
        return PendingIntent.getBroadcast(
            context,
            requestCodes.incrementAndGet(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
        )
    }

    /** Preferred SIM first; extra SIMs are used to retry recipients that failed. */
    private fun candidateSubscriptions(context: Context): List<Int> {
        val ids = LinkedHashSet<Int>()
        val defaultSms = SmsManager.getDefaultSmsSubscriptionId()
        if (defaultSms != SubscriptionManager.INVALID_SUBSCRIPTION_ID) ids += defaultSms

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
            try {
                context.getSystemService(SubscriptionManager::class.java)
                    ?.activeSubscriptionInfoList
                    ?.sortedBy { it.simSlotIndex }
                    ?.forEach { ids += it.subscriptionId }
            } catch (e: SecurityException) {
                Log.w(TAG, "Cannot list SIM cards", e)
            }
        }

        val defaultAny = SubscriptionManager.getDefaultSubscriptionId()
        if (defaultAny != SubscriptionManager.INVALID_SUBSCRIPTION_ID) ids += defaultAny
        // Nothing resolvable: let the platform choose.
        if (ids.isEmpty()) ids += SubscriptionManager.INVALID_SUBSCRIPTION_ID
        return ids.toList()
    }

    @Suppress("DEPRECATION")
    private fun smsManagerFor(context: Context, subscriptionId: Int): SmsManager? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val base = context.getSystemService(SmsManager::class.java) ?: return null
            return if (subscriptionId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) base
            else base.createForSubscriptionId(subscriptionId)
        }
        return if (subscriptionId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) SmsManager.getDefault()
        else SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
    }

    private fun describe(code: Int): String = when (code) {
        Activity.RESULT_OK -> "OK"
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "Generic failure (no balance or carrier rejected)"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "Radio off (airplane mode)"
        SmsManager.RESULT_ERROR_NULL_PDU -> "Invalid message"
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No mobile network"
        SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "SMS sending limit reached"
        SmsManager.RESULT_ERROR_SHORT_CODE_NOT_ALLOWED -> "Short code not allowed"
        else -> "Error code $code"
    }

    private fun resultMap(recipient: String, outcome: Outcome): Map<String, Any?> = mapOf(
        "recipient" to recipient,
        "status" to outcome.status,
        "error" to outcome.error,
        "subscriptionId" to outcome.subscriptionId,
    )

    /**
     * Fallback when direct sending is not possible: opens the default SMS app with every recipient
     * and the message pre-filled so the user only taps Send. Android blocks activity starts from the
     * background, so in that case a notification opens the composer instead.
     * Returns "opened", "notified" or "failed".
     */
    fun openComposer(context: Context, recipients: List<String>, message: String): String {
        if (recipients.isEmpty()) return "failed"
        // Samsung Messages separates recipients with ',', AOSP-based apps with ';'.
        val separator = if (Build.MANUFACTURER.equals("samsung", ignoreCase = true)) "," else ";"
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + recipients.joinToString(separator)))
            .putExtra("sms_body", message)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        MainActivity.foregroundActivity()?.let { activity ->
            try {
                activity.startActivity(intent)
                Log.i(TAG, "Opened SMS composer for ${recipients.size} recipient(s)")
                return "opened"
            } catch (e: ActivityNotFoundException) {
                Log.e(TAG, "No SMS app installed", e)
                return "failed"
            } catch (e: Exception) {
                Log.w(TAG, "Could not open SMS composer directly", e)
            }
        }

        return try {
            NotificationChannels.ensureCreated(context)
            val pendingIntent = PendingIntent.getActivity(
                context,
                COMPOSER_NOTIFICATION_ID,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notification = NotificationCompat.Builder(context, NotificationChannels.SOS_STATUS)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Tap to send your SOS SMS")
                .setContentText("The SMS could not be sent automatically. Tap to open Messages with your emergency message ready.")
                .setStyle(NotificationCompat.BigTextStyle().bigText(
                    "The SMS could not be sent automatically. Tap to open Messages with your emergency message ready."
                ))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ERROR)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return "failed"
            NotificationManagerCompat.from(context).notify(COMPOSER_NOTIFICATION_ID, notification)
            "notified"
        } catch (e: SecurityException) {
            Log.e(TAG, "Notification permission missing for SMS fallback", e)
            "failed"
        }
    }
}
