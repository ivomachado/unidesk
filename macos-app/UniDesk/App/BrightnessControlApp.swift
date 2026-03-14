import SwiftUI
import AppKit

// MARK: - App Delegate

/// Performs bootstrap at app launch — before the popover is ever opened.
/// This ensures serial connection, cursor monitoring, and key interception
/// are all active immediately, and any errors are visible when the user
/// first clicks the menu bar icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let serialPort = SerialPortService()
    let screenResolver = ScreenResolver()
    let cursorMonitor: CursorMonitor
    let keyInterceptor = KeyInterceptor()
    let audioOutputMonitor = AudioOutputMonitor()
    var brightnessRouter: BrightnessRouter?

    override init() {
        self.cursorMonitor = CursorMonitor(screenResolver: screenResolver)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh screen info
        screenResolver.refresh()

        // Start cursor monitoring
        cursorMonitor.start()

        // Wire up key interception → brightness routing
        let router = BrightnessRouter(
            serialPort: serialPort,
            cursorMonitor: cursorMonitor,
            screenResolver: screenResolver
        )
        brightnessRouter = router

        keyInterceptor.onBrightnessAction = { action in
            router.handleBrightness(action)
        }
        // Forward volume key presses to the ESP32 when appropriate.
        // The swallow decision (should route to external device) is handled inside KeyInterceptor —
        // this callback only fires when the key press should be routed away from macOS.
        keyInterceptor.onVolumeAction = { [weak self] action in
            guard let self = self else { return false }
            switch action {
            case .up:   self.serialPort.fiioVolumeUp()
            case .down: self.serialPort.fiioVolumeDown()
            }
            return true
        }
        // Forward Escape key releases to the ESP32 when available.
        // SerialPortService enforces "send-if-connected, drop-otherwise".
        keyInterceptor.onEsc = {
            self.serialPort.sendESC()
        }
        keyInterceptor.start(cursorMonitor: cursorMonitor, audioOutputMonitor: audioOutputMonitor)

        // Auto-connect to ESP32 in background
        Task { @MainActor in
            await serialPort.connect()
        }
    }
}

// MARK: - App

@main
struct BrightnessControlApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                serialPort: appDelegate.serialPort,
                screenResolver: appDelegate.screenResolver,
                cursorMonitor: appDelegate.cursorMonitor,
                keyInterceptor: appDelegate.keyInterceptor,
                audioOutputMonitor: appDelegate.audioOutputMonitor
            )
        } label: {
            MenuBarIcon(serialPort: appDelegate.serialPort)
        }
        .menuBarExtraStyle(.window)
    }

}

/// A small helper View that properly subscribes to `SerialPortService` changes
/// via `@ObservedObject`, ensuring the menu bar icon updates reactively.
/// The `App.body` (a `Scene`) does not observe `ObservableObject` changes
/// from `@NSApplicationDelegateAdaptor`, so a computed property there never triggers re-evaluation.
struct MenuBarIcon: View {
    @ObservedObject var serialPort: SerialPortService

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
    }

    private var iconName: String {
        if serialPort.isConnected {
            return serialPort.bleConnected
                ? "display"
                : "display.trianglebadge.exclamationmark"
        } else {
            return "tv.slash"
        }
    }
}

// MARK: - Settings Window Controller

/// Manages a standalone NSWindow for the Settings view so it doesn't
/// disappear when the MenuBarExtra panel loses focus.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func open(serialPort: SerialPortService, screenResolver: ScreenResolver, audioOutputMonitor: AudioOutputMonitor) {
        // If the window already exists, just bring it to front.
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            serialPort: serialPort,
            screenResolver: screenResolver,
            audioOutputMonitor: audioOutputMonitor
        )

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        // Use NSHostingView directly as contentView instead of
        // NSHostingController as contentViewController.
        // NSHostingController registers a windowDidLayout observer that calls
        // updateAnimatedWindowSize(_:) on every layout cycle. When @Published
        // property changes alter the SwiftUI layout (e.g. error banner
        // appearing), the window resize triggers KVO → setNeedsUpdate →
        // _postWindowNeedsUpdateConstraints re-entrantly inside the active
        // display cycle → SIGABRT.
        // A plain NSHostingView with autoresizing mask avoids this entirely.
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.autoresizingMask = [.width, .height]
        newWindow.contentView = hostingView
        newWindow.title = "UniDesk — Settings"
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}

// MARK: - Menu Bar Content

struct MenuBarContentView: View {
    @ObservedObject var serialPort: SerialPortService
    @ObservedObject var screenResolver: ScreenResolver
    @ObservedObject var cursorMonitor: CursorMonitor
    @ObservedObject var keyInterceptor: KeyInterceptor
    @ObservedObject var audioOutputMonitor: AudioOutputMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: serialPort.isConnected ? "cable.connector" : "cable.connector.slash")
                    .foregroundStyle(serialPort.isConnected ? .green : .red)
                Text(serialPort.isConnected ? "ESP32 Connected" : "ESP32 Disconnected")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Connection details — always show all rows to keep layout stable
            VStack(alignment: .leading, spacing: 6) {
                LabeledRow(label: "Serial Port", value: serialPort.isConnected ? (serialPort.portPath ?? "—") : "—")

                LabeledRow(
                    label: "BLE Status",
                    value: serialPort.isConnected
                        ? (serialPort.bleConnected ? "Connected" : "Disconnected")
                        : "—"
                )
            }

            // Current screen target
            Divider()
            HStack {
                Image(systemName: "cursorarrow.motionlines")
                Text("Active: \(cursorMonitor.activeScreenName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Accessibility permission warning
            if keyInterceptor.permissionStatus == .denied {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility permission required")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("Brightness keys won't work until you grant access.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Open System Settings…") {
                            keyInterceptor.openAccessibilitySettings()
                        }
                        .font(.caption2)
                        .controlSize(.small)
                    }
                }
            }

            // Error display — always reserve space to prevent layout jumps
            Divider()
            HStack(alignment: .top, spacing: 6) {
                if let error = serialPort.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(" ")
                        .font(.caption)
                        .hidden()
                }
            }

            Divider()

            // Actions
            if serialPort.isConnected {
                HStack(spacing: 12) {
                    Button {
                        serialPort.brightnessDown()
                    } label: {
                        Label("Brightness Down", systemImage: "sun.min")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        serialPort.brightnessUp()
                    } label: {
                        Label("Brightness Up", systemImage: "sun.max")
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 12) {
                    Button {
                        serialPort.fiioVolumeDown()
                    } label: {
                        Label("Volume Down", systemImage: "speaker.minus")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        serialPort.fiioVolumeUp()
                    } label: {
                        Label("Volume Up", systemImage: "speaker.plus")
                    }
                    .buttonStyle(.borderless)
                }

                Button {
                    serialPort.fiioToggleOutput()
                } label: {
                    Label("Toggle Output", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)

                if !serialPort.bleConnected {
                    Button {
                        Task { try? await serialPort.enterPairingMode() }
                    } label: {
                        Label("Pair Monitor", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderless)
                }

                Button {
                    Task { await serialPort.refreshStatus() }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    Task { await serialPort.connect() }
                } label: {
                    Label("Connect", systemImage: "cable.connector")
                }
                .buttonStyle(.borderless)
            }

            Button {
                SettingsWindowController.shared.open(
                    serialPort: serialPort,
                    screenResolver: screenResolver,
                    audioOutputMonitor: audioOutputMonitor
                )
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(.borderless)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}

// MARK: - Helper Views

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
