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
    private(set) var simctl: Simctl?
    /// Why simulators aren't listed (no Xcode, or simctl failing). Shown in Settings, not the sidebar, because
    /// Android-only users don't need Xcode.
    private(set) var simctlError: String?
    /// Booted simulators.
    private(set) var simulators: [SimulatorDevice] = []
    private(set) var sessions: [LogSession] = []
    var selectedSessionID: LogSession.ID?

    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    @ObservationIgnored private var simulatorTask: Task<Void, Never>?
    @ObservationIgnored private var propertyRequests: Set<String> = []
    /// adb serials and simulator UDIDs.
    @ObservationIgnored private var autoOpenedSerials: Set<String> = []

    var selectedSession: LogSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    func start() {
        guard trackingTask == nil else { return }
        connectADB()
        connectSimulators()
        if ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1" {
            startDebugReporting()
        }
    }

    /// Stops every adb child process. Called on quit, when tasks no longer get a chance to run.
    func shutdown() {
        trackingTask?.cancel()
        trackingTask = nil
        simulatorTask?.cancel()
        simulatorTask = nil
        for session in sessions {
            session.stop()
        }
    }

    /// Prints session state to stderr every few seconds, for diagnosing the app from a terminal.
    private func startDebugReporting() {
        Task { [weak self] in
            while let self {
                let devices = self.devices.map { "\($0.serial)[\($0.descriptor.state.description)]" }.joined(separator: ",")
                let simulators = self.simulators.map(\.name).joined(separator: ",")
                FileHandle.standardError.write(Data(
                    "[logcatnip] devices=\(devices) simulators=\(simulators) sessions=\(self.sessions.count)\n".utf8
                ))
                for session in self.sessions {
                    let line = "[logcatnip]   \(session.title): status=\(session.status.label) paused=\(session.isPaused) "
                        + "follow=\(session.autoScroll) total=\(session.totalCount) visible=\(session.visibleCount) "
                        + "rows=\(session.rows.count) processes=\(session.processNames.count) "
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

    /// Locates simctl and follows booted simulators, or stops when the setting is off.
    func connectSimulators() {
        simulatorTask?.cancel()
        simulatorTask = nil
        guard UserDefaults.standard.bool(forKey: SettingsKey.showSimulators) else {
            simctl = nil
            simctlError = nil
            updateSimulators([])
            return
        }
        simulatorTask = Task { [weak self] in
            let located = await Simctl.locate()
            guard let self, !Task.isCancelled else { return }
            switch located {
            case let .unavailable(message):
                self.simctl = nil
                self.simctlError = message
                self.updateSimulators([])
            case let .found(simctl):
                self.simctl = simctl
                self.simctlError = nil
                for await event in simctl.trackBootedDevices() {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .devices(booted):
                        self.simctlError = nil
                        self.updateSimulators(booted)
                    case let .failed(message):
                        self.simctlError = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
    }

    func simulator(udid: String) -> SimulatorDevice? {
        simulators.first { $0.udid == udid }
    }

    func updateSimulators(_ booted: [SimulatorDevice]) {
        let before = Set(simulators.map(\.udid))
        simulators = booted
        let after = Set(booted.map(\.udid))
        for udid in before.subtracting(after) {
            for session in sessions where session.udid == udid {
                session.deviceWentOffline()
            }
        }
        for udid in after.subtracting(before) {
            for session in sessions where session.udid == udid {
                session.deviceCameOnline()
            }
        }
        refreshTitles()
        for udid in after.subtracting(before) {
            autoOpenIfNeeded(id: udid) { $0.openSession(simulator: udid) }
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
        guard device(serial: serial)?.isOnline == true else { return }
        autoOpenIfNeeded(id: serial) { $0.openSession(serial: serial) }
    }

    /// Opens a session with `open` when nothing is open yet and the device or simulator `id` was never
    /// opened automatically, so closing its session doesn't bring it back.
    private func autoOpenIfNeeded(id: String, open: (AppModel) -> Void) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.autoOpenSessions),
              !autoOpenedSerials.contains(id),
              !sessions.contains(where: { $0.serial == id || $0.udid == id })
        else { return }
        autoOpenedSerials.insert(id)
        if sessions.isEmpty {
            open(self)
        }
    }

    // MARK: Sessions

    @discardableResult
    func openSession(serial: String) -> LogSession? {
        guard let adb else { return nil }
        autoOpenedSerials.insert(serial)
        return openStreamingSession(LogSession(source: .device(serial: serial), adb: adb, model: self))
    }

    @discardableResult
    func openSession(simulator udid: String) -> LogSession? {
        guard let simctl else { return nil }
        autoOpenedSerials.insert(udid)
        return openStreamingSession(LogSession(source: .simulator(udid: udid), simctl: simctl, model: self))
    }

    private func openStreamingSession(_ session: LogSession) -> LogSession {
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

    /// Selects an existing session for the simulator, or opens one.
    func showSimulator(udid: String) {
        if let existing = sessions.first(where: { $0.udid == udid }) {
            selectedSessionID = existing.id
        } else {
            openSession(simulator: udid)
        }
    }

    func openFile(_ url: URL) {
        let session = LogSession(source: .file(url), model: self)
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
