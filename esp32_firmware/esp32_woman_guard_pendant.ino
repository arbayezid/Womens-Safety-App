/**
 * ============================================================================
 * WOMAN GUARD - ESP32 SMART SAFETY PENDANT BLE FIRMWARE
 * ============================================================================
 * 
 * Hardware Requirements:
 * - Any standard ESP32 development board (e.g., ESP32 NodeMCU, ESP32-WROOM-32, 
 *   ESP32-S3, or Xiao ESP32-C3 wearable board).
 * - 1x Push Button connected between GPIO 4 (or GPIO 0) and GND (Active LOW).
 * - Optional: 1x Status LED connected to GPIO 2 (built-in LED).
 * 
 * Instructions:
 * 1. Open Arduino IDE.
 * 2. Ensure "esp32 by Espressif Systems" is installed in Boards Manager.
 * 3. Select board: "ESP32 Dev Module" (or your specific board).
 * 4. Connect ESP32 via USB and click Upload.
 * 5. Open Woman Guard Flutter App -> Tap "ESP32 Offline" badge -> Discover & Connect!
 * ============================================================================
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ── Device & UUID Configurations ───────────────────────────────────────────
#define DEVICE_NAME "ESP32-Safety-Pendant"

// Primary Service UUID matching Woman Guard App (Esp32BleService)
#define SERVICE_UUID                 "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
// SOS Characteristic UUID (Notify)
#define SOS_CHARACTERISTIC_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26a8"
// Standard Bluetooth SIG Battery Service & Characteristic UUID
#define BATTERY_SERVICE_UUID         "0000180f-0000-1000-8000-00805f9b34fb"
#define BATTERY_CHARACTERISTIC_UUID  "00002a19-0000-1000-8000-00805f9b34fb"

// ── Hardware Pin Definitions ───────────────────────────────────────────────
#define BUTTON_PIN   4    // Push button pin (Internal PULLUP, connects to GND)
#define LED_PIN      2    // Built-in LED (GPIO 2 on most ESP32 boards)

// ── Global BLE Pointers ───────────────────────────────────────────────────
BLEServer* pServer = NULL;
BLECharacteristic* pSosCharacteristic = NULL;
BLECharacteristic* pBatteryCharacteristic = NULL;

bool deviceConnected = false;
bool oldDeviceConnected = false;
uint8_t batteryLevel = 95; // Initial battery percentage (simulate or read ADC)

// Debouncing & double-click parameters
unsigned long lastDebounceTime = 0;
const unsigned long debounceDelay = 250; // ms debounce

// ── BLE Server Callbacks ───────────────────────────────────────────────────
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("[BLE] >>> App Connected to ESP32 Smart Pendant! <<<");
    digitalWrite(LED_PIN, HIGH); // Turn LED ON when connected
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("[BLE] <<< App Disconnected. Restarting Advertising... <<<");
    digitalWrite(LED_PIN, LOW); // Turn LED OFF when disconnected
  }
};

void setup() {
  Serial.begin(115200);
  delay(500);

  Serial.println("=============================================");
  Serial.println(" Woman Guard - ESP32 Smart Pendant Initializing");
  Serial.println("=============================================");

  // Setup hardware pins
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  // Initialize BLE
  BLEDevice::init(DEVICE_NAME);

  // Create BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // 1. Create Woman Guard Primary Safety Service
  BLEService* pSafetyService = pServer->createService(SERVICE_UUID);

  // Create SOS Characteristic with Notify property
  pSosCharacteristic = pSafetyService->createCharacteristic(
    SOS_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pSosCharacteristic->addDescriptor(new BLE2902());
  pSosCharacteristic->setValue("READY");
  pSafetyService->start();

  // 2. Create Standard Battery Service
  BLEService* pBatteryService = pServer->createService(BATTERY_SERVICE_UUID);
  pBatteryCharacteristic = pBatteryService->createCharacteristic(
    BATTERY_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pBatteryCharacteristic->addDescriptor(new BLE2902());
  pBatteryCharacteristic->setValue(&batteryLevel, 1);
  pBatteryService->start();

  // 3. Start Advertising with Name in Scan Response Data
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);

  // Explicitly bundle the device name into the scan response payload
  BLEAdvertisementData oScanResponseData;
  oScanResponseData.setName(DEVICE_NAME);
  pAdvertising->setScanResponseData(oScanResponseData);

  pAdvertising->setMinPreferred(0x06); // Helps iPhone & Android connection
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Advertising started. Waiting for Woman Guard app...");
}

void loop() {
  // ── Handle Disconnection & Restart Advertising ──────────────────────────
  if (!deviceConnected && oldDeviceConnected) {
    delay(500); // Give Bluetooth stack time to get ready
    pServer->startAdvertising();
    Serial.println("[BLE] Re-advertising started...");
    oldDeviceConnected = deviceConnected;
  }
  
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  // ── Read Physical Push Button (Active LOW: LOW when pressed) ────────────
  int buttonState = digitalRead(BUTTON_PIN);

  if (buttonState == LOW) {
    unsigned long currentTime = millis();
    if ((currentTime - lastDebounceTime) > debounceDelay) {
      lastDebounceTime = currentTime;

      Serial.println("\n[ALERT] !!! PHYSICAL SOS BUTTON PRESSED !!!");

      // Blink LED rapidly to indicate trigger dispatch
      for (int i = 0; i < 4; i++) {
        digitalWrite(LED_PIN, !digitalRead(LED_PIN));
        delay(60);
      }
      digitalWrite(LED_PIN, deviceConnected ? HIGH : LOW);

      // Send SOS Notification to connected Flutter App
      if (deviceConnected && pSosCharacteristic != NULL) {
        // Send alert packet: "SOS"
        const char* alertMsg = "SOS";
        pSosCharacteristic->setValue((uint8_t*)alertMsg, strlen(alertMsg));
        pSosCharacteristic->notify();
        Serial.println("[BLE] Notification sent: 'SOS' packet dispatched to App!");
      } else {
        Serial.println("[BLE] ⚠️ Not connected to app. Cannot dispatch notification.");
      }
    }
  }

  delay(20);
}

