# Backlog

## In Progress

_(empty)_

## To Do

### macOS App

- **Swallow brightness events on ViewFinity S9:** The event tap currently returns the event (not swallowed), so macOS adjusts the built-in display even when the cursor is over the ViewFinity S9. Return `nil` from the CGEventTap callback when `activeScreenType == .viewFinityS9` to prevent native brightness adjustment.

- **Brightness behavior setting:** Add a `UserDefaults`-backed setting (`brightnessBehavior`) with options: `cursorOnly` (default — swallow event when on S9), `alwaysBoth` (adjust both displays), `viewFinityOnly` (always send to ESP32, swallow native). Expose in `SettingsView` as a picker.

- **Reconnect on brightness key press:** When the ESP32 is disconnected and a brightness key is pressed while the cursor is over the ViewFinity S9, trigger a background reconnection attempt instead of silently ignoring the key.

- **Crash when connecting from Settings window:** Investigate crash when pressing "Connect" in the Settings window. Likely a re-entrant `connect()` call or threading race. Guard against concurrent connection attempts.

- **Remove `kiLog()` debug logger:** `kiLog()` in `KeyInterceptor.swift` writes every intercepted key event to `/tmp/keyinterceptor.log` (world-readable). Remove entirely or gate behind `#if DEBUG`.

- **Remove JIT entitlement:** `com.apple.security.cs.allow-jit` is unnecessary — remove from entitlements file.

- **Downgrade verbose logging:** Replace `NSLog` calls that log raw serial bytes and nonces with `Logger.debug` or `#if DEBUG`.

- **Remove brightness CLI fallback:** `adjustBrightnessFallback()` executes an external binary without signature verification. Remove or add verification.

- **Increase handshake nonce size:** Current nonce is 2 bytes (65536 values). Increase to 8 bytes to reduce collision risk with stale responses.

- **Add serial response length limits:** Truncate parsed serial response fields (e.g. device names) to reasonable lengths.

- **Audit Unmanaged pointer lifetimes:** `passUnretained` in IOKit/CGEventTap callbacks could dangle. Add invalidation guards or switch to `passRetained`.

### Firmware

_(empty)_

## Done

_(empty)_

## Won't Do

_(empty)_