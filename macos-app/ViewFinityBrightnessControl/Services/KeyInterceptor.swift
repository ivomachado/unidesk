import AppKit
import Foundation
import os.log

/// Enumerates the brightness actions derived from media key events.
enum BrightnessAction {
    case up
    case down
}

/// Describes the current Accessibility permission state.
enum AccessibilityStatus: Equatable {
    case unknown
    case granted
    case denied
}

// MARK: - Event Tap Internals (non-actor, runs on main run loop)

/// Handles the low-level CGEventTap on the main run loop.
///
/// Brightness keys can arrive through TWO paths:
///   1. **keyDown events** (type 10) — keycodes 144 (brightness up) and 145 (brightness down).
///      This is the path used on macOS Tahoe 26+.
///   2. **NX_SYSDEFINED events** (type 14) — subtype 8 with NX_KEYTYPE_BRIGHTNESS_UP (2)
///      and NX_KEYTYPE_BRIGHTNESS_DOWN (3) packed in data1.
///      This is the path used on earlier macOS versions.
private final class EventTapInternals {

    // NX constants for NX_SYSDEFINED media key events
    private static let NX_KEYTYPE_BRIGHTNESS_UP: Int = 2
    private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int = 3

    // Brightness keycodes used in keyDown events (macOS Tahoe 26+)
    private static let KEYCODE_BRIGHTNESS_UP: Int64 = 144
    private static let KEYCODE_BRIGHTNESS_DOWN: Int64 = 145

    var keyEventPort: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var tapRunLoop: CFRunLoop?

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "EventTap")

    var onBrightnessEvent: ((_ action: BrightnessAction, _ event: CGEvent) -> Unmanaged<CGEvent>?)?

    func startWatchingMediaKeys() -> Bool {
        // keyDown (10) for brightness keycodes 144/145 + NX_SYSDEFINED (14) for media key events.
        // Do NOT use UInt64.max — it overflows the valid CGEventMask range and silently drops
        // all keyboard events.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << 14) // NX_SYSDEFINED

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let internals = Unmanaged<EventTapInternals>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout {
                    internals.logger.warning("Event tap disabled by timeout — re-enabling")
                    if let port = internals.keyEventPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                } else if type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }

                return internals.handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            logger.error("CGEvent.tapCreate failed — Accessibility permission missing")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            logger.error("RunLoopSource creation failed")
            return false
        }

        self.keyEventPort = port
        self.runLoopSource = source

        // Add tap to the MAIN run loop — keyboard events may not be
        // delivered reliably to background thread run loops.
        self.tapRunLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(self.tapRunLoop, source, .commonModes)
        logger.info("Event tap added to main run loop")

        return true
    }

    func stopWatchingMediaKeys() {
        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            runLoopSource = nil
        }
        tapRunLoop = nil
        if let port = keyEventPort {
            CFMachPortInvalidate(port)
            keyEventPort = nil
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // PATH 1: Regular keyDown events — brightness keys as keycodes 144/145 (macOS Tahoe 26+)
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let action: BrightnessAction
            switch keyCode {
            case Self.KEYCODE_BRIGHTNESS_UP:
                action = .up
            case Self.KEYCODE_BRIGHTNESS_DOWN:
                action = .down
            default:
                return Unmanaged.passUnretained(event)
            }

            logger.debug("keyDown brightness \(action == .up ? "UP" : "DOWN") (keyCode=\(keyCode))")
            return onBrightnessEvent?(action, event) ?? Unmanaged.passUnretained(event)
        }

        // PATH 2: NX_SYSDEFINED events — traditional media-key path (pre-Tahoe)
        guard type.rawValue == UInt32(NX_SYSDEFINED) else {
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        let subtype = nsEvent.subtype.rawValue
        guard subtype == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let flags = data1 & 0x0000FFFF
        let isKeyDown = (flags & 0xFF00) == 0x0A00

        guard isKeyDown else {
            return Unmanaged.passUnretained(event)
        }

        let action: BrightnessAction
        switch Int(keyCode) {
        case Self.NX_KEYTYPE_BRIGHTNESS_UP:
            action = .up
        case Self.NX_KEYTYPE_BRIGHTNESS_DOWN:
            action = .down
        default:
            return Unmanaged.passUnretained(event)
        }

        logger.debug("NX_SYSDEFINED brightness \(action == .up ? "UP" : "DOWN") (nxKeyType=\(keyCode))")
        return onBrightnessEvent?(action, event) ?? Unmanaged.passUnretained(event)
    }
}

// MARK: - KeyInterceptor (MainActor, observable)

/// Observes brightness key presses via CGEventTap (keyDown keycodes 144/145 + NX_SYSDEFINED).
/// Requires Accessibility permission to function.
@MainActor
final class KeyInterceptor: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var permissionStatus: AccessibilityStatus = .unknown

    // MARK: - Callback

    var onBrightnessAction: ((BrightnessAction) -> Void)?

    // MARK: - Dependencies

    private var cursorMonitor: CursorMonitor?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "KeyInterceptor")
    private let internals = EventTapInternals()
    private var permissionCheckTimer: Timer?

    // MARK: - Lifecycle

    func start(cursorMonitor: CursorMonitor) {
        self.cursorMonitor = cursorMonitor
        guard !isMonitoring else {
            logger.debug("Already monitoring — ignoring duplicate start()")
            return
        }

        // Wire up the CGEventTap callback
        internals.onBrightnessEvent = { [weak self] action, event in
            guard let self = self else { return Unmanaged.passUnretained(event) }

            Task { @MainActor in
                self.onBrightnessAction?(action)
            }

            // TODO: When cursor is over ViewFinity S9, return nil to swallow the event
            return Unmanaged.passUnretained(event)
        }

        checkAccessibilityPermission(showPrompt: true)

        let success = internals.startWatchingMediaKeys()
        if success {
            isMonitoring = true
            permissionStatus = .granted
            stopPermissionCheckTimer()
            logger.info("Event tap active")
        } else {
            isMonitoring = false
            permissionStatus = .denied
            startPermissionCheckTimer()
        }
    }

    func stop() {
        stopPermissionCheckTimer()
        internals.stopWatchingMediaKeys()
        isMonitoring = false
    }

    // MARK: - Permission Handling

    private func checkAccessibilityPermission(showPrompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: showPrompt]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        permissionStatus = trusted ? .granted : .denied

        if trusted {
            stopPermissionCheckTimer()
        } else if showPrompt {
            startPermissionCheckTimer()
        }
    }

    private func startPermissionCheckTimer() {
        guard permissionCheckTimer == nil else { return }
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAccessibilityPermission(showPrompt: false)
                if self?.permissionStatus == .granted, self?.isMonitoring == false {
                    if let cm = self?.cursorMonitor {
                        self?.start(cursorMonitor: cm)
                    }
                }
            }
        }
    }

    private func stopPermissionCheckTimer() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}