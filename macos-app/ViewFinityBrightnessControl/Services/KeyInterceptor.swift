import AppKit
import Foundation
import IOKit.hid
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

/// Simple file logger for diagnostics (macOS GUI apps don't show print/NSLog in terminal)
private func kiLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/keyinterceptor.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

// MARK: - Event Tap Internals (non-actor, runs on background thread)

/// Handles the low-level CGEventTap on a dedicated background run loop.
///
/// Brightness keys can arrive through TWO paths:
///   1. **keyDown events** (type 10) — keycodes 144 (brightness up) and 145 (brightness down).
///   2. **NX_SYSDEFINED events** (type 14) — subtype 8 with NX_KEYTYPE_BRIGHTNESS_UP (2)
///      and NX_KEYTYPE_BRIGHTNESS_DOWN (3) packed in data1.
private final class EventTapInternals {

    // NX constants for NX_SYSDEFINED media key events
    private static let NX_KEYTYPE_BRIGHTNESS_UP: Int = 2
    private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int = 3

    // Function-key keycodes that map to brightness (used in keyDown events)
    private static let KEYCODE_BRIGHTNESS_UP: Int64 = 144
    private static let KEYCODE_BRIGHTNESS_DOWN: Int64 = 145
    private static let KEYCODE_F15_BRIGHTNESS_UP: Int64 = 113
    private static let KEYCODE_F14_BRIGHTNESS_DOWN: Int64 = 107

    var keyEventPort: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var tapRunLoop: CFRunLoop?
    var tapThread: Thread?

    var onBrightnessEvent: ((_ action: BrightnessAction, _ event: CGEvent) -> Unmanaged<CGEvent>?)?

    func startWatchingMediaKeys() -> Bool {
        kiLog("[EventTapInternals] Creating CGEventTap…")

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
                    kiLog("[EventTapCallback] ⚠️ Tap disabled by timeout — re-enabling")
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
            kiLog("[EventTapInternals] ❌ CGEvent.tapCreate failed — Accessibility permission missing")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            kiLog("[EventTapInternals] ❌ RunLoopSource creation failed")
            return false
        }

        self.keyEventPort = port
        self.runLoopSource = source

        // Add tap to the MAIN run loop — keyboard events may not be
        // delivered reliably to background thread run loops.
        self.tapRunLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(self.tapRunLoop, source, .commonModes)
        kiLog("[EventTapInternals] ✅ Event tap added to MAIN run loop")

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
        let typeRaw = type.rawValue

        // DIAGNOSTIC: Log ALL event types except mouse-related ones
        // We need to find what (if any) event type brightness keys produce
        if typeRaw != 5 && typeRaw != 6 && typeRaw != 7 && typeRaw != 22 && typeRaw != 27 {
            var extra = ""
            if typeRaw == 10 || typeRaw == 11 { // keyDown / keyUp
                let kc = event.getIntegerValueField(.keyboardEventKeycode)
                extra = " keycode=\(kc)"
            } else if typeRaw == 14 { // NX_SYSDEFINED
                if let nsEv = NSEvent(cgEvent: event) {
                    extra = " subtype=\(nsEv.subtype.rawValue) data1=0x\(String(nsEv.data1, radix: 16))"
                }
            }
            kiLog("[EventTap] type=\(typeRaw)\(extra)")
        }

        // PATH 1: Regular keyDown events — brightness keys as keycodes 144/145
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let action: BrightnessAction
            switch keyCode {
            case Self.KEYCODE_BRIGHTNESS_UP, Self.KEYCODE_F15_BRIGHTNESS_UP:
                action = .up
            case Self.KEYCODE_BRIGHTNESS_DOWN, Self.KEYCODE_F14_BRIGHTNESS_DOWN:
                action = .down
            default:
                return Unmanaged.passUnretained(event)
            }

            kiLog("[EventTap] 🔆 keyDown brightness \(action == .up ? "UP" : "DOWN") (keyCode=\(keyCode))")
            return onBrightnessEvent?(action, event) ?? Unmanaged.passUnretained(event)
        }

        // PATH 2: NX_SYSDEFINED events — traditional media-key path
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

        kiLog("[EventTap] 🔆 NX_SYSDEFINED brightness \(action == .up ? "UP" : "DOWN") (nxKeyType=\(keyCode))")
        return onBrightnessEvent?(action, event) ?? Unmanaged.passUnretained(event)
    }
}

// MARK: - IOHIDManager (raw HID events — captures keys before macOS processes them)

/// Monitors raw HID events at the lowest level. On Apple keyboards, brightness keys
/// arrive as F1/F2 on the Keyboard usage page (0x07), NOT as Consumer Control codes.
/// This captures them before macOS translates them.
private final class HIDKeyboardMonitor {

    private var manager: IOHIDManager?

    /// Called when a brightness-related HID event is detected.
    var onBrightnessEvent: ((_ action: BrightnessAction) -> Void)?

    func start() {
        kiLog("[HIDMonitor] Starting IOHIDManager…")

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = mgr

        // Match keyboards and consumer control devices
        let deviceMatches: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey: 0x01, // Generic Desktop
                kIOHIDDeviceUsageKey: 0x06      // Keyboard
            ],
            [
                kIOHIDDeviceUsagePageKey: 0x0C, // Consumer Control
                kIOHIDDeviceUsageKey: 0x01      // Consumer Control
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(mgr, deviceMatches as CFArray)

        let inputCallback: IOHIDValueCallback = { context, result, sender, value in
            let element = IOHIDValueGetElement(value)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let intValue = IOHIDValueGetIntegerValue(value)

            let isConsumer = usagePage == 0x0C
            let isKeyboard = usagePage == 0x07

            // Log consumer control events and key-down keyboard events
            if isConsumer && intValue != 0 {
                kiLog("[HIDMonitor] Consumer: page=0x0C usage=0x\(String(format: "%04X", usage)) value=\(intValue)")
            }

            // Check for brightness consumer control usages (0x006F up, 0x0070 down)
            if isConsumer && intValue != 0 {
                switch usage {
                case 0x006F:
                    kiLog("[HIDMonitor] 🔆 BRIGHTNESS UP via Consumer Control (0x006F)")
                case 0x0070:
                    kiLog("[HIDMonitor] 🔅 BRIGHTNESS DOWN via Consumer Control (0x0070)")
                default:
                    break
                }
            }

            // Check for F1/F2 on keyboard page (Apple keyboards report brightness here)
            if isKeyboard && intValue != 0 {
                switch usage {
                case 0x3A: // F1 — brightness down on Mac keyboards
                    kiLog("[HIDMonitor] ⌨️ F1 (0x3A) pressed — brightness DOWN candidate")
                case 0x3B: // F2 — brightness up on Mac keyboards
                    kiLog("[HIDMonitor] ⌨️ F2 (0x3B) pressed — brightness UP candidate")
                default:
                    break
                }
            }
        }

        IOHIDManagerRegisterInputValueCallback(mgr, inputCallback, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            kiLog("[HIDMonitor] ✅ IOHIDManager opened — monitoring keyboard + consumer HID events")
        } else {
            kiLog("[HIDMonitor] ❌ IOHIDManager open failed: \(openResult)")
        }
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        kiLog("[HIDMonitor] Stopped")
    }
}

// MARK: - KeyInterceptor (MainActor, observable)

/// Observes brightness key presses using multiple detection paths:
/// 1. CGEventTap (keyDown keycodes 144/145 + NX_SYSDEFINED)
/// 2. NSEvent global monitor (NX_SYSDEFINED fallback)
/// 3. IOHIDManager (raw HID events — captures F1/F2 before macOS processing)
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
    private let hidMonitor = HIDKeyboardMonitor()
    private var permissionCheckTimer: Timer?
    private var globalMonitor: Any?

    // MARK: - Lifecycle

    func start(cursorMonitor: CursorMonitor) {
        self.cursorMonitor = cursorMonitor
        guard !isMonitoring else {
            logger.debug("Already monitoring — ignoring duplicate start()")
            return
        }

        kiLog("[KeyInterceptor] Setting up event capture (CGEventTap + IOHIDManager + NSEvent)…")

        // Wire up the CGEventTap callback
        internals.onBrightnessEvent = { [weak self] action, event in
            guard let self = self else { return Unmanaged.passUnretained(event) }

            let screenType = self.cursorMonitor?.activeScreenType ?? .builtIn

            kiLog("[KeyInterceptor] ⏩ Brightness \(action == .up ? "UP" : "DOWN") for \(screenType)")
            Task { @MainActor in
                self.onBrightnessAction?(action)
            }

            // TODO: When cursor is over ViewFinity S9, return nil to swallow the event
            return Unmanaged.passUnretained(event)
        }

        checkAccessibilityPermission(showPrompt: true)

        // Install NSEvent global monitor as a parallel detection path
        installNSEventMonitor()

        // Start IOHIDManager to capture raw HID events (works even if CGEventTap doesn't see them)
        hidMonitor.start()

        let success = internals.startWatchingMediaKeys()
        if success {
            isMonitoring = true
            permissionStatus = .granted
            stopPermissionCheckTimer()
            kiLog("[KeyInterceptor] ✅ All capture paths active")
        } else {
            isMonitoring = false
            permissionStatus = .denied
            startPermissionCheckTimer()
        }
    }

    func stop() {
        stopPermissionCheckTimer()
        internals.stopWatchingMediaKeys()
        hidMonitor.stop()
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        isMonitoring = false
    }

    // MARK: - NSEvent Global Monitor (parallel approach)

    private func installNSEventMonitor() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            let subtype = event.subtype.rawValue
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let flags = data1 & 0x0000FFFF
            let isKeyDown = (flags & 0xFF00) == 0x0A00

            // Log all systemDefined events to see what arrives
            kiLog("[NSEventMonitor] subtype=\(subtype) keyCode=\(keyCode) flags=0x\(String(flags, radix: 16)) isKeyDown=\(isKeyDown)")

            guard subtype == 8, isKeyDown else { return }

            let action: BrightnessAction
            switch Int(keyCode) {
            case 2: action = .up
            case 3: action = .down
            default: return
            }

            kiLog("[NSEventMonitor] ✅ brightness \(action == .up ? "UP" : "DOWN")")
            Task { @MainActor [weak self] in
                self?.onBrightnessAction?(action)
            }
        }
        kiLog("[KeyInterceptor] NSEvent global monitor installed")
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