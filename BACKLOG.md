# Backlog

## In Progress

_(empty)_

## To Do

### macOS App

- **Swallow brightness events on ViewFinity S9:** The event tap currently returns the event (not swallowed), so macOS adjusts the built-in display even when the cursor is over the ViewFinity S9. Return `nil` from the CGEventTap callback when `activeScreenType == .viewFinityS9` to prevent native brightness adjustment.

- **Brightness behavior setting:** Add a `UserDefaults`-backed setting (`brightnessBehavior`) with options: `cursorOnly` (default — swallow event when on S9), `alwaysBoth` (adjust both displays), `viewFinityOnly` (always send to ESP32, swallow native). Expose in `SettingsView` as a picker.





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

- **Reconnect on brightness key press:** `BrightnessRouter.sendSerialBrightness` now calls `connect()` when disconnected before sending the command.
- **Configurable ESC debounce:** Added `CMD_GET_ESC_DEBOUNCE` (0x08) / `CMD_SET_ESC_DEBOUNCE` (0x07) to the serial protocol. Firmware stores the value in NVS (`app_settings/esc_dbnc_ms`) and loads it on boot. macOS Settings view exposes a slider (200–10000 ms) in the General section; value is read from the board on connect and written back on slider release.
- **Fix ESC debounce slider build error:** Moved `onEditingChanged` from an invalid view modifier to the correct trailing closure position in the `Slider` initializer (`label:minimumValueLabel:maximumValueLabel:onEditingChanged:`).
- **Fix Settings window crash on Connect:** Replaced `NSHostingController` with `NSHostingView` as `contentView` to eliminate re-entrant `_postWindowNeedsUpdateConstraints` SIGABRT caused by `updateAnimatedWindowSize` during `@Published` property changes. Added `isConnecting` guard to prevent concurrent `connect()` calls.
- **Fix firmware USB TX false failures:** `tinyusb_cdcacm_write_queue()` returns `size_t` (bytes written), not `esp_err_t`. The old code compared against `ESP_OK` (0), treating every successful write as failure and re-queuing duplicate data. Fixed return-value check in `send_response()`.

## Won't Do

- **Brightness step configuration (multi-step per keypress):** Implemented and tested a `UserDefaults`-backed setting (1–5 steps per keypress) that looped serial commands to the ESP32. The ViewFinity S9 monitor cannot reliably process rapid sequential HID brightness reports — it drops or misorders them. Reverted entirely. Any future attempt would need a firmware-side approach with inter-report delays, but the monitor's OSD latency makes this impractical.