import LogcatKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let session = model.selectedSession {
                SessionView(session: session)
                    .id(session.id)
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle(model.selectedSession?.title ?? "Logcatnip")
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL {
                model.openFile(url)
            }
            return !urls.isEmpty
        }
        .sheet(isPresented: Binding(
            get: { model.wireless.isSheetPresented },
            set: { if !$0 { model.wireless.sheetDismissed() } }
        )) {
            WirelessConnectView()
                .environment(model)
        }
        .alert("Couldn't Disconnect", isPresented: Binding(
            get: { model.wireless.alertMessage != nil },
            set: { if !$0 { model.wireless.alertMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.wireless.alertMessage ?? "")
        }
    }
}

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.adbError, model.adb == nil, model.simulators.isEmpty {
            ContentUnavailableView {
                Label("adb Not Found", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else if model.devices.contains(where: \.isOnline) || !model.simulators.isEmpty {
            ContentUnavailableView(
                "No Session Selected",
                systemImage: "text.alignleft",
                description: Text("Choose a device or simulator in the sidebar to start a session.")
            )
        } else {
            ContentUnavailableView(
                "No Devices",
                systemImage: "iphone.slash",
                description: Text("Connect a device with USB debugging enabled, or start an emulator or iOS simulator. You can also drop a saved log file here.")
            )
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSessionID) {
            if let error = model.adbError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .lineLimit(4)
                }
            }

            Section {
                let groups = model.deviceGroups
                if groups.isEmpty && model.simulators.isEmpty {
                    Text("No devices")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    DeviceRow(group: group)
                }
                ForEach(model.simulators) { simulator in
                    SimulatorRow(simulator: simulator)
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    Menu {
                        Button("Connect over Wi-Fi…") { model.wireless.presentSheet(tab: .qrCode) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a device")
                    .disabled(model.adb == nil)
                }
            }

            let discovered = model.wireless.discovered
            if !discovered.isEmpty {
                Section("Discovered") {
                    ForEach(discovered) { service in
                        DiscoveredRow(service: service)
                    }
                }
            }

            Section("Sessions") {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            if session.isStreamSource {
                                Button(session.udid != nil ? "Restart Log Stream" : "Restart Logcat") { session.restart() }
                            }
                            Button("Close Session") { model.close(session) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private extension DeviceTransport {
    /// SF Symbols stay in the app: LogcatKit has no UI dependencies.
    var symbolName: String {
        switch self {
        case .usb: "cable.connector"
        case .wifi: "wifi"
        case .emulator: "desktopcomputer"
        }
    }
}

/// One row per physical device. The leading icon tells a phone from an emulator; each online USB or Wi-Fi
/// transport (a phone can be on both) gets a small glyph before the button.
private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let group: DeviceGroup

    var body: some View {
        let primary = group.primary
        HStack(spacing: 8) {
            DeviceIcon(platform: .android, isVirtual: primary.transport == .emulator)
                .foregroundStyle(group.isOnline ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName)
                    .lineLimit(1)
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(group.transports.filter { $0.isOnline && $0.transport != .emulator }) { connection in
                Image(systemName: connection.transport.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if group.isOnline {
                Button {
                    model.openSession(serial: primary.serial)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("New logcat session")
            }
        }
        .contentShape(Rectangle())
        .help(tooltip)
        .onTapGesture(count: 2) {
            if group.isOnline { model.showDevice(serial: primary.serial) }
        }
        .contextMenu {
            Button("New Session") { model.openSession(serial: primary.serial) }
                .disabled(!group.isOnline)
            if group.transports.count == 1 {
                Button("Copy Serial") { copy(primary.serial) }
            } else {
                Menu("Copy Serial") {
                    ForEach(group.transports) { device in
                        Button("\(device.transport.label): \(device.serial)") { copy(device.serial) }
                    }
                }
            }
            // Offered in any state, so a stale offline connection can be dropped too.
            let disconnectable = group.transports.filter { $0.descriptor.isDisconnectable }
            if !disconnectable.isEmpty {
                Divider()
                if disconnectable.count == 1 {
                    Button("Disconnect") { model.wireless.disconnect(serial: disconnectable[0].serial) }
                } else {
                    Menu("Disconnect") {
                        ForEach(disconnectable) { device in
                            Button(device.serial) { model.wireless.disconnect(serial: device.serial) }
                        }
                    }
                }
            }
        }
    }

    private var tooltip: String {
        group.transports.map { device in
            let state = device.isOnline ? "" : " (\(device.descriptor.state.description))"
            return "\(device.transport.label): \(device.serial)\(state)"
        }.joined(separator: "\n")
    }

    private func copy(_ serial: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
    }
}

/// A device that advertises wireless debugging but isn't connected: one click connects it.
private struct DiscoveredRow: View {
    @Environment(AppModel.self) private var model
    let service: MdnsService

    var body: some View {
        let wireless = model.wireless
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.displayName)
                        .lineLimit(1)
                    Text(service.address ?? service.mdnsName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if wireless.connecting.contains(service.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Connect") { wireless.connect(service) }
                        .buttonStyle(.borderless)
                }
            }
            if let message = wireless.connectErrors[service.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(message)
            }
        }
        .help(service.mdnsName)
    }
}

/// A booted simulator. Shares the Devices section with Android devices; the icon's badge marks the platform.
struct SimulatorRow: View {
    @Environment(AppModel.self) private var model
    let simulator: SimulatorDevice

    var body: some View {
        HStack(spacing: 8) {
            DeviceIcon(platform: .apple, isVirtual: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(simulator.name)
                    .lineLimit(1)
                Text("\(simulator.runtimeName) · Simulator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                model.openSession(simulator: simulator.udid)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("New log session")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.showSimulator(udid: simulator.udid)
        }
        .contextMenu {
            Button("New Session") { model.openSession(simulator: simulator.udid) }
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(simulator.udid, forType: .string)
            }
        }
    }
}

/// The sidebar glyph for a device. Hardware gets a phone of its platform; emulators and simulators get a
/// computer with a platform badge, so the two kinds of device read apart at a glance.
struct DeviceIcon: View {
    enum Platform {
        case android
        case apple
    }

    let platform: Platform
    let isVirtual: Bool

    var body: some View {
        Group {
            if isVirtual {
                Image(systemName: "desktopcomputer")
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: badgeSymbol)
                            .font(.system(size: 8, weight: .semibold))
                            .padding(1.5)
                            .background(.background, in: RoundedRectangle(cornerRadius: 2.5))
                            .offset(x: 4, y: 3)
                    }
            } else {
                Image(systemName: phoneSymbol)
            }
        }
        .frame(width: 18)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Android has no system symbol of its own, so a plain phone stands in for it, next to the notched iPhone.
    private var phoneSymbol: String {
        switch platform {
        case .android: "smartphone"
        case .apple: "iphone"
        }
    }

    private var badgeSymbol: String {
        switch platform {
        case .android: "smartphone"
        case .apple: "apple.logo"
        }
    }

    private var accessibilityLabel: String {
        switch (platform, isVirtual) {
        case (.android, false): "Android device"
        case (.android, true): "Android emulator"
        case (.apple, false): "iPhone"
        case (.apple, true): "Simulator"
        }
    }
}

private struct SessionRow: View {
    let session: LogSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts = [session.isPaused ? "Paused" : session.status.label]
        if !session.filterQuery.isEmpty { parts.append(session.filterQuery) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if session.isPaused { return .yellow }
        switch session.status {
        case .streaming: return .green
        case .starting, .loading: return .yellow
        case .disconnected, .failed: return .red
        case .stopped: return .gray
        case .loaded: return .blue
        }
    }
}
