# Changelog

All notable changes and discoveries for this project are documented here.

---

## 2026-02-27 — macOS Tahoe (26.x) CGEventTap & Display Detection Fixes

### Problem

The macOS host app's `CGEventTap` received **zero keyboard events** — only mouse/trackpad `NX_SYSDEFINED` (type 14, subtype 7) events arrived. Brightness keys, regular letter keys, and modifier keys were all invisible to the tap. The tap created successfully, Accessibility permission was granted and verified, and the callback fired for mouse events — but nothing keyboard-related came through.

### Root Cause

#### CGEventMask must not use `UInt64.max`

The original mask was set to `UInt64.max` (minus a few mouse bits) as a "catch-all" diagnostic approach. This overflows the valid `CGEventMask` range and causes `CGEvent.tapCreate` to silently drop **all** keyboard event delivery — only mouse/trackpad NX_SYSDEFINED events (subtype 7) arrived.

**Working mask:**
```
let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)     // 10
    | (1 << 14)                                                 // NX_SYSDEFINED
```

**Broken mask (no keyboard events):**
```
let mask = UInt64.max & ~(mouse bits)  // overflows valid CGEventMask range
```

This was initially misdiagnosed as needing `keyUp` (11) and `flagsChanged` (12) in the mask. Testing confirmed that the narrow `keyDown` + `NX_SYSDEFINED` mask works correctly on macOS Tahoe 26.

#### Brightness keys arrive as `keyDown` keycodes, not `NX_SYSDEFINED`

On macOS Tahoe, brightness keys are delivered as **`keyDown` events** (type 10) with keycodes:
- **144** — Brightness Up
- **145** — Brightness Down

On earlier macOS versions, they arrived as `NX_SYSDEFINED` events (type 14, subtype 8) with `NX_KEYTYPE_BRIGHTNESS_UP` (2) and `NX_KEYTYPE_BRIGHTNESS_DOWN` (3) packed in `data1`. The app must handle both paths for cross-version compatibility.

#### Event tap should use the main run loop

Adding the `CGEventTap` run loop source to a background thread's run loop may cause keyboard events to not be delivered on macOS Tahoe. Using `CFRunLoopGetMain()` is the most reliable approach.

#### IODisplayConnect EDID lookup fails on macOS Tahoe

`IOServiceGetMatchingServices` with `IODisplayConnect` returns no results on macOS Tahoe, causing the EDID-based display name lookup to return empty strings. The fix is to fall back to `NSScreen.localizedName`, which correctly reports the display name (e.g., `S27C900P` for the 27″ ViewFinity S9).

### How It Was Diagnosed

1. Added verbose file logging (`/tmp/keyinterceptor.log`) since GUI apps don't output to terminal.
2. Built a standalone `test_tap.swift` CLI tool with the same `CGEventTap` logic — it captured all events correctly, proving the API works and Accessibility was granted.
3. Compared the standalone binary (no hardened runtime, ad-hoc signed) vs the app bundle (hardened runtime, Apple Development signed) — initially suspected code signing, but the real issue was the event mask.
4. Widened the mask to match the standalone tool's mask (which included `keyUp` and `flagsChanged`) — this restored keyboard events, but was a red herring.
5. Retested with the narrow mask (`keyDown` + `NX_SYSDEFINED` only) — also worked. Confirmed the actual root cause was the `UInt64.max` overflow, not missing event type bits.

### Summary

The original bug was entirely caused by using `UInt64.max` as a diagnostic "catch-all" mask, which overflows `CGEventMask` and silently breaks keyboard event delivery. The correct mask is `(1 << NX_KEYDOWN) | (1 << NX_SYSDEFINED)`.

### Files Changed

- `Services/KeyInterceptor.swift` — Fixed event mask, moved tap to main run loop
- `Services/ScreenResolver.swift` — Added `NSScreen.localizedName` fallback, added `S27C9`/`S32C9` patterns
- `UniDesk.entitlements` — Added `com.apple.security.cs.allow-jit`
