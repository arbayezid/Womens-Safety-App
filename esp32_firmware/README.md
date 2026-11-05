# ESP32 Smart Safety Pendant Hardware Guide

This directory contains the firmware sketch for the **Woman Guard** wearable safety pendant / hardware button.

## 📌 Wiring Diagram

| ESP32 Pin | Component | Connection |
| :--- | :--- | :--- |
| **GPIO 4** | Push Button Leg 1 | Connect to push button leg. |
| **GND** | Push Button Leg 2 | Connect to other push button leg. (Internal pull-up enabled). |
| **GPIO 2** | Built-in LED | Indicates connection & trigger flash. |
| **VIN / 5V** | Power Source | USB or 3.7V LiPo via charging module / 5V boost. |
| **GND** | Ground | Battery / Power Ground. |

---

## 🚀 How to Flash with Arduino IDE

1. **Open Arduino IDE** (version 2.0+ recommended).
2. Go to **File -> Preferences -> Additional Boards Manager URLs** and add:
   ```
   https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
   ```
3. Go to **Tools -> Board -> Boards Manager**, search for `esp32` by Espressif Systems, and click **Install**.
4. Open [`esp32_woman_guard_pendant.ino`](./esp32_woman_guard_pendant.ino).
5. Select **Tools -> Board -> ESP32 Arduino -> ESP32 Dev Module** (or your specific board e.g. NodeMCU ESP32, Xiao ESP32-C3).
6. Connect the ESP32 board to your computer via USB and select the corresponding COM Port under **Tools -> Port**.
7. Click **Upload** (arrow icon).

---

## 📱 Connecting with the Woman Guard App

1. Once uploaded, the ESP32 will start advertising with the name **`ESP32-Safety-Pendant`**.
2. Open the **Woman Guard** mobile app on your Android phone.
3. Tap the **"ESP32 Offline"** badge in the top right header (or navigate to **Settings -> Device Setup**).
4. If your phone's Bluetooth is turned off, a prompt will appear saying **"Bluetooth is Turned Off"** with a **"Turn On Bluetooth"** button.
5. Tap **"Turn On Bluetooth"**.
6. The app will immediately start scanning and display **`ESP32-Safety-Pendant`** in the available device list with an `ESP32` tag and live signal strength (RSSI).
7. Tap **"Connect"**.
8. Once connected:
   - The top header badge turns green: **"ESP32 Connected"**.
   - Pressing the physical button on GPIO 4 triggers the app's full emergency pipeline (loud siren, SMS alert with live GPS coordinates, and guardian notification dispatch).

