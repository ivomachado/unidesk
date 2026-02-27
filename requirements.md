# Requirements for Hybrid Brightness Control System

This document outlines the implementation of a hardware-software bridge for brightness control on external monitors (e.g., Samsung ViewFinity S9) using an **ESP32-S3** and a **macOS Host App**.

---

## 1. Board Firmware (ESP32-S3)
The board acts as an independent physical bridge. Once configured, it must be capable of reconnecting to the monitor without intervention from the Mac host.

* **USB-CDC Communication:**
    * Must use the S3 chip's native USB port to emulate a Serial interface.
    * The USB device descriptor must use **VID `0x303A`** (Espressif) and **PID `0x4001`** (TinyUSB CDC default). The macOS app uses this VID/PID pair to auto-discover the board among `/dev/cu.usbmodem*` devices.
    * The code should listen for simple bytes (e.g., `0x01` to increase, `0x02` to decrease) sent by the Mac.
* **Bluetooth Keyboard Emulation (HOGP):**
    * The firmware must announce itself as an **HID Over GATT Profile** device.
    * It must send specific *Consumer Control* codes for brightness: `0x006F` (Brightness Up) and `0x0070` (Brightness Down).
    * After a brightness key press/release, the firmware must send an **ESC key** (Keyboard usage `0x29`) press/release to dismiss the monitor's on-screen brightness UI. The ESC is **debounced** (400ms timeout): during rapid brightness adjustments (e.g., key held down), only a single ESC is sent after the burst settles, avoiding redundant OSD dismissals.
* **Bonding Persistence:**
    * To work across multiple Macs, security must be configured with `ESP_LE_AUTH_BOND`.
    * This saves encryption keys in the board's **NVS (Non-Volatile Storage)**, allowing the monitor to recognize it instantly upon receiving power from any USB port.
    * The multi-host story is entirely firmware-driven: all pairing state, bond keys, and device identity live on the ESP32. The macOS app is stateless with respect to BLE pairing — it only sends commands over USB serial.
* **State Management:**
    * Implement a serial command to enter "Pairing Mode" (clear NVS and restart advertising) to facilitate initial setup via the macOS application.
    * Provide a serial command to report the paired device name and connection status.
    * Provide a serial command to unpair (clear bond) on demand from the macOS app.
    * Implement a handshake/ping command to verify the ESP32 firmware upon connection. The handshake includes a **nonce** (see Serial Protocol below) so the macOS app can distinguish the fresh response from stale responses buffered across reconnections.
* **Logging & Diagnostics:**
    * The firmware must output verbose logs via UART (COM port) for debugging with `idf.py monitor`.
    * Logs must include: every USB serial byte received, every serial response sent, every command dispatched, BLE connection/disconnection events, BLE bonding events, and step-by-step HID report sends (consumer control press/release, ESC press/release) with success/failure status.
    * Console output must be routed to UART0 (`CONFIG_ESP_CONSOLE_UART_DEFAULT=y`) to avoid conflicts with the native USB CDC port.

---

## 2. macOS Application (Host App)
The application manages the business logic and intelligent routing of commands.

* **USB-CDC Serial Communication:**
    * Auto-discover the ESP32-S3 board by matching **VID `0x303A`** and **PID `0x4001`** among `/dev/cu.usbmodem*` devices via IOKit.
    * After opening the serial port, the app must explicitly assert **DTR** (`ioctl(TIOCSDTR)`) and **RTS** (`ioctl(TIOCMBIS, TIOCM_RTS)`) signals so the ESP32 USB-CDC knows the host is ready. Without this, the ESP32 may ignore incoming bytes on reconnections — macOS sometimes auto-asserts DTR only on the very first open after USB enumeration, but not on subsequent opens.
    * The ESP32 USB-CDC buffers commands from previous sessions. When the port is reopened and the first byte is written, the ESP32 processes all buffered commands at once and floods back stale responses. The handshake command includes a **random 4-character hex nonce** that the ESP32 echoes back, allowing the app to instantly identify the fresh response and discard all stale ones without needing drain delays.
* **System Key Interception:**
    * Use `CGEventTapCreate` with `.defaultTap` to observe system-defined events at `kCGSessionEventTap`. This is the industry-standard approach for media key observation on macOS.
    * **Event mask:** The `CGEventMask` must include `keyDown` (10) and `NX_SYSDEFINED` (14). **Do not use `UInt64.max` or overly broad masks** — `CGEvent.tapCreate` silently drops all keyboard events when the mask overflows the valid `CGEventMask` range, leaving only mouse/trackpad events (NX_SYSDEFINED subtype 7) arriving at the callback.
    * **Brightness key event format (macOS Tahoe):** On macOS 26, brightness keys arrive as **`keyDown` events** (type 10) with keycodes **144** (brightness up) and **145** (brightness down) — **not** as `NX_SYSDEFINED` subtype 8 with `NX_KEYTYPE_BRIGHTNESS_UP`/`DOWN`. The app must handle both paths for backward compatibility with earlier macOS versions.
    * **Run loop:** The event tap should be added to the **main run loop** (`CFRunLoopGetMain()`). Adding it to a background thread run loop may result in keyboard events not being delivered reliably.
    * **Accessibility permission is required.** The app checks permission via `AXIsProcessTrusted()` and can prompt the user via `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt`. A periodic timer re-checks every 2 seconds until the user grants access in System Settings → Privacy & Security → Accessibility. The permission status is published so the UI can display a banner guiding the user.
    * **No Input Monitoring permission required.**
    * Note: `IOHIDManager` was evaluated but Apple keyboards report brightness keys as raw F1/F2 on the Keyboard usage page (0x07), not as Consumer Control usages (0x006F/0x0070). `NSEvent.addGlobalMonitorForEvents` was also evaluated but requires Input Monitoring permission; `CGEventTap` requires Accessibility instead, which is more commonly granted and is the industry-standard approach for media key observation.
* **Context Detection (Cursor-Aware):**
    * The app must monitor the cursor position via `NSEvent.mouseLocation`.
    * It must compare mouse coordinates with the frames of available screens (`NSScreen.screens`).
* **Display Identification:**
    * The app classifies each connected display by reading its EDID model name from the IORegistry (`IODisplayCreateInfoDictionary` on `IODisplayConnect` services).
    * **macOS Tahoe 26+ fallback:** On macOS Tahoe, `IODisplayConnect` services may not be exposed, causing the EDID lookup to return empty. The app must fall back to `NSScreen.localizedName` for display identification.
    * ViewFinity S9 monitors are matched by substring patterns in the model name. Known patterns include: `ViewFinity`, `S32CM`, `S27CM`, `S32C9`, `S27C9`, `LS32C`, `LS27C`, `S9`. The actual `localizedName` observed for the 27″ model is **`S27C900P`**.
* **Command Routing:**
    * **Native/Compatible Display:** If the cursor is over the MacBook screen or an Apple/LG UltraFine monitor, the App should call system APIs or utilities like the `brightness` CLI to adjust hardware natively.
    * **ViewFinity S9 Monitor:** If the cursor is over the S9, the App must send the corresponding command via the serial port `/dev/cu.usbmodem*` to the ESP32.
* **Interface and UX:**
    * Run as a **Menu Bar App** with dynamic icon states (e.g., filled monitor display when connected, dimmed/slashed monitor display when disconnected).
    * Configuration interface for initial monitor pairing and a "Launch at Login" toggle.
    * Auto-connection: Automatically detect the USB board via `/dev/cu.usbmodem*` and confirm firmware via a handshake.
    * **Connection Feedback:** The handshake must time out after ~2–3 seconds. If the board is found but the firmware doesn't respond, the app must show a clear failure message (e.g. "Board found but firmware did not respond — is the correct firmware flashed?").
    * **Manual Brightness Controls:** When the ESP32 is connected, the menu bar popover must include Brightness Up and Brightness Down buttons that send the corresponding commands (`0x01`, `0x02`) directly to the board, allowing the user to test and control brightness without relying on keyboard keys.
* **Code Signing:**
    * The app must use a stable code signing identity (e.g., `Apple Development`) instead of ad-hoc signing (`-`). Ad-hoc signing generates a new `cdhash` on every build, causing macOS TCC to treat each rebuild as a new application and reset Accessibility permissions. Using a stable developer certificate preserves permissions across rebuilds.
    * The `CODE_SIGN_IDENTITY` build setting must be set to `"Apple Development"` and a valid `DEVELOPMENT_TEAM` must be configured in the Xcode project.
* **System Lifecycle Handling:**
    * Listen to `NSWorkspace.didWakeNotification` to proactively close and re-open the serial port and re-run the handshake after Mac sleep/wake cycles.

---

## 3. Hardware Setup

* **ESP32-S3 DevKit** has two USB-C ports:
    * **COM port** — USB-UART bridge for flashing firmware and viewing debug logs (`/dev/cu.usbserial-*`).
    * **USB port** — Native USB peripheral used for CDC serial communication with the macOS app (`/dev/cu.usbmodem*`).
* Both ports can be connected to the Mac simultaneously without conflicts.
* In production use, only the **USB port** needs to be connected. The COM port is for development/debugging only.

---

## 4. Suggested Operational Flow

1.  **One-Time Setup:** The user clicks "Pair" in the Mac App. The ESP32 enters discovery mode, the monitor accepts it, and the keys are stored in the ESP32's NVS.
2.  **Multi-Host Usage:** When moving the ESP32 to another Mac with the App installed, the board reconnects to the monitor via Bluetooth within seconds; the App simply sends commands through the USB serial port.
3.  **Screen Intelligence:** If the user has two screens (S9 + MacBook) and the mouse is on the MacBook, the brightness key adjusts the laptop screen. When moving the mouse to the S9, the same keys control the actual brightness of the Samsung monitor via the Bluetooth bridge.
