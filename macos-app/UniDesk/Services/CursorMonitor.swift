import AppKit
import Combine
import os.log

/// Monitors the mouse cursor position and publishes the `ScreenType` of the
/// display the cursor is currently over.
///
/// Uses a lightweight polling timer (~100 ms) to sample `NSEvent.mouseLocation`,
/// then resolves the enclosing `NSScreen` and delegates classification to
/// `ScreenResolver`.
///
/// Coordinate space note: `NSEvent.mouseLocation` uses the Cocoa coordinate
/// system (origin at bottom-left of the primary screen), which matches
/// `NSScreen.frame` — so no manual conversion is needed.
@MainActor
final class CursorMonitor: ObservableObject {

    // MARK: - Published State

    /// The screen type the cursor is currently over.
    @Published private(set) var activeScreenType: ScreenType = .builtIn

    /// The `NSScreen` the cursor is currently over (if any).
    @Published private(set) var activeScreen: NSScreen?

    /// Human-readable name of the active screen.
    @Published private(set) var activeScreenName: String = "Unknown"

    // MARK: - Dependencies

    private let screenResolver: ScreenResolver

    // MARK: - Private

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "CursorMonitor")

    /// Polling timer — fires every ~100 ms.
    private var timer: Timer?

    /// Last resolved display ID, used to avoid redundant updates.
    private var lastDisplayID: CGDirectDisplayID?

    // MARK: - Init

    /// - Parameter screenResolver: The resolver used to classify each `NSScreen`.
    init(screenResolver: ScreenResolver) {
        self.screenResolver = screenResolver
    }

    // MARK: - Lifecycle

    /// Starts polling the cursor position.
    func start() {
        guard timer == nil else { return }

        logger.info("Cursor monitoring started")
        // Fire once immediately so the UI reflects the initial state.
        poll()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    /// Stops polling the cursor position.
    func stop() {
        timer?.invalidate()
        timer = nil
        logger.info("Cursor monitoring stopped")
    }

    // MARK: - Polling

    /// Samples the current mouse location and updates published state if the
    /// cursor has moved to a different screen.
    private func poll() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = screen(containing: mouseLocation) else { return }
        guard let displayID = screen.displayID else { return }

        // Skip redundant updates.
        guard displayID != lastDisplayID else { return }
        lastDisplayID = displayID

        let type = screenResolver.screenType(for: screen)
        activeScreen = screen
        activeScreenType = type
        activeScreenName = screen.localizedName

        logger.debug("Cursor moved to display \(displayID) (\(screen.localizedName)) — type: \(String(describing: type))")
    }

    /// Returns the `NSScreen` whose frame contains the given point.
    ///
    /// Both `NSEvent.mouseLocation` and `NSScreen.frame` use the same Cocoa
    /// coordinate system, so a simple `contains` check is sufficient.
    private func screen(containing point: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        // Fallback: if the cursor is somehow outside all frames (e.g. hot corners,
        // display reconfiguration), return the main screen.
        return NSScreen.main
    }
}