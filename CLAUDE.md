# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project Overview

**UniDesk** is a macOS menu-bar utility paired with ESP32-S3 firmware that routes brightness and volume key presses to a Samsung ViewFinity S9 monitor over USB-CDC serial and BLE HID, bypassing macOS native brightness control when the cursor is over the monitor.

The repository contains three main components:
- **macos-app/** — Swift/SwiftUI menu bar application (brightness/volume interception and routing)
- **firmware/** — ESP-IDF C++ firmware (USB-CDC serial gateway, BLE HID Consumer Control reports)
- **linux-app/** — Stub Linux app (not implemented)
- **PROTOCOL.md** — Serial communication specification between macOS app and ESP32-S3 (shared contract)

---

## Build & Development

### macOS App

**Requirements:**
- macOS 13+ (Ventura or later)
- Xcode 15+
- Accessibility permission (required at runtime)
- Code signing with stable Apple Development identity (not ad-hoc)

**Build:**
```sh
cd macos-app
xcodebuild -project UniDesk.xcodeproj \
  -scheme UniDesk \
  -configuration Release \
  -derivedDataPath build clean build
```

The built app is at `build/Build/Products/Release/UniDesk.app`.

**Install:**
```sh
cp -r build/Build/Products/Release/UniDesk.app /Applications/
```

Then launch and grant Accessibility permission (System Settings → Privacy & Security → Accessibility).

**Run macOS app unit tests:**
```sh
cd macos-app
xcodebuild -project UniDesk.xcodeproj -scheme UniDeskTests \
  -destination 'platform=macOS' test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

**Run firmware unit tests (host-native, no ESP32 needed):**
```sh
cd firmware/test
cmake -B build && cmake --build build && build/test_protocol_parser
```
Or via ctest: `ctest --test-dir build`

**Debug:**
- Build with `-configuration Debug` instead of Release
- Run via Xcode for console output
- Code signing must use a stable identity; ad-hoc signing (`-`) resets Accessibility permissions on every rebuild

**Project structure:**
```
macos-app/UniDesk/
├── App/
│   ├── BrightnessControlApp.swift       # @main, MenuBarExtra, status icons
│   └── SettingsView.swift               # Settings window (display picker, pairing, ESC debounce slider)
├── Services/
│   ├── SerialPortService.swift          # USB-CDC discovery (@MainActor, handshake + I/O)
│   ├── KeyInterceptor.swift             # CGEventTap brightness/volume key interception
│   ├── CursorMonitor.swift              # Cursor position tracking (100ms timer)
│   ├── ScreenResolver.swift             # Display classification (built-in, compatible, ViewFinity S9)
│   ├── BrightnessRouter.swift           # Route brightness to native IOKit or serial
│   └── AudioOutputMonitor.swift         # CoreAudio default output device tracking for FiiO
└── Models/
    └── ScreenType.swift                 # Enum: .builtIn, .compatible, .viewFinityS9, .unsupported
```

---

### ESP32-S3 Firmware

**Requirements:**
- ESP32-S3 DevKit (any variant with native USB)
- ESP-IDF v5.x
- USB-C cable for flashing

**Environment setup:**
```sh
source ~/Workspace/esp/esp-idf/export.sh
```

**Build & Flash:**
```sh
cd firmware
idf.py set-target esp32s3          # First time only
idf.py build flash                 # Build and flash via COM port
idf.py monitor                     # View debug logs (Ctrl+] to exit)
```

**Project structure:**
```
firmware/main/
├── main.cpp                   # app_main() — initializes components, idle loop
├── nvs_manager.h/cpp          # NVS flash init, bond storage, bond clearing
├── ble_hid_service.h/cpp      # BLE HOGP service (GAP, GATT, HID service, advertising, bonding)
├── brightness_control.h/cpp   # HID brightness report sequences (Consumer Control + ESC dismiss)
├── usb_serial.h/cpp           # TinyUSB CDC serial interface (read callback, response writing)
├── command_handler.h/cpp      # Serial command dispatcher (0x01–0x0B command bytes)
├── fiio_control.h/cpp         # FiiO K11 R2R DAC volume control (quadrature encoder)
└── CMakeLists.txt             # Component build config
```

**Debug ports:**
- **COM port** (`/dev/cu.usbserial-*`) — UART0, firmware flashing, console logs
- **USB port** (`/dev/cu.usbmodem*`) — Native USB CDC (VID 0x303A, PID 0x4001), serial communication with macOS app

Console logs are routed to UART0, not USB, to avoid conflicts with CDC serial.

---

## Serial Protocol

All communication between the macOS app and ESP32-S3 is defined in **PROTOCOL.md**. Key points:

**Commands (Mac → ESP32):**
- `0x01` — Brightness Up (fire-and-forget)
- `0x02` — Brightness Down (fire-and-forget)
- `0x03` — Enter Pairing Mode (response: `OK:PAIRING\n`)
- `0x04 <nonce> \n` — Handshake/Ping (response: `OK:PING:<nonce>\n`)
- `0x05` — Get Status (response: `STATUS:<connected|disconnected>:<name>\n`)
- `0x06` — Unpair (response: `OK:UNPAIRED\n`)
- `0x07 <ms_hi> <ms_lo2> <ms_lo1> <ms_lo0>` — Set ESC Debounce (4-byte big-endian uint32)
- `0x08` — Get ESC Debounce (response: `OK:ESC_DEBOUNCE:<ms>\n`)
- `0x09` — ESC Key (fire-and-forget)
- `0x0A` — FiiO Volume Up (fire-and-forget)
- `0x0B` — FiiO Volume Down (fire-and-forget)

**Responses (ESP32 → Mac):**
- `OK:PING:<nonce>\n` — Handshake response (nonce echoed back)
- `STATUS:<connected|disconnected>:<name>\n` — Connection state and paired device name
- `OK:PAIRING\n`, `OK:UNPAIRED\n` — Pairing/unpairing confirmation
- `OK:ESC_DEBOUNCE:<ms>\n` — ESC debounce read/write confirmation
- `ERR:<message>\n` — Error response

**Port configuration:**
- Baud rate: 115200, 8N1, no flow control
- **DTR and RTS must be explicitly asserted** after every `open()` call via `ioctl(TIOCSDTR)` and `ioctl(TIOCMBIS, TIOCM_RTS)`
- Handshake nonce is used to discard stale buffered responses on reconnect (no drain delays needed)

**Any protocol change must update PROTOCOL.md and both implementations.**

---

## Architecture & Key Design Decisions

### macOS App

**Threading model:** All service state lives on `@MainActor` (main thread), eliminating data races without explicit locks. Serial **reads** happen on a background GCD queue via `DispatchSourceRead`; the handler parses bytes there and hops to `@MainActor` only to update state. Serial **writes** (1–7 bytes) execute directly on the main thread — the kernel USB-CDC buffer absorbs them in microseconds, so main-thread blocking is unmeasurable. If writes ever grow (bulk transfers), move to a dedicated `DispatchQueue` with synchronized `fileDescriptor` access.

**Brightness routing logic:**
1. `KeyInterceptor` intercepts brightness keys via `CGEventTap` on the main run loop
2. `CursorMonitor` tracks cursor position (100ms timer) and publishes active screen
3. `BrightnessRouter` checks cursor location:
   - **Built-in / compatible display** → `IODisplaySetFloatParameter` (native brightness)
   - **ViewFinity S9** → `SerialPortService.sendFireAndForget(0x01/0x02)` (serial command)
   - **Unsupported** → ignore

**Display classification:**
- `ScreenResolver` examines EDID model names via IOKit (or `NSScreen.localizedName` on macOS Tahoe)
- Patterns: `ViewFinity`, `S27CM`, `S32CM`, `S27C9`, `S32C9` → ViewFinity S9
- User can override via `UserDefaults` (`screenTypeOverrides`)

**USB-CDC handshake:**
- On connect, `SerialPortService` sends `0x04` + 4-char random hex nonce + `\n`
- Waits for `OK:PING:<nonce>` (retries up to 3 times with 1s delay for USB hubs)
- Discards responses until nonce matches (stale buffered data is ignored)
- Then queries status with `0x05` to check BLE connection state

**Brightness key interception:**
- Tahoe (26+): `keyDown` events with keycodes 144 (up) / 145 (down)
- Earlier macOS: `NX_SYSDEFINED` events (type 14, subtype 8) with `NX_KEYTYPE_BRIGHTNESS_UP` (2) / `NX_KEYTYPE_BRIGHTNESS_DOWN` (3)
- Both paths are handled for cross-version compatibility

### ESP32-S3 Firmware

**Component initialization order:** NVS → BLE → USB-CDC (BLE and USB coexist without resource conflicts)

**BLE HID service:**
- HID Over GATT Profile (HOGP) with two report collections:
  - Report ID 1 (Consumer Control, 2 bytes): Brightness increment/decrement (usage codes 0x006F/0x0070)
  - Report ID 2 (Keyboard, 8 bytes): ESC key to dismiss monitor OSD
- Battery and Device Information services included
- "Just Works" pairing (IO capability `ESP_IO_CAP_NONE`) — no PIN required
- Bonding persistence via NVS (one bond per device)

**Brightness sequence:**
1. Consumer Control press (Report ID 1): `[0x6F, 0x00]` (up) or `[0x70, 0x00]` (down)
2. Wait 20ms
3. Consumer Control release (Report ID 1): `[0x00, 0x00]`
4. Wait 50ms (let OSD appear)
5. ESC press (Report ID 2): `[0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00]`
6. Wait 20ms
7. ESC release (Report ID 2): all zeros

**ESC debounce:** During rapid brightness adjustments (key held down), only a single ESC is sent after the burst settles (user-configurable 200–10000 ms, default 2000 ms, stored in NVS under `app_settings/esc_dbnc_ms`).

**Serial command handling:**
- Received bytes flow through `usb_serial.cpp` RX callback → `CommandHandler.handle_byte()` → `BrightnessControl`/`BleHidService` actions
- Fire-and-forget commands (0x01, 0x02, 0x09, 0x0A, 0x0B) produce no response
- Response-producing commands (0x03, 0x04, 0x05, 0x06, 0x07, 0x08) queue ASCII responses via `send_response()`

---

## Testing & Debugging

### macOS App

**Accessibility permission:**
- Requires System Settings → Privacy & Security → Accessibility
- Code signing must use a stable identity; ad-hoc signing resets permissions on every rebuild
- Re-verified every 2 seconds at runtime

**Display name detection:**
- EDID lookup via IOKit (fails on macOS Tahoe)
- Falls back to `NSScreen.localizedName` (e.g., `S27C900P` for 27″ ViewFinity S9)
- User override via Settings window

**Serial port discovery:**
- Uses IOKit to match VID 0x303A / PID 0x4001
- Logs warning if fallback to first `/dev/cu.usbmodem*` is used
- Explicit port picker in Settings for manual override

**Brightness routing:**
- Cursor position is checked every 100ms
- Built-in/compatible displays use IOKit brightness API
- ViewFinity S9 uses serial commands; app auto-connects on key press if disconnected

### Firmware

**Monitor debug output:**
```sh
idf.py monitor
# or from previous session:
cat firmware/monitor.log
```

Console logs (UART0) show:
- Serial command received (byte-level)
- Command dispatch and response sent
- BLE connection/disconnection events
- Bonding events and NVS operations
- HID report sends with success/failure status

**Key configuration (sdkconfig):**
- `CONFIG_ESP_CONSOLE_UART_DEFAULT=y` — console on UART0, not USB (critical to avoid CDC conflicts)
- `CONFIG_BT_ENABLED=y`, `CONFIG_BT_BLE_ENABLED=y`, `CONFIG_BT_BLUEDROID_ENABLED=y`, `CONFIG_BT_BLE_SMP_ENABLE=y` — BLE stack
- `CONFIG_TINYUSB_CDC_ENABLED=y` — USB CDC
- `CONFIG_NVS_ENABLED=y` — Non-volatile storage for bonding

---

## Workflow & Conventions

**Before starting work:** Read `BACKLOG.md` to understand open items and priorities.

**When completing a task:** Move item from "To Do" or "In Progress" → "Done" in `BACKLOG.md` with a one-line summary.

**When discovering new work:** Add to "To Do" in `BACKLOG.md` with enough context for another agent to pick it up.

**Key references:**
- `PROTOCOL.md` — Serial protocol spec (shared contract; any change requires updating both implementations)
- `macos-app/AGENTS.md` — Gotchas and landmines specific to the macOS app
- `firmware/AGENTS.md` — Gotchas and landmines specific to the firmware
- Per-app `README.md` files — Detailed architecture and setup

**Formatting rule:** Never leave trailing spaces on any lines, especially empty lines.

---

## Critical Gotchas & Landmines

### macOS App

1. **CGEventMask overflow:** Using `UInt64.max` as an event mask silently breaks keyboard event delivery. The correct mask is `(1 << CGEventType.keyDown.rawValue) | (1 << 14)` (NX_SYSDEFINED).

2. **Event tap run loop:** The event tap must be added to the **main run loop** (`CFRunLoopGetMain()`). Background thread run loops do not reliably deliver keyboard events.

3. **Brightness key keycodes vary:** Tahoe (26+) sends `keyDown` with keycodes 144/145; earlier macOS sends `NX_SYSDEFINED` with `NX_KEYTYPE_BRIGHTNESS_UP`/`DOWN`. Both paths must be handled.

4. **DTR/RTS assertion:** After every `open()` on the serial port, **explicitly assert DTR and RTS** via `ioctl(TIOCSDTR)` and `ioctl(TIOCMBIS, TIOCM_RTS)`. macOS may not auto-assert on reconnect.

5. **Code signing identity:** Use a stable `Apple Development` identity, not ad-hoc (`-`). Ad-hoc signing generates a new `cdhash` per build, causing TCC to reset Accessibility permissions.

6. **App Sandbox disabled intentionally:** `CGEventTap` and POSIX serial I/O are incompatible with App Sandbox. Do not re-enable it.

7. **NSHostingView vs NSHostingController:** When embedding SwiftUI in a standalone `NSWindow`, use `NSHostingView` as `contentView` — never `NSHostingController` as `contentViewController`. The controller's `windowDidLayout` observer calls `updateAnimatedWindowSize()` which causes a re-entrant SIGABRT when `@Published` changes alter layout during a display cycle.

8. **IODisplayConnect EDID lookup fails on Tahoe:** Fall back to `NSScreen.localizedName` for display identification.

9. **POSIX serial writes on main thread:** All writes (1–7 bytes) execute on `@MainActor` by design. The kernel USB-CDC buffer absorbs them in microseconds, so blocking is unmeasurable. If writes grow, move to a dedicated `DispatchQueue`.

### Firmware

1. **Console output must be on UART0, not USB:** Set `CONFIG_ESP_CONSOLE_UART_DEFAULT=y`. The native USB port is used for CDC serial — routing console logs there causes conflicts and garbled data.

2. **ESC key debouncing:** During rapid brightness adjustments, only a single ESC should be sent after the burst settles (user-configurable timeout, default 2000 ms). Without this, the monitor's OSD flickers on every keystroke.

3. **NVS initialization:** Handle `ESP_ERR_NVS_NO_FREE_PAGES` by erasing and reinitializing. The firmware crashes on first boot after flash erase if this is not done.

4. **BLE task stack size:** Must be at least **4096 bytes**. BLE callbacks consume significant stack — smaller sizes cause silent stack overflows and random crashes.

5. **HID Report Map:** Consumer Control must use **16-bit usage range** (not 8-bit). The ViewFinity S9 ignores 8-bit descriptors.

6. **Brightness press/release timing:** 20ms between press and release, 50ms before ESC. Too fast and the monitor ignores; too slow and it may auto-repeat.

7. **GATT CCCD backing arrays:** Each CCCD must have its own `uint8_t[2]` array. Sharing a single array across Consumer Control, Keyboard, and Battery CCCDs causes CCCD writes to silently corrupt notification state.

8. **BLE disconnect:** `esp_ble_gap_disconnect()` requires a valid `esp_bd_addr_t`. Passing `nullptr` crashes or silently fails. Store the remote BDA from `ESP_GATTS_CONNECT_EVT`.

9. **USB return value check:** `tinyusb_cdcacm_write_queue()` returns `size_t` (bytes written), not `esp_err_t`. Comparing against `ESP_OK` (0) treats every successful write as failure.

10. **RX callback is set-once:** `UsbSerial::set_rx_callback()` is set before `init()` and never reassigned. The callback (`std::function`) is not mutex-protected; it is written from `app_main` and read from the `usb_cmd_proc` task.

---

## Known Issues & Won't-Do Items

**Won't Do — Multi-step brightness:**
Implemented and tested a feature to loop serial commands (1–5 steps per keypress). The ViewFinity S9 cannot reliably process rapid sequential HID brightness reports — it drops or misorders them. Reverted entirely. Any future attempt would need firmware-side inter-report delays, but the monitor's OSD latency makes this impractical.

**In Progress / To Do:**
See `BACKLOG.md` for current work items and known gaps (e.g., swallow brightness events on S9, configurable brightness behavior, larger handshake nonce).

---

## Security Notes

Both the macOS app and firmware have security review findings documented in `SECURITY_REVIEW.md` files. Key highlights:

**macOS app:**
- Runs unsandboxed (necessary for `CGEventTap` + POSIX serial I/O)
- No authentication on serial commands
- Unmanaged pointer lifetimes in IOKit callbacks

**Firmware:**
- No Secure Boot or flash encryption
- NVS not encrypted
- BLE advertising on boot (unverified)
- Serial commands have no authentication

These trade-offs are acceptable for a personal utility but should be understood when modifying the codebase.

