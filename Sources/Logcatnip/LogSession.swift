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
    @ObservationIgnored private var processRefreshForced = false
    @ObservationIgnored private var lastProcessRefresh = Date.distantPast
    @ObservationIgnored private var processResolver = ProcessNameResolver()
    /// How many `ps` lookups this session ran. For debug output.
    @ObservationIgnored private(set) var processLookupCount = 0

    @ObservationIgnored private var packageTracker = PackageUIDTracker()
    @ObservationIgnored private var packageRefreshInFlight = false
    @ObservationIgnored private var packageRefreshQueued = false
    @ObservationIgnored private var lastPackageRefresh = Date.distantPast
    /// How many `pm list packages` reads this session ran. For debug output.
    @ObservationIgnored private(set) var packageLookupCount = 0

    @ObservationIgnored private var markerTracker = ProcessMarkerTracker()
    /// How many process markers this session inserted. For debug output.
    @ObservationIgnored private(set) var processMarkerCount = 0
    private static let debugMarkers = ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1"

    /// How long a new pid waits for ActivityManager's `Start proc` line before `ps` is asked about it, so
    /// processes announced in the stream never cost a `ps`.
    private static let processStartGrace = 0.3

    @ObservationIgnored private var jdwpTask: Task<Void, Never>?
    @ObservationIgnored private var jdwpPids = JDWPProcessSet()
    /// How many debuggable processes `adb track-jdwp` listed last; nil when it is not running. For debug output.
    @ObservationIgnored private(set) var jdwpPidCount: Int?

    /// How long a jdwp report waits: an end for ActivityManager's line, which says why and arrives through
    /// logcat, and a start for the app to rename itself before `ps` looks.
    private static let jdwpGrace = 1.0
    /// `track-jdwp` runs that delivered no list before it is given up on until the next `start()`.
    private static let jdwpMaxIdleRuns = 3

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

    /// Names are stamped on entries at ingestion or when a `ps` snapshot resolves them. There is no
    /// pid-map fallback: a reused pid would rename the unresolved entries of the process that died.
    func processName(for entry: LogEntry) -> String? {
        entry.processName
    }

    /// How many pids the resolver knows, is waiting on, or gave up on. For debug output.
    var processNameStats: ProcessNameResolver.Stats { processResolver.stats }

    /// The package for an entry: its process name's, else the packages that own its uid.
    func resolvedPackage(for entry: LogEntry) -> ResolvedPackage? {
        packageTracker.map.resolvedPackage(for: entry)
    }

    /// The owners of the entry's uid, without building a `ResolvedPackage`, for the table's per-row path.
    func packageOwner(for entry: LogEntry) -> PackageUIDMap.Owner? {
        packageTracker.map.owner(forUID: entry.uid)
    }

    /// How many app ids have a known owner. For debug output.
    var packageOwnerCount: Int { packageTracker.map.count }

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
        startJDWPTracking(token: token)
        requestProcessNames(force: true)
        packageTracker.reset()
        requestPackages(force: true)

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
        stopJDWPTracking()
        ageRefresh?.cancel()
        if isLive { status = .stopped }
    }

    /// Clears the view and starts logcat again from the start of the device buffer.
    func restart() {
        stop()
        clear()
        resumeAfter = nil
        lastTimestamp = nil
        // The buffer is replayed from the start, so the tracker must not remember the previous replay.
        markerTracker = ProcessMarkerTracker()
        processMarkerCount = 0
        start()
    }

    func deviceWentOffline() {
        guard serial != nil, status != .disconnected, status != .stopped else { return }
        streamToken = nil
        streamTask?.cancel()
        stopJDWPTracking()
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
        stopJDWPTracking()
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

    // MARK: jdwp

    /// Follows `adb track-jdwp` for the life of the logcat stream. It ends the markers of debuggable apps as
    /// soon as their process goes away, which neither `ps` (polled on demand) nor logcat (when its buffers
    /// lack ActivityManager's lines) can do. Restarts when adb drops it, and gives up after a few runs that
    /// never delivered a list, so a device that lacks the service costs nothing.
    private func startJDWPTracking(token: UUID) {
        jdwpTask?.cancel()
        jdwpTask = nil
        jdwpPids = JDWPProcessSet()
        jdwpPidCount = nil
        guard let serial, let adb else { return }
        jdwpTask = Task { [weak self] in
            var idleRuns = 0
            while !Task.isCancelled, idleRuns < Self.jdwpMaxIdleRuns {
                var received = false
                for await event in adb.trackJDWP(serial: serial) {
                    guard let self, self.streamToken == token else { return }
                    if case let .pids(list) = event {
                        received = true
                        self.applyJDWP(list, token: token)
                    }
                }
                guard let self, self.streamToken == token, !Task.isCancelled else { return }
                // A new run starts with a new baseline: what changed while adb was away is not known.
                self.jdwpPids = JDWPProcessSet()
                self.jdwpPidCount = nil
                idleRuns = received ? 0 : idleRuns + 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopJDWPTracking() {
        jdwpTask?.cancel()
        jdwpTask = nil
        jdwpPidCount = nil
    }

    /// A new debuggable pid asks `ps` for its name once the app has had time to rename itself; a pid that
    /// went away is ended after the grace period, unless an ActivityManager or events line reported it first.
    private func applyJDWP(_ list: Set<Int32>, token: UUID) {
        let change = jdwpPids.apply(list)
        jdwpPidCount = jdwpPids.pids.count
        if !change.added.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.jdwpGrace))
                guard let self, self.streamToken == token else { return }
                self.requestProcessNames(force: true)
            }
        }
        guard !change.removed.isEmpty else { return }
        let observed = nextID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.jdwpGrace))
            guard let self, self.streamToken == token else { return }
            self.jdwpEnded(change.removed, observedAt: observed)
        }
    }

    private func jdwpEnded(_ pids: [Int32], observedAt: Int) {
        var markers: [ProcessMarkerTracker.Marker] = []
        for pid in pids {
            processResolver.processEnded(pid: pid, seq: observedAt)
            // `observedAt` keeps a pid that was reused during the grace period from being ended.
            if let marker = markerTracker.ended(
                pid: pid, process: nil, reason: nil, seq: nextID, observedAt: observedAt) {
                markers.append(marker)
            }
        }
        appendProcessMarkers(markers, at: lastTimestamp ?? Date().timeIntervalSince1970, source: "jdwp")
    }

    // MARK: Ingestion

    private func ingest(_ batch: [LogEntry]) {
        let now = ProcessInfo.processInfo.systemUptime
        var named = ProcessNameResolver.Update()
        var events: [Int: ProcessEvent] = [:]
        for index in batch.indices {
            if let event = ProcessEvent(batch[index]) { events[index] = event }
        }
        let hoisted = events.isEmpty ? [:] : ProcessMarkerTracker.hoistedStarts(in: batch, events: events)
        entries.reserveCapacity(entries.count + batch.count)
        for index in batch.indices {
            var entry = batch[index]
            if let resumeAfter {
                if entry.timestamp < resumeAfter { continue }
                if entry.timestamp == resumeAfter, alreadyHave(entry) { continue }
                if entry.timestamp > resumeAfter { self.resumeAfter = nil }
            }
            // The child logs before system_server writes its `Start proc` line; the marker goes above them.
            if let startIndex = hoisted[index], case let .started(pid, process, uid)? = events[startIndex] {
                appendProcessMarkers(
                    markerTracker.started(pid: pid, process: process, uid: uid, seq: nextID), at: entry.timestamp,
                    source: batch[startIndex].tag)
            }
            entry.id = nextID
            nextID += 1
            processResolver.stamp(&entry, now: now)
            if entry.processName == nil, let uid = PackageUIDMap.uid(fromLogcat: entry.uid) {
                packageTracker.note(uid: uid)
            }
            lastTimestamp = entry.timestamp
            entries.append(entry)
            markerTracker.note(entry)
            if let event = events[index] { apply(event, entry: entry, to: &named) }
        }
        if !named.isEmpty { applyNameUpdate(named) }
        trimIfNeeded()
        if processResolver.needsLookup { requestProcessNames() }
        if packageTracker.needsRefresh { requestPackages() }
        scheduleFlush()
    }

    /// Binds pids named by ActivityManager (or the events buffer) and inserts the process markers they call for.
    /// The update fills in entries the pid logged before its start line (the child logs a few lines before
    /// system_server writes the event). Markers follow the line that reported them, after any crash entry that
    /// came first.
    private func apply(_ event: ProcessEvent, entry: LogEntry, to update: inout ProcessNameResolver.Update) {
        switch event {
        case let .started(pid, process, uid):
            update.merge(processResolver.processStarted(pid: pid, name: process, seq: entry.id))
            if let uid { packageTracker.note(uid: uid) }
        case let .ended(pid, _, _):
            processResolver.processEnded(pid: pid, seq: entry.id)
        case .crashed:
            break
        }
        // Empty for a start whose marker was already placed above the pid's first lines, and for a source that
        // reports a transition another one already did.
        appendProcessMarkers(markerTracker.apply(event, seq: entry.id), at: entry.timestamp, source: entry.tag)
    }

    /// Appends marker rows. They are generated for every process; the scope setting only decides which show.
    /// `source` says which report produced them, for debug output.
    private func appendProcessMarkers(_ markers: [ProcessMarkerTracker.Marker], at timestamp: Double, source: String) {
        guard !markers.isEmpty else { return }
        let context = Self.debugMarkers ? filterContext() : nil
        for marker in markers {
            var entry = marker.entry(at: timestamp)
            entry.id = nextID
            nextID += 1
            entries.append(entry)
            processMarkerCount += 1
            if let context { debugPrint(marker: entry, source: source, context: context) }
        }
        scheduleFlush()
    }

    /// Debug output for `LOGCATNIP_DEBUG=1`: the marker, whether the current filter shows it, and the newest
    /// earlier entry of the same pid, so ordering against crash entries can be read from a terminal.
    private func debugPrint(marker: LogEntry, source: String, context: FilterContext) {
        let visible = filter.matches(marker, context: context)
        let after = entries.suffix(2000).last { $0.kind == .log && $0.pid == marker.pid }
        let anchor = after.map { "#\($0.id) \($0.tag)/\($0.level.letter)" } ?? "-"
        let line = "[logcatnip]   \(title): marker #\(marker.id) \"\(marker.message)\" source=\(source) visible=\(visible) after=\(anchor)\n"
        FileHandle.standardError.write(Data(line.utf8))
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
        FilterContext(
            myPackages: Defaults.myPackages, now: Date().timeIntervalSince1970, packages: packageTracker.map,
            processMarkers: Defaults.processMarkerScope)
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

    /// Asks for a `ps` snapshot when entries wait for a name. `force` skips the grace period for a pid that a
    /// process-start event may still name; lookups are never closer together than 1.5 s.
    private func requestProcessNames(force: Bool = false) {
        if force { processRefreshForced = true }
        guard serial != nil, adb != nil else { return }
        if processRefreshInFlight {
            processRefreshQueued = true
            return
        }
        guard !processRefreshQueued else { return }
        let throttle = 1.5 - Date().timeIntervalSince(lastProcessRefresh)
        let wait = max(throttle, processRefreshForced ? 0 : Self.processStartGrace)
        guard wait > 0 else {
            runProcessLookup()
            return
        }
        processRefreshQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.processRefreshQueued = false
            // A process-start event may have named the waiting pids in the meantime.
            if self.processRefreshForced || self.processResolver.needsLookup { self.runProcessLookup() }
        }
    }

    private func runProcessLookup() {
        guard let serial, let adb, !processRefreshInFlight else { return }
        processRefreshForced = false
        processRefreshInFlight = true
        lastProcessRefresh = Date()
        processLookupCount += 1
        let lookup = processResolver.beginLookup(seq: nextID)
        Task { [weak self] in
            let names = try? await adb.processes(serial: serial)
            guard let self else { return }
            self.processRefreshInFlight = false
            if let names {
                self.applyProcessNames(names, from: lookup)
            } else {
                self.processResolver.cancelLookup(lookup)
            }
            // After a failure, retry only when asked again, so an unreachable device is not polled.
            let again = self.processRefreshQueued || (names != nil && self.processResolver.needsLookup)
            self.processRefreshQueued = false
            if again { self.requestProcessNames() }
        }
    }

    private func applyProcessNames(_ names: [Int32: String], from lookup: ProcessNameResolver.Lookup) {
        applyNameUpdate(processResolver.applySnapshot(names, from: lookup, now: ProcessInfo.processInfo.systemUptime))
        // `ps` also lists daemons, so only the user's packages get markers from it.
        let mine = Defaults.myPackages
        appendProcessMarkers(
            markerTracker.applySnapshot(names, lookupStartSeq: lookup.startSeq) { mine.contains($0) },
            at: lastTimestamp ?? Date().timeIntervalSince1970, source: "ps")
    }

    /// Stamps names from a snapshot or an event on the entries that waited for them, and refreshes what the
    /// table shows.
    private func applyNameUpdate(_ update: ProcessNameResolver.Update) {
        // Cells only change when entries got a name, so skip the refresh otherwise.
        guard update.apply(to: &entries) > 0 else { return }
        // Entries the filter has not seen yet are filtered with their names at the next flush.
        guard update.assignments.values.contains(where: { $0.firstSeq <= lastFilteredID }) else { return }
        if filter.dependsOnProcessNames {
            refilter()
        } else {
            onRowsChanged?(.refreshVisible)
        }
    }

    // MARK: Packages by uid

    /// Reads `pm list packages -U` when the stream starts and when an entry carries an app uid the map lacks
    /// (each app id at most once, see `PackageUIDTracker`). Entries whose process was never seen can then
    /// still be attributed to their app. Lookups are at least 2 s apart.
    private func requestPackages(force: Bool = false) {
        guard let serial, adb != nil else { return }
        // `pm list packages -U` needs Android 8.0. Start proc events cover older releases.
        if let api = model?.device(serial: serial)?.properties?.apiLevel, api < 26 { return }
        guard force || packageTracker.needsRefresh else { return }
        if packageRefreshInFlight {
            packageRefreshQueued = true
            return
        }
        guard !packageRefreshQueued else { return }
        let wait = 2 - Date().timeIntervalSince(lastPackageRefresh)
        guard wait > 0 else {
            runPackageLookup()
            return
        }
        packageRefreshQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.packageRefreshQueued = false
            if force || self.packageTracker.needsRefresh { self.runPackageLookup() }
        }
    }

    private func runPackageLookup() {
        guard let serial, let adb, !packageRefreshInFlight else { return }
        packageRefreshInFlight = true
        lastPackageRefresh = Date()
        packageLookupCount += 1
        let refresh = packageTracker.beginRefresh()
        Task { [weak self] in
            let map = try? await adb.packagesByUID(serial: serial)
            guard let self else { return }
            self.packageRefreshInFlight = false
            // A device with apps never lists none, so an empty list is an error message, not an answer.
            if let map, map.count > 0 {
                if self.packageTracker.finishRefresh(refresh, with: map) { self.packagesChanged() }
            } else {
                self.packageTracker.failRefresh(refresh)
            }
            if self.packageRefreshQueued {
                self.packageRefreshQueued = false
                self.requestPackages()
            }
        }
    }

    /// New owners can change which entries `package:` terms match and what the Package cells show.
    private func packagesChanged() {
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
        if entry.isMarker {
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
