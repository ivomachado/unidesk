import AppKit
import IOKit.graphics
import os.log

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

        let service = ioServicePort(for: displayID)
        guard service != 0 else {
            logger.warning("Could not find IOService for display \(displayID) — trying fallback")
            adjustBrightnessFallback(action: action)
            return
        }
        defer { IOObjectRelease(service) }

        // Read current brightness.
        var current: Float = 0
        let readResult = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &current)
        guard readResult == kIOReturnSuccess else {
            logger.warning("IODisplayGetFloatParameter failed (\(readResult)) — trying fallback")
            adjustBrightnessFallback(action: action)
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

    /// Fallback: use the `brightness` CLI tool if IOKit direct control isn't available.
    private func adjustBrightnessFallback(action: BrightnessAction) {
        // Try to find the `brightness` CLI in common locations.
        let candidates = ["/usr/local/bin/brightness", "/opt/homebrew/bin/brightness"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            logger.warning("No `brightness` CLI found — cannot adjust native brightness via fallback")
            return
        }

        // The `brightness` CLI typically works with the built-in display.
        // Usage: `brightness <float 0.0–1.0>`
        // We read the current value via the tool, adjust, and write back.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)

        // Read current value first.
        let readPipe = Pipe()
        process.standardOutput = readPipe
        process.arguments = ["-l"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run brightness CLI: \(error.localizedDescription)")
            return
        }

        let output = String(data: readPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Parse current brightness from output (format: "display 0: brightness X.XXXXXX")
        guard let currentValue = parseBrightnessOutput(output) else {
            logger.warning("Could not parse brightness CLI output")
            return
        }

        let delta: Float = (action == .up) ? Self.brightnessStep : -Self.brightnessStep
        let newValue = min(max(currentValue + delta, 0), 1)

        let setProcess = Process()
        setProcess.executableURL = URL(fileURLWithPath: tool)
        setProcess.arguments = [String(format: "%.4f", newValue)]

        do {
            try setProcess.run()
            setProcess.waitUntilExit()
            logger.debug("Fallback brightness set to \(String(format: "%.2f", newValue))")
        } catch {
            logger.error("Failed to set brightness via CLI: \(error.localizedDescription)")
        }
    }

    /// Parses the output of `brightness -l` to extract the current brightness float.
    private func parseBrightnessOutput(_ output: String) -> Float? {
        // Expected format: "display 0: brightness 0.671875"
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("brightness") {
                let parts = line.components(separatedBy: " ")
                if let last = parts.last, let value = Float(last) {
                    return value
                }
            }
        }
        return nil
    }

    // MARK: - Serial Brightness (ESP32)

    /// Sends the brightness command to the ESP32 via the serial bridge.
    private func sendSerialBrightness(action: BrightnessAction) {
        guard serialPort.isConnected else {
            logger.warning("ESP32 not connected — cannot send brightness command")
            return
        }

        Task {
            switch action {
            case .up:
                await serialPort.brightnessUp()
            case .down:
                await serialPort.brightnessDown()
            }
        }
    }

    // MARK: - IOKit Helpers

    /// Resolves the IOKit service for a given `CGDirectDisplayID`.
    private func ioServicePort(for displayID: CGDirectDisplayID) -> io_service_t {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)

        let matching = IOServiceMatching("IODisplayConnect") as NSMutableDictionary

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            guard let infoDict = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? [String: Any] else {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
                continue
            }

            let dVendor  = infoDict[kDisplayVendorID]    as? UInt32 ?? 0
            let dProduct = infoDict[kDisplayProductID]   as? UInt32 ?? 0
            let dSerial  = infoDict[kDisplaySerialNumber] as? UInt32 ?? 0

            if dVendor == vendorID, dProduct == productID, dSerial == serialNumber {
                return service // caller is responsible for IOObjectRelease
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return 0
    }
}