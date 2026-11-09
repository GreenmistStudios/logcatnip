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
                if model.devices.isEmpty {
                    Text("No devices")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
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

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.descriptor.isEmulator ? "desktopcomputer" : "iphone")
                .foregroundStyle(device.isOnline ? .primary : .tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if device.isOnline {
                Button {
                    model.openSession(serial: device.serial)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("New logcat session")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if device.isOnline { model.showDevice(serial: device.serial) }
        }
        .contextMenu {
            Button("New Session") { model.openSession(serial: device.serial) }
                .disabled(!device.isOnline)
            Button("Copy Serial") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.serial, forType: .string)
            }
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
