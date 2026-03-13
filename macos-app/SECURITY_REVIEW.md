# macOS App Security Review

**Date:** 2025-01-20
**Scope:** macOS menu bar app (UniDesk)

---

## Findings

### 🔴 M-01: Debug Log Writes to World-Readable Temp File

**File:** `Services/KeyInterceptor.swift` L21–30

The `kiLog()` function writes every intercepted key event (type, keycode, flags) to `/tmp/keyinterceptor.log`. This file is:

- Created with default permissions (world-readable on macOS).
- Never rotated or cleaned up.
- Written to on every event tap callback, including non-brightness keys.

Any local user or process can read this file to observe keyboard activity patterns.

```
private func kiLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/keyinterceptor.log"
    ...
}
```

**Recommendation:**
- Remove `kiLog()` entirely or gate it behind a compile-time `DEBUG` flag.
- If runtime diagnostics are needed, use `os.log` (which respects system log levels and does not persist to a user-accessible file).

---

### 🔴 M-02: App Sandbox Disabled

**File:** `project.yml` L37

```
ENABLE_APP_SANDBOX: false
```

The app runs completely unsandboxed. Combined with Accessibility permission (which grants global event tap access) and hardened runtime's JIT entitlement, the app has broad system access. While sandbox disabling may be necessary for `CGEvent.tapCreate` and IOKit serial access, it means any vulnerability in the app gives an attacker full user-level access.

**Recommendation:**
- Document why sandboxing is disabled (CGEventTap + POSIX serial I/O are incompatible with App Sandbox).
- Minimise attack surface by removing unnecessary entitlements (see M-03).
- Consider distributing outside the Mac App Store with notarisation only, and document the security trade-off.

---

### 🟡 M-03: Unnecessary JIT Entitlement

**File:** `UniDesk.entitlements`

```xml
<key>com.apple.security.cs.allow-jit</key>
<true/>
```

The app does not use JIT compilation. This entitlement weakens hardened runtime protections by allowing memory pages to be mapped as both writable and executable (`MAP_JIT`). It was likely added during debugging and should be removed.

**Recommendation:**
- Remove `com.apple.security.cs.allow-jit` from the entitlements file.
- Test that the app launches and functions correctly without it.

---

### 🟡 M-04: Serial Port Fallback Bypasses VID/PID Verification

**File:** `Services/SerialPortService.swift` L398–401 (`discoverESP32Port()`)

```swift
// Fallback: return first /dev/cu.usbmodem* if IOKit matching didn't find VID/PID
let ports = availablePorts()
if let first = ports.first {
    ...
    return first
}
```

If the IOKit VID/PID walk fails (which can happen due to IORegistry structure variations), the app falls back to opening the **first** `/dev/cu.usbmodem*` device it finds. This could be an unrelated USB serial device. The handshake nonce protects against sending commands to wrong firmware, but the app still opens and configures an arbitrary serial device.

**Recommendation:**
- Log a warning when the fallback is used (already done).
- Consider removing the blind fallback in production and requiring explicit user selection when VID/PID matching fails.

---

### 🟡 M-05: Unmanaged Pointer Lifetime in IOKit / Event Tap Callbacks

**File:** `Services/SerialPortService.swift` L840 (`setupUSBNotifications()`)

```swift
let selfPtr = Unmanaged.passUnretained(self).toOpaque()
```

**File:** `Services/KeyInterceptor.swift` L68 (`startWatchingMediaKeys()`)

```swift
let refcon = Unmanaged.passUnretained(self).toOpaque()
```

Both use `passUnretained` to pass `self` as a raw pointer to C callbacks. If the owning object is deallocated while the callback is still registered, the callback will dereference a dangling pointer (use-after-free). In practice this is unlikely because:

- `AppDelegate` owns these objects for the process lifetime.
- `SerialPortService.deinit` tears down the notification port.

However, there is no guarantee the IOKit callbacks won't fire *during* `deinit` teardown, and the `EventTapInternals` instance has no explicit invalidation guard in its callbacks.

**Recommendation:**
- Use `passRetained` / `takeRetainedValue` or ensure callbacks are fully unregistered before the raw pointer becomes invalid.
- Add a `Bool` invalidation flag checked at the top of each C callback.

---

### 🟡 M-06: Brightness CLI Fallback Executes External Binary

**File:** `Services/BrightnessRouter.swift` L105–140 (`adjustBrightnessFallback()`)

```swift
let candidates = ["/usr/local/bin/brightness", "/opt/homebrew/bin/brightness"]
guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { ... }
```

The app searches for and executes an external `brightness` CLI tool from fixed paths. If an attacker places a malicious binary at `/usr/local/bin/brightness` (which is user-writable without root on some configurations), it would be executed with the app's privileges.

**Recommendation:**
- Verify the binary's code signature or checksum before execution.
- Or remove the CLI fallback entirely and rely solely on `IODisplaySetFloatParameter` (the primary path already works for compatible displays).

---

### 🟡 M-07: Verbose NSLog / os.log in Production

**Files:** `Services/SerialPortService.swift` (throughout), `Services/KeyInterceptor.swift`, `Services/BrightnessRouter.swift`

The app logs raw serial bytes (hex + ASCII), every RX/TX transaction, nonce values, device paths, and display IDs via `NSLog` and `os.log` at info level. Examples:

```swift
NSLog("[SerialPort] RX raw (%d bytes): [%@] ascii: %@", bytesRead, hex, ascii...)
NSLog("[SerialPort] TX: 0x04 + nonce '%@', expecting 'OK:PING:%@'", nonce, nonce)
```

This data is visible in Console.app to any local user and persists in the unified log.

**Recommendation:**
- Move byte-level and protocol-level logging to `Logger.debug` (which is stripped in release by default).
- Remove `NSLog` calls or wrap them in `#if DEBUG`.
- Never log nonce values at info level.

---

### 🟢 M-08: Handshake Nonce Is Not Cryptographic

**File:** `Services/SerialPortService.swift` L647–650

```swift
private func generateNonce() -> String {
    let bytes = (0..<2).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}
```

The nonce is 2 bytes (4 hex characters, 65536 possible values). It is used to match handshake responses, not for authentication. However, the small space means collisions with stale responses are plausible if the buffer contains old `OK:PING:XXXX` lines.

**Recommendation:**
- Increase nonce to 8 bytes (16 hex characters) to make accidental collisions negligible.
- This is low severity since the nonce is not used for security, only for response matching.

---

### 🟢 M-09: No Input Validation on Serial Response Parsing

**File:** `Services/SerialPortService.swift` L33–52 (`SerialResponse.parse()`)

The parser trusts all data received from the serial port. A malicious or malfunctioning device could send crafted responses (e.g., very long device names in `STATUS:connected:<name>`) that would be stored in `pairedDeviceName` and displayed in the UI.

While this is unlikely to cause code execution (Swift strings are memory-safe), extremely long strings could cause UI layout issues or memory pressure.

**Recommendation:**
- Truncate parsed fields to reasonable lengths (e.g., device names to 64 characters).
- Validate that response payloads contain only expected characters.

---

### 🟢 M-10: CGEventTap Intercepts But Does Not Swallow Events

**File:** `Services/KeyInterceptor.swift` L345–349

```swift
// TODO: When cursor is over ViewFinity S9, return nil to swallow the event
return Unmanaged.passUnretained(event)
```

Brightness key events are always passed through (returned, not swallowed). This means macOS will also process them, potentially adjusting the built-in display brightness simultaneously when the cursor is over the ViewFinity S9.

This is a functional issue, not a security issue, but the existing `TODO` suggests it's known. Noted here because `defaultTap` (not `listenOnly`) is used, meaning the tap *can* swallow events — the capability is there but unused.

**Recommendation:**
- Return `nil` from the event tap callback when the cursor is over the ViewFinity S9 to prevent macOS from double-processing brightness keys.

---

## Summary

| ID   | Severity | Finding                                | Effort |
|------|----------|----------------------------------------|--------|
| M-01 | 🔴 High  | Debug log to world-readable temp file  | Low    |
| M-02 | 🔴 High  | App Sandbox disabled                   | N/A    |
| M-03 | 🟡 Med   | Unnecessary JIT entitlement            | Low    |
| M-04 | 🟡 Med   | Serial port fallback skips VID/PID     | Low    |
| M-05 | 🟡 Med   | Unmanaged pointer lifetime risk        | Medium |
| M-06 | 🟡 Med   | External CLI execution without verification | Low |
| M-07 | 🟡 Med   | Verbose logging exposes protocol data  | Low    |
| M-08 | 🟢 Low   | Small handshake nonce space            | Low    |
| M-09 | 🟢 Low   | No input validation on serial responses| Low    |
| M-10 | 🟢 Low   | Brightness events not swallowed        | Low    |

### Suggested Priority

1. **M-01** — Remove or gate `kiLog()` behind `DEBUG`. Quick win, high impact.
2. **M-03** — Remove the JIT entitlement. One-line change.
3. **M-07** — Downgrade `NSLog` calls to `Logger.debug` or `#if DEBUG`.
4. **M-06** — Remove the brightness CLI fallback or add signature verification.
5. **M-04** — Remove blind serial port fallback in release builds.
6. **M-08** — Increase nonce to 8 bytes.
7. **M-09** — Add length limits to parsed serial response fields.
8. **M-05** — Audit Unmanaged pointer lifetimes; add invalidation guards.
9. **M-10** — Implement event swallowing for ViewFinity S9 (functional fix).
10. **M-02** — Document sandbox rationale; no code change possible.
