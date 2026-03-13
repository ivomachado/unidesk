import CoreAudio
import Foundation
import os.log

/// Monitors the default audio output device via CoreAudio and publishes
/// its name. Used to decide whether volume keys should be routed to the
/// FiiO K11 R2R (via ESP32) or left for macOS to handle natively.
///
/// Thread safety:
/// - CoreAudio property listener callbacks fire on arbitrary threads.
/// - `@Published` state is updated on `@MainActor`.
/// - `isFiioActive` is protected by `os_unfair_lock` so the CGEventTap
///   callback (which runs on the main run loop but outside Swift concurrency)
///   can read it synchronously without actor-hopping.
@MainActor
final class AudioOutputMonitor: ObservableObject {

    // MARK: - Published State

    /// Human-readable name of the current default output device (e.g. "MacBook Pro Speakers").
    @Published private(set) var currentDeviceName: String = ""

    /// Published mirror so SwiftUI views can observe changes.
    /// The event tap callback should use the lock-based `isFiioActiveSync` instead.
    @Published private(set) var isFiioActive: Bool = false

    // MARK: - Thread-Safe Flag

    /// Lock-protected flag that the CGEventTap callback can read synchronously.
    /// Updated whenever `currentDeviceName` or the user's FiiO device setting changes.
    private let lock = NSLock()
    private var isFiioActiveLocked: Bool = false

    /// Whether the current default output device matches the user's chosen FiiO device.
    /// Safe to call from any thread (lock-protected). Use this from the event tap callback.
    var isFiioActiveSync: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFiioActiveLocked
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "AudioOutputMonitor")

    /// The UserDefaults key for the user-chosen FiiO audio device name.
    static let fiioDeviceNameKey = "fiioAudioDeviceName"

    // MARK: - Init

    init() {
        refreshCurrentDevice()
        registerDefaultOutputListener()
    }

    // No deinit cleanup needed — this is a singleton-like object that lives for
    // the process lifetime. The CoreAudio listener is cleaned up on process exit.
    // AudioObjectRemovePropertyListenerBlock requires the exact same block pointer,
    // which is impractical with Swift closures.

    // MARK: - Public API

    /// Returns all audio output devices with their IDs and names.
    func listOutputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []
        for id in deviceIDs {
            // Only include devices that have output streams.
            guard hasOutputStreams(deviceID: id) else { continue }
            if let name = deviceName(for: id) {
                result.append((id: id, name: name))
            }
        }
        return result
    }

    /// Call this when the user changes the FiiO device name setting
    /// to re-evaluate `isFiioActive`.
    func updateFiioActiveState() {
        let fiioName = UserDefaults.standard.string(forKey: Self.fiioDeviceNameKey) ?? ""
        let active = !fiioName.isEmpty && currentDeviceName == fiioName
        logger.debug("FiiO active check: saved='\(fiioName)' current='\(self.currentDeviceName)' match=\(active)")
        lock.lock()
        isFiioActiveLocked = active
        lock.unlock()
        isFiioActive = active
    }

    // MARK: - CoreAudio Listener

    private func registerDefaultOutputListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil  // fires on an internal CA dispatch queue
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentDevice()
            }
        }

        if status == noErr {
            logger.info("Registered CoreAudio default output device listener")
        } else {
            logger.error("Failed to register CoreAudio listener: \(status)")
        }
    }

    // MARK: - Refresh

    private func refreshCurrentDevice() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            logger.error("Failed to get default output device: \(status)")
            currentDeviceName = ""
            updateFiioActiveState()
            return
        }

        let name = deviceName(for: deviceID) ?? ""
        if name != currentDeviceName {
            currentDeviceName = name
            logger.info("Default output device changed to: \(name)")
        }
        updateFiioActiveState()
    }

    // MARK: - Helpers

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &name
        )

        guard status == noErr else { return nil }
        return name as String
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }
}
