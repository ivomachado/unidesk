# macOS Host App — Implementation Plan

## Tech Stack

- **Language:** Swift
- **UI:** SwiftUI (Menu Bar app via `MenuBarExtra`)
- **Min target:** macOS 13+
- **Serial:** `IOKit` for USB device discovery + raw POSIX I/O on `/dev/cu.usbmodem*`
- **No external dependencies** — prefer system frameworks only

---

## Project Structure

```
ViewFinityBrightnessControl/
├── App/
│   ├── BrightnessControlApp.swift        # @main, MenuBarExtra
│   └── SettingsView.swift                # Pairing UI, serial port picker
├── Services/
│   ├── SerialPortService.swift           # USB-CDC discovery & communication
│   ├── KeyInterceptor.swift              # Observe brightness keys (F1/F2)
│   ├── CursorMonitor.swift               # NSEvent.mouseLocation tracking
│   ├── ScreenResolver.swift              # Map cursor → NSScreen
│   └── BrightnessRouter.swift            # Route command: native vs ESP32
├── Models/
│   └── ScreenType.swift                  # enum: builtIn, compatible, viewFinity
└── Info.plist                            # Accessibility usage description
```

---

## Implementation Order

### 1. `SerialPortService`

- Enumerate `/dev/cu.usbmodem*` devices.
- Match ESP32-S3 by **VID/PID** via IOKit (`IOServiceGetMatchingServices`).
- Open/close serial port using POSIX `open()`, `termios` configuration.
- Assert **DTR** (`ioctl(TIOCSDTR)`) and **RTS** (`ioctl(TIOCMBIS, TIOCM_RTS)`) signals after opening the port so the ESP32 USB-CDC knows the host is ready. Without this, the ESP32 may ignore incoming bytes on reconnections (macOS sometimes auto-asserts DTR only on the very first open after enumeration).
- Perform a firmware handshake to verify the expected protocol before enabling controls.
- **Connection feedback:** the handshake must time out after ~2–3 seconds. On timeout, set `lastError` with a descriptive message (e.g. "Board found but firmware did not respond — is the correct firmware flashed?") so the UI can display it.
- Send single-byte commands: `0x01` (brightness up), `0x02` (brightness down).
- Send pairing mode command (e.g. `0x03`), handshake (`0x04`), get status (`0x05`), and unpair (`0x06`).
- Auto-reconnect on USB plug via `IOServiceAddMatchingNotification`.
- Listen to `NSWorkspace.didWakeNotification` to proactively close, re-open, and re-handshake after Mac sleep.

### 2. `ScreenResolver`

- Wrap `NSScreen.screens` to enumerate all displays.
- Classify each screen:
  - **Built-in:** via `CGDisplayIsBuiltin()`.
  - **ViewFinity S9:** lookup model name from `IODisplayCreateInfoDictionary` on `IODisplayConnect` services, matching against known substrings: `ViewFinity`, `S32CM`, `S27CM`, `S32C9`, `S27C9`, `LS32C`, `LS27C`, `S9`.
  - **Compatible (Apple/LG):** everything else that supports native brightness.
- **macOS Tahoe 26+ fallback:** `IODisplayConnect` services may not be exposed on Tahoe, causing the EDID lookup to return empty. Fall back to `NSScreen.localizedName` for display identification. The observed `localizedName` for the 27″ ViewFinity S9 is **`S27C900P`**.
- Add a fallback user mapping (display ID → type) because EDID names can be short or localized (e.g., "LS32C…").
- Expose a method: `screenType(for: NSScreen) -> ScreenType`.

### 3. `CursorMonitor`

- Track `NSEvent.mouseLocation` on a timer (~100ms interval) or passively via `CGEvent` callbacks.
- Resolve the current screen using `ScreenResolver` by comparing cursor coordinates against each `NSScreen.frame`.
- Publish the active `ScreenType` for consumption by the router.

### 4. `KeyInterceptor`

- Use `CGEventTapCreate` with `.defaultTap` to observe system-defined events at `kCGSessionEventTap`. This is the industry-standard approach for media key observation on macOS.
- **Event mask:** The `CGEventMask` must include `keyDown` (10) and `NX_SYSDEFINED` (14). **Do not use `UInt64.max` or overly broad masks** — `CGEvent.tapCreate` silently drops all keyboard events when the mask overflows the valid `CGEventMask` range, leaving only mouse/trackpad events (NX_SYSDEFINED subtype 7) arriving at the callback.
- **Brightness key event format (macOS Tahoe):** On macOS 26, brightness keys arrive as **`keyDown` events** (type 10) with keycodes **144** (brightness up) and **145** (brightness down) — **not** as `NX_SYSDEFINED` subtype 8 with `NX_KEYTYPE_BRIGHTNESS_UP`/`DOWN`. The app must handle both paths for backward compatibility with earlier macOS versions.
- **Run loop:** The event tap should be added to the **main run loop** (`CFRunLoopGetMain()`). Adding it to a background thread run loop may result in keyboard events not being delivered reliably.
- Only act on key-down events, ignore key-up.
- Forward the parsed action to `BrightnessRouter`.
- **Accessibility permission is required.** The interceptor checks permission via `AXIsProcessTrusted()` and can prompt the user via `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt`. A periodic timer re-checks every 2 seconds until the user grants access in System Settings → Privacy & Security → Accessibility. The permission status is published so the UI can display a banner guiding the user.
- **No Input Monitoring permission required.**
- Note: `IOHIDManager` was evaluated as an alternative but Apple keyboards report brightness keys as raw F1/F2 on the Keyboard usage page (0x07), not as Consumer Control usages (0x006F/0x0070). `NSEvent.addGlobalMonitorForEvents` was also evaluated but requires Input Monitoring permission; `CGEventTap` requires Accessibility instead, which is more commonly granted and is the industry-standard approach for media key observation.

### 5. `BrightnessRouter`

Core routing logic:

- Query `CursorMonitor` for the active screen type.
- **Built-in / Compatible display:**
  - Use `IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey, value)` via IOKit.
  - Alternatively, shell out to the `brightness` CLI as a fallback.
- **ViewFinity S9:**
  - Send the corresponding byte (`0x01` or `0x02`) via `SerialPortService`.

### 6. `BrightnessControlApp`

- `@main` app using `MenuBarExtra` with dynamic SF Symbol icons (e.g., filled monitor display when connected, dimmed/slashed monitor display when disconnected).
- Display:
  - Connection status (ESP32 connected / disconnected) with a failure message when handshake times out.
  - Currently targeted screen name.
  - "Pair Monitor" button.
  - Serial port override picker (dropdown).
  - Quit button.

### 7. `SettingsView`

- SwiftUI view embedded in the menu bar popover.
- List of detected serial ports with selection.
- "Pair Monitor" button that sends the pairing byte to the ESP32.
- Status indicators: ESP32 connection, paired device name, BLE pairing state (reported via serial).
- Provide an Unpair button (clears bond via serial command).
- "Launch at Login" toggle using `SMAppService.mainApp`.

---

## Key Considerations

- **`CGEventTap` for brightness key observation.** The app uses `CGEventTapCreate` with `.defaultTap` to observe brightness key events. **Accessibility permission is required** — the app detects this via `AXIsProcessTrusted()` and displays a UI banner guiding the user to System Settings → Privacy & Security → Accessibility when access is denied. No Input Monitoring permission is required. This is the industry-standard approach for media key observation on macOS.
- **Multi-host is firmware-only.** All pairing state, bond keys, and device identity live on the ESP32's NVS. The macOS app is stateless with respect to BLE pairing — it only sends commands over USB serial and displays status reported by the board.
- **DTR/RTS assertion is required.** The ESP32 USB-CDC may not process incoming bytes unless DTR is asserted by the host. macOS sometimes auto-asserts DTR on the first port open after USB enumeration, but not on subsequent opens. The app must explicitly assert DTR and RTS via `ioctl` after every `open()` call to ensure reliable communication across reconnections.
- **Sandboxing must be disabled** (or use hardened runtime exceptions) to access `/dev/cu.*` serial ports.
- **Code signing must use a stable identity.** The `CODE_SIGN_IDENTITY` build setting is set to `"Apple Development"` (not ad-hoc `"-"`). Ad-hoc signing generates a new `cdhash` on every build, causing macOS TCC to treat each rebuild as a new application and reset Accessibility permissions. A stable developer certificate preserves the Accessibility grant across rebuilds. A valid `DEVELOPMENT_TEAM` must be configured.
- **Brightness key event delivery varies by macOS version.** On macOS Tahoe 26+, brightness keys arrive as `keyDown` events (type 10) with keycodes 144/145. On earlier versions, they arrive as `NX_SYSDEFINED` events (type 14, subtype 8) with NX key codes `NX_KEYTYPE_BRIGHTNESS_UP` (2) and `NX_KEYTYPE_BRIGHTNESS_DOWN` (3). The app handles both paths. At the raw HID level, Apple keyboards report these as F1/F2 on the Keyboard usage page (0x07) — the system translates them before they reach the event tap.
- **CGEventTap mask must not use `UInt64.max`.** Using an overly broad mask (e.g. `UInt64.max`) overflows the valid `CGEventMask` range and causes `CGEvent.tapCreate` to silently drop all keyboard events. The correct mask is `(1 << keyDown) | (1 << NX_SYSDEFINED)`.
- **Coordinate space mismatch:** `NSEvent.mouseLocation` uses a different origin than `NSScreen.frame`. Add a helper to normalize and avoid wrong screen targeting.
- **Native brightness support varies:** `IODisplaySetFloatParameter` often works only on Apple displays. Add per-screen capability detection and a graceful fallback.
- **Serial reliability:** handle device-busy, reconnect races, and write buffering (queue + retry, flush on write). The ESP32 USB-CDC buffers commands from previous sessions; on reconnect, sending any byte triggers a flood of stale responses. The app must filter responses by expected tag to discard stale data.
- **Connection feedback:** handshake timeout and failure must produce a human-readable error message displayed in the menu bar popover.
- Use `IOServiceAddMatchingNotification` to detect ESP32 USB plug/unplug events for seamless auto-connection.
- **Sleep/Wake cycles:** USB serial ports often drop during sleep. Re-initialize the connection on `NSWorkspace.didWakeNotification`.
- The app should store user preferences (selected serial port, screen assignments) in `UserDefaults`.

---

## Serial Protocol

### Commands (Mac → ESP32)

| Bytes                  | Command              |
|------------------------|----------------------|
| `0x01`                 | Brightness Up        |
| `0x02`                 | Brightness Down      |
| `0x03`                 | Enter Pairing Mode   |
| `0x04` + `<nonce>\n`   | Handshake / Ping     |
| `0x05`                 | Get Status & Name    |
| `0x06`                 | Unpair / Clear Bond  |

The handshake command (`0x04`) is followed by a **4-character random hex nonce** and a newline (e.g. `0x04 a 3 f 2 \n`). The ESP32 reads the nonce and echoes it back in the response. This allows the macOS app to instantly distinguish the fresh handshake response from stale `OK:PING` responses buffered across reconnections — no drain delays needed.

### Responses (ESP32 → Mac)

All responses are newline-terminated ASCII strings prefixed by a tag:

| Response format                          | When                        | Description                                                            |
|------------------------------------------|-----------------------------|------------------------------------------------------------------------|
| `OK:PING:<nonce>\n`                      | After `0x04`                | Firmware is alive; `<nonce>` is the same hex string sent by the host.  |
| `OK:UP\n`                                | After `0x01`                | Brightness-up HID report sent successfully.                            |
| `OK:DOWN\n`                              | After `0x02`                | Brightness-down HID report sent successfully.                          |
| `OK:PAIRING\n`                           | After `0x03`                | NVS cleared, advertising restarted — board is in pairing mode.         |
| `OK:UNPAIRED\n`                          | After `0x06`                | Bond cleared successfully.                                             |
| `STATUS:<connected\|disconnected>:<name>\n` | After `0x05`             | BLE connection state and paired device name (empty if none).           |
| `ERR:<message>\n`                        | On any failure              | Human-readable error (e.g., `ERR:NOT_CONNECTED`, `ERR:UNKNOWN_CMD`).  |

The macOS app reads until `\n`, splits on the first `:` to get the tag (`OK`, `STATUS`, `ERR`), and parses the remainder.

---

## Estimated Effort

~3–4 days for a working MVP.