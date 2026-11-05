package com.smartsafety.smart_safety

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the app's existing Dart safety pipeline for a fired deadline.
 *
 * If the app's UI engine is alive, the call goes to it (so in-memory state such as the active SOS
 * stays consistent). Otherwise a headless FlutterEngine is started with the same app channels
 * (SMS, device, deadline) and the `safetyDeadlineBackgroundMain` Dart entrypoint. Must be used on
 * the main thread.
 */
object DeadlineDartRunner {
    private const val TAG = "WG/DeadlineDart"
    private const val HEADLESS_ENTRYPOINT = "safetyDeadlineBackgroundMain"
    private const val READY_TIMEOUT_MS = 60_000L

    /** Messenger of the visible app's engine; set by MainActivity, null when the UI engine is gone. */
    @Volatile
    var mainMessenger: BinaryMessenger? = null

    private class Call(val method: String, val args: Map<String, Any?>, val onDone: (Any?) -> Unit)

    private val handler = Handler(Looper.getMainLooper())
    private var headless: FlutterEngine? = null
    private var headlessChannel: MethodChannel? = null
    private var headlessReady = false
    private val pending = mutableListOf<Call>()
    private val readyTimeout = Runnable {
        if (!headlessReady) {
            Log.e(TAG, "Headless Dart engine did not become ready; giving up on ${pending.size} call(s)")
            failPending()
            destroyHeadless()
        }
    }

    fun run(context: Context, method: String, args: Map<String, Any?>, onDone: (Any?) -> Unit) {
        val main = mainMessenger
        if (main != null) {
            MethodChannel(main, AppChannels.DEADLINE).invokeMethod(method, args, object : MethodChannel.Result {
                override fun success(result: Any?) = onDone(result)
                override fun error(code: String, message: String?, details: Any?) {
                    Log.e(TAG, "App engine failed $method: $code $message")
                    onDone(null)
                }
                override fun notImplemented() {
                    // The UI engine exists but Dart has not registered its handler yet: use a headless run.
                    runHeadless(context, Call(method, args, onDone))
                }
            })
            return
        }
        runHeadless(context, Call(method, args, onDone))
    }

    private fun runHeadless(context: Context, call: Call) {
        pending += call
        if (headless == null) {
            startHeadless(context.applicationContext)
        } else if (headlessReady) {
            flush()
        }
    }

    private fun startHeadless(app: Context) {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            val engine = FlutterEngine(app) // registers every pubspec plugin automatically
            val messenger = engine.dartExecutor.binaryMessenger
            AppChannels.registerShared(messenger, app)
            val channel = MethodChannel(messenger, AppChannels.DEADLINE)
            channel.setMethodCallHandler { call, result ->
                if (call.method == "headlessReady") {
                    headlessReady = true
                    handler.removeCallbacks(readyTimeout)
                    result.success(null)
                    flush()
                } else {
                    AppChannels.handleDeadlineCall(app, call, result)
                }
            }
            headless = engine
            headlessChannel = channel
            headlessReady = false
            handler.postDelayed(readyTimeout, READY_TIMEOUT_MS)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), HEADLESS_ENTRYPOINT)
            )
            Log.i(TAG, "Started headless Dart engine")
        } catch (e: Exception) {
            Log.e(TAG, "Could not start headless Dart engine", e)
            failPending()
            destroyHeadless()
        }
    }

    private fun flush() {
        val channel = headlessChannel ?: return
        val calls = pending.toList()
        pending.clear()
        for (c in calls) {
            channel.invokeMethod(c.method, c.args, object : MethodChannel.Result {
                override fun success(result: Any?) = c.onDone(result)
                override fun error(code: String, message: String?, details: Any?) {
                    Log.e(TAG, "Headless ${c.method} failed: $code $message")
                    c.onDone(null)
                }
                override fun notImplemented() = c.onDone(null)
            })
        }
    }

    private fun failPending() {
        val calls = pending.toList()
        pending.clear()
        calls.forEach { it.onDone(null) }
    }

    /** Releases the headless engine once no deadline work is running. */
    fun destroyHeadless() {
        handler.removeCallbacks(readyTimeout)
        headlessChannel?.setMethodCallHandler(null)
        headlessChannel = null
        headless?.destroy()
        headless = null
        headlessReady = false
    }
}
