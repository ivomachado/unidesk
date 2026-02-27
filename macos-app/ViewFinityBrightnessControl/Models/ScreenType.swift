import AppKit

/// Describes how the app should handle brightness for a given display.
enum ScreenType: Equatable, CustomStringConvertible {
    /// The built-in MacBook display.
    case builtIn
    /// An external display that supports native brightness control (e.g. Apple, LG UltraFine).
    case compatible
    /// A Samsung ViewFinity S9 — brightness routed through the ESP32 serial bridge.
    case viewFinityS9
    /// An unknown external display with no known brightness control path.
    case unsupported

    var description: String {
        switch self {
        case .builtIn:      return "Built-in Display"
        case .compatible:   return "Compatible Display"
        case .viewFinityS9: return "ViewFinity S9"
        case .unsupported:  return "Unsupported Display"
        }
    }

    /// Whether this screen type supports any form of brightness adjustment through the app.
    var supportsBrightness: Bool {
        switch self {
        case .builtIn, .compatible, .viewFinityS9: return true
        case .unsupported: return false
        }
    }

    /// Whether brightness for this screen type is routed through the ESP32 serial bridge.
    var usesSerialBridge: Bool {
        self == .viewFinityS9
    }
}