import AppKit
import Foundation
import IOKit
import IOKit.serial
import os.log

// MARK: - Serial Protocol Constants

enum SerialCommand: UInt8 {
    case brightnessUp      = 0x01
    case brightnessDown    = 0x02
    case enterPairing      = 0x03
    case handshake         = 0x04
    case getStatus         = 0x05
    case unpair            = 0x06
    case setEscDebounce    = 0x07
    case getEscDebounce    = 0x08
}

enum SerialResponse {
    case ok(String)          // OK:PING:<nonce>, OK:UP, OK:DOWN, OK:PAIRING, OK:UNPAIRED
    case status(connected: Bool, deviceName: String)
    case error(String)       // ERR:<message>

    /// The full payload after "OK:" — used for nonce matching on PING responses.
    var okPayload: String? {
        if case .ok(let p) = self { return p }
        return nil
    }

    static func parse(_ line: String) -> SerialResponse? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("OK:") {
            let payload = String(trimmed.dropFirst(3))
            return .ok(payload)
        } else if trimmed.hasPrefix("STATUS:") {
            let payload = String(trimmed.dropFirst(7))
            let parts = payload.split(separator: ":", maxSplits: 1)
            guard let first = parts.first else { return .error("MALFORMED_STATUS") }
            let connected = first == "connected"
            let name = parts.count > 1 ? String(parts[1]) : ""
            return .status(connected: connected, deviceName: name)
        } else if trimmed.hasPrefix("ERR:") {
            let payload = String(trimmed.dropFirst(4))
            return .error(payload)
        }
        return nil
    }
}

// MARK: - SerialPortService

/// Manages USB-CDC serial communication with the ESP32-S3 brightness bridge.
///
/// Responsibilities:
/// - Discover `/dev/cu.usbmodem*` ports and match ESP32-S3 by VID/PID via IOKit.
/// - Open/close the serial port with POSIX I/O and correct termios configuration.
/// - Perform a handshake to verify firmware identity on connect.
/// - Send single-byte commands and parse newline-terminated ASCII responses.
/// - Auto-reconnect on USB plug events via IOKit matching notifications.
/// - Re-initialize the connection after macOS sleep/wake cycles.
@MainActor
final class SerialPortService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var portPath: String?
    @Published private(set) var lastError: String?
    @Published private(set) var bleConnected: Bool = false

    // MARK: - Constants

    /// ESP32-S3 native USB VID/PID (TinyUSB CDC default descriptor)
    private static let espressifVID: Int = 0x303A
    private static let esp32S3PID: Int   = 0x4001

    private static let baudRate: speed_t = 115200

    private static let responseTimeout: TimeInterval = 5.0
    private static let reconnectDelay: TimeInterval = 2.0

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "SerialPort")

    private var fileDescriptor: Int32 = -1
    private var originalTermios = termios()
    private var readSource: DispatchSourceRead?

    /// Buffer for accumulating partial reads until a newline is received.
    private var readBuffer = Data()

    /// Pending response continuation for request/response commands.
    private var responseContinuation: CheckedContinuation<SerialResponse, Error>?

    /// When set, only responses matching this tag will resolve the continuation.
    /// All other responses are discarded as stale.
    /// Use `consumeContinuation()` to atomically nil-check and clear in both
    /// timeout and data-driven resume paths.
    private var expectedResponseTag: String?

    /// The nonce sent with the current handshake, used to match `OK:PING:<nonce>`.
    private var handshakeNonce: String?

    /// IOKit notification port and iterators for USB plug/unplug.
    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    /// Workspace notification observer token for sleep/wake.
    private var wakeObserver: NSObjectProtocol?

    /// Whether we're in the middle of a reconnect attempt.
    private var isReconnecting = false

    /// Whether `connect()` is currently executing — guards against concurrent calls
    /// from the Settings UI, USB notifications, wake handler, or BrightnessRouter.
    private var isConnecting = false

    /// Set when handshake fails — prevents auto-reconnect loops when the
    /// board is present but running wrong/no firmware.
    private var handshakeFailed = false

    /// The user's preferred port path (if manually overridden).
    var preferredPortPath: String? {
        didSet {
            UserDefaults.standard.set(preferredPortPath, forKey: "preferredSerialPort")
        }
    }

    // MARK: - Init / Deinit

    init() {
        preferredPortPath = UserDefaults.standard.string(forKey: "preferredSerialPort")
        setupWakeNotification()
        setupUSBNotifications()
    }

    deinit {
        // Clean up is best-effort; we're tearing down anyway.
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
        // deinit is nonisolated, so we inline the critical cleanup directly.
        readSource?.cancel()
        readSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    // MARK: - Public API

    /// Lists all `/dev/cu.usbmodem*` ports currently present on the system.
    func availablePorts() -> [String] {
        let fm = FileManager.default
        do {
            let devContents = try fm.contentsOfDirectory(atPath: "/dev")
            return devContents
                .filter { $0.hasPrefix("cu.usbmodem") }
                .map { "/dev/\($0)" }
                .sorted()
        } catch {
            logger.error("Failed to list /dev: \(error.localizedDescription)")
            return []
        }
    }

    /// Attempts to connect to the ESP32. Discovers the port automatically or uses
    /// the user-preferred port path. Performs a handshake after opening.
    func connect() async {
        guard !isConnecting else {
            logger.info("connect() already in progress — skipping concurrent call")
            return
        }
        guard fileDescriptor == -1 else {
            logger.info("Already connected on \(self.portPath ?? "?")")
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        lastError = nil
        handshakeFailed = false

        // Resolve the port to use.
        let port: String
        if let preferred = preferredPortPath, FileManager.default.fileExists(atPath: preferred) {
            port = preferred
        } else if let discovered = discoverESP32Port() {
            port = discovered
        } else {
            let msg = "No ESP32-S3 serial port found"
            logger.warning("\(msg)")
            lastError = msg
            return
        }

        logger.info("Opening serial port: \(port)")

        guard openPort(port) else {
            return
        }

        portPath = port
        startReading()

        // Wait for the ESP32 USB-CDC TX FIFO to become ready after DTR
        // assertion. The firmware log shows tinyusb_cdcacm_write_queue
        // fails if the host sends a command immediately after opening the
        // port — the CDC ACM endpoint isn't fully initialised yet.
        logger.debug("Post-open settle delay (500ms) — waiting for ESP32 CDC TX ready")
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Handshake — uses a random nonce so the app can instantly identify
        // the fresh response among stale OK:PING responses buffered from
        // previous sessions. No drain delays needed.
        do {
            let response = try await sendHandshake()
            if case .ok(let payload) = response, payload.hasPrefix("PING:") {
                logger.info("Handshake successful (nonce matched)")
                handshakeFailed = false
                isConnected = true

                // Query status (with one retry on timeout)
                await refreshStatusWithRetry()
            } else {
                logger.error("Unexpected handshake response: \(String(describing: response))")
                handshakeFailed = true
                lastError = "Board responded with an unexpected message — is the correct firmware flashed?"
                disconnectKeepError()
            }
        } catch let error as SerialError where error == .timeout {
            logger.error("Handshake timed out")
            handshakeFailed = true
            lastError = "Board found but firmware did not respond — is the correct firmware flashed?"
            disconnectKeepError()
        } catch {
            logger.error("Handshake failed: \(error.localizedDescription)")
            handshakeFailed = true
            lastError = "Connection failed: \(error.localizedDescription)"
            disconnectKeepError()
        }
    }

    /// Disconnects from the serial port.
    func disconnect() {
        disconnectSync()
        isConnected = false
        portPath = nil
        lastError = nil
        bleConnected = false
    }

    /// Disconnects but preserves `lastError` so the UI can display the failure reason.
    private func disconnectKeepError() {
        let savedError = lastError
        disconnectSync()
        isConnected = false
        portPath = nil
        bleConnected = false
        lastError = savedError
    }

    /// Sends a brightness-up command to the ESP32 (fire-and-forget — no response expected).
    func brightnessUp() {
        do {
            try sendFireAndForget(.brightnessUp)
        } catch {
            logger.error("brightnessUp failed: \(error.localizedDescription)")
        }
    }

    /// Sends a brightness-down command to the ESP32 (fire-and-forget — no response expected).
    func brightnessDown() {
        do {
            try sendFireAndForget(.brightnessDown)
        } catch {
            logger.error("brightnessDown failed: \(error.localizedDescription)")
        }
    }

    /// Writes a single-byte command without setting up a continuation or waiting
    /// for a response. Used for brightness up/down which are fire-and-forget per
    /// the serial protocol (the firmware sends no response for 0x01/0x02).
    private func sendFireAndForget(_ command: SerialCommand) throws {
        guard fileDescriptor >= 0 else { throw SerialError.notConnected }
        var byte = command.rawValue
        let written = write(fileDescriptor, &byte, 1)
        guard written == 1 else {
            let err = String(cString: strerror(errno))
            logger.error("write() failed: \(err)")
            throw SerialError.writeFailed(err)
        }
        logger.debug("TX fire-and-forget: 0x\(String(format: "%02X", command.rawValue))")
    }

    /// Instructs the ESP32 to enter BLE pairing mode (clears NVS and restarts advertising).
    func enterPairingMode() async throws {
        let response = try await sendCommand(.enterPairing)
        if case .ok(let tag) = response, tag == "PAIRING" {
            logger.info("Board entered pairing mode")
            bleConnected = false
        } else if case .error(let msg) = response {
            throw SerialError.deviceError(msg)
        }
    }

    /// Instructs the ESP32 to clear its BLE bond.
    func unpair() async throws {
        let response = try await sendCommand(.unpair)
        if case .ok(let tag) = response, tag == "UNPAIRED" {
            logger.info("Bond cleared")
            bleConnected = false
        } else if case .error(let msg) = response {
            throw SerialError.deviceError(msg)
        }
    }

    /// Queries the ESP32 for its BLE connection status and paired device name.
    func refreshStatus() async {
        guard isConnected else { return }
        do {
            let response = try await sendCommand(.getStatus)
            if case .status(let connected, _) = response {
                bleConnected = connected
                logger.debug("Status: BLE \(connected ? "connected" : "disconnected")")
            } else {
                logger.warning("getStatus returned unexpected response: \(String(describing: response))")
            }
        } catch {
            logger.error("refreshStatus failed: \(error.localizedDescription)")
        }
    }

    /// Queries the ESC debounce timeout from the ESP32 (milliseconds).
    /// Returns nil if not connected or on error.
    func getEscDebounce() async -> UInt32? {
        guard isConnected else { return nil }
        do {
            let response = try await sendCommand(.getEscDebounce)
            return parseEscDebounceResponse(response)
        } catch {
            logger.error("getEscDebounce failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sends a new ESC debounce timeout (milliseconds) to the ESP32 and persists it in NVS.
    /// Returns the clamped value confirmed by the firmware, or nil on error.
    @discardableResult
    func setEscDebounce(_ ms: UInt32) async throws -> UInt32 {
        guard isConnected else { throw SerialError.notConnected }

        // Encode as 4 big-endian bytes appended immediately after the command byte.
        var payload = Data([SerialCommand.setEscDebounce.rawValue])
        payload.append(UInt8((ms >> 24) & 0xFF))
        payload.append(UInt8((ms >> 16) & 0xFF))
        payload.append(UInt8((ms >>  8) & 0xFF))
        payload.append(UInt8( ms        & 0xFF))

        // Cancel any stale pending continuation.
        if let stale = consumeContinuation() {
            stale.resume(throwing: SerialError.timeout)
        }

        let written = payload.withUnsafeBytes { buf in
            write(fileDescriptor, buf.baseAddress!, buf.count)
        }
        guard written == payload.count else {
            let err = String(cString: strerror(errno))
            throw SerialError.writeFailed(err)
        }

        let tag = "ESC_DEBOUNCE"
        logger.debug("TX: setEscDebounce \(ms) ms")

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SerialResponse, Error>) in
            self.expectedResponseTag = tag
            self.responseContinuation = continuation

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.responseTimeout * 1_000_000_000))
                if let pending = self?.consumeContinuation() {
                    pending.resume(throwing: SerialError.timeout)
                }
            }
        }

        if case .error(let msg) = response {
            throw SerialError.deviceError(msg)
        }
        guard let confirmed = parseEscDebounceResponse(response) else {
            throw SerialError.deviceError("Unexpected response")
        }
        return confirmed
    }

    /// Parses an `OK:ESC_DEBOUNCE:<ms>` response into a UInt32.
    private func parseEscDebounceResponse(_ response: SerialResponse) -> UInt32? {
        guard case .ok(let payload) = response,
              payload.hasPrefix("ESC_DEBOUNCE:"),
              let ms = UInt32(payload.dropFirst("ESC_DEBOUNCE:".count)) else {
            return nil
        }
        return ms
    }

    /// Queries status with a single retry on timeout.
    private func refreshStatusWithRetry() async {
        await refreshStatus()

        // If we didn't get a status (BLE state still default), retry once
        // after a brief delay — the first attempt may have been consumed by
        // stale data still being flushed from the ESP32.
        if isConnected && !bleConnected {
            logger.debug("Status may have failed — retrying after 500ms")
            try? await Task.sleep(nanoseconds: 500_000_000)
            readBuffer.removeAll()
            await refreshStatus()
        }
    }

    // MARK: - Port Discovery

    /// Uses IOKit to find a `/dev/cu.usbmodem*` device matching the ESP32-S3 VID/PID.
    private func discoverESP32Port() -> String? {
        let matchingDict = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matchingDict[kIOSerialBSDTypeKey] = kIOSerialBSDModemType

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard kr == KERN_SUCCESS else {
            logger.error("IOServiceGetMatchingServices failed: \(kr)")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            // Get the callout device path (e.g. /dev/cu.usbmodemXXXX)
            guard let pathCF = IORegistryEntryCreateCFProperty(
                service,
                kIOCalloutDeviceKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String else {
                continue
            }

            // Walk up the registry to find USB VID/PID
            if matchesESP32VIDandPID(service: service) {
                logger.info("Discovered ESP32-S3 at \(pathCF)")
                return pathCF
            }
        }

        return nil
    }

    /// Walks up the IORegistry tree from the serial service to find USB VID/PID properties.
    private func matchesESP32VIDandPID(service: io_service_t) -> Bool {
        var current = service
        IOObjectRetain(current)

        while current != 0 {
            if let vidCF = IORegistryEntryCreateCFProperty(
                current, "idVendor" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Int,
               let pidCF = IORegistryEntryCreateCFProperty(
                current, "idProduct" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? Int {
                IOObjectRelease(current)
                return vidCF == Self.espressifVID && pidCF == Self.esp32S3PID
            }

            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            if kr != KERN_SUCCESS { break }
            current = parent
        }

        return false
    }

    // MARK: - POSIX Serial I/O

    private func openPort(_ path: String) -> Bool {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            logger.error("open(\(path)) failed: \(err)")
            lastError = "Cannot open port: \(err)"
            return false
        }

        // Clear the O_NONBLOCK flag now that the port is open — we want blocking-aware reads
        // via GCD, not spinning.
        var flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            flags &= ~O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)
        } else {
            logger.warning("fcntl(F_GETFL) failed: \(String(cString: strerror(errno))) — O_NONBLOCK may remain set")
        }

        // Acquire an exclusive lock
        if ioctl(fd, TIOCEXCL) == -1 {
            logger.warning("ioctl(TIOCEXCL) failed — port may not be exclusive")
        }

        // Assert DTR and RTS signals so the ESP32 USB-CDC knows the host is
        // ready to communicate. Without this, the ESP32 may ignore incoming
        // bytes on reconnections (macOS sometimes auto-asserts DTR only on
        // the very first open after enumeration).
        if ioctl(fd, TIOCSDTR) == -1 {
            logger.warning("ioctl(TIOCSDTR) failed — DTR not asserted")
        }
        var modemBits: CInt = TIOCM_RTS
        if ioctl(fd, TIOCMBIS, &modemBits) == -1 {
            // RTS is less critical but good practice for USB-CDC.
            logger.warning("ioctl(TIOCMBIS, TIOCM_RTS) failed — RTS not asserted")
        }
        logger.debug("DTR/RTS asserted on fd=\(fd)")

        // Configure termios
        var options = termios()
        tcgetattr(fd, &options)
        originalTermios = options

        // Raw mode
        cfmakeraw(&options)

        // Baud rate
        cfsetispeed(&options, Self.baudRate)
        cfsetospeed(&options, Self.baudRate)

        // 8N1
        options.c_cflag |= UInt(CS8)
        options.c_cflag |= UInt(CLOCAL | CREAD)

        // VMIN = 1 byte, VTIME = 0 (block until at least 1 byte)
        withUnsafeMutablePointer(to: &options.c_cc) { ptr in
            let cc = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: cc_t.self)
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }

        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            let err = String(cString: strerror(errno))
            logger.error("tcsetattr failed: \(err)")
            lastError = "Serial config failed: \(err)"
            close(fd)
            return false
        }

        // Flush any stale data
        tcflush(fd, TCIOFLUSH)
        logger.debug("Port opened and flushed: \(path) (fd=\(fd))")

        fileDescriptor = fd
        return true
    }

    /// Starts a GCD dispatch source that reads incoming serial data.
    private func startReading() {
        guard fileDescriptor >= 0 else { return }

        readBuffer.removeAll()

        let fd = fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))

        source.setEventHandler { [weak self] in
            // Read on the background queue (non-isolated).
            var buf = [UInt8](repeating: 0, count: 256)
            let bytesRead = read(fd, &buf, buf.count)

            if bytesRead > 0 {
                let data = Data(buf[0..<bytesRead])
                Task { @MainActor [weak self] in
                    self?.processIncomingData(data)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EINTR) {
                Task { @MainActor [weak self] in
                    self?.handlePortDisconnected()
                }
            }
        }

        source.setCancelHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.logger.debug("Read source cancelled")
            }
        }

        readSource = source
        source.resume()
    }

    /// Accumulates incoming bytes and dispatches complete newline-terminated lines.
    private func processIncomingData(_ data: Data) {
        readBuffer.append(data)

        // Process all complete lines in the buffer.
        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)

            guard let lineString = String(data: lineData, encoding: .utf8) else { continue }
            handleResponseLine(lineString)
        }

        // Safety: prevent the buffer from growing unbounded if firmware sends garbage.
        if readBuffer.count > 4096 {
            logger.warning("Read buffer overflow — flushing")
            readBuffer.removeAll()
        }
    }

    /// Atomically checks and clears the pending continuation, returning it if
    /// one was present. Both the timeout task and the data-driven resume path
    /// must use this to avoid double-resume of a `CheckedContinuation`.
    private func consumeContinuation() -> CheckedContinuation<SerialResponse, Error>? {
        guard let c = responseContinuation else { return nil }
        responseContinuation = nil
        expectedResponseTag = nil
        return c
    }

    /// Routes a parsed response line to the pending continuation (if any).
    private func handleResponseLine(_ line: String) {
        logger.debug("RX: \(line)")

        guard let response = SerialResponse.parse(line) else {
            logger.warning("Unparseable response: \(line)")
            return
        }

        guard responseContinuation != nil else {
            logger.debug("Unsolicited response (no continuation): \(line)")
            return
        }

        // If we're filtering for a specific response tag, skip non-matching responses.
        // This handles the case where the ESP32 flushes stale responses from previous
        // sessions when the port is reopened.
        if let expected = expectedResponseTag {
            if !responseMatchesExpected(response, tag: expected) {
                logger.debug("Skipping stale response (expected '\(expected)'): \(line)")
                return
            }
        }

        guard let continuation = consumeContinuation() else { return }
        continuation.resume(returning: response)
    }

    /// Checks whether a response matches the expected tag for the pending command.
    private func responseMatchesExpected(_ response: SerialResponse, tag: String) -> Bool {
        switch response {
        case .ok(let payload):
            // For handshake, match "PING:<nonce>" using the stored nonce.
            if let nonce = handshakeNonce, tag.hasPrefix("PING:") {
                return payload == "PING:\(nonce)"
            }
            // For responses whose payload carries extra data (e.g. "ESC_DEBOUNCE:1500"),
            // match by prefix so the tag acts as a namespace.
            if payload.hasPrefix(tag + ":") || payload == tag {
                return true
            }
            return false
        case .status:
            return tag == "STATUS"
        case .error:
            // Errors always match — the caller should see them.
            return true
        }
    }

    // MARK: - Command Sending

    enum SerialError: LocalizedError, Equatable {
        case notConnected
        case writeFailed(String)
        case timeout
        case deviceError(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:       return "Not connected to ESP32"
            case .writeFailed(let m): return "Write failed: \(m)"
            case .timeout:            return "Response timeout"
            case .deviceError(let m): return "Device error: \(m)"
            }
        }
    }

    /// Maps a command to the response tag we expect back from the ESP32.
    private func expectedTag(for command: SerialCommand) -> String {
        switch command {
        case .brightnessUp:    return "UP"
        case .brightnessDown:  return "DOWN"
        case .enterPairing:    return "PAIRING"
        case .handshake:       return "PING"  // handshake uses sendHandshake() with nonce
        case .getStatus:       return "STATUS"
        case .unpair:          return "UNPAIRED"
        case .setEscDebounce:  return "ESC_DEBOUNCE"
        case .getEscDebounce:  return "ESC_DEBOUNCE"
        }
    }

    /// Generates a random 4-character hex nonce.
    private func generateNonce() -> String {
        let bytes = (0..<2).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Sends the handshake command with a random nonce: `0x04` + `<nonce>\n`.
    /// The ESP32 echoes the nonce back as `OK:PING:<nonce>\n`, allowing the
    /// app to instantly distinguish the fresh response from stale ones.
    private func sendHandshake() async throws -> SerialResponse {
        guard fileDescriptor >= 0 else { throw SerialError.notConnected }

        // Cancel any stale pending continuation.
        if let stale = consumeContinuation() {
            handshakeNonce = nil
            stale.resume(throwing: SerialError.timeout)
        }

        let nonce = generateNonce()
        handshakeNonce = nonce

        // Write: 0x04 + nonce + \n
        var payload = Data([SerialCommand.handshake.rawValue])
        payload.append(Data(nonce.utf8))
        payload.append(Data([0x0A])) // \n

        let written = payload.withUnsafeBytes { buf in
            write(fileDescriptor, buf.baseAddress!, buf.count)
        }
        guard written == payload.count else {
            let err = String(cString: strerror(errno))
            logger.error("write() failed: \(err)")
            handshakeNonce = nil
            throw SerialError.writeFailed(err)
        }

        let tag = "PING:\(nonce)"
        logger.debug("TX: handshake with nonce '\(nonce)'")

        // Wait for the matching response with a timeout.
        return try await withCheckedThrowingContinuation { continuation in
            self.expectedResponseTag = tag
            self.responseContinuation = continuation

            // Timeout task
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.responseTimeout * 1_000_000_000))
                if let pending = self?.consumeContinuation() {
                    self?.handshakeNonce = nil
                    pending.resume(throwing: SerialError.timeout)
                }
            }
        }
    }

    /// Sends a single-byte command and waits for the matching response,
    /// discarding any stale responses from previous sessions.
    private func sendCommand(_ command: SerialCommand) async throws -> SerialResponse {
        guard fileDescriptor >= 0 else { throw SerialError.notConnected }

        // Cancel any stale pending continuation.
        if let stale = consumeContinuation() {
            stale.resume(throwing: SerialError.timeout)
        }

        // Write the command byte.
        var byte = command.rawValue
        let written = write(fileDescriptor, &byte, 1)
        guard written == 1 else {
            let err = String(cString: strerror(errno))
            logger.error("write() failed: \(err)")
            throw SerialError.writeFailed(err)
        }

        let tag = expectedTag(for: command)
        logger.debug("TX: 0x\(String(format: "%02X", command.rawValue))")

        // Wait for the matching response with a timeout.
        // Non-matching (stale) responses are skipped by handleResponseLine.
        return try await withCheckedThrowingContinuation { continuation in
            self.expectedResponseTag = tag
            self.responseContinuation = continuation

            // Timeout task
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.responseTimeout * 1_000_000_000))
                if let pending = self?.consumeContinuation() {
                    pending.resume(throwing: SerialError.timeout)
                }
            }
        }
    }

    // MARK: - Disconnect / Cleanup

    private func disconnectSync() {
        handshakeNonce = nil
        readSource?.cancel()
        readSource = nil

        if fileDescriptor >= 0 {
            // Restore original termios
            tcsetattr(fileDescriptor, TCSANOW, &originalTermios)
            close(fileDescriptor)
            logger.debug("Port closed (fd=\(self.fileDescriptor))")
            fileDescriptor = -1
        }

        readBuffer.removeAll()

        // Cancel any pending continuation
        if let pending = consumeContinuation() {
            pending.resume(throwing: SerialError.notConnected)
        }
    }

    private func handlePortDisconnected() {
        logger.warning("Serial port disconnected")
        disconnect()
        if !handshakeFailed {
            scheduleReconnect()
        }
    }

    // MARK: - Auto-Reconnect

    private func scheduleReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reconnectDelay * 1_000_000_000))
            guard let self, !self.isConnected, !self.handshakeFailed else {
                self?.isReconnecting = false
                return
            }
            self.isReconnecting = false
            self.logger.info("Attempting auto-reconnect…")
            await self.connect()
        }
    }

    // MARK: - Sleep/Wake Handling

    private func setupWakeNotification() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logger.info("System woke from sleep — reconnecting serial port")
                self.disconnect()
                // Brief delay to let USB enumerate
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.connect()
            }
        }
    }

    // MARK: - USB Plug/Unplug Notifications (IOKit)

    private func setupUSBNotifications() {
        let matchingDict = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matchingDict[kIOSerialBSDTypeKey] = kIOSerialBSDModemType

        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort else {
            logger.error("Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // We need two copies of the matching dict — IOKit consumes one per call.
        guard let matchCopy = matchingDict.mutableCopy() as? NSMutableDictionary else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Device appeared
        IOServiceAddMatchingNotification(
            notificationPort,
            kIOMatchedNotification,
            matchingDict,
            { (refcon, iterator) in
                guard let refcon else { return }
                let service = Unmanaged<SerialPortService>.fromOpaque(refcon).takeUnretainedValue()
                // Drain the iterator (required by IOKit)
                var entry = IOIteratorNext(iterator)
                while entry != 0 {
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(iterator)
                }
                Task { @MainActor in
                    if !service.isConnected {
                        service.logger.info("USB serial device appeared — attempting connect")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await service.connect()
                    }
                }
            },
            selfPtr,
            &matchedIterator
        )
        // Drain initial iterator
        drainIterator(matchedIterator)

        // Device removed
        IOServiceAddMatchingNotification(
            notificationPort,
            kIOTerminatedNotification,
            matchCopy,
            { (refcon, iterator) in
                guard let refcon else { return }
                let service = Unmanaged<SerialPortService>.fromOpaque(refcon).takeUnretainedValue()
                var entry = IOIteratorNext(iterator)
                while entry != 0 {
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(iterator)
                }
                Task { @MainActor in
                    if service.isConnected {
                        service.logger.info("USB serial device removed")
                        service.disconnect()
                    }
                }
            },
            selfPtr,
            &removedIterator
        )
        drainIterator(removedIterator)
    }

    private func tearDownUSBNotifications() {
        if matchedIterator != 0 { IOObjectRelease(matchedIterator); matchedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    private func drainIterator(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }
}