import AppKit
import IOKit.graphics
import os.log

// MARK: - Shared IOKit Display Matching

/// Iterates all `IODisplayConnect` services in the IORegistry and calls `body`
/// with the first service whose vendor, product, and serial number match
/// the given `CGDirectDisplayID`.
///
/// The caller receives an **unretained** `io_service_t` and the already-parsed
/// info dictionary. The service is released automatically after `body` returns;
/// if the caller needs to keep it (e.g. for `IODisplaySetFloatParameter`), they
/// must call `IOObjectRetain` on it and take ownership.
///
/// - Returns: The value returned by `body`, or `nil` if no matching service was found.
func withMatchingIODisplayService<T>(
    for displayID: CGDirectDisplayID,
    body: (io_service_t, [String: Any]) -> T
) -> T? {
    let vendorID    = CGDisplayVendorNumber(displayID)
    let productID   = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    let matching = IOServiceMatching("IODisplayConnect") as NSMutableDictionary

    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard result == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }

    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard let infoDict = IODisplayCreateInfoDictionary(
            service,
            IOOptionBits(kIODisplayOnlyPreferredName)
        )?.takeRetainedValue() as? [String: Any] else {
            continue
        }

        let dVendor  = infoDict[kDisplayVendorID]     as? UInt32 ?? 0
        let dProduct = infoDict[kDisplayProductID]     as? UInt32 ?? 0
        let dSerial  = infoDict[kDisplaySerialNumber]  as? UInt32 ?? 0

        guard dVendor == vendorID, dProduct == productID, dSerial == serialNumber else {
            continue
        }

        return body(service, infoDict)
    }

    return nil
}

// MARK: - BrightnessRouter

/// Routes brightness adjustment commands to the correct backend based on which
/// display the cursor is currently over.
///
/// - **Built-in / Compatible displays:** adjust brightness natively via IOKit
///   (`IODisplaySetFloatParameter` with `kIODisplayBrightnessKey`).
/// - **ViewFinity S9:** forward the command as a single byte over the USB serial
///   bridge to the ESP32.
@MainActor
final class BrightnessRouter: ObservableObject {

    // MARK: - Dependencies

    private let serialPort: SerialPortService
    private let cursorMonitor: CursorMonitor
    private let screenResolver: ScreenResolver

    // MARK: - Constants

    /// The step size used when adjusting native brightness (1/16 ≈ 6.25 %).
    private static let brightnessStep: Float = 1.0 / 16.0

    // MARK: - Private

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "BrightnessRouter")

    // MARK: - Init

    init(serialPort: SerialPortService,
         cursorMonitor: CursorMonitor,
         screenResolver: ScreenResolver) {
        self.serialPort = serialPort
        self.cursorMonitor = cursorMonitor
        self.screenResolver = screenResolver
    }

    // MARK: - Public API

    /// Handle a brightness action by routing it to the appropriate backend.
    func handleBrightness(_ action: BrightnessAction) {
        let screenType = cursorMonitor.activeScreenType

        switch screenType {
        case .builtIn, .compatible:
            adjustNativeBrightness(action: action)

        case .viewFinityS9:
            sendSerialBrightness(action: action)

        case .unsupported:
            logger.info("Cursor is on an unsupported display — brightness action ignored")
        }
    }

    // MARK: - Native Brightness (IOKit)

    /// Adjusts brightness on the display the cursor is over using IOKit.
    private func adjustNativeBrightness(action: BrightnessAction) {
        guard let screen = cursorMonitor.activeScreen,
              let displayID = screen.displayID else {
            logger.warning("No active screen to adjust brightness on")
            return
        }

        guard let service = retainedIOServicePort(for: displayID) else {
            logger.warning("Could not find IOService for display \(displayID)")
            return
        }
        defer { IOObjectRelease(service) }

        // Read current brightness.
        var current: Float = 0
        let readResult = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &current)
        guard readResult == kIOReturnSuccess else {
            logger.warning("IODisplayGetFloatParameter failed (\(readResult))")
            return
        }

        // Compute the new value, clamping to [0, 1].
        let delta: Float = (action == .up) ? Self.brightnessStep : -Self.brightnessStep
        let newValue = min(max(current + delta, 0), 1)

        let writeResult = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, newValue)
        if writeResult == kIOReturnSuccess {
            logger.debug("Native brightness set to \(String(format: "%.2f", newValue)) on display \(displayID)")
        } else {
            logger.error("IODisplaySetFloatParameter failed (\(writeResult))")
        }
    }

    // MARK: - Serial Brightness (ESP32)

    /// Sends the brightness command to the ESP32 via the serial bridge.
    /// If the ESP32 is disconnected, attempts a background reconnection
    /// and sends the command if the connection succeeds.
    private func sendSerialBrightness(action: BrightnessAction) {
        Task {
            if !serialPort.isConnected {
                logger.info("ESP32 not connected — attempting reconnect before sending brightness command")
                await serialPort.connect()
            }

            guard serialPort.isConnected else {
                logger.warning("ESP32 reconnect failed — brightness command dropped")
                return
            }

            switch action {
            case .up:
                serialPort.brightnessUp()
            case .down:
                serialPort.brightnessDown()
            }
        }
    }

    // MARK: - IOKit Helpers

    /// Returns a **retained** `io_service_t` for the given display ID.
    /// The caller must call `IOObjectRelease` when done.
    private func retainedIOServicePort(for displayID: CGDirectDisplayID) -> io_service_t? {
        withMatchingIODisplayService(for: displayID) { service, _ in
            IOObjectRetain(service)
            return service
        }
    }
}