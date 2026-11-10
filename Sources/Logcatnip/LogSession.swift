import AppKit
import Foundation
import LogcatKit
import Observation

/// One log view: a live logcat stream from a device, or an imported file. Owns the entry buffer, the
/// filter, and the filtered rows the table shows.
@MainActor
@Observable
final class LogSession: Identifiable {
    enum Source: Equatable {
        /// `serial` is the adb transport now in use; it changes when the device reconnects on a new port or
        /// switches between USB and Wi-Fi. `identity` stays with the session.
        case device(serial: String, identity: DeviceIdentity)
        case file(URL)
    }

    enum Status: Equatable {
        case starting
        case streaming
        case disconnected
        case stopped
        case loading
        case loaded
        case failed(String)

        var label: String {
            switch self {
            case .starting: "Connecting…"
            case .streaming: "Live"
            case .disconnected: "Disconnected"
            case .stopped: "Stopped"
            case .loading: "Loading…"
            case .loaded: "File"
            case let .failed(message): "Error: \(message)"
            }
        }
    }

    /// One table row: a line of an entry's message. Multi-line messages (stack traces) take several rows,
    /// which keeps row heights fixed and scrolling fast.
    struct Row: Equatable {
        let entryID: Int
        let line: Int32
    }

    enum RowsChange {
        case appended(Range<Int>)
        /// Rows were replaced. `removedFront` rows were dropped from the top (buffer trimming), so a
        /// scrolled-back view can keep its place.
        case reloaded(removedFront: Int)
        /// Rows are unchanged but cell contents may differ (process names resolved).
        case refreshVisible
    }

    let id = UUID()
    private(set) var source: Source
    /// Which buffer of a file this session shows; bug reports open one session per buffer.
    var fileSection: LogFileSection = .main
    private(set) var fileInfo: LogFileInfo?
    /// Observed, so the status bar follows a load's progress.
    private(set) var fileLoader: FileLoader?
    /// The latest save, observed for the status bar.
    private(set) var fileSaver: FileSaver?
    private(set) var baseTitle = ""
    var title = ""
    private(set) var status: Status = .starting
    var isPaused = false {
        didSet { if oldValue && !isPaused { flushRows() } }
    }
    var autoScroll = true
    var filterQuery = "" {
        didSet { if filterQuery != oldValue { scheduleFilterUpdate() } }
    }
    var caseSensitive = false {
        didSet { if caseSensitive != oldValue { applyFilterNow() } }
    }
    private(set) var filter = LogFilter.everything
    private(set) var filterError: FilterError?
    private(set) var totalCount = 0
    private(set) var visibleCount = 0
    /// Incremented to ask the filter field to take focus.
    var focusFilterRequest = 0

    @ObservationIgnored private(set) var entries: [LogEntry] = []
    @ObservationIgnored private(set) var rows: [Row] = []
    @ObservationIgnored private(set) var processNames: [Int32: String] = [:]
    /// The device a `.logcat` was saved with, or the live device once it was described, so saving again after the
    /// device is gone still names it.
    @ObservationIgnored private(set) var fileDevice: LogcatFileDevice?
    @ObservationIgnored var onRowsChanged: ((RowsChange) -> Void)?

    @ObservationIgnored private let adb: ADB?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var firstID = 0
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastFilteredID = -1
    @ObservationIgnored private var filterGeneration = 0
    @ObservationIgnored private var refilterInFlight = false
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var filterDebounce: Task<Void, Never>?
    @ObservationIgnored private var ageRefresh: Task<Void, Never>?

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamToken: UUID?
    @ObservationIgnored private var lastTimestamp: Double?
    @ObservationIgnored private var resumeAfter: Double?
    /// Set when logcat itself reported that it has no `-v epoch` / `-v uid`; a transient failure never sets it.
    @ObservationIgnored private var legacyFormatDetected = false
    /// Whether the current stream passes `-v epoch -v uid`; read by the debug report.
    @ObservationIgnored private(set) var streamsModernFormat = true
    @ObservationIgnored private var restartAttempts = 0

    @ObservationIgnored private var processRefreshInFlight = false
    @ObservationIgnored private var processRefreshQueued = false
    @ObservationIgnored private var lastProcessRefresh = Date.distantPast
    @ObservationIgnored private var unresolvablePids: Set<Int32> = []

    init(source: Source, adb: ADB?, model: AppModel) {
        self.source = source
        self.adb = adb
        self.model = model
    }

    var serial: String? {
        if case let .device(serial, _) = source { serial } else { nil }
    }

    var identity: DeviceIdentity? {
        if case let .device(_, identity) = source { identity } else { nil }
    }

    var isLive: Bool { status == .streaming || status == .starting }

    func refreshBaseTitle() {
        switch source {
        case let .device(serial, _):
            // A device that went away keeps its name while the session waits for it to come back.
            if let device = model?.device(serial: serial) {
                baseTitle = device.displayName
            } else if baseTitle.isEmpty {
                baseTitle = serial
            }
        case let .file(url):
            baseTitle = fileSection.title.map { "\(url.lastPathComponent) · \($0)" } ?? url.lastPathComponent
        }
    }

    // MARK: Lookup

    func entry(for row: Row) -> LogEntry? {
        let index = row.entryID - firstID
        guard index >= 0, index < entries.count else { return nil }
        return entries[index]
    }

    func processName(for entry: LogEntry) -> String? {
        entry.processName ?? processNames[entry.pid]
    }

    // MARK: Streaming

    func start() {
        guard case let .device(serial, _) = source, let adb else { return }
        streamTask?.cancel()
        status = .starting
        let api = model?.device(serial: serial)?.properties?.apiLevel
        let modern = !legacyFormatDetected && ADB.LogcatOptions.modernFormatSupported(apiLevel: api)
        streamsModernFormat = modern
        let options = ADB.LogcatOptions(buffers: Defaults.logcatBuffers, since: resumeAfter, modernFormat: modern)
        let token = UUID()
        streamToken = token
        requestProcessNames()

        streamTask = Task { [weak self] in
            var receivedAny = false
            self?.status = .streaming
            for await event in adb.logcat(serial: serial, options: options) {
                guard let self, self.streamToken == token else { return }
                switch event {
                case let .entries(batch):
                    if !receivedAny {
                        receivedAny = true
                        self.restartAttempts = 0
                    }
                    self.ingest(batch)
                case let .ended(exit):
                    self.logcatEnded(exit)
                }
            }
        }
    }

    func stop() {
        // Closing the Events or Radio session of a bug report shouldn't abandon the system log still loading.
        if fileSection == .main { fileLoader?.cancel() }
        streamToken = nil
        streamTask?.cancel()
        streamTask = nil
        ageRefresh?.cancel()
        if isLive { status = .stopped }
    }

    /// Clears the view and starts logcat again from the start of the device buffer.
    func restart() {
        stop()
        clear()
        resumeAfter = nil
        lastTimestamp = nil
        legacyFormatDetected = false
        restartAttempts = 0
        start()
    }

    func deviceWentOffline() {
        guard serial != nil, status != .disconnected, status != .stopped else { return }
        streamToken = nil
        streamTask?.cancel()
        status = .disconnected
        appendMarker("Device disconnected")
    }

    /// Replaces the identity once it is known, for a session opened before getprop answered.
    func adopt(identity: DeviceIdentity) {
        guard case let .device(serial, _) = source else { return }
        source = .device(serial: serial, identity: identity)
    }

    /// Streams from `newSerial` from now on: the device came back, maybe on a new port or transport, or a
    /// better transport of the same device appeared. Resumes after the last entry, so nothing repeats or
    /// goes missing beyond what the device's buffer has already dropped.
    func reattach(serial newSerial: String, transport: DeviceTransport) {
        guard case let .device(_, identity) = source, status != .stopped else { return }
        let reconnected = status == .disconnected
        streamToken = nil
        streamTask?.cancel()
        streamTask = nil
        source = .device(serial: newSerial, identity: identity)
        let via = transport == .emulator ? newSerial : transport.label
        appendMarker(reconnected ? "Device reconnected (\(via))" : "Switched to \(via)")
        resumeAfter = lastTimestamp
        restartAttempts = 0
        start()
    }

    private func logcatEnded(_ exit: LogcatExit) {
        streamToken = nil
        let online = serial.flatMap { model?.device(serial: $0)?.isOnline } ?? false
        switch exit.recovery(restartAttempts: restartAttempts, deviceOnline: online) {
        case .useLegacyFormat:
            legacyFormatDetected = true
            appendMarker("logcat doesn't support -v epoch or -v uid; using the legacy format")
            start()
        case .restart:
            restartAttempts += 1
            appendMarker("logcat exited\(exit.detail.map { ": \($0)" } ?? " (\(exit.status))"); restarting")
            resumeAfter = lastTimestamp
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.streamToken == nil, self.isLive else { return }
                self.start()
            }
        case .waitForDevice:
            status = .disconnected
            appendMarker("Device disconnected")
        case let .fail(message):
            status = .failed(message)
            appendMarker("logcat failed: \(message)")
        }
    }

    // MARK: File loading

    func beginLoading(_ loader: FileLoader) {
        fileLoader = loader
        status = .loading
    }

    func ingestLoaded(_ batch: [LogEntry]) {
        ingest(batch)
    }

    func setFileInfo(_ info: LogFileInfo) {
        fileInfo = info
    }

    func adoptProcessNames(_ names: [Int32: String]) {
        applyProcessNames(names)
    }

    /// A `.logcat` file carries the filter it was saved with, and Android Studio applies it on open; so do we.
    func applyFileMetadata(_ metadata: LogcatFileMetadata) {
        fileDevice = metadata.device
        if let device = metadata.device { fileInfo = LogFileInfo(device: device) }
        let query = metadata.filter(forMyPackages: Defaults.myPackages).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        filterQuery = query
        applyFilterNow()
    }

    func finishLoading(delivered: Int, state: FileLoader.State, fraction: Double?) {
        switch state {
        case .running:
            return
        case .finished:
            status = .loaded
        case .cancelled:
            appendMarker("Stopped loading at \(Int((fraction ?? 0) * 100))%")
            status = .stopped
        case let .failed(message):
            status = .failed(message)
        }
        let kept = entries.lazy.filter { $0.kind == .log }.count
        if delivered > kept {
            appendMarker("Showing the newest \(kept.formatted()) of \(delivered.formatted()) entries. "
                + "Raise Settings › Logcat › Keep up to for more.")
        }
    }

    // MARK: Ingestion

    private func ingest(_ batch: [LogEntry]) {
        var sawUnknownPid = false
        entries.reserveCapacity(entries.count + batch.count)
        for var entry in batch {
            if let resumeAfter {
                if entry.timestamp < resumeAfter { continue }
                if entry.timestamp == resumeAfter, alreadyHave(entry) { continue }
                if entry.timestamp > resumeAfter { self.resumeAfter = nil }
            }
            entry.id = nextID
            nextID += 1
            if entry.processName == nil, entry.pid > 0 {
                if let name = processNames[entry.pid] {
                    entry.processName = name
                } else if !unresolvablePids.contains(entry.pid) {
                    sawUnknownPid = true
                }
            }
            lastTimestamp = entry.timestamp
            entries.append(entry)
        }
        trimIfNeeded()
        if sawUnknownPid { requestProcessNames() }
        scheduleFlush()
    }

    private func alreadyHave(_ entry: LogEntry) -> Bool {
        entries.suffix(128).contains {
            $0.timestamp == entry.timestamp && $0.pid == entry.pid && $0.tid == entry.tid
                && $0.tag == entry.tag && $0.message == entry.message
        }
    }

    private func appendMarker(_ text: String) {
        var marker = LogEntry.marker(text, at: lastTimestamp ?? Date().timeIntervalSince1970)
        marker.id = nextID
        nextID += 1
        entries.append(marker)
        scheduleFlush()
    }

    private func trimIfNeeded() {
        let limit = Defaults.maxEntriesValue
        guard entries.count > limit else { return }
        let drop = entries.count - limit * 9 / 10
        entries.removeFirst(drop)
        firstID += drop
        let removedRows = firstRowIndex(atOrAfter: firstID)
        guard removedRows > 0 else { return }
        var removedEntries = 0
        var lastID = -1
        for row in rows[..<removedRows] where row.entryID != lastID {
            lastID = row.entryID
            removedEntries += 1
        }
        visibleCount = max(0, visibleCount - removedEntries)
        rows.removeFirst(removedRows)
        onRowsChanged?(.reloaded(removedFront: removedRows))
    }

    /// Binary search over `rows`, which are sorted by entry id.
    private func firstRowIndex(atOrAfter entryID: Int) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].entryID < entryID { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.flushScheduled = false
            self.flushRows()
        }
    }

    /// Filters entries that arrived since the last flush and appends their rows.
    private func flushRows() {
        totalCount = entries.count
        guard !isPaused, !refilterInFlight else { return }
        let startID = max(lastFilteredID + 1, firstID)
        let startIndex = startID - firstID
        guard startIndex < entries.count else { return }
        let context = filterContext()
        var newRows: [Row] = []
        var matched = 0
        for entry in entries[startIndex...] where filter.matches(entry, context: context) {
            matched += 1
            Self.appendRows(for: entry, to: &newRows)
        }
        lastFilteredID = nextID - 1
        guard !newRows.isEmpty else { return }
        let start = rows.count
        rows.append(contentsOf: newRows)
        visibleCount += matched
        onRowsChanged?(.appended(start..<rows.count))
    }

    nonisolated private static func appendRows(for entry: LogEntry, to rows: inout [Row]) {
        var lines: Int32 = 1
        for byte in entry.message.utf8 where byte == 0x0A {
            lines += 1
        }
        for line in 0..<lines {
            rows.append(Row(entryID: entry.id, line: line))
        }
    }

    // MARK: Filtering

    private func filterContext() -> FilterContext {
        FilterContext(processNames: processNames, myPackages: Defaults.myPackages, now: Date().timeIntervalSince1970)
    }

    private func scheduleFilterUpdate() {
        filterDebounce?.cancel()
        filterDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.applyFilterNow()
        }
    }

    /// Parses the query and refilters. An invalid query keeps the previous filter and reports the error.
    func applyFilterNow() {
        filterDebounce?.cancel()
        do {
            filter = try LogFilter(filterQuery, caseSensitive: caseSensitive)
            filterError = nil
        } catch {
            filterError = error
            return
        }
        refilter()
        scheduleAgeRefresh()
    }

    /// Recomputes all rows off the main thread.
    func refilter() {
        filterGeneration += 1
        let generation = filterGeneration
        let snapshot = entries
        let filter = filter
        let context = filterContext()
        let lastID = nextID - 1
        refilterInFlight = true

        Task { [weak self] in
            let (rows, visible) = await Task.detached(priority: .userInitiated) {
                var rows: [Row] = []
                var visible = 0
                for entry in snapshot where filter.matches(entry, context: context) {
                    visible += 1
                    LogSession.appendRows(for: entry, to: &rows)
                }
                return (rows, visible)
            }.value
            guard let self, generation == self.filterGeneration else { return }
            self.refilterInFlight = false
            // Entries may have been trimmed while filtering.
            let firstValid = rows.firstIndex { $0.entryID >= self.firstID } ?? rows.count
            self.rows = firstValid == 0 ? rows : Array(rows[firstValid...])
            self.visibleCount = firstValid == 0 ? visible : Set(self.rows.map(\.entryID)).count
            self.lastFilteredID = lastID
            self.onRowsChanged?(.reloaded(removedFront: 0))
            self.flushRows()
        }
    }

    /// `age:` results change as time passes, so refilter periodically while such a filter is active.
    private func scheduleAgeRefresh() {
        ageRefresh?.cancel()
        guard filter.dependsOnTime else { return }
        ageRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.filter.dependsOnTime, !self.isPaused else { continue }
                self.refilter()
            }
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        firstID = nextID
        lastFilteredID = nextID - 1
        filterGeneration += 1
        refilterInFlight = false
        totalCount = 0
        visibleCount = 0
        onRowsChanged?(.reloaded(removedFront: 0))
    }

    /// Clears the device's log buffer as well as the view.
    func clearDeviceBuffer() {
        guard let serial, let adb else {
            clear()
            return
        }
        clear()
        Task {
            try? await adb.clearLogcat(serial: serial, buffers: Defaults.logcatBuffers)
        }
    }

    // MARK: Process names

    private func requestProcessNames() {
        guard let serial, let adb else { return }
        if processRefreshInFlight {
            processRefreshQueued = true
            return
        }
        let wait = 1.5 - Date().timeIntervalSince(lastProcessRefresh)
        if wait > 0 {
            guard !processRefreshQueued else { return }
            processRefreshQueued = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                self.processRefreshQueued = false
                self.requestProcessNames()
            }
            return
        }
        processRefreshInFlight = true
        lastProcessRefresh = Date()
        Task { [weak self] in
            let names = try? await adb.processes(serial: serial)
            guard let self else { return }
            self.processRefreshInFlight = false
            if let names { self.applyProcessNames(names) }
            if self.processRefreshQueued {
                self.processRefreshQueued = false
                self.requestProcessNames()
            }
        }
    }

    private func applyProcessNames(_ names: [Int32: String]) {
        processNames.merge(names) { _, new in new }
        // Fill in recent entries that arrived before their process was known; give up on pids that have
        // already exited so they don't trigger refreshes forever.
        var stillUnknown: Set<Int32> = []
        var index = entries.count - 1
        let stop = max(0, entries.count - 50_000)
        while index >= stop {
            if entries[index].processName == nil, entries[index].pid > 0 {
                if let name = names[entries[index].pid] {
                    entries[index].processName = name
                } else {
                    stillUnknown.insert(entries[index].pid)
                }
            }
            index -= 1
        }
        unresolvablePids.formUnion(stillUnknown)
        if filter.dependsOnProcessNames {
            refilter()
        } else {
            onRowsChanged?(.refreshVisible)
        }
    }

    // MARK: Query editing

    static func quoted(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0.isWhitespace || "\"'()&|\\".contains($0) }
        guard needsQuotes else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Appends a term such as `tag=:Foo` to the query and applies it immediately.
    func addTerm(_ term: String) {
        let base = filterQuery.trimmingCharacters(in: .whitespaces)
        filterQuery = base.isEmpty ? term : "\(base) \(term)"
        applyFilterNow()
        FilterLibrary.remember(filterQuery)
    }

    private static let levelTermPattern = try! NSRegularExpression(pattern: #"(^|\s)level:(\S+)"#, options: [.caseInsensitive])

    /// The level of a `level:` term in the query, if there is exactly one.
    var minimumLevel: LogLevel? {
        let range = NSRange(filterQuery.startIndex..., in: filterQuery)
        let matches = Self.levelTermPattern.matches(in: filterQuery, range: range)
        guard matches.count == 1, let valueRange = Range(matches[0].range(at: 2), in: filterQuery) else { return nil }
        return LogLevel(name: String(filterQuery[valueRange]))
    }

    /// Replaces any `level:` terms in the query.
    func setMinimumLevel(_ level: LogLevel?) {
        let range = NSRange(filterQuery.startIndex..., in: filterQuery)
        var query = Self.levelTermPattern.stringByReplacingMatches(in: filterQuery, range: range, withTemplate: "$1")
            .trimmingCharacters(in: .whitespaces)
        query = query.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        if let level {
            query = query.isEmpty ? "level:\(level.name)" : "\(query) level:\(level.name)"
        }
        filterQuery = query
        applyFilterNow()
    }

    // MARK: Text output

    func formattedLine(for entry: LogEntry) -> String {
        if entry.kind == .marker {
            return "--------- \(entry.message)"
        }
        let time = LogcatTime.format(entry.timestamp)
        let process = processName(for: entry) ?? "?"
        return "\(time) \(entry.pid)-\(entry.tid) \(entry.tag) \(process) \(entry.level.letter)  \(entry.message)"
    }

    /// Text for the given rows, one line per entry (a multi-line message is copied once, in full).
    func text(forRows rowIndexes: IndexSet) -> String {
        var seen = Set<Int>()
        var lines: [String] = []
        for index in rowIndexes where index < rows.count {
            let row = rows[index]
            guard seen.insert(row.entryID).inserted, let entry = entry(for: row) else { continue }
            lines.append(formattedLine(for: entry))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Saving

    var isSaving: Bool { fileSaver?.state == .running }

    /// Saves what the table shows (`visibleOnly`) or the whole buffer, in the background. Taking the snapshot is
    /// cheap: the buffer is copy-on-write, and only the row ids are copied.
    func save(to url: URL, format: LogSaveFormat, visibleOnly: Bool) {
        guard !isSaving else { return }
        let request = LogSaveRequest(
            format: format, entries: entries, onlyEntryIDs: visibleOnly ? rows.map(\.entryID) : nil,
            processNames: processNames, metadata: saveMetadata()
        )
        let saver = FileSaver(url: url, format: format, visibleOnly: visibleOnly)
        fileSaver = saver
        saver.start(request)
    }

    /// What a `.logcat` records besides the messages, as Android Studio's Save does: the device, the filter as typed,
    /// and My packages (its "project application ids").
    func saveMetadata() -> LogcatFileMetadata {
        // Follow-up for the ignore lists: pass them as ignoredTags and ignoredPackages once they exist here.
        LogcatFileMetadata(device: saveDevice(), filter: filterQuery, projectApplicationIds: Defaults.myPackages.sorted())
    }

    private func saveDevice() -> LogcatFileDevice? {
        guard case let .device(serial, _) = source else {
            return fileDevice ?? fileInfo.flatMap(LogcatFileDevice.init(info:))
        }
        guard let device = model?.device(serial: serial), let properties = device.properties else { return fileDevice }
        let avdPath = properties.avdName.flatMap {
            AvdLocator.path(
                forAvdName: $0, environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser
            )
        }
        let described = LogcatFileDevice(properties: properties, serial: serial, isOnline: device.isOnline, avdPath: avdPath)
        fileDevice = described
        return described
    }
}
