package com.smartsafety.smart_safety

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * Keeps the ESP32 pendant connected while Woman Guard is closed, cleared from Recent apps or the
 * phone is locked. Only an explicit Disconnect / Forget (or Bluetooth being turned off) ends it.
 *
 * - First connect to a new device: direct GATT connect with retries, then the device must expose
 *   the safety service or the Nordic UART Service and an SOS characteristic, or it is refused.
 * - Every reconnect after that uses autoConnect, so Android waits for the pendant indefinitely and
 *   reconnects by itself when it comes back in range (also in Doze, with the screen off).
 * - A pendant SOS packet runs the app's SOS pipeline through [DeadlineDartRunner]: in the open app
 *   if there is one, otherwise in a headless Dart engine.
 */
@SuppressLint("MissingPermission") // every entry point checks PendantLink.hasConnectPermission first
class PendantLinkService : Service() {
    companion object {
        private const val TAG = "WG/PendantLink"
        private const val NOTIFICATION_ID = 7320
        private const val SOS_FAILURE_NOTIFICATION_ID = 7321

        private const val ACTION_CONNECT = "com.smartsafety.smart_safety.PENDANT_CONNECT"
        private const val ACTION_ENSURE = "com.smartsafety.smart_safety.PENDANT_ENSURE"
        private const val EXTRA_ADDRESS = "address"
        private const val EXTRA_NAME = "name"

        private val SAFETY_SERVICE: UUID = UUID.fromString("4fafc201-1fb5-459e-8fcc-c5c9c331914b")
        private val SOS_CHAR: UUID = UUID.fromString("beb5483e-36e1-4688-b7f5-ea07361b26a8")
        private val NUS_SERVICE: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val NUS_TX_CHAR: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private const val MAX_TRIAL_ATTEMPTS = 3
        private const val CONNECT_TIMEOUT_MS = 15_000L
        private const val DISCOVERY_TIMEOUT_MS = 15_000L
        private const val OP_TIMEOUT_MS = 5_000L
        private const val RSSI_INTERVAL_MS = 20_000L
        private const val RECONNECT_MIN_MS = 1_000L
        private const val RECONNECT_MAX_MS = 30_000L
        private const val SOS_WAKE_MS = 3 * 60_000L

        /** True while the service exists in this process. */
        @Volatile
        var isRunning = false
            private set

        /** User tapped Connect on [address]. */
        fun connect(context: Context, address: String, name: String): Boolean = start(
            context,
            Intent(context, PendantLinkService::class.java)
                .setAction(ACTION_CONNECT)
                .putExtra(EXTRA_ADDRESS, address)
                .putExtra(EXTRA_NAME, name),
        )

        /** Starts the link for the saved pendant if the user left it enabled. */
        fun ensureRunning(context: Context): Boolean {
            if (PendantLink.savedAddress(context) == null || !PendantLink.isEnabled(context)) return false
            if (!PendantLink.hasConnectPermission(context)) return false
            if (isRunning) return true
            return start(context, Intent(context, PendantLinkService::class.java).setAction(ACTION_ENSURE))
        }

        /** User tapped Disconnect ([forget] = false) or Forget Device. */
        fun disconnect(context: Context, forget: Boolean) {
            if (forget) PendantLink.clear(context) else PendantLink.setEnabled(context, false)
            PendantWatchdogReceiver.cancel(context)
            context.stopService(Intent(context, PendantLinkService::class.java))
            PendantLink.update(status = PendantLink.STATUS_DISCONNECTED, rssi = 0)
        }

        private fun start(context: Context, intent: Intent): Boolean = try {
            ContextCompat.startForegroundService(context, intent)
            true
        } catch (e: Exception) {
            // Android 12+ refuses some background starts; the watchdog and the next app open retry.
            Log.w(TAG, "Could not start pendant service", e)
            false
        }
    }

    private enum class Phase {
        /** Verifying a device that is not the saved pendant yet (user tapped Connect). */
        TRIAL,
        /** One fast direct attempt at the saved pendant (user tapped Connect). */
        DIRECT,
        /** autoConnect: waiting for the saved pendant to come in range. */
        WAITING,
        /** Connected and subscribed to the SOS characteristic. */
        UP,
    }

    private enum class Rejection(val result: String, val reason: String) {
        NOT_PENDANT("notPendant", "device has no Woman Guard safety service"),
        UNSUPPORTED("unsupportedFirmware", "pendant firmware has no SOS characteristic"),
    }

    private class Op(val run: (BluetoothGatt) -> Int, val onDone: ((Boolean) -> Unit)? = null)

    private val handler = Handler(Looper.getMainLooper())
    private val filter = PendantSosFilter()

    private var gatt: BluetoothGatt? = null
    private var target: String? = null
    private var targetName: String = ""
    private var phase = Phase.WAITING
    private var attempt = 0
    private var reconnectDelayMs = RECONNECT_MIN_MS

    private val ops = ArrayDeque<Op>()
    private var currentOp: Op? = null

    private var sosWakeLock: PowerManager.WakeLock? = null
    private var receiverRegistered = false

    private val connectTimeout = Runnable { onLinkFailed("connection timed out") }
    private val discoveryTimeout = Runnable { onLinkFailed("service discovery timed out", clearCache = true) }
    private val opTimeout = Runnable { finishOp(false) }
    private val reconnect = Runnable { openGatt(direct = false) }
    private val retryTrial = Runnable { openGatt(direct = true) }
    private val rssiPoll = object : Runnable {
        override fun run() {
            val g = gatt
            if (phase == Phase.UP && g != null && currentOp == null) {
                runCatching { g.readRemoteRssi() }
            }
            handler.postDelayed(this, RSSI_INTERVAL_MS)
        }
    }

    // ── Service lifecycle ────────────────────────────────────────────────────

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        // System broadcasts still reach a not-exported receiver.
        ContextCompat.registerReceiver(
            this,
            bluetoothStateReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!PendantLink.hasConnectPermission(this)) {
            Log.w(TAG, "Bluetooth connect permission missing; stopping")
            enterForeground() // a started foreground service must call startForeground before stopping
            PendantLink.update(status = PendantLink.STATUS_PERMISSION_DENIED)
            PendantLink.completeConnect("failed", "Bluetooth permission is not granted")
            stopClean()
            return START_NOT_STICKY
        }
        if (!enterForeground()) {
            PendantLink.completeConnect("failed", "could not start the pendant service")
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent?.action == ACTION_CONNECT) {
            val address = intent.getStringExtra(EXTRA_ADDRESS)
            if (address.isNullOrEmpty()) {
                PendantLink.completeConnect("failed", "no device address")
                stopIfIdle()
                return START_NOT_STICKY
            }
            val name = intent.getStringExtra(EXTRA_NAME) ?: ""
            if (address == target && phase == Phase.UP) {
                PendantLink.completeConnect("connected")
                return START_STICKY
            }
            val isSaved = address == PendantLink.savedAddress(this)
            if (isSaved) PendantLink.setEnabled(this, true)
            startLink(address, name, if (isSaved) Phase.DIRECT else Phase.TRIAL)
            return START_STICKY
        }

        // ACTION_ENSURE, or a sticky restart after Android killed the process (null intent).
        val saved = PendantLink.savedAddress(this)
        if (saved == null || !PendantLink.isEnabled(this)) {
            stopClean()
            return START_NOT_STICKY
        }
        if (target != saved || gatt == null) {
            startLink(saved, PendantLink.savedName(this) ?: "", Phase.WAITING)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        handler.removeCallbacksAndMessages(null)
        closeGatt()
        filter.onDisconnected()
        if (receiverRegistered) {
            runCatching { unregisterReceiver(bluetoothStateReceiver) }
            receiverRegistered = false
        }
        releaseSosWakeLock()
        PendantLink.completeConnect("failed", "pendant service stopped")
        PendantLink.update(
            status = if (isBluetoothOn()) PendantLink.STATUS_DISCONNECTED else PendantLink.STATUS_BLUETOOTH_OFF,
            rssi = 0,
        )
        super.onDestroy()
    }

    // ── Connection state machine ─────────────────────────────────────────────

    private fun startLink(address: String, name: String, newPhase: Phase) {
        closeGatt()
        handler.removeCallbacks(reconnect)
        handler.removeCallbacks(retryTrial)
        filter.onDisconnected()
        target = address
        targetName = name
        phase = newPhase
        attempt = 0
        reconnectDelayMs = RECONNECT_MIN_MS
        if (newPhase != Phase.TRIAL) PendantWatchdogReceiver.schedule(this)
        Log.i(TAG, "Linking $address ($name), phase $newPhase")
        openGatt(direct = newPhase != Phase.WAITING, announceConnecting = true)
    }

    private fun openGatt(direct: Boolean, announceConnecting: Boolean = direct) {
        closeGatt()
        val address = target ?: return stopIfIdle()
        val adapter = bluetoothAdapter()
        if (adapter == null || !adapter.isEnabled) {
            if (phase == Phase.TRIAL || phase == Phase.DIRECT) {
                PendantLink.completeConnect("failed", "Bluetooth is off")
            }
            if (phase == Phase.TRIAL) return trialFailed()
            phase = Phase.WAITING
            PendantLink.update(status = PendantLink.STATUS_BLUETOOTH_OFF, rssi = 0)
            updateNotification()
            return // bluetoothStateReceiver reconnects when Bluetooth is back on
        }
        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            PendantLink.completeConnect("failed", "invalid device address")
            return if (phase == Phase.TRIAL) trialFailed() else stopClean()
        }

        val status = if (announceConnecting) PendantLink.STATUS_CONNECTING else PendantLink.STATUS_DISCONNECTED
        PendantLink.update(status = status, address = address)
        updateNotification()

        gatt = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(this, !direct, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(this, !direct, gattCallback)
            }
        } catch (e: Exception) {
            Log.e(TAG, "connectGatt failed", e)
            null
        }
        if (gatt == null) return onLinkFailed("could not open a Bluetooth connection")
        // autoConnect has no timeout on purpose: Android keeps waiting for the pendant.
        if (direct) handler.postDelayed(connectTimeout, CONNECT_TIMEOUT_MS)
    }

    private fun onConnected(g: BluetoothGatt) {
        handler.removeCallbacks(connectTimeout)
        Log.i(TAG, "GATT connected to ${g.device.address}; discovering services")
        handler.postDelayed(discoveryTimeout, DISCOVERY_TIMEOUT_MS)
        // A short pause avoids discovery failures right after the link comes up on some phones.
        handler.postDelayed({
            if (g === gatt && !g.discoverServices()) onLinkFailed("service discovery could not start")
        }, 400)
    }

    private fun onServicesDiscovered(g: BluetoothGatt) {
        handler.removeCallbacks(discoveryTimeout)
        val serviceIds = g.services.map { it.uuid }
        if (SAFETY_SERVICE !in serviceIds && NUS_SERVICE !in serviceIds) return reject(Rejection.NOT_PENDANT)

        val sosChar = g.getService(SAFETY_SERVICE)?.getCharacteristic(SOS_CHAR)
            ?: g.getService(NUS_SERVICE)?.getCharacteristic(NUS_TX_CHAR)
            ?: return reject(Rejection.UNSUPPORTED)
        val batteryChar = g.services.flatMap { it.characteristics }.firstOrNull { it.uuid == BATTERY_CHAR }

        enqueue(Op({ enableNotify(it, sosChar) }) { ok ->
            if (ok) onLinkUp(g) else onLinkFailed("could not subscribe to the SOS button")
        })
        if (batteryChar != null) {
            if (batteryChar.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
                enqueue(Op({ if (it.readCharacteristic(batteryChar)) OP_STARTED else OP_FAILED }))
            }
            if (batteryChar.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                enqueue(Op({ enableNotify(it, batteryChar) }))
            }
        }
    }

    private fun onLinkUp(g: BluetoothGatt) {
        if (g !== gatt) return
        val address = g.device.address
        val name = g.device.name?.takeIf { it.isNotBlank() }
            ?: targetName.takeIf { it.isNotBlank() }
            ?: PendantLink.savedName(this)
            ?: "ESP32 Smart Device"
        phase = Phase.UP
        attempt = 0
        reconnectDelayMs = RECONNECT_MIN_MS
        filter.onConnected(SystemClock.elapsedRealtime())
        PendantLink.save(this, address, name)
        PendantWatchdogReceiver.schedule(this)
        PendantLink.update(status = PendantLink.STATUS_CONNECTED, name = name, address = address)
        PendantLink.completeConnect("connected")
        handler.removeCallbacks(rssiPoll)
        handler.post(rssiPoll)
        updateNotification()
        Log.i(TAG, "Pendant $address connected and armed")
    }

    /** The link dropped (out of range, pendant off) or a connect attempt ended with an error. */
    private fun onLinkFailed(reason: String, clearCache: Boolean = false) {
        Log.w(TAG, "Link failed in phase $phase: $reason")
        closeGatt(clearCache)
        filter.onDisconnected()
        when (phase) {
            Phase.TRIAL -> {
                if (++attempt < MAX_TRIAL_ATTEMPTS) {
                    handler.postDelayed(retryTrial, 800)
                } else {
                    PendantLink.completeConnect("failed", reason)
                    trialFailed()
                }
            }
            Phase.DIRECT -> {
                PendantLink.completeConnect(
                    "failed",
                    "$reason. It will reconnect automatically when the pendant is nearby.",
                )
                waitForPendant(immediately = true)
            }
            Phase.UP, Phase.WAITING -> waitForPendant(immediately = phase == Phase.UP)
        }
    }

    /** Hands the saved pendant to Android's autoConnect, with backoff after repeated errors. */
    private fun waitForPendant(immediately: Boolean) {
        phase = Phase.WAITING
        PendantLink.update(status = PendantLink.STATUS_DISCONNECTED, rssi = 0)
        updateNotification()
        handler.removeCallbacks(reconnect)
        val delay = if (immediately) RECONNECT_MIN_MS else reconnectDelayMs
        if (!immediately) reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(RECONNECT_MAX_MS)
        handler.postDelayed(reconnect, delay)
    }

    /** A new device could not be verified: go back to the saved pendant, or stop. */
    private fun trialFailed() {
        closeGatt()
        val saved = PendantLink.savedAddress(this)
        if (saved != null && PendantLink.isEnabled(this) && saved != target) {
            startLink(saved, PendantLink.savedName(this) ?: "", Phase.WAITING)
        } else {
            target = null
            PendantLink.update(status = PendantLink.STATUS_DISCONNECTED, rssi = 0)
            stopClean()
        }
    }

    private fun reject(rejection: Rejection) {
        Log.w(TAG, "Device $target refused: ${rejection.reason}")
        closeGatt()
        filter.onDisconnected()
        PendantLink.completeConnect(rejection.result, rejection.reason)
        if (phase == Phase.TRIAL) return trialFailed()
        // The saved pendant no longer looks like a pendant (e.g. reflashed with other firmware).
        if (rejection == Rejection.NOT_PENDANT) PendantLink.clear(this) else PendantLink.setEnabled(this, false)
        PendantWatchdogReceiver.cancel(this)
        target = null
        PendantLink.update(status = PendantLink.STATUS_DISCONNECTED, rssi = 0)
        stopClean()
    }

    private fun closeGatt(clearCache: Boolean = false) {
        handler.removeCallbacks(connectTimeout)
        handler.removeCallbacks(discoveryTimeout)
        handler.removeCallbacks(opTimeout)
        handler.removeCallbacks(rssiPoll)
        ops.clear()
        currentOp = null
        val g = gatt ?: return
        gatt = null
        if (clearCache) {
            // A stale Android GATT cache can make discovery fail on every attempt.
            runCatching { g.javaClass.getMethod("refresh").invoke(g) }
        }
        runCatching { g.disconnect() }
        runCatching { g.close() }
    }

    // ── GATT operation queue (Android allows one outstanding operation) ──────

    private fun enqueue(op: Op) {
        ops.addLast(op)
        if (currentOp == null) nextOp()
    }

    private fun nextOp() {
        val g = gatt ?: return
        val op = ops.removeFirstOrNull() ?: return
        currentOp = op
        val outcome = try {
            op.run(g)
        } catch (e: Exception) {
            Log.w(TAG, "GATT operation failed", e)
            OP_FAILED
        }
        when (outcome) {
            OP_STARTED -> handler.postDelayed(opTimeout, OP_TIMEOUT_MS)
            OP_DONE -> finishOp(true)
            else -> finishOp(false)
        }
    }

    private fun finishOp(ok: Boolean) {
        handler.removeCallbacks(opTimeout)
        val op = currentOp ?: return
        currentOp = null
        op.onDone?.invoke(ok)
        if (currentOp == null) nextOp()
    }

    private fun enableNotify(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic): Int {
        if (!g.setCharacteristicNotification(characteristic, true)) return OP_FAILED
        val cccd = characteristic.getDescriptor(CCCD) ?: return OP_DONE
        val props = characteristic.properties
        val value = if (props and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0 &&
            props and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
        ) {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        }
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            cccd.value = value
            @Suppress("DEPRECATION")
            g.writeDescriptor(cccd)
        }
        return if (started) OP_STARTED else OP_FAILED
    }

    // ── Incoming data ────────────────────────────────────────────────────────

    private fun onNotification(g: BluetoothGatt, uuid: UUID, value: ByteArray) {
        if (g !== gatt) return
        when (uuid) {
            SOS_CHAR, NUS_TX_CHAR -> {
                if (filter.accept(value, SystemClock.elapsedRealtime())) triggerSos()
            }
            BATTERY_CHAR -> onBattery(value)
        }
    }

    private fun onBattery(value: ByteArray) {
        if (value.isEmpty()) return
        PendantLink.update(battery = (value[0].toInt() and 0xFF).coerceIn(0, 100))
    }

    private fun triggerSos() {
        Log.i(TAG, "HARDWARE SOS from pendant $target")
        acquireSosWakeLock()
        DeadlineDartRunner.run(this, "hardwareSos", mapOf("source" to "ESP32 Hardware")) { result ->
            Log.i(TAG, "Hardware SOS result: $result")
            if (result == null || result == "skipped" || result == "failed") postSosFailureNotification()
            DeadlineDartRunner.destroyHeadless() // frees a headless engine only once nothing else uses it
            releaseSosWakeLock()
        }
    }

    private fun acquireSosWakeLock() {
        releaseSosWakeLock()
        val pm = getSystemService(PowerManager::class.java) ?: return
        sosWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WomanGuard:PendantSos").apply {
            setReferenceCounted(false)
            acquire(SOS_WAKE_MS)
        }
    }

    private fun releaseSosWakeLock() {
        sosWakeLock?.let { if (it.isHeld) runCatching { it.release() } }
        sosWakeLock = null
    }

    // ── Bluetooth adapter on / off ───────────────────────────────────────────

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                    if (gatt == null && PendantLink.status == PendantLink.STATUS_BLUETOOTH_OFF) return
                    Log.i(TAG, "Bluetooth turned off")
                    handler.removeCallbacks(reconnect)
                    closeGatt()
                    filter.onDisconnected()
                    if (phase == Phase.TRIAL) {
                        PendantLink.completeConnect("failed", "Bluetooth was turned off")
                        return trialFailed()
                    }
                    if (phase == Phase.DIRECT) PendantLink.completeConnect("failed", "Bluetooth was turned off")
                    phase = Phase.WAITING
                    PendantLink.update(status = PendantLink.STATUS_BLUETOOTH_OFF, rssi = 0)
                    updateNotification()
                }
                BluetoothAdapter.STATE_ON -> {
                    if (target == null || gatt != null) return
                    Log.i(TAG, "Bluetooth back on; reconnecting pendant")
                    phase = Phase.WAITING
                    reconnectDelayMs = RECONNECT_MIN_MS
                    handler.removeCallbacks(reconnect)
                    handler.postDelayed(reconnect, RECONNECT_MIN_MS)
                }
            }
        }
    }

    private fun bluetoothAdapter(): BluetoothAdapter? =
        getSystemService(BluetoothManager::class.java)?.adapter

    private fun isBluetoothOn(): Boolean = runCatching { bluetoothAdapter()?.isEnabled == true }.getOrDefault(false)

    // ── GATT callback (binder thread -> main thread) ─────────────────────────

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                if (g !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    onConnected(g)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    onLinkFailed(if (phase == Phase.UP) "link lost (status $status)" else "GATT error $status")
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            handler.post {
                if (g !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    onServicesDiscovered(g)
                } else {
                    handler.removeCallbacks(discoveryTimeout)
                    onLinkFailed("service discovery failed (status $status)", clearCache = true)
                }
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            handler.post { if (g === gatt) finishOp(status == BluetoothGatt.GATT_SUCCESS) }
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            val uuid = characteristic.uuid
            val copy = value.copyOf()
            handler.post { onRead(g, uuid, copy, status) }
        }

        @Deprecated("Used below Android 13")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val uuid = characteristic.uuid
            val copy = characteristic.value?.copyOf() ?: ByteArray(0)
            handler.post { onRead(g, uuid, copy, status) }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val uuid = characteristic.uuid
            val copy = value.copyOf()
            handler.post { onNotification(g, uuid, copy) }
        }

        @Deprecated("Used below Android 13")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            // Copy now: the stack reuses the characteristic's buffer for the next packet.
            val uuid = characteristic.uuid
            val copy = characteristic.value?.copyOf() ?: return
            handler.post { onNotification(g, uuid, copy) }
        }

        override fun onReadRemoteRssi(g: BluetoothGatt, rssi: Int, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            handler.post { if (g === gatt && phase == Phase.UP) PendantLink.update(rssi = rssi) }
        }
    }

    private fun onRead(g: BluetoothGatt, uuid: UUID, value: ByteArray, status: Int) {
        if (g !== gatt) return
        val ok = status == BluetoothGatt.GATT_SUCCESS
        if (ok && uuid == BATTERY_CHAR) onBattery(value)
        finishOp(ok)
    }

    // ── Notification ─────────────────────────────────────────────────────────

    private fun buildNotification(): android.app.Notification {
        val (title, text) = when (PendantLink.status) {
            PendantLink.STATUS_CONNECTED ->
                "ESP32 pendant connected" to "Press the pendant button to send SOS, even when the app is closed."
            PendantLink.STATUS_CONNECTING ->
                "Connecting to ESP32 pendant" to "Keep the pendant switched on and nearby."
            PendantLink.STATUS_BLUETOOTH_OFF ->
                "Bluetooth is off" to "Turn on Bluetooth to reconnect your ESP32 pendant."
            else ->
                "ESP32 pendant out of range" to "It reconnects automatically when the pendant is nearby."
        }
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, NotificationChannels.GUARDIAN_PROTECTION)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(open)
            .build()
    }

    private fun enterForeground(): Boolean = try {
        NotificationChannels.ensureCreated(this)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), type)
        true
    } catch (e: Exception) {
        Log.e(TAG, "startForeground failed", e)
        false
    }

    private fun updateNotification() {
        runCatching { NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, buildNotification()) }
    }

    private fun postSosFailureNotification() {
        val open = PendingIntent.getActivity(
            this, SOS_FAILURE_NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(this, NotificationChannels.SAFETY_CHECKS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Pendant SOS could not be sent")
            .setContentText("Open Woman Guard and press SOS if you need help.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(this).notify(SOS_FAILURE_NOTIFICATION_ID, n) }
    }

    private fun stopIfIdle() {
        if (target == null) stopClean()
    }

    private fun stopClean() {
        runCatching { ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }
}

private const val OP_STARTED = 0
private const val OP_DONE = 1
private const val OP_FAILED = 2

/**
 * Strict filter for packets on the pendant's SOS characteristic; same rules as the Dart
 * `SosPacketFilter`. Accepts only `SOS` or `SOS:<sequence>` (any case), and ignores packets in the
 * first [CONNECT_SETTLE_MS] after connecting, a repeated sequence number, and anything within
 * [HW_COOLDOWN_MS] of the last accepted trigger. Times are SystemClock.elapsedRealtime().
 */
class PendantSosFilter {
    companion object {
        const val HW_COOLDOWN_MS = 30_000L
        const val CONNECT_SETTLE_MS = 3_000L
        const val MAX_PACKET_LENGTH = 32
        private val SOS_PACKET = Regex("^SOS(?::(\\d+))?$")
    }

    private var connectedAt: Long? = null
    private var lastTriggerAt: Long? = null
    private var lastSeq: Int? = null

    fun onConnected(now: Long) {
        connectedAt = now
        lastSeq = null
    }

    fun onDisconnected() {
        connectedAt = null
    }

    fun accept(data: ByteArray, now: Long): Boolean {
        if (data.isEmpty() || data.size > MAX_PACKET_LENGTH) return false
        val since = connectedAt ?: return false
        if (now - since < CONNECT_SETTLE_MS) return false
        val text = String(data, Charsets.UTF_8).trim().uppercase()
        val match = SOS_PACKET.matchEntire(text)
        if (match == null) {
            Log.d("WG/PendantLink", "Ignored non-SOS packet: \"$text\"")
            return false
        }
        val seq = match.groupValues[1].takeIf { it.isNotEmpty() }?.toIntOrNull()
        if (seq != null && seq == lastSeq) return false
        val last = lastTriggerAt
        if (last != null && now - last < HW_COOLDOWN_MS) return false
        lastSeq = seq
        lastTriggerAt = now
        return true
    }
}
