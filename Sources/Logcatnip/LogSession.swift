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
        case device(serial: String)
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
    let source: Source
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
    @ObservationIgnored private var useLegacyFormat = false
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
        if case let .device(serial) = source { serial } else { nil }
    }

    var isLive: Bool { status == .streaming || status == .starting }

    func refreshBaseTitle() {
        switch source {
        case let .device(serial):
            baseTitle = model?.device(serial: serial)?.displayName ?? serial
        case let .file(url):
            baseTitle = url.lastPathComponent
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
        guard case let .device(serial) = source, let adb else { return }
        streamTask?.cancel()
        status = .starting
        let api = model?.device(serial: serial)?.properties?.apiLevel
        let modern = !useLegacyFormat && (api ?? 99) >= 24
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
                case let .ended(status, error):
                    self.logcatEnded(status: status, error: error, receivedAny: receivedAny, modernFormat: modern)
                }
            }
        }
    }

    func stop() {
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
        start()
    }

    func deviceWentOffline() {
        guard serial != nil, status != .disconnected, status != .stopped else { return }
        streamToken = nil
        streamTask?.cancel()
        status = .disconnected
        appendMarker("Device disconnected")
    }

    func deviceCameOnline() {
        guard status == .disconnected else { return }
        appendMarker("Device reconnected")
        resumeAfter = lastTimestamp
        start()
    }

    private func logcatEnded(status exitStatus: Int32, error: String, receivedAny: Bool, modernFormat: Bool) {
        streamToken = nil
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !receivedAny, modernFormat, exitStatus != 0, !useLegacyFormat {
            // Pre-Nougat logcat rejects -v epoch / -v uid.
            useLegacyFormat = true
            start()
            return
        }
        let online = serial.flatMap { model?.device(serial: $0)?.isOnline } ?? false
        if online, restartAttempts < 3 {
            restartAttempts += 1
            appendMarker("logcat exited\(message.isEmpty ? "" : ": \(message)"); restarting")
            resumeAfter = lastTimestamp
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.streamToken == nil, self.status != .stopped else { return }
                self.start()
            }
            return
        }
        if online {
            status = .failed(message.isEmpty ? "logcat exited (\(exitStatus))" : message)
        } else {
            status = .disconnected
            appendMarker("Device disconnected")
        }
    }

    func loadFile() {
        guard case let .file(url) = source else { return }
        status = .loading
        Task { [weak self] in
            let result: Result<[LogEntry], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let data = try Data(contentsOf: url)
                    return .success(LogFileImporter.parse(String(decoding: data, as: UTF8.self)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case let .success(entries):
                self.ingest(entries)
                self.status = .loaded
            case let .failure(error):
                self.status = .failed(error.localizedDescription)
            }
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
            noteForCompletion(entry)
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
        resetCompletionStats()
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

    /// Kept so the table's context menu keeps building its terms the same way.
    static func quoted(_ value: String) -> String { FilterQueryEditor.quoted(value) }

    /// Adds a term such as `tag=:Foo` or `-tag=:Foo` to the whole query and applies it immediately.
    func addTerm(_ term: String) {
        filterQuery = FilterQueryEditor.adding(term, to: filterQuery)
        applyFilterNow()
        FilterLibrary.remember(filterQuery)
    }

    /// What the level picker shows, from the applied filter rather than the query text. While the field holds an
    /// invalid query this is the level of the filter that is actually applied.
    var levelSelection: LevelSelection { filter.levelSelection }

    /// Replaces the query's top-level level terms, or removes them for `nil`.
    func setMinimumLevel(_ level: LogLevel?) {
        filterQuery = FilterQueryEditor.settingMinimumLevel(level, in: filterQuery)
        applyFilterNow()
    }

    // MARK: Completion

    /// How active a pid has been and its latest entry, so a pid's process name can be looked up when the user
    /// asks for suggestions instead of being kept for every entry.
    private struct PidActivity {
        var count: Int
        var lastID: Int
    }

    /// Entries seen per tag and per pid. They describe the session, so they survive buffer trimming and reset
    /// with Clear and Restart.
    @ObservationIgnored private var tagCounts: [String: Int] = [:]
    @ObservationIgnored private var pidActivity: [Int32: PidActivity] = [:]

    /// One dictionary update per tag and pid per entry; nothing here touches the table path.
    private func noteForCompletion(_ entry: LogEntry) {
        guard entry.kind == .log else { return }
        if !entry.tag.isEmpty { tagCounts[entry.tag, default: 0] += 1 }
        if entry.pid > 0 {
            var activity = pidActivity[entry.pid] ?? PidActivity(count: 0, lastID: entry.id)
            activity.count += 1
            activity.lastID = entry.id
            pidActivity[entry.pid] = activity
        }
    }

    private func resetCompletionStats() {
        tagCounts.removeAll()
        pidActivity.removeAll()
    }

    /// The entry with this sequence number, if it is still in the buffer.
    private func entry(withID id: Int) -> LogEntry? {
        let index = id - firstID
        guard index >= 0, index < entries.count else { return nil }
        return entries[index]
    }

    /// Process names from the latest `ps`. The only place completion reads `processNames`.
    private var runningProcessNames: [String] { Array(Set(processNames.values)) }

    /// Distinct tags seen, for the debug output.
    var distinctTagCount: Int { tagCounts.count }

    func completionSource() -> FilterCompletionSource {
        var processCounts: [String: Int] = [:]
        var pids: [FilterPidInfo] = []
        pids.reserveCapacity(pidActivity.count)
        for (pid, activity) in pidActivity {
            let name = entry(withID: activity.lastID).flatMap(processName(for:))
            if let name { processCounts[name, default: 0] += activity.count }
            pids.append(FilterPidInfo(pid: pid, count: activity.count, processName: name))
        }
        return FilterCompletionSource(
            tagCounts: tagCounts,
            processCounts: processCounts,
            runningProcesses: runningProcessNames,
            pids: pids,
            myPackages: Defaults.myPackages.sorted(),
            history: UserDefaults.standard.bool(forKey: SettingsKey.filterHistoryAutocomplete)
                ? FilterLibrary.favorites + FilterLibrary.history : []
        )
    }

    func completionSuggestions(query: String, cursor: Int) -> [FilterSuggestion] {
        FilterCompletion.suggestions(query: query, cursor: cursor, source: completionSource())
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

    /// The buffer in `logcat -v long` format, which Logcatnip and Android Studio can both read back.
    func exportText(visibleOnly: Bool) -> String {
        var output = ""
        if visibleOnly {
            var last = -1
            for row in rows where row.entryID != last {
                last = row.entryID
                if let entry = entry(for: row), entry.kind == .log {
                    output += LogcatLongFormat.format(entry)
                }
            }
        } else {
            for entry in entries where entry.kind == .log {
                output += LogcatLongFormat.format(entry)
            }
        }
        return output
    }
}
