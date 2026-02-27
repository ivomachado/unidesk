# ESP32-S3 Firmware — Implementation Plan

## Tech Stack

- **Language:** C++ (with ESP-IDF C APIs wrapped in classes)
- **Framework:** ESP-IDF v5.x
- **Build:** CMake (ESP-IDF default)
- **BLE:** Bluedroid stack (`esp_bt`, `esp_gatts_api`, `esp_gap_ble_api`)
- **USB:** TinyUSB CDC via ESP-IDF's native USB support (`tinyusb`, `tusb_cdc_acm`)
- **Storage:** NVS (`nvs_flash`) for bonding persistence

---

## Project Structure

```
firmware/
├── CMakeLists.txt                    # Top-level ESP-IDF project CMake
├── sdkconfig.defaults                # Pre-set config (BLE, USB-CDC, NVS, etc.)
├── PLAN.md                           # This file
├── main/
│   ├── CMakeLists.txt                # Component CMake (source list)
│   ├── main.cpp                      # app_main() — init & run loop
│   ├── ble_hid_service.h             # BLE HOGP service class
│   ├── ble_hid_service.cpp           # GATT server, GAP, HID report map, bonding
│   ├── usb_serial.h                  # USB-CDC serial interface class
│   ├── usb_serial.cpp                # TinyUSB CDC read/write, command dispatch
│   ├── command_handler.h             # Serial command router
│   ├── command_handler.cpp           # Maps 0x01–0x06 → actions, sends responses
│   ├── brightness_control.h          # Brightness HID report sender
│   ├── brightness_control.cpp        # Sends Consumer Control brightness codes
│   └── nvs_manager.h                 # Thin NVS wrapper (bond clear, status read)
│   └── nvs_manager.cpp
```

---

## Implementation Order

### 1. `NvsManager`

- Initialize NVS flash (`nvs_flash_init`, handle `ESP_ERR_NVS_NO_FREE_PAGES` with erase+reinit).
- Provide `clear_bonds()` — erases the BLE bonding namespace to force re-pairing.
- Provide `is_bonded()` — checks whether any bond keys exist.

### 2. `BleHidService`

Core BLE HOGP implementation:

- **GAP Configuration:**
  - Set device name: `"VF9 Brightness Bridge"`.
  - Configure advertising data with HID appearance (`ESP_BLE_APPEARANCE_HID_KEYBOARD`).
  - Set security: `ESP_LE_AUTH_BOND | ESP_LE_AUTH_REQ_SC_MITM_BOND` for bonding persistence.
  - Configure IO capability: `ESP_IO_CAP_NONE` (Just Works pairing).
  - Store encryption keys in NVS automatically (`ESP_BLE_SM_AUTHEN_REQ_MODE`).

- **GATT Server:**
  - Register an HID service (UUID `0x1812`).
  - Include required characteristics:
    - **HID Information** (`0x2A4A`): version, country code, flags.
    - **Report Map** (`0x2A4B`): USB HID descriptor declaring Consumer Control + Keyboard.
    - **Report** (`0x2A4D`): two input reports — Report ID 1 (Consumer Control, 2 bytes) and Report ID 2 (Keyboard, 8 bytes).
    - **Protocol Mode** (`0x2A4E`): Report Protocol.
  - Include **Battery Service** (`0x180F`) — some monitors expect this.
  - Include **Device Information Service** (`0x180A`): manufacturer, model, PnP ID.

- **Report Map (HID Descriptor):**
  ```
  // --- Report ID 1: Consumer Control (brightness keys) ---
  Usage Page (Consumer Devices)        0x05, 0x0C
  Usage (Consumer Control)             0x09, 0x01
  Collection (Application)             0xA1, 0x01
    Report ID (1)                      0x85, 0x01
    Logical Minimum (0)                0x15, 0x00
    Logical Maximum (0x3FF)            0x26, 0xFF, 0x03
    Usage Minimum (0)                  0x19, 0x00
    Usage Maximum (0x3FF)              0x2A, 0xFF, 0x03
    Report Size (16)                   0x75, 0x10
    Report Count (1)                   0x95, 0x01
    Input (Data, Array, Absolute)      0x81, 0x00
  End Collection                       0xC0

  // --- Report ID 2: Keyboard (ESC key to dismiss OSD) ---
  Usage Page (Generic Desktop)         0x05, 0x01
  Usage (Keyboard)                     0x09, 0x06
  Collection (Application)             0xA1, 0x01
    Report ID (2)                      0x85, 0x02
    // Modifier byte
    Usage Page (Key Codes)             0x05, 0x07
    Usage Minimum (0xE0)               0x19, 0xE0
    Usage Maximum (0xE7)               0x2A, 0xE7
    Logical Minimum (0)                0x15, 0x00
    Logical Maximum (1)                0x25, 0x01
    Report Size (1)                    0x75, 0x01
    Report Count (8)                   0x95, 0x08
    Input (Data, Variable, Absolute)   0x81, 0x02
    // Reserved byte
    Report Count (1)                   0x95, 0x01
    Report Size (8)                    0x75, 0x08
    Input (Constant)                   0x81, 0x01
    // Key array (6 keys)
    Usage Page (Key Codes)             0x05, 0x07
    Usage Minimum (0)                  0x19, 0x00
    Usage Maximum (0xFF)               0x2A, 0xFF, 0x00
    Logical Minimum (0)                0x15, 0x00
    Logical Maximum (0xFF)             0x26, 0xFF, 0x00
    Report Size (8)                    0x75, 0x08
    Report Count (6)                   0x95, 0x06
    Input (Data, Array, Absolute)      0x81, 0x00
  End Collection                       0xC0
  ```

- **Advertising:**
  - Start advertising on boot if bonded (directed) or undirected if not bonded.
  - On pairing mode: stop advertising → clear bonds → restart undirected advertising.

- **Connection Events:**
  - Track connection state (connected/disconnected) and peer device name.
  - On connect: stop advertising, store connection handle.
  - On disconnect: restart advertising.
  - On bonding complete: log the bonded device name.

- **Public API:**
  - `init()` — start the BLE stack and register services.
  - `start_advertising()` / `stop_advertising()`.
  - `send_report(uint16_t usage_code)` — send a Consumer Control HID input report.
  - `is_connected() -> bool`.
  - `get_peer_name() -> std::string`.
  - `enter_pairing_mode()` — clear bonds and restart advertising.
  - `unpair()` — clear bonds, disconnect if connected.

### 3. `BrightnessControl`

Thin wrapper around `BleHidService` report sending:

- `brightness_up()` — full sequence:
  1. Send Consumer Control report (ID 1): usage `0x006F` (Brightness Increment).
  2. Wait ~20 ms.
  3. Send Consumer Control release (ID 1): usage `0x0000`.
  4. Wait ~50 ms for the monitor OSD to appear.
  5. Send Keyboard report (ID 2): ESC key (`0x29`).
  6. Wait ~20 ms.
  7. Send Keyboard release (ID 2): all zeros.
- `brightness_down()` — same sequence but with usage `0x0070` (Brightness Decrement).
- Returns `true` if the BLE connection was active and all reports were sent.
- The ESC key dismisses the Samsung ViewFinity S9's on-screen brightness UI, which otherwise stays visible indefinitely.

### 4. `UsbSerial`

USB-CDC interface using ESP-IDF's TinyUSB integration:

- **Init:**
  - Configure TinyUSB descriptors: set VID `0x303A`, PID `0x1001` (Espressif default).
  - Set device strings: manufacturer, product name (`"VF9 Brightness Bridge"`), serial.
  - Initialize `tinyusb_driver_install()` and `tusb_cdc_acm_init()`.

- **Read Loop:**
  - Register a CDC receive callback (`tinyusb_cdcacm_register_callback`).
  - On data received: read bytes, forward each byte to `CommandHandler`.

- **Write:**
  - `send_response(const std::string& response)` — writes a newline-terminated ASCII string to CDC.
  - Handle write buffering and flush.

### 5. `CommandHandler`

Dispatches incoming serial bytes to the appropriate action:

- Receives a single byte from `UsbSerial`.
- Routes based on command byte:

  | Byte   | Action                                              | Response                                |
  |--------|-----------------------------------------------------|-----------------------------------------|
  | `0x01` | `BrightnessControl::brightness_up()`                | `OK:UP\n` or `ERR:NOT_CONNECTED\n`      |
  | `0x02` | `BrightnessControl::brightness_down()`              | `OK:DOWN\n` or `ERR:NOT_CONNECTED\n`    |
  | `0x03` | `BleHidService::enter_pairing_mode()`               | `OK:PAIRING\n`                          |
  | `0x04` | Handshake ping                                      | `OK:PING\n`                             |
  | `0x05` | Query `BleHidService` state                         | `STATUS:<connected\|disconnected>:<name>\n` |
  | `0x06` | `BleHidService::unpair()`                           | `OK:UNPAIRED\n`                         |
  | other  | —                                                   | `ERR:UNKNOWN_CMD\n`                     |

### 6. `main.cpp`

Entry point (`app_main()`):

1. Initialize NVS (`NvsManager::init()`).
2. Initialize BLE stack and HOGP service (`BleHidService::init()`).
3. Start BLE advertising.
4. Initialize USB-CDC (`UsbSerial::init()`).
5. Wire `UsbSerial` → `CommandHandler` → `BrightnessControl` / `BleHidService`.
6. Enter idle loop (FreeRTOS `vTaskDelay` or event-driven).

---

## Serial Protocol

### Commands (Mac → ESP32)

| Byte   | Command              |
|--------|----------------------|
| `0x01` | Brightness Up        |
| `0x02` | Brightness Down      |
| `0x03` | Enter Pairing Mode   |
| `0x04` | Handshake / Ping     |
| `0x05` | Get Status & Name    |
| `0x06` | Unpair / Clear Bond  |

### Responses (ESP32 → Mac)

All responses are newline-terminated ASCII strings prefixed by a tag:

| Response format                             | When             | Description                                                           |
|---------------------------------------------|------------------|-----------------------------------------------------------------------|
| `OK:PING\n`                                 | After `0x04`     | Firmware is alive and running the expected protocol.                   |
| `OK:UP\n`                                   | After `0x01`     | Brightness-up HID report sent successfully.                           |
| `OK:DOWN\n`                                 | After `0x02`     | Brightness-down HID report sent successfully.                         |
| `OK:PAIRING\n`                              | After `0x03`     | NVS cleared, advertising restarted — board is in pairing mode.        |
| `OK:UNPAIRED\n`                             | After `0x06`     | Bond cleared successfully.                                            |
| `STATUS:<connected\|disconnected>:<name>\n` | After `0x05`     | BLE connection state and paired device name (empty if none).          |
| `ERR:<message>\n`                           | On any failure   | Human-readable error (e.g., `ERR:NOT_CONNECTED`, `ERR:UNKNOWN_CMD`). |

---

## BLE HID Details

### Consumer Control Usage Codes

| Usage Code | Meaning              |
|------------|----------------------|
| `0x006F`   | Brightness Increment |
| `0x0070`   | Brightness Decrement |
| `0x0000`   | Release (no key)     |

### Keyboard Usage Codes

| Usage Code | Meaning    |
|------------|------------|
| `0x29`     | ESC key    |
| `0x00`     | Release    |

### HID Report Structures

- **Report ID 1 (Consumer Control):** 2 bytes — 16-bit usage code, little-endian.
- **Report ID 2 (Keyboard):** 8 bytes — 1 byte modifiers, 1 byte reserved, 6 bytes key array.

### Full Brightness Press Sequence

1. Report ID 1: `[0x6F, 0x00]` (brightness up) — press
2. Wait 20 ms
3. Report ID 1: `[0x00, 0x00]` — release
4. Wait 50 ms (let OSD appear)
5. Report ID 2: `[0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00]` — ESC press
6. Wait 20 ms
7. Report ID 2: `[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]` — ESC release

### Bonding

- Auth mode: `ESP_LE_AUTH_BOND` — keys stored in NVS.
- IO capability: `ESP_IO_CAP_NONE` — "Just Works" (no PIN).
- Key distribution: `ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK` for both local and peer.
- On `ESP_GAP_BLE_AUTH_CMPL_EVT`: log success/failure and peer address.

---

## sdkconfig Essentials

```
# BLE
CONFIG_BT_ENABLED=y
CONFIG_BT_BLE_ENABLED=y
CONFIG_BT_BLUEDROID_ENABLED=y
CONFIG_BT_BLE_SMP_ENABLE=y
CONFIG_BT_BLE_BLUEDROID_BLE_ONLY=y

# NVS
CONFIG_NVS_ENABLED=y

# USB
CONFIG_TINYUSB_ENABLED=y
CONFIG_TINYUSB_CDC_ENABLED=y
CONFIG_TINYUSB_CDC_COUNT=1

# Use native USB (GPIO19/GPIO20 on S3)
CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=n
CONFIG_ESP_CONSOLE_NONE=y
```

---

## Key Considerations

- **USB-CDC and ESP console conflict:** The ESP32-S3 has two USB interfaces — the native USB (GPIO19/20) and USB-Serial-JTAG. We use the native USB for CDC. Console logging must be disabled or routed to UART to avoid conflicts.
- **BLE + USB coexistence:** Both stacks run fine simultaneously on the S3. BLE uses the radio, USB uses the USB peripheral — no resource conflicts.
- **Report Map compatibility:** Some monitors are picky about HID descriptors. The Report Map must declare Consumer Control with a 16-bit usage range. If the Samsung S9 doesn't respond, try alternative descriptor layouts (8-bit usage, bitmap-style).
- **Press/release timing:** The monitor expects a press followed by a release. Too fast and it's ignored; too slow and it might auto-repeat. 20 ms is a safe default — tune if needed. The ESC delay (50 ms after brightness release) gives the OSD time to appear before dismissing it.
- **Dual-report HID descriptor:** The Report Map declares two collections (Consumer Control + Keyboard) with separate Report IDs. Some monitors may be strict about descriptor layout — if issues arise, try splitting into two HID service instances.
- **Bonding capacity:** ESP-IDF supports up to ~10 bonded devices by default. For this use case, 1 bond (the monitor) is sufficient. Consider limiting to 1 and clearing old bonds on new pairing.
- **Advertising after boot:** If a bond exists, the board should auto-advertise on power-up so the monitor reconnects without any Mac involvement.
- **FreeRTOS stack sizes:** BLE callbacks need adequate stack. Use at least 4096 bytes for BLE-related tasks.

---

## Estimated Effort

~2–3 days for a working firmware.