import AppKit
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
    private(set) var simctl: Simctl?
    /// Why simulators aren't listed (no Xcode, or simctl failing). Shown in Settings, not the sidebar, because
    /// Android-only users don't need Xcode.
    private(set) var simctlError: String?
    /// Booted simulators.
    private(set) var simulators: [SimulatorDevice] = []
    private(set) var sessions: [LogSession] = []
    var selectedSessionID: LogSession.ID?

    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    /// In-flight getprop requests by serial. The token lets a request that was overtaken (the transport went
    /// away and came back) be ignored when it finally completes.
    @ObservationIgnored private var propertyRequests: [String: UUID] = [:]
    @ObservationIgnored private var simulatorTask: Task<Void, Never>?
    @ObservationIgnored private var autoOpenedIdentities: Set<DeviceIdentity> = []
    @ObservationIgnored private var autoOpenedSimulators: Set<String> = []

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
        connectSimulators()
        if ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1" {
            startDebugReporting()
        }
        if let raw = ProcessInfo.processInfo.environment["LOGCATNIP_WRAP_TOGGLE"], let period = Double(raw) {
            startDebugWrapToggle(period: period)
        }
        if let raw = ProcessInfo.processInfo.environment["LOGCATNIP_VIEW_CYCLE"], let period = Double(raw) {
            startDebugViewCycle(period: period)
        }
        // Debug helper: open log files at launch, `LOGCATNIP_OPEN=/path/a.txt:/path/b.txt`.
        if let paths = ProcessInfo.processInfo.environment["LOGCATNIP_OPEN"] {
            for path in paths.split(separator: ":") {
                openFile(URL(fileURLWithPath: String(path)))
            }
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
                let devices = self.devices.map {
                    "\($0.serial)[\($0.descriptor.state.description),\($0.transport.rawValue),\($0.identity?.description ?? "?")]"
                }.joined(separator: ",")
                let simulators = self.simulators.map(\.name).joined(separator: ",")
                let header = "[logcatnip] devices=\(devices) groups=\(self.deviceGroups.count) simulators=\(simulators) "
                    + "sessions=\(self.sessions.count)\n"
                FileHandle.standardError.write(Data(header.utf8))
                for session in self.sessions {
                    let stats = session.processNameStats
                    let markers = session.entries.filter { $0.kind == .marker }
                    let line = "[logcatnip]   \(session.title): status=\(session.status.label) paused=\(session.isPaused) "
                        + "follow=\(session.autoScroll) total=\(session.totalCount) visible=\(session.visibleCount) "
                        + "rows=\(session.rows.count) processes=\(stats.running) pending=\(stats.pending) "
                        + "unresolved=\(stats.unresolvable) "
                        + "filter=\"\(session.filterQuery)\" error=\(session.filterError?.message ?? "-") "
                        + "serial=\(session.serial ?? "-") identity=\(session.identity?.description ?? "-") "
                        + "markers=\(markers.count) lastMarker=\"\(markers.last?.message ?? "-")\" "
                        + "dups=\(Self.duplicateCount(in: session))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    FileHandle.standardError.write(Data("[logcatnip]     options: \(session.viewOptions.summary)\n".utf8))
                    if session.find.isVisible {
                        FileHandle.standardError.write(Data("[logcatnip]     \(session.find.debugSummary())\n".utf8))
                    }
                    if let table = session.tableDebug {
                        FileHandle.standardError.write(Data("[logcatnip]     table: \(table.debugSummary())\n".utf8))
                        FileHandle.standardError.write(Data("[logcatnip]     \(table.debugViewSummary())\n".utf8))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Debug helper: `LOGCATNIP_WRAP_TOGGLE=<seconds>` waits for the selected session to have rows, selects a
    /// row (`LOGCATNIP_WRAP_SELECT`: `middle`, the default, `end`, `none` or a row number), then toggles soft wrap four times,
    /// `<seconds>` apart, printing the table's state after each. `LOGCATNIP_SCROLL_BENCH=<pages>` adds a scroll
    /// timing for each mode, and `LOGCATNIP_WRAP_RESIZE=<points>` ends with a window resize,
    /// `LOGCATNIP_WINDOW_WIDTH=<points>` sets the window's width first, `LOGCATNIP_FIND_JUMP=1` jumps to the
    /// first find match,
    /// and `LOGCATNIP_WRAP_KEYS=1` sends the arrow keys, and sideways scroll gestures, to the table in each
    /// mode (`arrow-keys` and `message-scroll` lines that end in `pinned=ok` while the other columns stay
    /// put). It bypasses `setSoftWrap`, so it never changes the saved default.
    private func startDebugWrapToggle(period: Double) {
        let environment = ProcessInfo.processInfo.environment
        let pages = environment["LOGCATNIP_SCROLL_BENCH"].flatMap(Int.init)
        Task { [weak self] in
            func say(_ text: String) {
                FileHandle.standardError.write(Data("[logcatnip] \(text)\n".utf8))
            }
            @MainActor func sayKeys(_ table: any LogTableDebugging) {
                say(table.debugPressArrowKeys())
                say(table.debugMessageScroll())
            }
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if let session = self.selectedSession, !session.rows.isEmpty, session.status != .loading, session.status != .starting {
                    break
                }
            }
            // `LOGCATNIP_WINDOW_WIDTH=<points>` sets the window's width first (the Message column needs room
            // beside the other columns to be pinned), and the helper puts it back when it is done.
            let window = NSApp.windows.first(where: \.isVisible)
            let originalWidth = window?.frame.width
            if let width = environment["LOGCATNIP_WINDOW_WIDTH"].flatMap(Double.init), let window {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
            try? await Task.sleep(for: .seconds(2))
            guard let self, let session = self.selectedSession, let table = session.tableDebug else { return }
            // `LOGCATNIP_FIND_JUMP=1` goes to the first find match, as Find Next does, and prints where the
            // message text ended up (with `LOGCATNIP_FIND` for the query).
            if environment["LOGCATNIP_FIND_JUMP"] == "1" {
                session.find.navigate(.next)
                try? await Task.sleep(for: .seconds(1))
                say("find-jump: \(session.find.debugSummary())")
                say("find-jump: \(table.debugSummary()) \(table.debugPinned())")
            }
            if let pages { say(table.debugScrollBenchmark(pages: pages)) }
            let pressKeys = environment["LOGCATNIP_WRAP_KEYS"] == "1"
            if pressKeys { sayKeys(table) }
            let last = session.rows.count - 1
            let select = environment["LOGCATNIP_WRAP_SELECT"] ?? "middle"
            switch select {
            case "none": break
            case "end": table.debugSelect(row: last, at: 1, following: true)
            default: table.debugSelect(row: Int(select) ?? last / 2, at: 0.8, following: false)
            }
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(period))
                session.softWrap.toggle()
                try? await Task.sleep(for: .seconds(1))
                say("wrap-toggle: \(table.debugSummary())")
                if pressKeys { sayKeys(table) }
                if let pages { say(table.debugScrollBenchmark(pages: pages)) }
            }
            // `LOGCATNIP_WRAP_RESIZE=<points>` then narrows the window by that much and widens it again, which
            // re-wraps the rows the way a drag of the window edge does.
            if let delta = environment["LOGCATNIP_WRAP_RESIZE"].flatMap(Double.init),
               let window = NSApp.windows.first(where: \.isVisible)
            {
                for change in [-delta, delta] {
                    var frame = window.frame
                    frame.size.width += change
                    window.setFrame(frame, display: true)
                    try? await Task.sleep(for: .seconds(1))
                    say("wrap-resize: \(table.debugSummary())")
                    if pressKeys { sayKeys(table) }
                }
            }
            if let window, let originalWidth, window.frame.width != originalWidth {
                var frame = window.frame
                frame.size.width = originalWidth
                window.setFrame(frame, display: true)
            }
        }
    }

    /// Debug helper: `LOGCATNIP_VIEW_CYCLE=<seconds>` waits for the selected session to have rows, then steps
    /// through the view options, `<seconds>` apart, each step building on the last: Standard, Compact,
    /// Standard with the time only, epoch, since start, delta, date and time in UTC, PID only, the Process
    /// column, hide repeated, no tag colors, and Standard again (which must print `preset=standard`). After
    /// each step it prints the table's `view:` line and what Copy would paste for the last three entries.
    /// It sets the session's options directly, so it never changes the saved default.
    private func startDebugViewCycle(period: Double) {
        Task { [weak self] in
            func say(_ text: String) {
                FileHandle.standardError.write(Data("[logcatnip] \(text)\n".utf8))
            }
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if let session = self.selectedSession, !session.rows.isEmpty, session.status != .loading, session.status != .starting {
                    break
                }
            }
            try? await Task.sleep(for: .seconds(2))
            guard let self, let session = self.selectedSession, let table = session.tableDebug else { return }
            var options = session.viewOptions
            let steps: [(String, (inout LogViewOptions) -> Void)] = [
                ("standard", { $0 = .standard }),
                ("compact", { $0 = .compact }),
                ("standard+time", { $0 = .standard; $0.timestampStyle = .time }),
                ("epoch", { $0.timestampStyle = .epoch }),
                ("sinceStart", { $0.timestampStyle = .sinceStart }),
                ("delta", { $0.timestampStyle = .delta }),
                ("dateTime+utc", { $0.timestampStyle = .dateTime; $0.timeZone = .utc }),
                ("pid", { $0.pidStyle = .pid }),
                ("process", { $0.setVisible(.process, true) }),
                ("hideRepeated", { $0.hideRepeatedTags = true; $0.hideRepeatedPackages = true; $0.hideRepeatedProcesses = true }),
                ("noTagColors", { $0.colorTags = false }),
                ("standard again", { $0 = .standard }),
            ]
            for (index, step) in steps.enumerated() {
                step.1(&options)
                session.viewOptions = options
                try? await Task.sleep(for: .seconds(period))
                say("view-cycle \(index + 1) \(step.0): \(table.debugViewSummary())")
                say("copy: \(table.debugCopyText(entries: 3))")
            }
        }
    }

    /// Debug helper: `LOGCATNIP_VIEW=standard|compact|<json>` sets the view options of new sessions, next
    /// to `LOGCATNIP_FILTER`. It does not touch the saved default.
    private func applyDebugView(to session: LogSession) {
        guard let raw = ProcessInfo.processInfo.environment["LOGCATNIP_VIEW"] else { return }
        switch raw.lowercased() {
        case "standard": session.viewOptions = .standard
        case "compact": session.viewOptions = .compact
        default: if let options = LogViewOptions(json: raw) { session.viewOptions = options }
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
                    self.updateDevices(descriptors)
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
                session.simulatorBooted()
            }
        }
        refreshTitles()
        for udid in after.subtracting(before) {
            autoOpenIfNeeded(simulator: udid)
        }
    }

    func device(serial: String) -> Device? {
        devices.first { $0.serial == serial }
    }

    func updateDevices(_ descriptors: [DeviceDescriptor]) {
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

    /// Opens a session for the first device that shows up, so a fresh window starts showing logs. Each device
    /// is opened automatically once, so closing its session doesn't bring it back.
    private func autoOpenIfNeeded(serial: String) {
        guard autoOpenEnabled,
              let device = device(serial: serial), device.isOnline, let identity = device.identity,
              !autoOpenedIdentities.contains(identity),
              !sessions.contains(where: { $0.identity == identity })
        else { return }
        autoOpenedIdentities.insert(identity)
        if sessions.isEmpty {
            openSession(serial: serial)
        }
    }

    /// The simulator counterpart of `autoOpenIfNeeded(serial:)`. A UDID is stable, so it is the identity.
    private func autoOpenIfNeeded(simulator udid: String) {
        guard autoOpenEnabled,
              !autoOpenedSimulators.contains(udid),
              !sessions.contains(where: { $0.udid == udid })
        else { return }
        autoOpenedSimulators.insert(udid)
        if sessions.isEmpty {
            openSession(simulator: udid)
        }
    }

    private var autoOpenEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.autoOpenSessions)
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
        return openStreamingSession(LogSession(source: .device(serial: chosen, identity: identity), adb: adb, model: self))
    }

    @discardableResult
    func openSession(simulator udid: String) -> LogSession? {
        guard let simctl else { return nil }
        autoOpenedSimulators.insert(udid)
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
        applyDebugView(to: session)
        applyDebugFind(to: session)
        session.start()
        return session
    }

    /// Debug helper: `LOGCATNIP_FIND='text'` opens the find bar with that query in new sessions.
    private func applyDebugFind(to session: LogSession) {
        guard let query = ProcessInfo.processInfo.environment["LOGCATNIP_FIND"] else { return }
        session.find.query = query
        session.find.isVisible = true
        session.find.applyNow()
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
        if let initialFilter = ProcessInfo.processInfo.environment["LOGCATNIP_FILTER"] {
            session.filterQuery = initialFilter
            session.applyFilterNow()
        }
        applyDebugView(to: session)
        applyDebugFind(to: session)
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
