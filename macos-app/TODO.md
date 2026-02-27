# macOS App — TODO

## High Priority

_(empty)_

---

## Completed

- ✅ **KeyInterceptor brightness key detection (NSEvent approach)** — Uses `NSEvent.addGlobalMonitorForEvents(matching: .systemDefined)` with Input Monitoring permission detection via `IOHIDCheckAccess`/`IOHIDRequestAccess`. Works correctly when permission is granted but requires Input Monitoring. Replaced by CGEventTap approach below.

- ✅ **Rewrite `KeyInterceptor` to use `CGEventTap` with Accessibility permission** — Replaced the `NSEvent.addGlobalMonitorForEvents` approach with `CGEventTapCreate`. Uses a passive/active tap at `kCGSessionEventTap` to observe `NX_SYSDEFINED` events with subtype `NX_SUBTYPE_AUX_CONTROL_BUTTON` (8). Parses `data1` for key codes `NX_KEYTYPE_BRIGHTNESS_UP` (2) and `NX_KEYTYPE_BRIGHTNESS_DOWN` (3). Checks permission via `AXIsProcessTrusted()` and prompts via `AXIsProcessTrustedWithOptions`. Re-checks every 2 seconds until granted, with a UI banner guiding the user to System Settings → Privacy & Security → Accessibility. Swallows events when cursor is over ViewFinity S9 to prevent native OSD.

## Backlog

_(empty)_