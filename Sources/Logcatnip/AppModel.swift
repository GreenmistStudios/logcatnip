import Foundation
import LogcatKit
import Observation

/// A device known to adb, with the properties read from it once it came online.
struct Device: Identifiable, Hashable {
    var descriptor: DeviceDescriptor
    var properties: DeviceProperties?

    var id: String { descriptor.serial }
    var serial: String { descriptor.serial }
    var isOnline: Bool { descriptor.isOnline }

    var displayName: String {
        if let avd = properties?.avdName, !avd.isEmpty {
            return avd.replacingOccurrences(of: "_", with: " ")
        }
        if let model = properties?.model {
            if let manufacturer = properties?.manufacturer, !model.lowercased().hasPrefix(manufacturer.lowercased()) {
                return "\(manufacturer.capitalized) \(model)"
            }
            return model
        }
        return descriptor.model ?? serial
    }

    var subtitle: String {
        var parts: [String] = []
        if let release = properties?.release, let api = properties?.apiLevel {
            parts.append("Android \(release), API \(api)")
        }
        if !isOnline {
            parts.append(descriptor.state.description)
        }
        parts.append(serial)
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var adb: ADB?
    private(set) var adbError: String?
    private(set) var devices: [Device] = []
    private(set) var sessions: [LogSession] = []
    var selectedSessionID: LogSession.ID?

    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    @ObservationIgnored private var propertyRequests: Set<String> = []
    @ObservationIgnored private var autoOpenedSerials: Set<String> = []

    var selectedSession: LogSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    func start() {
        guard trackingTask == nil else { return }
        connectADB()
        if ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1" {
            startDebugReporting()
        }
    }

    /// Stops every adb child process. Called on quit, when tasks no longer get a chance to run.
    func shutdown() {
        trackingTask?.cancel()
        trackingTask = nil
        for session in sessions {
            session.stop()
        }
    }

    /// Prints session state to stderr every few seconds, for diagnosing the app from a terminal.
    private func startDebugReporting() {
        Task { [weak self] in
            while let self {
                let devices = self.devices.map { "\($0.serial)[\($0.descriptor.state.description)]" }.joined(separator: ",")
                FileHandle.standardError.write(Data("[logcatnip] devices=\(devices) sessions=\(self.sessions.count)\n".utf8))
                for session in self.sessions {
                    let stats = session.processNameStats
                    let line = "[logcatnip]   \(session.title): status=\(session.status.label) paused=\(session.isPaused) "
                        + "follow=\(session.autoScroll) total=\(session.totalCount) visible=\(session.visibleCount) "
                        + "rows=\(session.rows.count) processes=\(stats.running) pending=\(stats.pending) "
                        + "unresolved=\(stats.unresolvable) "
                        + "filter=\"\(session.filterQuery)\" error=\(session.filterError?.message ?? "-")\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// (Re)locates adb using the current settings and restarts device tracking.
    func connectADB() {
        trackingTask?.cancel()
        let override = UserDefaults.standard.string(forKey: SettingsKey.adbPath)
        guard let adb = ADB.locate(overridePath: override) else {
            self.adb = nil
            adbError = "adb not found. Install the Android SDK platform-tools or set the adb path in Settings."
            return
        }
        self.adb = adb
        adbError = nil
        trackingTask = Task { [weak self] in
            for await event in adb.trackDevices() {
                guard let self else { return }
                switch event {
                case let .devices(descriptors):
                    self.adbError = nil
                    self.update(descriptors)
                case let .failed(message):
                    self.adbError = message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    func device(serial: String) -> Device? {
        devices.first { $0.serial == serial }
    }

    private func update(_ descriptors: [DeviceDescriptor]) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.serial, $0) })
        devices = descriptors.map { descriptor in
            var device = Device(descriptor: descriptor, properties: previous[descriptor.serial]?.properties)
            if !descriptor.isOnline { device.properties = previous[descriptor.serial]?.properties }
            return device
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        let online = Set(devices.filter(\.isOnline).map(\.serial))
        let wasOnline = Set(previous.values.filter(\.isOnline).map(\.serial))

        for device in devices where device.isOnline && device.properties == nil {
            loadProperties(serial: device.serial)
        }
        for serial in wasOnline.subtracting(online) {
            for session in sessions where session.serial == serial {
                session.deviceWentOffline()
            }
        }
        for serial in online.subtracting(wasOnline) {
            for session in sessions where session.serial == serial {
                session.deviceCameOnline()
            }
        }
    }

    private func loadProperties(serial: String) {
        guard let adb, !propertyRequests.contains(serial) else { return }
        propertyRequests.insert(serial)
        Task { [weak self] in
            let properties = try? await adb.properties(serial: serial)
            guard let self else { return }
            self.propertyRequests.remove(serial)
            if let index = self.devices.firstIndex(where: { $0.serial == serial }), let properties {
                self.devices[index].properties = properties
            }
            self.refreshTitles()
            self.autoOpenIfNeeded(serial: serial)
        }
    }

    /// Opens a session for the first device that shows up, so a fresh window starts showing logs.
    private func autoOpenIfNeeded(serial: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.autoOpenSessions),
              !autoOpenedSerials.contains(serial),
              !sessions.contains(where: { $0.serial == serial }),
              device(serial: serial)?.isOnline == true
        else { return }
        autoOpenedSerials.insert(serial)
        if sessions.isEmpty {
            openSession(serial: serial)
        }
    }

    // MARK: Sessions

    @discardableResult
    func openSession(serial: String) -> LogSession? {
        guard let adb else { return nil }
        autoOpenedSerials.insert(serial)
        let session = LogSession(source: .device(serial: serial), adb: adb, model: self)
        sessions.append(session)
        selectedSessionID = session.id
        refreshTitles()
        if let initialFilter = ProcessInfo.processInfo.environment["LOGCATNIP_FILTER"] {
            session.filterQuery = initialFilter
            session.applyFilterNow()
        }
        session.start()
        return session
    }

    /// Selects an existing session for the device, or opens one.
    func showDevice(serial: String) {
        if let existing = sessions.first(where: { $0.serial == serial }) {
            selectedSessionID = existing.id
        } else {
            openSession(serial: serial)
        }
    }

    func openFile(_ url: URL) {
        let session = LogSession(source: .file(url), adb: adb, model: self)
        sessions.append(session)
        selectedSessionID = session.id
        refreshTitles()
        session.loadFile()
    }

    func close(_ session: LogSession) {
        session.stop()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        refreshTitles()
    }

    private func refreshTitles() {
        for session in sessions {
            session.refreshBaseTitle()
        }
        for session in sessions {
            session.title = uniqueTitle(session.baseTitle, for: session)
        }
    }

    /// A title for a new session that is unique among open sessions.
    func uniqueTitle(_ base: String, for session: LogSession) -> String {
        let same = sessions.filter { $0.baseTitle == base }
        guard same.count > 1, let position = same.firstIndex(where: { $0.id == session.id }) else { return base }
        return position == 0 ? base : "\(base) #\(position + 1)"
    }
}
