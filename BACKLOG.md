# Backlog

## In Progress

_(empty)_

## To Do

### macOS App

- **Swallow brightness events on ViewFinity S9:** The event tap currently returns the event (not swallowed), so macOS adjusts the built-in display even when the cursor is over the ViewFinity S9. Return `nil` from the CGEventTap callback when `activeScreenType == .viewFinityS9` to prevent native brightness adjustment.

- **Brightness behavior setting:** Add a `UserDefaults`-backed setting (`brightnessBehavior`) with options: `cursorOnly` (default — swallow event when on S9), `alwaysBoth` (adjust both displays), `viewFinityOnly` (always send to ESP32, swallow native). Expose in `SettingsView` as a picker.

- **Increase handshake nonce size:** Current nonce is 2 bytes (65536 values). Increase to 8 bytes to reduce collision risk with stale responses. Requires protocol change.

- **Add serial response length limits:** Truncate parsed serial response fields (e.g. device names) to reasonable lengths.

- **Audit Unmanaged pointer lifetimes:** `passUnretained` in IOKit/CGEventTap callbacks could dangle. Add invalidation guards or switch to `passRetained`.

### Firmware

_(empty)_

## Done

- **Fix connection not sustained through USB hub (macOS app):** Through the ViewFinity S9's built-in USB hub, the CDC ACM TX endpoint takes longer to become ready — `tud_cdc_n_connected()` returns false for several hundred milliseconds after DTR is asserted, causing `send_response()` to silently drop the PING reply. The single handshake attempt then timed out. Fixed by retrying the handshake up to 3 times with a 1s delay between attempts; the 500ms post-open settle delay is kept for the first attempt. Direct USB connections still succeed on attempt 1 at no extra cost.

- **Fix connection not sustained (macOS app):** Two bugs caused the connection to drop and not recover. (1) `setupUSBNotifications` used `kIOSerialBSDServiceValue`/`kIOSerialBSDModemType` which matched every USB serial device on the system — any UART dongle, hub event, etc. triggered a spurious `connect()` that opened/closed the port and asserted/de-asserted DTR, producing the ~111 identical `DTR=1 RTS=1` callbacks visible in monitor.log. Fixed by switching to `IOUSBHostDevice` matching with `idVendor`/`idProduct` so only the ESP32 itself fires the notification. (2) A handshake timeout (caused by the firmware flushing its RX queue on the DTR storm) set `handshakeFailed = true`, permanently blocking all future auto-reconnects. Timeouts are now treated as transient — `handshakeFailed` is only set on wrong-firmware responses, preserving reconnect recovery.

- **FiiO K11 R2R DAC volume control (macOS app):** Added `AudioOutputMonitor` (CoreAudio default output device tracking), `VolumeAction` enum, volume key interception in `KeyInterceptor`, `SerialCommand.fiioVolumeUp`/`.fiioVolumeDown` (0x0A/0x0B), menu bar Volume Up/Down buttons, and FiiO DAC audio device picker in Settings. Volume keys are swallowed and routed to ESP32 when the current default audio output matches the configured FiiO device name.

- **Code audit fixes (F-01–F-21):** Removed `kiLog()` world-readable debug logger and all call sites (F-02). Removed dead `HIDKeyboardMonitor` class (F-03). Removed duplicate `NSEvent` global monitor that fired double brightness events (F-04). Removed F14/F15 keycode interception — not brightness keys (F-05). Removed diagnostic logging in event tap hot path (F-19). Extracted `consumeContinuation()` to prevent `CheckedContinuation` double-resume race (F-01). Made `brightnessUp`/`brightnessDown` fire-and-forget — no 5s timeout on protocol-defined no-response commands (F-10). Replaced all `NSLog` with `Logger.debug` (F-12). Removed blind serial port fallback to first `cu.usbmodem*` (F-14). Fixed `fcntl(F_GETFL)` unchecked return value (F-21). Replaced magic `c_cc` tuple indices with `VMIN`/`VTIME` via unsafe pointer (F-07). Fixed `IOObjectRelease(iterator)` double-release in `ScreenResolver` (F-08). Deduplicated 3 IOKit display-matching loops into shared `withMatchingIODisplayService` (F-09). Removed `adjustBrightnessFallback` external CLI execution (F-13). Removed overly broad `"S9"` EDID pattern (F-20). Removed unnecessary `com.apple.security.cs.allow-jit` entitlement (F-11).

- **Reconnect on brightness key press:** `BrightnessRouter.sendSerialBrightness` now calls `connect()` when disconnected before sending the command.
- **Configurable ESC debounce:** Added `CMD_GET_ESC_DEBOUNCE` (0x08) / `CMD_SET_ESC_DEBOUNCE` (0x07) to the serial protocol. Firmware stores the value in NVS (`app_settings/esc_dbnc_ms`) and loads it on boot. macOS Settings view exposes a slider (200–10000 ms) in the General section; value is read from the board on connect and written back on slider release.
- **Fix ESC debounce slider build error:** Moved `onEditingChanged` from an invalid view modifier to the correct trailing closure position in the `Slider` initializer (`label:minimumValueLabel:maximumValueLabel:onEditingChanged:`).
- **Fix Settings window crash on Connect:** Replaced `NSHostingController` with `NSHostingView` as `contentView` to eliminate re-entrant `_postWindowNeedsUpdateConstraints` SIGABRT caused by `updateAnimatedWindowSize` during `@Published` property changes. Added `isConnecting` guard to prevent concurrent `connect()` calls.
- **Fix firmware USB TX false failures:** `tinyusb_cdcacm_write_queue()` returns `size_t` (bytes written), not `esp_err_t`. The old code compared against `ESP_OK` (0), treating every successful write as failure and re-queuing duplicate data. Fixed return-value check in `send_response()`.
- **Firmware audit fixes (C01–C15):** Fixed 15 findings — separate CCCD backing arrays, null BDA in `esp_ble_gap_disconnect`, CommandHandler race condition (sentinel via RX queue), ESC debounce read timeout, press/release timing 5→20ms, atomic `connected_`/`conn_id_`/`dtr_active_`, advertising double-start guard, `svc_inst_id` dispatch, partial USB TX loop, bond-clearing dedup, ESC task stack 3072→4096, `app_main` return, `peer_name_` population, stack overflow detection in sdkconfig, AGENTS.md gotchas.

## Won't Do

- **Brightness step configuration (multi-step per keypress):** Implemented and tested a `UserDefaults`-backed setting (1–5 steps per keypress) that looped serial commands to the ESP32. The ViewFinity S9 monitor cannot reliably process rapid sequential HID brightness reports — it drops or misorders them. Reverted entirely. Any future attempt would need a firmware-side approach with inter-report delays, but the monitor's OSD latency makes this impractical.