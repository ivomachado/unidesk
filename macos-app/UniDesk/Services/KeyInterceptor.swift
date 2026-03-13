import AppKit
import Foundation
import os.log

/// Enumerates the brightness actions derived from media key events.
enum BrightnessAction {
    case up
    case down
}

/// Enumerates volume actions derived from media key events.
/// Semantically distinct from `BrightnessAction` — routed to the FiiO K11 R2R
/// DAC via optocoupler-isolated GPIO quadrature, not to display brightness.
enum VolumeAction {
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
    private static let NX_KEYTYPE_SOUND_UP: Int = 0
    private static let NX_KEYTYPE_SOUND_DOWN: Int = 1
    private static let NX_KEYTYPE_BRIGHTNESS_UP: Int = 2
    private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int = 3

    // Brightness keycodes used in keyDown events (macOS Tahoe 26+)
    private static let KEYCODE_BRIGHTNESS_UP: Int64 = 144
    private static let KEYCODE_BRIGHTNESS_DOWN: Int64 = 145

    // Volume keycodes used in keyDown events (macOS Tahoe 26+)
    private static let KEYCODE_VOLUME_UP: Int64 = 128
    private static let KEYCODE_VOLUME_DOWN: Int64 = 129

    // Traditional Carbon/HIToolbox volume keycodes (kVK_VolumeUp / kVK_VolumeDown).
    // These may be used on pre-Tahoe systems or in keyUp events.
    private static let KEYCODE_VOLUME_UP_LEGACY: Int64 = 0x48  // 72
    private static let KEYCODE_VOLUME_DOWN_LEGACY: Int64 = 0x49  // 73

    // Standard keyboard Escape key
    private static let KEYCODE_ESCAPE: Int64 = 53

    var keyEventPort: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var tapRunLoop: CFRunLoop?

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "EventTap")

    var onBrightnessEvent: ((_ action: BrightnessAction, _ event: CGEvent) -> Unmanaged<CGEvent>?)?
    /// Called when a volume key (NX_KEYTYPE_SOUND_UP/DOWN or Tahoe keycodes 128/129) is pressed.
    /// Return nil to swallow the event, or Unmanaged.passUnretained(event) to let macOS handle it.
    var onVolumeEvent: ((_ action: VolumeAction, _ event: CGEvent) -> Unmanaged<CGEvent>?)?
    /// Called when the Escape key is released (keyUp) on the keyboard.
    /// This callback is executed on the main run loop context of the event tap.
    var onEscKeyUp: (() -> Void)?

    /// Synchronous check for whether volume events should be swallowed.
    /// Used for key-up swallowing without firing actions.
    var shouldSwallowVolume: (() -> Bool)?

    func startWatchingMediaKeys() -> Bool {
        // keyDown (10) and keyUp (11) for regular keyboard events + NX_SYSDEFINED (14) for media key events.
        // Do NOT use UInt64.max — it overflows the valid CGEventMask range and silently drops
        // all keyboard events.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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

        // PATH 0: Regular keyUp events — Escape release + volume key-up swallowing.
        // Volume key-ups MUST be swallowed when FiiO is active, otherwise macOS
        // processes the volume change on key-up even if key-down was swallowed.
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.KEYCODE_ESCAPE {
                if let cb = onEscKeyUp {
                    Task { @MainActor in
                        cb()
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            // Swallow volume key-ups when FiiO is the active output device.
            // No action is fired — the action was already dispatched on key-down.
            if keyCode == Self.KEYCODE_VOLUME_UP || keyCode == Self.KEYCODE_VOLUME_UP_LEGACY
                || keyCode == Self.KEYCODE_VOLUME_DOWN || keyCode == Self.KEYCODE_VOLUME_DOWN_LEGACY
            {
                if shouldSwallowVolume?() == true {
                    logger.debug("keyUp volume swallowed (keyCode=\(keyCode))")
                    return nil
                }
            }
        }

        // PATH 1: Regular keyDown events — brightness keys as keycodes 144/145,
        //          volume keys as keycodes 128/129 (macOS Tahoe 26+)
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            switch keyCode {
            case Self.KEYCODE_BRIGHTNESS_UP:
                logger.debug("keyDown brightness UP (keyCode=\(keyCode))")
                return onBrightnessEvent?(.up, event) ?? Unmanaged.passUnretained(event)
            case Self.KEYCODE_BRIGHTNESS_DOWN:
                logger.debug("keyDown brightness DOWN (keyCode=\(keyCode))")
                return onBrightnessEvent?(.down, event) ?? Unmanaged.passUnretained(event)
            case Self.KEYCODE_VOLUME_UP, Self.KEYCODE_VOLUME_UP_LEGACY:
                logger.debug("keyDown volume UP (keyCode=\(keyCode))")
                return onVolumeEvent?(.up, event) ?? Unmanaged.passUnretained(event)
            case Self.KEYCODE_VOLUME_DOWN, Self.KEYCODE_VOLUME_DOWN_LEGACY:
                logger.debug("keyDown volume DOWN (keyCode=\(keyCode))")
                return onVolumeEvent?(.down, event) ?? Unmanaged.passUnretained(event)
            default:
                return Unmanaged.passUnretained(event)
            }
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

        switch Int(keyCode) {
        case Self.NX_KEYTYPE_BRIGHTNESS_UP:
            guard isKeyDown else { return Unmanaged.passUnretained(event) }
            logger.debug("NX_SYSDEFINED brightness UP (nxKeyType=\(keyCode))")
            return onBrightnessEvent?(.up, event) ?? Unmanaged.passUnretained(event)
        case Self.NX_KEYTYPE_BRIGHTNESS_DOWN:
            guard isKeyDown else { return Unmanaged.passUnretained(event) }
            logger.debug("NX_SYSDEFINED brightness DOWN (nxKeyType=\(keyCode))")
            return onBrightnessEvent?(.down, event) ?? Unmanaged.passUnretained(event)
        case Self.NX_KEYTYPE_SOUND_UP:
            if isKeyDown {
                logger.debug("NX_SYSDEFINED volume UP keyDown (nxKeyType=\(keyCode))")
                return onVolumeEvent?(.up, event) ?? Unmanaged.passUnretained(event)
            } else {
                // Key-up: swallow without firing action to prevent macOS from
                // processing the volume change on key-up.
                if shouldSwallowVolume?() == true {
                    logger.debug("NX_SYSDEFINED volume UP keyUp swallowed")
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
        case Self.NX_KEYTYPE_SOUND_DOWN:
            if isKeyDown {
                logger.debug("NX_SYSDEFINED volume DOWN keyDown (nxKeyType=\(keyCode))")
                return onVolumeEvent?(.down, event) ?? Unmanaged.passUnretained(event)
            } else {
                if shouldSwallowVolume?() == true {
                    logger.debug("NX_SYSDEFINED volume DOWN keyUp swallowed")
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
        default:
            return Unmanaged.passUnretained(event)
        }
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
    /// Called when a volume key is pressed. The callback should return `true`
    /// to swallow the event (preventing macOS from adjusting system volume),
    /// or `false` to let it pass through.
    var onVolumeAction: ((VolumeAction) -> Bool)?
    /// Called when the Escape key is released (keyUp). Consumers should assign this
    /// to perform the ESC-forwarding action (e.g. call SerialPortService.sendESC()).
    var onEsc: (() -> Void)?

    // MARK: - Dependencies

    private var cursorMonitor: CursorMonitor?
    /// Provides the thread-safe `isFiioActive` flag for the event tap callback
    /// to decide synchronously whether to swallow volume key events.
    private var audioOutputMonitor: AudioOutputMonitor?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "KeyInterceptor")
    private let internals = EventTapInternals()
    private var permissionCheckTimer: Timer?

    // MARK: - Lifecycle

    func start(cursorMonitor: CursorMonitor, audioOutputMonitor: AudioOutputMonitor) {
        self.cursorMonitor = cursorMonitor
        self.audioOutputMonitor = audioOutputMonitor
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

        // Wire up volume key handling. The swallow decision must be synchronous
        // (CGEventTap callback returns immediately), so we read the lock-protected
        // `isFiioActive` flag from AudioOutputMonitor instead of actor-hopping.
        let volumeLogger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "VolumeIntercept")
        internals.onVolumeEvent = { [weak self] action, event in
            guard let self = self else { return Unmanaged.passUnretained(event) }

            let shouldSwallow = self.audioOutputMonitor?.isFiioActiveSync ?? false
            volumeLogger.debug("Volume event: action=\(String(describing: action)) isFiioActiveSync=\(shouldSwallow)")

            if shouldSwallow {
                Task { @MainActor in
                    _ = self.onVolumeAction?(action)
                }
                return nil  // swallow — prevent macOS from adjusting system volume
            }

            return Unmanaged.passUnretained(event)  // pass through to macOS
        }

        // Synchronous swallow check for key-up events (no action dispatched).
        internals.shouldSwallowVolume = { [weak self] in
            self?.audioOutputMonitor?.isFiioActiveSync ?? false
        }

        // Wire up Escape key release handling to call the consumer-provided callback.
        // Consumers of `KeyInterceptor` should assign `onEsc` to implement the sendESC behavior.
        internals.onEscKeyUp = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.onEsc?()
            }
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
                    if let cm = self?.cursorMonitor, let aom = self?.audioOutputMonitor {
                        self?.start(cursorMonitor: cm, audioOutputMonitor: aom)
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
