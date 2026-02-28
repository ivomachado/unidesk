# ESP32-S3 Firmware — ViewFinity Brightness Bridge

ESP-IDF firmware that receives brightness commands over USB-CDC serial from the macOS app and translates them into BLE HID Consumer Control reports, adjusting the Samsung ViewFinity S9 monitor's brightness. After initial pairing, the board reconnects to the monitor automatically on power-up — no Mac involvement needed.

---

## Requirements

- **ESP32-S3 DevKit** (any variant with native USB — e.g., ESP32-S3-DevKitC-1)
- **ESP-IDF v5.x** installed and configured
- **USB-C cable** for flashing and communication

---

## Board Setup

The ESP32-S3 DevKit has two USB-C ports:

| Port | Label | Purpose | macOS Device |
|------|-------|---------|--------------|
| **COM** | USB-UART | Flashing firmware & debug logs (`idf.py flash monitor`) | `/dev/cu.usbserial-*` |
| **USB** | Native USB | CDC serial communication with the macOS app | `/dev/cu.usbmodem*` |

Both ports can be connected simultaneously. In production, only the **USB** port is needed.

### USB Descriptor

The firmware configures TinyUSB with:

- **VID:** `0x303A` (Espressif)
- **PID:** `0x4001` (TinyUSB CDC default)
- **Device name:** `VF9 Brightness Bridge`

The macOS app uses this VID/PID pair to auto-discover the board among serial devices.

---

## Build & Flash

```sh
cd firmware

# First time only — set the target chip
idf.py set-target esp32s3

# Build and flash (connect via the COM port)
idf.py build flash

# Monitor debug output (UART console)
idf.py monitor
```

Press `Ctrl+]` to exit the monitor.

### Console Output

Debug logs are routed to **UART0** (the COM port) to avoid conflicts with the native USB-CDC port. The firmware logs every serial command received, every response sent, BLE connection/disconnection events, bonding events, and HID report sends with success/failure status.

---

## Architecture

```
main.cpp (app_main)
    │
    ├── NvsManager            ← NVS init, bond storage, clear bonds
    │
    ├── BleHidService         ← BLE HOGP: GAP, GATT, HID service, bonding
    │       │
    │       ▼
    ├── BrightnessControl     ← Sends HID reports (brightness + ESC dismiss)
    │
    ├── UsbSerial             ← TinyUSB CDC: read/write serial data
    │       │
    │       ▼
    └── CommandHandler        ← Maps serial bytes → actions, sends responses
```

### Source Files

| File | Description |
|------|-------------|
| `main.cpp` | `app_main()` — initializes all components and enters idle loop |
| `nvs_manager.h/cpp` | NVS flash init, bond clearing, bonded state check |
| `ble_hid_service.h/cpp` | BLE HOGP service: GAP config, GATT server, HID report map, advertising, bonding |
| `brightness_control.h/cpp` | Brightness HID report sequences (Consumer Control + ESC dismiss) |
| `usb_serial.h/cpp` | TinyUSB CDC serial interface: read callback, response writing |
| `command_handler.h/cpp` | Serial command dispatcher: maps `0x01`–`0x06` to actions |

---

## Serial Protocol

See [PROTOCOL.md](../PROTOCOL.md) for the full serial communication specification.

### Quick Reference

| Command Byte | Action | Response |
|-------------|--------|----------|
| `0x01` | Brightness Up | `OK:UP\n` |
| `0x02` | Brightness Down | `OK:DOWN\n` |
| `0x03` | Enter Pairing Mode | `OK:PAIRING\n` |
| `0x04` + nonce + `\n` | Handshake | `OK:PING:<nonce>\n` |
| `0x05` | Get Status | `STATUS:<state>:<name>\n` |
| `0x06` | Unpair | `OK:UNPAIRED\n` |

---

## BLE HID Details

### Profile

The firmware implements **HID Over GATT Profile (HOGP)** with:

- **HID Service** (`0x1812`) — Consumer Control + Keyboard reports
- **Battery Service** (`0x180F`) — some monitors expect this
- **Device Information Service** (`0x180A`) — manufacturer, model, PnP ID

### HID Report Map

Two input report collections:

| Report ID | Type | Size | Purpose |
|-----------|------|------|---------|
| 1 | Consumer Control | 2 bytes | Brightness increment/decrement (16-bit usage code) |
| 2 | Keyboard | 8 bytes | ESC key to dismiss the monitor's OSD |

### Consumer Control Usage Codes

| Usage Code | Meaning |
|-----------|---------|
| `0x006F` | Brightness Increment |
| `0x0070` | Brightness Decrement |
| `0x0000` | Release (no key) |

### Brightness Key Sequence

Each brightness command sends a full press/release cycle followed by an ESC to dismiss the ViewFinity S9's on-screen brightness UI:

1. **Consumer Control press** — Report ID 1: `[0x6F, 0x00]` (brightness up) or `[0x70, 0x00]` (down)
2. **Wait 20ms**
3. **Consumer Control release** — Report ID 1: `[0x00, 0x00]`
4. **Wait 50ms** — let the OSD appear
5. **ESC press** — Report ID 2: `[0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00]`
6. **Wait 20ms**
7. **ESC release** — Report ID 2: all zeros

The ESC key press is **debounced** with a 400ms timeout: during rapid brightness adjustments (e.g., key held down), only a single ESC is sent after the burst settles, avoiding redundant OSD dismissals.

---

## BLE Pairing & Bonding

### Security Configuration

- **Auth mode:** `ESP_LE_AUTH_BOND` — encryption keys stored in NVS
- **IO capability:** `ESP_IO_CAP_NONE` — "Just Works" pairing (no PIN)
- **Key distribution:** `ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK` (both local and peer)

### Pairing Flow

1. The macOS app sends command `0x03` (Enter Pairing Mode).
2. The firmware clears all bonds from NVS and restarts BLE advertising in undirected mode.
3. On the ViewFinity S9, navigate to Settings → Connection → Bluetooth Device Manager.
4. The monitor discovers `VF9 Brightness Bridge` and pairs.
5. Encryption keys are stored in NVS — the monitor will reconnect automatically on subsequent power cycles.

### Advertising Behavior

- **On boot (bonded):** Starts directed advertising so the previously paired monitor reconnects quickly.
- **On boot (not bonded):** Starts undirected advertising, waiting for pairing.
- **On disconnect:** Restarts advertising automatically.
- **On pairing mode:** Clears bonds, switches to undirected advertising.

### Multi-Mac Usage

All pairing state lives on the ESP32's NVS. The macOS app is stateless with respect to BLE pairing. Move the board to any Mac with the app installed — it reconnects to the monitor independently.

---

## sdkconfig

Key configuration options in `sdkconfig.defaults`:

```
# BLE
CONFIG_BT_ENABLED=y
CONFIG_BT_BLE_ENABLED=y
CONFIG_BT_BLUEDROID_ENABLED=y
CONFIG_BT_BLE_SMP_ENABLE=y

# NVS
CONFIG_NVS_ENABLED=y

# USB-CDC
CONFIG_TINYUSB_ENABLED=y
CONFIG_TINYUSB_CDC_ENABLED=y
CONFIG_TINYUSB_CDC_COUNT=1

# Console on UART (not USB — avoids CDC conflict)
CONFIG_ESP_CONSOLE_UART_DEFAULT=y
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| macOS app says "Board found but firmware did not respond" | Wrong firmware or USB port | Make sure you're connected via the **USB** port (not COM). Reflash firmware. |
| Monitor doesn't see `VF9 Brightness Bridge` | Not in pairing mode | Send `0x03` via the app's "Pair Monitor" button. Check that BLE advertising is active in the monitor output. |
| Brightness keys do nothing | BLE not connected | Check `0x05` status response. The monitor may need to be power-cycled to reconnect. |
| OSD stays on screen | ESC timing issue | The 50ms delay before ESC may need tuning for your monitor's firmware version. |
| `idf.py monitor` shows garbled output | Wrong UART baud rate | Ensure `idf.py monitor` uses the default baud rate matching your sdkconfig. |