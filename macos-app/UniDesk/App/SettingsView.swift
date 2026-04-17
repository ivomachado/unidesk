import SwiftUI
import ServiceManagement
import os.log

struct SettingsView: View {
    @ObservedObject var serialPort: SerialPortService
    @ObservedObject var screenResolver: ScreenResolver
    @ObservedObject var audioOutputMonitor: AudioOutputMonitor

    @State private var availablePorts: [String] = []
    @State private var selectedPort: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var isPairing: Bool = false
    @State private var isUnpairing: Bool = false
    @State private var actionMessage: String?
    @State private var actionIsError: Bool = false
    @State private var screens: [(id: CGDirectDisplayID, name: String, type: ScreenType)] = []
    @State private var escDebounceMs: Double = 2000
    @State private var escDebouncePending: Bool = false
    @State private var fiioDeviceName: String = ""
    @State private var audioOutputDevices: [(id: UInt32, name: String)] = []

    private let logger = Logger(subsystem: "com.viewfinity.brightnesscontrol", category: "SettingsView")

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            // Serial Port Section
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Serial Port", icon: "cable.connector")

                    HStack {
                        Picker("Port", selection: $selectedPort) {
                            Text("Auto-detect").tag("")
                            ForEach(availablePorts, id: \.self) { port in
                                Text(port.replacingOccurrences(of: "/dev/", with: ""))
                                    .tag(port)
                            }
                        }
                        .labelsHidden()

                        Button {
                            refreshPorts()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh available ports")
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(serialPort.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(serialPort.isConnected
                             ? "Connected to \(serialPort.portPath ?? "ESP32")"
                             : "Disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if serialPort.isConnected {
                            Button("Disconnect") {
                                serialPort.disconnect()
                            }
                            .font(.caption)
                            .controlSize(.small)
                        } else {
                            Button("Connect") {
                                Task {
                                    serialPort.preferredPortPath = selectedPort.isEmpty ? nil : selectedPort
                                    await serialPort.connect()
                                }
                            }
                            .font(.caption)
                            .controlSize(.small)
                        }
                    }

                    if let error = serialPort.lastError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer().frame(height: 12)

            // BLE Pairing Section
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Monitor Pairing", icon: "antenna.radiowaves.left.and.right")

                    HStack(spacing: 8) {
                        Circle()
                            .fill(serialPort.bleConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)

                        if serialPort.bleConnected {
                            Text("Monitor paired")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No monitor paired via BLE")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        if !serialPort.bleConnected {
                            Button {
                                performPairing()
                            } label: {
                                Label("Pair Monitor", systemImage: "link.badge.plus")
                            }
                            .disabled(!serialPort.isConnected || isPairing)
                        } else {
                            Button(role: .destructive) {
                                performUnpair()
                            } label: {
                                Label("Unpair", systemImage: "link.badge.minus")
                            }
                            .disabled(!serialPort.isConnected || isUnpairing)
                        }

                        if isPairing || isUnpairing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if !serialPort.isConnected {
                        Text("Connect to the ESP32 board first to manage pairing.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer().frame(height: 12)

            // Screen Assignments Section
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sectionHeader("Display Assignments", icon: "display.2")
                        Spacer()
                        Button {
                            refreshScreens()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .help("Refresh displays")
                    }

                    if screens.isEmpty {
                        Text("No displays detected.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(screens, id: \.id) { screen in
                            screenRow(screen)
                        }
                    }
                }
                .padding(4)
            }

            Spacer().frame(height: 12)

            // Launch at Login + ESC Debounce
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("General", icon: "gear")

                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            setLaunchAtLogin(newValue)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("OSD Dismiss Delay")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(escDebounceMs)) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: $escDebounceMs,
                            in: 200...10000,
                            step: 100
                        ) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("200").font(.caption2).foregroundStyle(.tertiary)
                        } maximumValueLabel: {
                            Text("10s").font(.caption2).foregroundStyle(.tertiary)
                        } onEditingChanged: { editing in
                            if !editing {
                                applyEscDebounce()
                            }
                        }
                        .disabled(!serialPort.isConnected || escDebouncePending)

                        Text("How long after the last brightness key press before the monitor OSD is dismissed.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !serialPort.isConnected {
                            Text("Connect to the ESP32 board to change this setting.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer().frame(height: 12)

            // FiiO DAC Volume Routing Section
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("FiiO DAC", icon: "speaker.wave.3")

                    HStack {
                        Text("Audio Output Device")
                            .font(.caption)
                        Spacer()
                    }

                    HStack {
                        Picker("", selection: $fiioDeviceName) {
                            Text("None (disabled)").tag("")
                            ForEach(audioOutputDevices, id: \.id) { device in
                                Text(device.name).tag(device.name)
                            }
                        }
                        .labelsHidden()

                        Button {
                            refreshAudioDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh audio output devices")
                    }
                    .onChange(of: fiioDeviceName) { newValue in
                        UserDefaults.standard.set(newValue, forKey: AudioOutputMonitor.fiioDeviceNameKey)
                        audioOutputMonitor.updateFiioActiveState()
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(audioOutputMonitor.isFiioActive ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(audioOutputMonitor.isFiioActive
                             ? "Active — volume keys route to FiiO"
                             : fiioDeviceName.isEmpty
                                ? "No device selected"
                                : "Inactive — \(audioOutputMonitor.currentDeviceName) is current output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("When the selected device is the active sound output, volume keys will control the FiiO K11 R2R via the ESP32 instead of macOS volume.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Action message banner
            if let message = actionMessage {
                Spacer().frame(height: 12)
                HStack {
                    Image(systemName: actionIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(actionIsError ? .yellow : .green)
                    Text(message)
                        .font(.caption)
                    Spacer()
                    Button {
                        actionMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(actionIsError ? Color.yellow.opacity(0.1) : Color.green.opacity(0.1))
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            refreshPorts()
            refreshScreens()
            refreshAudioDevices()
            selectedPort = serialPort.preferredPortPath ?? ""
            launchAtLogin = currentLaunchAtLoginState()
            fiioDeviceName = UserDefaults.standard.string(forKey: AudioOutputMonitor.fiioDeviceNameKey) ?? ""
            if serialPort.isConnected {
                Task { await loadEscDebounce() }
            }
        }
        .onChange(of: serialPort.isConnected) { connected in
            if connected {
                Task { await loadEscDebounce() }
            }
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .fontWeight(.medium)
    }

    // MARK: - Screen Row

    @ViewBuilder
    private func screenRow(_ screen: (id: CGDirectDisplayID, name: String, type: ScreenType)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name)
                    .font(.caption)
                Text("ID: \(screen.id)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Picker("", selection: screenTypeBinding(for: screen.id, current: screen.type)) {
                Text("Auto").tag(ScreenType?.none as ScreenType?)
                Text("Built-in").tag(ScreenType?.some(.builtIn) as ScreenType?)
                Text("Compatible").tag(ScreenType?.some(.compatible) as ScreenType?)
                Text("ViewFinity S9").tag(ScreenType?.some(.viewFinityS9) as ScreenType?)
                Text("Unsupported").tag(ScreenType?.some(.unsupported) as ScreenType?)
            }
            .labelsHidden()
            .fixedSize()

            screenTypeIcon(screen.type)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func screenTypeIcon(_ type: ScreenType) -> some View {
        switch type {
        case .builtIn:
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.blue)
        case .compatible:
            Image(systemName: "display")
                .foregroundStyle(.green)
        case .viewFinityS9:
            Image(systemName: "display")
                .foregroundStyle(.orange)
        case .unsupported:
            Image(systemName: "display.slash")
                .foregroundStyle(.gray)
        }
    }

    private func screenTypeBinding(for displayID: CGDirectDisplayID, current: ScreenType) -> Binding<ScreenType?> {
        Binding<ScreenType?>(
            get: {
                // Check if there's a user override; if so return it, else nil (Auto).
                let overrides = UserDefaults.standard.dictionary(forKey: "screenTypeOverrides") as? [String: String] ?? [:]
                if overrides[String(displayID)] != nil {
                    return current
                }
                return nil
            },
            set: { newValue in
                screenResolver.setOverride(newValue, for: displayID)
                refreshScreens()
            }
        )
    }

    // MARK: - Actions

    private func refreshPorts() {
        availablePorts = serialPort.availablePorts()
    }

    private func refreshScreens() {
        screenResolver.refresh()
        screens = screenResolver.allScreens()
    }

    private func refreshAudioDevices() {
        audioOutputDevices = audioOutputMonitor.listOutputDevices()
    }

    private func performPairing() {
        isPairing = true
        actionMessage = nil
        Task {
            do {
                try await serialPort.enterPairingMode()
                actionMessage = "Pairing mode activated — select the device on your monitor."
                actionIsError = false
            } catch {
                actionMessage = "Pairing failed: \(error.localizedDescription)"
                actionIsError = true
            }
            isPairing = false
        }
    }

    private func performUnpair() {
        isUnpairing = true
        actionMessage = nil
        Task {
            do {
                try await serialPort.unpair()
                actionMessage = "Bond cleared successfully."
                actionIsError = false
            } catch {
                actionMessage = "Unpair failed: \(error.localizedDescription)"
                actionIsError = true
            }
            isUnpairing = false
        }
    }

    // MARK: - ESC Debounce

    private func loadEscDebounce() async {
        guard let ms = await serialPort.getEscDebounce() else { return }
        escDebounceMs = Double(ms)
    }

    private func applyEscDebounce() {
        escDebouncePending = true
        let ms = UInt32(escDebounceMs)
        Task {
            do {
                let confirmed = try await serialPort.setEscDebounce(ms)
                escDebounceMs = Double(confirmed)
            } catch {
                actionMessage = "Failed to set OSD dismiss delay: \(error.localizedDescription)"
                actionIsError = true
            }
            escDebouncePending = false
        }
    }

    // MARK: - Launch at Login

    private func currentLaunchAtLoginState() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    logger.info("Launch at Login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    logger.info("Launch at Login disabled")
                }
            } catch {
                logger.error("Failed to set Launch at Login: \(error.localizedDescription)")
                actionMessage = "Failed to set Launch at Login: \(error.localizedDescription)"
                actionIsError = true
                // Revert the toggle
                launchAtLogin = !enabled
            }
        }
    }
}