import Foundation
import LogcatKit
import Observation

/// A device known to adb, with the properties read from it once it came online.
struct Device: Identifiable, Hashable {
    var descriptor: DeviceDescriptor
    var properties: DeviceProperties?
    /// True once getprop has been tried for this transport, whether or not it succeeded. Identity is unknown
    /// until then, so a reused serial cannot be mistaken for the device that had it before.
    var propertiesLoaded = false
    /// What this device is after `AppModel` resolved conflicts between transports; nil until `propertiesLoaded`.
    var identity: DeviceIdentity?

    var id: String { descriptor.serial }
    var serial: String { descriptor.serial }
    var isOnline: Bool { descriptor.isOnline }
    var transport: DeviceTransport { DeviceTransport(descriptor: descriptor, properties: properties) }

    /// The identity this transport reports on its own, before conflicts with other transports are resolved.
    var baseIdentity: DeviceIdentity? {
        propertiesLoaded ? DeviceIdentity(descriptor: descriptor, properties: properties) : nil
    }

    var rawState: TransportState {
        TransportState(serial: serial, transport: transport, identity: baseIdentity, isOnline: isOnline)
    }

    var resolvedState: TransportState {
        TransportState(serial: serial, transport: transport, identity: identity, isOnline: isOnline)
    }

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

/// One physical device, with every adb transport it is currently reachable through (USB, Wi-Fi, ...).
struct DeviceGroup: Identifiable {
    /// Preferred transport first: online, then USB before emulator before Wi-Fi.
    let transports: [Device]
    let identity: DeviceIdentity?

    var primary: Device { transports[0] }
    var id: String { identity?.description ?? "transport:" + primary.serial }
    var displayName: String { primary.displayName }
    var isOnline: Bool { transports.contains(where: \.isOnline) }

    var subtitle: String {
        var parts: [String] = []
        if let described = transports.first(where: { $0.properties?.release != nil && $0.properties?.apiLevel != nil }),
           let release = described.properties?.release, let api = described.properties?.apiLevel {
            parts.append("Android \(release), API \(api)")
        }
        let online = transports.filter(\.isOnline)
        if online.isEmpty {
            parts.append(primary.descriptor.state.description)
        }
        if online.count > 1 {
            parts.append(online.map { $0.transport.label }.joined(separator: " + "))
        } else {
            parts.append(primary.serial)
        }
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
    let wireless = WirelessModel()

    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    /// In-flight getprop requests by serial. The token lets a request that was overtaken (the transport went
    /// away and came back) be ignored when it finally completes.
    @ObservationIgnored private var propertyRequests: [String: UUID] = [:]
    @ObservationIgnored private var autoOpenedIdentities: Set<DeviceIdentity> = []

    /// Devices grouped by identity, one entry per physical device.
    var deviceGroups: [DeviceGroup] {
        let byIdentity = Dictionary(devices.map { ($0.serial, $0) }, uniquingKeysWith: { first, _ in first })
        return DeviceMatching.groups(devices.map(\.resolvedState))
            .map { group in
                let members = group.compactMap { byIdentity[$0.serial] }
                return DeviceGroup(transports: members, identity: group[0].identity)
            }
            .filter { !$0.transports.isEmpty }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var selectedSession: LogSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    func start() {
        guard trackingTask == nil else { return }
        connectADB()
        wireless.runLaunchHooks(environment: ProcessInfo.processInfo.environment)
        if ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1" {
            startDebugReporting()
        }
    }

    /// Stops every adb child process. Called on quit, when tasks no longer get a chance to run.
    func shutdown() {
        trackingTask?.cancel()
        trackingTask = nil
        wireless.stop()
        for session in sessions {
            session.stop()
        }
    }

    /// Prints session state to stderr every few seconds, for diagnosing the app from a terminal.
    private func startDebugReporting() {
        Task { [weak self] in
            while let self {
                let devices = self.devices.map {
                    "\($0.serial)[\($0.descriptor.state.description),\($0.transport.rawValue),\($0.identity?.description ?? "?")]"
                }.joined(separator: ",")
                let header = "[logcatnip] devices=\(devices) groups=\(self.deviceGroups.count) sessions=\(self.sessions.count)\n"
                FileHandle.standardError.write(Data(header.utf8))
                FileHandle.standardError.write(Data("[logcatnip] \(self.wireless.debugSummary)\n".utf8))
                for session in self.sessions {
                    let markers = session.entries.filter { $0.kind == .marker }
                    let line = "[logcatnip]   \(session.title): status=\(session.status.label) format=\(session.streamsModernFormat ? "modern" : "legacy") paused=\(session.isPaused) "
                        + "follow=\(session.autoScroll) total=\(session.totalCount) visible=\(session.visibleCount) "
                        + "rows=\(session.rows.count) processes=\(session.processNames.count) "
                        + "filter=\"\(session.filterQuery)\" error=\(session.filterError?.message ?? "-") "
                        + "serial=\(session.serial ?? "-") identity=\(session.identity?.description ?? "-") "
                        + "markers=\(markers.count) lastMarker=\"\(markers.last?.message ?? "-")\" "
                        + "dups=\(Self.duplicateCount(in: session))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private struct EntryKey: Hashable {
        let timestamp: Double
        let pid: Int32
        let tid: Int32
        let tag: String
        let message: String
    }

    /// Visible log entries (last 20,000 rows) that repeat an earlier one: what a reattach must not produce.
    private static func duplicateCount(in session: LogSession) -> Int {
        var seenIDs = Set<Int>()
        var seen = Set<EntryKey>()
        var duplicates = 0
        for row in session.rows.suffix(20_000) {
            guard seenIDs.insert(row.entryID).inserted, let entry = session.entry(for: row), entry.kind == .log else { continue }
            let key = EntryKey(timestamp: entry.timestamp, pid: entry.pid, tid: entry.tid, tag: entry.tag, message: entry.message)
            if !seen.insert(key).inserted { duplicates += 1 }
        }
        return duplicates
    }

    /// (Re)locates adb using the current settings and restarts device tracking.
    func connectADB() {
        trackingTask?.cancel()
        let override = UserDefaults.standard.string(forKey: SettingsKey.adbPath)
        guard let adb = ADB.locate(overridePath: override) else {
            self.adb = nil
            wireless.stop()
            adbError = "adb not found. Install the Android SDK platform-tools or set the adb path in Settings."
            return
        }
        self.adb = adb
        adbError = nil
        wireless.start(adb: adb, app: self)
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
            var device = Device(descriptor: descriptor)
            if let old = previous[descriptor.serial] {
                device.properties = old.properties
                device.propertiesLoaded = old.propertiesLoaded
                // A serial can be reused by another device (emulator-5554 running a different AVD), so read
                // the properties again whenever a transport comes online instead of trusting the old ones.
                if descriptor.isOnline, !old.isOnline { device.propertiesLoaded = false }
            }
            if !descriptor.isOnline { propertyRequests[descriptor.serial] = nil }
            return device
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for serial in propertyRequests.keys where !descriptors.contains(where: { $0.serial == serial }) {
            propertyRequests[serial] = nil
        }

        resolveIdentities()
        for device in devices where device.isOnline && (!device.propertiesLoaded || device.properties == nil) {
            loadProperties(serial: device.serial)
        }
        reconcileSessions()
    }

    private func loadProperties(serial: String) {
        guard let adb, propertyRequests[serial] == nil else { return }
        let token = UUID()
        propertyRequests[serial] = token
        Task { [weak self] in
            let properties = try? await adb.properties(serial: serial)
            guard let self, self.propertyRequests[serial] == token else { return }
            self.propertyRequests[serial] = nil
            if let index = self.devices.firstIndex(where: { $0.serial == serial }) {
                if let properties {
                    self.devices[index].properties = properties
                } else if !self.devices[index].propertiesLoaded {
                    // The old properties may belong to whatever used this serial before; don't derive an
                    // identity from them.
                    self.devices[index].properties = nil
                }
                self.devices[index].propertiesLoaded = true
            }
            self.resolveIdentities()
            self.reconcileSessions()
            self.autoOpenIfNeeded(serial: serial)
        }
    }

    /// Gives every transport its identity, keeping two transports that would claim the same one apart.
    private func resolveIdentities() {
        let resolved = DeviceMatching.resolveConflicts(devices.map(\.rawState))
        for (index, state) in resolved.enumerated() where devices[index].identity != state.identity {
            devices[index].identity = state.identity
        }
    }

    /// Brings every device session in line with the transports adb reports. Called whenever the transports or
    /// their identities change, so it must be idempotent. This is where a session follows its device to a new
    /// serial: a Wi-Fi port, an emulator port, or USB versus Wi-Fi.
    private func reconcileSessions() {
        let states = devices.map(\.resolvedState)
        for session in sessions {
            guard let serial = session.serial, var identity = session.identity, session.status != .stopped else { continue }
            // A session opened before getprop answered only knows its transport serial.
            if identity.kind == .transport, identity.value == serial,
               let known = device(serial: serial)?.identity, known.isStable {
                session.adopt(identity: known)
                identity = known
            }
            guard let target = DeviceMatching.preferredTransport(for: identity, current: serial, in: states) else {
                // Still online with an unknown identity means getprop has not answered yet: wait for it.
                if device(serial: serial)?.isOnline != true { session.deviceWentOffline() }
                continue
            }
            if session.status == .disconnected || target.serial != serial {
                session.reattach(serial: target.serial, transport: target.transport)
            }
        }
        refreshTitles()
    }

    /// Opens a session for the first device that shows up, so a fresh window starts showing logs.
    private func autoOpenIfNeeded(serial: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.autoOpenSessions),
              let device = device(serial: serial), device.isOnline, let identity = device.identity,
              !autoOpenedIdentities.contains(identity),
              !sessions.contains(where: { $0.identity == identity })
        else { return }
        autoOpenedIdentities.insert(identity)
        if sessions.isEmpty {
            openSession(serial: serial)
        }
    }

    // MARK: Sessions

    @discardableResult
    func openSession(serial: String) -> LogSession? {
        guard let adb else { return nil }
        let identity = device(serial: serial)?.identity ?? DeviceIdentity(kind: .transport, value: serial)
        var chosen = serial
        if identity.isStable,
           let preferred = DeviceMatching.preferredTransport(for: identity, current: serial, in: devices.map(\.resolvedState)) {
            chosen = preferred.serial
        }
        autoOpenedIdentities.insert(identity)
        let session = LogSession(source: .device(serial: chosen, identity: identity), adb: adb, model: self)
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

    /// Selects an existing session for the device, or opens one. A session counts if it follows the same
    /// device, even when it currently streams over another transport.
    func showDevice(serial: String) {
        let identity = device(serial: serial)?.identity
        if let existing = sessions.first(where: { $0.serial == serial || (identity != nil && $0.identity == identity) }) {
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
