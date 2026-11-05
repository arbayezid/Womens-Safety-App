package com.smartsafety.smart_safety

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * App-level method channels shared by the UI engine (MainActivity) and the headless engine that
 * runs safety deadlines while the app is closed, so the Dart SOS pipeline behaves the same in both.
 */
object AppChannels {
    private const val TAG = "WG/AppChannels"

    const val DEVICE = "com.smartsafety.smart_safety/device"
    const val SMS = "com.smartsafety.smart_safety/sms"
    const val DEADLINE = "com.smartsafety.smart_safety/deadline"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Device + SMS channels (identical handlers in every engine). */
    fun registerShared(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, DEVICE).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "getManufacturer" -> result.success(Build.MANUFACTURER ?: "")
                "openAutoStartSettings" -> result.success(openAutoStartSettings(app))
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, SMS).setMethodCallHandler { call, result -> onSmsCall(app, call, result) }
    }

    /** Deadline channel for Dart -> native calls in the UI engine. */
    fun registerDeadline(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, DEADLINE).setMethodCallHandler { call, result -> handleDeadlineCall(app, call, result) }
    }

    private fun onSmsCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sendSms" -> {
                val recipients = call.argument<List<String>>("recipients") ?: emptyList()
                val message = call.argument<String>("message") ?: ""
                val timeoutMs = (call.argument<Number>("timeoutMs") ?: 20000).toLong()
                SmsSender.sendAsync(context, recipients, message, timeoutMs) { results ->
                    mainHandler.post { result.success(results) }
                }
            }
            "openComposer" -> {
                val recipients = call.argument<List<String>>("recipients") ?: emptyList()
                val message = call.argument<String>("message") ?: ""
                result.success(SmsSender.openComposer(context, recipients, message))
            }
            else -> result.notImplemented()
        }
    }

    fun handleDeadlineCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        when (call.method) {
            "arm" -> {
                val args = call.arguments as? Map<*, *> ?: return result.success(false)
                result.success(SafetyDeadlines.arm(context, SafetyDeadlines.Deadline.fromArgs(args), args["replace"] == true))
            }
            "prompt" -> {
                val escalateAt = call.argument<Number>("escalateAt")?.toLong() ?: return result.success(false)
                result.success(SafetyDeadlines.prompt(context, id, escalateAt, byApp = true))
            }
            "clear" -> {
                SafetyDeadlines.clear(context, id)
                result.success(null)
            }
            "claim" -> result.success(SafetyDeadlines.claim(context, id))
            "get" -> result.success(SafetyDeadlines.get(context, id)?.toArgs())
            "canScheduleExactAlarms" -> result.success(SafetyDeadlines.canScheduleExactAlarms(context))
            "openExactAlarmSettings" -> result.success(openExactAlarmSettings(context))
            else -> result.notImplemented()
        }
    }

    private fun openExactAlarmSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return tryStart(
            context,
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}")),
        )
    }

    /** Opens the manufacturer's auto-start / background-launch screen, or the app's details page. */
    private fun openAutoStartSettings(context: Context): Boolean {
        val candidates = listOf(
            // Xiaomi / Redmi / POCO (MIUI, HyperOS)
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            // Oppo / Realme / OnePlus (ColorOS)
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            ComponentName("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
            // Vivo / iQOO
            ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            // Samsung (Device care > Battery)
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
            // Huawei / Honor
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        )
        for (component in candidates) {
            if (tryStart(context, Intent().setComponent(component))) return true
        }
        return tryStart(
            context,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
        )
    }

    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        Log.w(TAG, "Not allowed to open ${intent.component ?: intent.action}", e)
        false
    }
}
