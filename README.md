# UniDesk

UniDesk is a small macOS menu-bar utility plus ESP32‑S3 firmware that lets your Mac's brightness and volume keys control a Samsung ViewFinity S9 monitor as if it were a native display.

When the cursor is on the ViewFinity S9, brightness and volume key presses are routed through the macOS app to an ESP32‑S3 board over USB‑CDC. The board sends BLE HID Consumer Control reports to adjust brightness or volume on the monitor. When the cursor is on your Mac's built-in display (or a natively compatible monitor), macOS handles keys normally.

---

## How It Works

```
┌──────────────┐    Brightness/Volume    ┌──────────────┐    USB-CDC     ┌──────────────┐    BLE HID     ┌──────────────┐
│              │    key press (brightness/volume) │              │    serial      │              │    Consumer    │              │
│   MacBook    │ ───────────────────────────────▶ │   macOS App  │ ────────────▶  │   ESP32-S3   │ ────────────▶  │ ViewFinity   │
│   Keyboard   │                                  │  (menu bar)  │   0x01/0x02 /  │  (firmware)  │    Control    │     S9       │
│              │                                  │              │   0x0A/0x0B    │              │   brightness/ │              │
│              │                                  │              │               │              │   volume HID  │              │
└──────────────┘                                  └──────────────┘               └──────────────┘               └──────────────┘
```

1. The **macOS menu bar app** intercepts brightness key presses via `CGEventTap` and tracks which display the cursor is on.
2. If the cursor is over the **ViewFinity S9**, the macOS app sends a single-byte command over USB serial to the ESP32-S3.
3. The **ESP32-S3 firmware** receives the command and sends the corresponding BLE HID Consumer Control report (Brightness Increment/Decrement or Volume Increment/Decrement) to the monitor.
4. If the cursor is over the **built-in display** or a compatible external monitor, macOS handles brightness natively — the app doesn't interfere.

---

## Hardware Requirements

- **Samsung ViewFinity S9** monitor (27″ or 32″ — models S27C900P, S32C900P, or similar)
- **ESP32-S3 DevKit** board (any variant with native USB — e.g., ESP32-S3-DevKitC-1)
- **USB-C cable** to connect the ESP32-S3's native USB port to your Mac

The ESP32-S3 has two USB-C ports:

| Port | Purpose | macOS Device |
|------|---------|--------------|
| **COM** | UART bridge — flashing firmware & debug logs | `/dev/cu.usbserial-*` |
| **USB** | Native USB — CDC serial communication with the app | `/dev/cu.usbmodem*` |

In daily use, only the **USB** port needs to be connected. The COM port is for development only.

---

## Components

### [macOS App](macos-app/README.md)

A Swift/SwiftUI menu bar application that intercepts brightness and volume keys, detects which display the cursor is on, and routes commands accordingly. Requires macOS 13+ and Accessibility permission.

### [ESP32-S3 Firmware](firmware/README.md)

ESP-IDF firmware that receives brightness and volume commands over USB-CDC serial and translates them into BLE HID reports. Handles bonding persistence, pairing management, and automatic reconnection to the monitor.

### [Serial Protocol](PROTOCOL.md)

The communication protocol between the macOS app and the ESP32-S3 firmware over USB-CDC serial.

---

## Quick Start

### 1. Flash the firmware

```sh
cd firmware
idf.py set-target esp32s3
idf.py build flash
```

See [firmware/README.md](firmware/README.md) for detailed setup instructions.

### 2. Build the macOS app

```sh
cd macos-app
xcodebuild -project UniDesk.xcodeproj \
  -scheme UniDesk \
  -configuration Release \
  -derivedDataPath build clean build
```

Copy `build/Build/Products/Release/UniDesk.app` to `/Applications` (Xcode's product name may still show the old name until you update the project settings; check the `Release` folder for the actual `.app` filename).

See [macos-app/README.md](macos-app/README.md) for detailed build and installation instructions.

### 3. Pair the monitor

1. Connect the ESP32-S3's **USB** port to your Mac.
2. Launch the app — it auto-detects the board and performs a handshake.
3. Click **Pair Monitor** in the menu bar popover.
4. Accept the Bluetooth pairing request on your ViewFinity S9.
5. Done — brightness keys now work on the S9 when the cursor is over it.

---

## Multi-Mac Usage

The pairing state lives entirely on the ESP32-S3's NVS (non-volatile storage). Move the board to any Mac with UniDesk installed and it reconnects to the monitor automatically — no re-pairing needed.

---

## FiiO / External Audio Device Volume Control

UniDesk also supports routing macOS volume key presses directly to Bluetooth audio devices and monitors that accept HID Consumer Control volume commands (for example certain FiiO devices and some Bluetooth-capable monitors). When paired through the ESP32-S3 bridge, UniDesk forwards standard Consumer Control Volume Up/Down HID reports (the firmware's FiiO quadrature commands are preserved in the serial protocol) so the target device's hardware volume is adjusted directly instead of changing the macOS system volume.


## License

This project is for personal use.
