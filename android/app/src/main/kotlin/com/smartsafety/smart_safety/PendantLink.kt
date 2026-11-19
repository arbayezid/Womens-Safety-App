package com.smartsafety.smart_safety

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Shared state of the ESP32 pendant link, owned by [PendantLinkService].
 *
 * The connection lives in a native foreground service, not in the Flutter UI engine, so it survives
 * the app being swiped away, "Clear all" and the screen being locked. The app only talks to it over
 * [CHANNEL]: it asks to connect / disconnect / forget and receives status updates. All members are
 * used on the main thread.
 */
object PendantLink {
    private const val TAG = "WG/PendantLink"
    const val CHANNEL = "com.smartsafety.smart_safety/pendant"

    private const val PREFS = "wg_pendant_link"
    private const val KEY_ADDRESS = "address"
    private const val KEY_NAME = "name"
    private const val KEY_ENABLED = "enabled"

    const val STATUS_CONNECTED = "connected"
    const val STATUS_CONNECTING = "connecting"
    const val STATUS_DISCONNECTED = "disconnected"
    const val STATUS_BLUETOOTH_OFF = "bluetoothDisabled"
    const val STATUS_PERMISSION_DENIED = "permissionDenied"

    // ── Persisted pairing ────────────────────────────────────────────────────

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Address of the verified pendant, or null when none is paired. */
    fun savedAddress(context: Context): String? = prefs(context).getString(KEY_ADDRESS, null)

    fun savedName(context: Context): String? = prefs(context).getString(KEY_NAME, null)

    /** True while the user wants the link kept up (cleared by Disconnect / Forget). */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun save(context: Context, address: String, name: String) {
        prefs(context).edit()
            .putString(KEY_ADDRESS, address)
            .putString(KEY_NAME, name)
            .putBoolean(KEY_ENABLED, true)
            .apply()
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    fun hasConnectPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    // ── Live state ───────────────────────────────────────────────────────────

    var status: String = STATUS_DISCONNECTED
        private set
    var battery: Int = -1
        private set
    var rssi: Int = 0
        private set
    var deviceName: String? = null
        private set
    var deviceAddress: String? = null
        private set

    fun update(
        status: String? = null,
        battery: Int? = null,
        rssi: Int? = null,
        name: String? = null,
        address: String? = null,
    ) {
        status?.let { this.status = it }
        battery?.let { this.battery = it }
        rssi?.let { this.rssi = it }
        name?.let { deviceName = it }
        address?.let { deviceAddress = it }
        publish()
    }

    fun stateMap(context: Context): Map<String, Any?> = mapOf(
        "status" to status,
        "battery" to battery,
        "rssi" to rssi,
        "name" to (deviceName ?: savedName(context)),
        "address" to (deviceAddress ?: savedAddress(context)),
        "savedAddress" to savedAddress(context),
        "savedName" to savedName(context),
        "enabled" to isEnabled(context),
        "running" to PendantLinkService.isRunning,
    )

    // ── Bridge to the UI engine ──────────────────────────────────────────────

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var channelMessenger: BinaryMessenger? = null

    /** Result of the app's pending "connect" call, answered once the outcome is known. */
    private var pendingConnect: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        appContext = app
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getState" -> result.success(stateMap(app))
                "connect" -> {
                    val address = call.argument<String>("address")
                    if (address.isNullOrEmpty()) return@setMethodCallHandler result.success(outcome("failed", "no device address"))
                    val name = call.argument<String>("name") ?: ""
                    // A newer request replaces an older one still waiting.
                    completeConnect("failed", "replaced by a newer connect request")
                    pendingConnect = result
                    if (!PendantLinkService.connect(app, address, name)) {
                        completeConnect("failed", "could not start the pendant service")
                    }
                }
                "ensure" -> result.success(PendantLinkService.ensureRunning(app))
                "disconnect" -> {
                    completeConnect("failed", "disconnected")
                    PendantLinkService.disconnect(app, forget = false)
                    result.success(null)
                }
                "forget" -> {
                    completeConnect("failed", "device forgotten")
                    PendantLinkService.disconnect(app, forget = true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        channelMessenger = messenger
        publish()
    }

    fun unregister(messenger: BinaryMessenger) {
        if (channelMessenger !== messenger) return
        channel?.setMethodCallHandler(null)
        channel = null
        channelMessenger = null
        // The UI is gone; the link itself keeps running in the service.
        pendingConnect = null
    }

    fun publish() {
        val ctx = appContext ?: return
        val ch = channel ?: return
        try {
            ch.invokeMethod("onState", stateMap(ctx))
        } catch (e: Exception) {
            Log.w(TAG, "Could not publish pendant state", e)
        }
    }

    /** Answers the app's pending connect call: "connected", "notPendant", "unsupportedFirmware" or "failed". */
    fun completeConnect(result: String, error: String? = null) {
        val pending = pendingConnect ?: return
        pendingConnect = null
        try {
            pending.success(outcome(result, error))
        } catch (e: Exception) {
            Log.w(TAG, "Connect result was already answered", e)
        }
    }

    private fun outcome(result: String, error: String?) = mapOf("result" to result, "error" to error)
}
