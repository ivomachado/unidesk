import AppKit
import IOKit
import os.log

/// Resolves which `ScreenType` a given `NSScreen` corresponds to by inspecting
/// the IORegistry for EDID-based model names, checking for built-in displays,
/// and honouring user-provided overrides stored in `UserDefaults`.
@MainActor
final class ScreenResolver: ObservableObject {

    // MARK: - Published State

    /// A human-readable mapping of display ID → resolved screen type, for UI display.
    @Published private(set) var screenMap: [CGDirectDisplayID: ScreenType] = [:]

    // MARK: - Private

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "ScreenResolver")

    /// Substrings that, when found inside the EDID model name, identify a ViewFinity S9.
    /// Samsung EDID names are often truncated (e.g. "LS32C…", "S32CM…", "S27C9…").
    private static let viewFinityPatterns: [String] = [
        "ViewFinity",
        "S32CM",
        "S27CM",
        "S32C9",
        "S27C9",
        "LS32C",
        "LS27C",
        "S9"
    ]

    /// UserDefaults key for the user-override dictionary: [String(displayID): String(rawScreenType)]
    private static let overridesKey = "screenTypeOverrides"

    /// Cache: displayID → EDID model name (survives for the process lifetime; displays rarely change).
    private var edidNameCache: [CGDirectDisplayID: String] = [:]

    // MARK: - Public API

    /// Returns the `ScreenType` for the given screen.
    func screenType(for screen: NSScreen) -> ScreenType {
        guard let displayID = screen.displayID else {
            return .unsupported
        }
        return screenType(for: displayID)
    }

    /// Returns the `ScreenType` for a display identified by its `CGDirectDisplayID`.
    func screenType(for displayID: CGDirectDisplayID) -> ScreenType {
        // 1. Check user overrides first.
        if let override = userOverride(for: displayID) {
            return override
        }

        // 2. Built-in display.
        if CGDisplayIsBuiltin(displayID) != 0 {
            return .builtIn
        }

        // 3. EDID-based classification.
        var name = edidModelName(for: displayID)

        // Fallback: on macOS Tahoe, IODisplayConnect may not be available.
        // Use NSScreen.localizedName instead.
        if name.isEmpty {
            if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
                name = screen.localizedName
                logger.debug("EDID lookup empty, using NSScreen.localizedName: \(name)")
            }
        }

        if isViewFinityS9(name: name) {
            return .viewFinityS9
        }

        // 4. Check if the display supports native brightness (Apple / LG UltraFine).
        if supportsNativeBrightness(displayID: displayID) {
            return .compatible
        }

        return .unsupported
    }

    /// Refreshes the published `screenMap` from the current set of attached screens.
    func refresh() {
        var map: [CGDirectDisplayID: ScreenType] = [:]
        for screen in NSScreen.screens {
            if let displayID = screen.displayID {
                map[displayID] = screenType(for: displayID)
            }
        }
        screenMap = map
        logger.info("Screen map refreshed: \(map.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
    }

    /// Returns a list of `(displayID, name, screenType)` tuples for all currently attached screens.
    func allScreens() -> [(id: CGDirectDisplayID, name: String, type: ScreenType)] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            let name = screen.localizedName
            let type = screenType(for: displayID)
            return (id: displayID, name: name, type: type)
        }
    }

    // MARK: - User Overrides

    /// Sets a user override for a specific display. Pass `nil` to remove the override.
    func setOverride(_ type: ScreenType?, for displayID: CGDirectDisplayID) {
        var overrides = loadOverrides()
        let key = String(displayID)

        if let type {
            overrides[key] = encode(type)
        } else {
            overrides.removeValue(forKey: key)
        }

        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        refresh()
    }

    private func userOverride(for displayID: CGDirectDisplayID) -> ScreenType? {
        let overrides = loadOverrides()
        guard let raw = overrides[String(displayID)] else { return nil }
        return decode(raw)
    }

    private func loadOverrides() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
    }

    private func encode(_ type: ScreenType) -> String {
        switch type {
        case .builtIn:      return "builtIn"
        case .compatible:   return "compatible"
        case .viewFinityS9: return "viewFinityS9"
        case .unsupported:  return "unsupported"
        }
    }

    private func decode(_ raw: String) -> ScreenType? {
        switch raw {
        case "builtIn":      return .builtIn
        case "compatible":   return .compatible
        case "viewFinityS9": return .viewFinityS9
        case "unsupported":  return .unsupported
        default:             return nil
        }
    }

    // MARK: - EDID Name Lookup

    /// Retrieves the EDID-based model name for a display from the IORegistry.
    private func edidModelName(for displayID: CGDirectDisplayID) -> String {
        if let cached = edidNameCache[displayID] {
            return cached
        }

        let name = readEDIDName(for: displayID)
        edidNameCache[displayID] = name
        if !name.isEmpty {
            logger.debug("EDID name for display \(displayID): \(name)")
        }
        return name
    }

    /// Reads the display product name from the IORegistry EDID info dictionary.
    private func readEDIDName(for displayID: CGDirectDisplayID) -> String {
        // Get the IOService port for this display.
        var serialNumber: UInt32 = 0
        var vendorID: UInt32 = 0
        var productID: UInt32 = 0

        vendorID = CGDisplayVendorNumber(displayID)
        productID = CGDisplayModelNumber(displayID)
        serialNumber = CGDisplaySerialNumber(displayID)

        // Build a matching dictionary for IODisplayConnect services.
        let matching = IOServiceMatching("IODisplayConnect") as NSMutableDictionary

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let infoDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            // Match by vendor + product + serial to find the right display.
            let dVendor = infoDict[kDisplayVendorID] as? UInt32 ?? 0
            let dProduct = infoDict[kDisplayProductID] as? UInt32 ?? 0
            let dSerial = infoDict[kDisplaySerialNumber] as? UInt32 ?? 0

            guard dVendor == vendorID, dProduct == productID, dSerial == serialNumber else {
                continue
            }

            // Extract the localised product name.
            if let nameDict = infoDict[kDisplayProductName] as? [String: String],
               let name = nameDict.values.first {
                return name
            }
        }

        return ""
    }

    /// Checks whether the EDID model name matches known ViewFinity S9 patterns.
    private func isViewFinityS9(name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let upper = name.uppercased()
        return Self.viewFinityPatterns.contains { pattern in
            upper.contains(pattern.uppercased())
        }
    }

    // MARK: - Native Brightness Detection

    /// Returns `true` if the display supports native brightness control via IOKit
    /// (typically Apple displays and LG UltraFine).
    private func supportsNativeBrightness(displayID: CGDirectDisplayID) -> Bool {
        // Attempt to read the current brightness via IOKit's DisplayServices.
        // If the call succeeds, the display supports native brightness.
        var brightness: Float = 0

        let service = IOServicePortFromCGDisplayID(displayID)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        return result == kIOReturnSuccess
    }

    /// Resolves the IOKit service for a given CGDirectDisplayID.
    private func IOServicePortFromCGDisplayID(_ displayID: CGDirectDisplayID) -> io_service_t {
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
            guard let infoDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] else {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
                continue
            }

            let dVendor = infoDict[kDisplayVendorID] as? UInt32 ?? 0
            let dProduct = infoDict[kDisplayProductID] as? UInt32 ?? 0
            let dSerial = infoDict[kDisplaySerialNumber] as? UInt32 ?? 0

            if dVendor == vendorID, dProduct == productID, dSerial == serialNumber {
                // Found the matching service — return it without releasing.
                IOObjectRelease(iterator)
                return service
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return 0
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// Extracts the `CGDirectDisplayID` from the screen's device description.
    var displayID: CGDirectDisplayID? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return id
    }
}