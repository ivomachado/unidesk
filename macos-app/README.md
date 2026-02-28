# macOS App — ViewFinity Brightness Control

A Swift/SwiftUI menu bar application that intercepts brightness key presses, detects which display the cursor is on, and routes brightness commands to the appropriate backend — either macOS native APIs for built-in displays, or the ESP32-S3 serial bridge for the Samsung ViewFinity S9.

---

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode 15+** (for building)
- **Accessibility permission** — required for `CGEventTap` to intercept brightness keys
- **No App Sandbox** — required for POSIX serial I/O (`/dev/cu.*`) and `CGEventTap`

---

## Architecture

```
BrightnessControlApp (MenuBarExtra)
    │
    ├── KeyInterceptor          ← CGEventTap: intercepts brightness keys
    │       │
    │       ▼
    ├── BrightnessRouter        ← Routes command based on cursor location
    │       │
    │       ├── Native (IOKit)  ← Built-in / compatible displays
    │       │
    │       └── Serial (ESP32)  ← ViewFinity S9 via SerialPortService
    │
    ├── CursorMonitor           ← Tracks which screen the cursor is on
    │
    ├── ScreenResolver          ← Classifies displays (built-in, compatible, ViewFinity S9)
    │
    └── SerialPortService       ← USB-CDC discovery, handshake, command I/O
```

### Services

#### `SerialPortService`

Manages the USB-CDC serial connection to the ESP32-S3:

- **Discovery:** Enumerates `/dev/cu.usbmodem*` and matches VID `0x303A` / PID `0x4001` via IOKit.
- **Connection:** POSIX `open()`, `termios` configuration, DTR/RTS assertion.
- **Handshake:** Sends `0x04` + random nonce to verify firmware and discard stale buffered responses.
- **Commands:** Sends single-byte brightness commands (`0x01` up, `0x02` down) and management commands (pair, unpair, status).
- **Auto-reconnect:** Detects USB plug/unplug via `IOServiceAddMatchingNotification` and re-connects after sleep/wake via `NSWorkspace.didWakeNotification`.

See [PROTOCOL.md](../PROTOCOL.md) for the full serial protocol specification.

#### `KeyInterceptor`

Intercepts brightness key presses using `CGEventTapCreate` with `.defaultTap`:

- **macOS Tahoe (26+):** Brightness keys arrive as `keyDown` events (type 10) with keycodes 144 (up) and 145 (down).
- **Earlier macOS:** Brightness keys arrive as `NX_SYSDEFINED` events (type 14, subtype 8) with `NX_KEYTYPE_BRIGHTNESS_UP` (2) and `NX_KEYTYPE_BRIGHTNESS_DOWN` (3).
- Both paths are handled for cross-version compatibility.
- The event tap runs on the **main run loop** for reliable keyboard event delivery.
- Requires **Accessibility** permission (`AXIsProcessTrusted()`). The app prompts the user and re-checks every 2 seconds until granted.

#### `CursorMonitor`

Tracks `NSEvent.mouseLocation` on a 100ms timer and resolves the active screen by comparing cursor coordinates against each `NSScreen.frame`. Publishes the active `ScreenType` for the router.

#### `ScreenResolver`

Classifies each connected display:

- **Built-in:** Detected via `CGDisplayIsBuiltin()`.
- **ViewFinity S9:** Matched by EDID model name substrings (`ViewFinity`, `S27CM`, `S32CM`, `S27C9`, `S32C9`, `S9`, etc.) from `IODisplayCreateInfoDictionary`. Falls back to `NSScreen.localizedName` on macOS Tahoe where `IODisplayConnect` services may not be exposed.
- **Compatible:** Any other display that supports native brightness via IOKit.
- **Unsupported:** Displays with no known brightness control path.

Supports user overrides stored in `UserDefaults` for manual display type assignment.

#### `BrightnessRouter`

Routes brightness actions based on cursor position:

- **Built-in / Compatible:** Adjusts brightness via `IODisplaySetFloatParameter` with `kIODisplayBrightnessKey`. Falls back to the `brightness` CLI if IOKit direct control fails.
- **ViewFinity S9:** Sends `0x01` or `0x02` to the ESP32 via `SerialPortService`.
- **Unsupported:** Ignores the action.

### Models

#### `ScreenType`

Enum: `.builtIn`, `.compatible`, `.viewFinityS9`, `.unsupported`.

### App Layer

#### `BrightnessControlApp`

`@main` app using `MenuBarExtra` with a dynamic SF Symbol icon reflecting connection status:

| State | Icon |
|-------|------|
| ESP32 disconnected | `tv.slash` |
| ESP32 connected, BLE disconnected | `display.trianglebadge.exclamationmark` |
| ESP32 connected, BLE connected | `display` |

#### `SettingsView`

SwiftUI settings window with:

- Serial port picker (auto-detect or manual override)
- Connect/disconnect controls
- BLE pairing management (pair, unpair, status)
- Display assignment overrides
- Launch at Login toggle (`SMAppService`)

---

## Project Structure

```
ViewFinityBrightnessControl/
├── App/
│   ├── BrightnessControlApp.swift       # @main, MenuBarExtra, AppDelegate
│   └── SettingsView.swift               # Settings window
├── Services/
│   ├── SerialPortService.swift          # USB-CDC discovery & communication
│   ├── KeyInterceptor.swift             # CGEventTap brightness key interception
│   ├── CursorMonitor.swift              # Cursor position tracking
│   ├── ScreenResolver.swift             # Display classification (EDID / localizedName)
│   └── BrightnessRouter.swift           # Route brightness to native or serial
├── Models/
│   └── ScreenType.swift                 # ScreenType enum
├── Info.plist
└── ViewFinityBrightnessControl.entitlements
```

---

## Build

```sh
cd macos-app
xcodebuild -project ViewFinityBrightnessControl.xcodeproj \
  -scheme ViewFinityBrightnessControl \
  -configuration Release \
  -derivedDataPath build clean build
```

The built app is at `build/Build/Products/Release/ViewFinity Brightness Control.app`.

### Code Signing

The project uses `Apple Development` code signing with a stable developer certificate. This is important — ad-hoc signing (`-`) generates a new `cdhash` on every build, causing macOS TCC to reset Accessibility permissions each time.

A valid `DEVELOPMENT_TEAM` must be configured in the Xcode project.

---

## Install

1. Copy `ViewFinity Brightness Control.app` to `/Applications`.
2. Launch the app.
3. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility).
4. The app appears in the menu bar and auto-connects to the ESP32-S3 if plugged in.

### Transferring to Another Mac

Build and zip:

```sh
cd build/Build/Products/Release
zip -r ~/Desktop/ViewFinityBrightnessControl.zip "ViewFinity Brightness Control.app"
```

Transfer via AirDrop, USB drive, or `scp`. On the destination Mac:

1. Unzip the archive.
2. Move the `.app` to `/Applications`.
3. **Remove the quarantine attribute** (required since the app is not notarized):
   ```sh
   xattr -cr /Applications/ViewFinity\ Brightness\ Control.app
   ```
4. Launch and grant Accessibility permission.

> **Note:** Without `xattr -cr`, macOS Gatekeeper will block the app with an "app is damaged" or "can't be opened" error. This is because the app is signed but not notarized — the quarantine flag triggers Gatekeeper's check on first launch.

---

## Permissions

| Permission | Required | Why |
|-----------|----------|-----|
| **Accessibility** | Yes | `CGEventTap` needs it to intercept brightness key events |
| **Input Monitoring** | No | Not required — `CGEventTap` uses Accessibility, not Input Monitoring |
| **App Sandbox** | Disabled | POSIX serial I/O and `CGEventTap` are incompatible with App Sandbox |

---

## User Preferences

Stored in `UserDefaults`:

| Key | Type | Description |
|-----|------|-------------|
| `preferredSerialPort` | `String?` | Manual serial port override (e.g. `/dev/cu.usbmodem14201`) |
| `screenTypeOverrides` | `[String: String]` | Display ID → ScreenType overrides |
| `brightnessBehavior` | `String` | Brightness routing mode (see TODO) |