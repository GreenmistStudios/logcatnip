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
    }
}

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.adbError, model.adb == nil {
            ContentUnavailableView {
                Label("adb Not Found", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else if model.devices.contains(where: \.isOnline) {
            ContentUnavailableView(
                "No Session Selected",
                systemImage: "text.alignleft",
                description: Text("Choose a device in the sidebar to start a logcat session.")
            )
        } else {
            ContentUnavailableView(
                "No Devices",
                systemImage: "iphone.slash",
                description: Text("Connect a device with USB debugging enabled, or start an emulator. You can also drop a saved log file here.")
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

            Section("Devices") {
                let groups = model.deviceGroups
                if groups.isEmpty {
                    Text("No devices")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    DeviceRow(group: group)
                }
            }

            Section("Sessions") {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            if session.serial != nil {
                                Button("Restart Logcat") { session.restart() }
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

/// One row per physical device. The leading icon is the transport sessions stream over; other online
/// transports of the same device (a phone on both USB and Wi-Fi) get a small glyph before the button.
private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let group: DeviceGroup

    var body: some View {
        let primary = group.primary
        HStack(spacing: 8) {
            Image(systemName: primary.transport.symbolName)
                .foregroundStyle(group.isOnline ? .primary : .tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName)
                    .lineLimit(1)
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(group.transports.dropFirst().filter(\.isOnline)) { other in
                Image(systemName: other.transport.symbolName)
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
