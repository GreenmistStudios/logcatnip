import AppKit
import Foundation
import LogcatKit
import Observation

/// One log view: a live logcat stream from a device, a simulator's `log stream`, or an imported file. Owns
/// the entry buffer, the filter, and the filtered rows the table shows.
@MainActor
@Observable
final class LogSession: Identifiable {
    enum Source: Equatable {
        /// `serial` is the adb transport now in use; it changes when the device reconnects on a new port or
        /// switches between USB and Wi-Fi. `identity` stays with the session.
        case device(serial: String, identity: DeviceIdentity)
        case simulator(udid: String)
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
    /// Find-in-results for this session's rows.
    let find = FindController()
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
    /// Counts and groups of `signals`, reassigned only when the index changes so views aren't invalidated
    /// on every flush.
    private(set) var signalSummary = SignalSummary()
    /// Whether Next Crash / Next Error have somewhere to go. Assigned only when they flip, so the menu
    /// isn't rebuilt on every flush.
    private(set) var hasCrashTargets = false
    private(set) var hasErrorTargets = false
    /// Bumped when which occurrences the filter shows may have changed: a refilter, trim or clear, a signal
    /// change, or a flush that showed an anchor row. The popover reads it instead of `visibleCount`, which
    /// changes on every flush and misses refilters that keep the count.
    private(set) var visibilityGeneration = 0

    @ObservationIgnored private(set) var entries: [LogEntry] = []
    @ObservationIgnored private(set) var rows: [Row] = []
    /// Crashes, ANRs, leaks and warnings in `entries`. Keyed by entry, so refilters leave it alone.
    @ObservationIgnored private(set) var signals = SignalIndex()
    /// Rows of the visible error and assert entries, for scroller ticks and Next Error.
    @ObservationIgnored private(set) var errorRows = IncrementalRowIndex.errors
    /// Every entry that matched an anchor rule of a crash, native crash or ANR (all of a burst's reports, not
    /// just the first), so the table tints them with a set lookup. Kept from the index's changes.
    @ObservationIgnored private(set) var fatalAnchorIDs: Set<Int> = []
    /// The same for leaks, out of memory and jank.
    @ObservationIgnored private(set) var warningAnchorIDs: Set<Int> = []
    /// Rows of the visible entries in `fatalAnchorIDs` and `warningAnchorIDs`, for the scroller ticks and as
    /// the source of Next Crash. A burst can have several; ``visibleSignalRows(kinds:)`` keeps one per
    /// occurrence.
    @ObservationIgnored private(set) var fatalAnchorRows = IncrementalRowIndex()
    @ObservationIgnored private(set) var warningAnchorRows = IncrementalRowIndex()
    @ObservationIgnored var onRowsChanged: ((RowsChange) -> Void)?

    @ObservationIgnored private let adb: ADB?
    @ObservationIgnored private let simctl: Simctl?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var firstID = 0
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastFilteredID = -1
    @ObservationIgnored private var filterGeneration = 0
    /// Bumped whenever `rows` changes, for caches of row indexes.
    @ObservationIgnored private var rowsGeneration = 0
    @ObservationIgnored private var signalDebugCheck: (key: [Int], verdict: String)?
    /// The `signals.generation` that `signalSummary` was built from, so flushes without signal changes
    /// don't rebuild and compare it.
    @ObservationIgnored private var signalSummaryGeneration = -1
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
    @ObservationIgnored private var processResolver = ProcessNameResolver()
    /// `dumpsys package` results by package (a nil version when the device doesn't have it), so repeated copies
    /// don't wait on adb. They expire after `appVersionLifetime` and on clear, since the app may be reinstalled.
    @ObservationIgnored private var appVersions: [String: (version: AppVersion?, fetched: ContinuousClock.Instant)] = [:]
    private static let appVersionLifetime: Duration = .seconds(30)

    init(source: Source, adb: ADB? = nil, simctl: Simctl? = nil, model: AppModel) {
        self.source = source
        self.adb = adb
        self.simctl = simctl
        self.model = model
        find.session = self
    }

    /// The adb serial of an Android device session.
    var serial: String? {
        if case let .device(serial, _) = source { serial } else { nil }
    }

    var identity: DeviceIdentity? {
        if case let .device(_, identity) = source { identity } else { nil }
    }

    /// The UDID of a simulator session.
    var udid: String? {
        if case let .simulator(udid) = source { udid } else { nil }
    }

    /// Whether logs stream from a device or simulator, as opposed to a file.
    var isStreamSource: Bool { serial != nil || udid != nil }

    /// The command that produces the logs, for menus and markers.
    var streamName: String { udid != nil ? "log stream" : "logcat" }

    private var isSourceOnline: Bool {
        switch source {
        case let .device(serial, _): model?.device(serial: serial)?.isOnline ?? false
        case let .simulator(udid): model?.simulator(udid: udid) != nil
        case .file: false
        }
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
        case let .simulator(udid):
            if let simulator = model?.simulator(udid: udid) {
                baseTitle = simulator.name
            } else if baseTitle.isEmpty {
                // Keep the name once the simulator shuts down.
                baseTitle = udid
            }
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

    /// Id of the oldest entry still in the buffer. Entries are indexed by `id - firstEntryID`.
    var firstEntryID: Int { firstID }

    /// Index of `row` in `rows`, or nil when it is gone (trimmed, or filtered out).
    func rowIndex(of row: Row) -> Int? {
        let index = firstRowIndex(atOrAfter: row.entryID) + Int(row.line)
        guard index < rows.count, rows[index] == row else { return nil }
        return index
    }

    /// Names are stamped on entries at ingestion or when a `ps` snapshot resolves them. There is no
    /// pid-map fallback: a reused pid would rename the unresolved entries of the process that died.
    func processName(for entry: LogEntry) -> String? {
        entry.processName
    }

    /// How many pids the resolver knows, is waiting on, or gave up on. For debug output.
    var processNameStats: ProcessNameResolver.Stats { processResolver.stats }

    // MARK: Streaming

    func start() {
        let stream: AsyncStream<LogStreamEvent>
        switch source {
        case let .device(serial, _):
            guard let adb else { return }
            let api = model?.device(serial: serial)?.properties?.apiLevel
            let modern = !legacyFormatDetected && ADB.LogcatOptions.modernFormatSupported(apiLevel: api)
            streamsModernFormat = modern
            let options = ADB.LogcatOptions(buffers: Defaults.logcatBuffers, since: resumeAfter, modernFormat: modern)
            stream = adb.logcat(serial: serial, options: options)
        case let .simulator(udid):
            guard let simctl else { return }
            stream = simctl.logStream(udid: udid)
        case .file:
            return
        }
        streamTask?.cancel()
        status = .starting
        let token = UUID()
        streamToken = token
        requestProcessNames()

        streamTask = Task { [weak self] in
            var receivedAny = false
            self?.status = .streaming
            for await event in stream {
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
        streamToken = nil
        streamTask?.cancel()
        streamTask = nil
        ageRefresh?.cancel()
        if isLive { status = .stopped }
    }

    /// Clears the view and starts the stream again: logcat from the start of the device buffer, a simulator's
    /// `log stream` from now.
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
        guard isStreamSource, status != .disconnected, status != .stopped else { return }
        streamToken = nil
        streamTask?.cancel()
        status = .disconnected
        appendMarker(disconnectedText)
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

    /// Resumes a simulator session after the simulator boots again. Its UDID never changes, so unlike
    /// `reattach` there is no transport to switch to.
    func simulatorBooted() {
        guard udid != nil, status == .disconnected else { return }
        appendMarker("Simulator booted")
        resumeAfter = lastTimestamp
        restartAttempts = 0
        start()
    }

    private func logcatEnded(_ exit: LogcatExit) {
        streamToken = nil
        switch exit.recovery(restartAttempts: restartAttempts, deviceOnline: isSourceOnline) {
        case .useLegacyFormat:
            legacyFormatDetected = true
            appendMarker("logcat doesn't support -v epoch or -v uid; using the legacy format")
            start()
        case .restart:
            restartAttempts += 1
            appendMarker("\(streamName) exited\(exit.detail.map { ": \($0)" } ?? " (\(exit.status))"); restarting")
            resumeAfter = lastTimestamp
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.streamToken == nil, self.isLive else { return }
                self.start()
            }
        case .waitForDevice:
            status = .disconnected
            appendMarker(disconnectedText)
        case let .fail(message):
            status = .failed(message)
            appendMarker("\(streamName) failed: \(message)")
        }
    }

    private var disconnectedText: String {
        udid != nil ? "Simulator shut down" : "Device disconnected"
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

    /// Shows a fixed set of entries, as if loaded from a file, and filters them right away instead of on
    /// the next flush. Screenshot tests use it to render the table without adb.
    func show(_ batch: [LogEntry], status: Status = .loaded) {
        ingest(batch)
        self.status = status
        flushRows()
    }

    private func ingest(_ batch: [LogEntry]) {
        let now = ProcessInfo.processInfo.systemUptime
        let start = entries.count
        entries.reserveCapacity(entries.count + batch.count)
        for var entry in batch {
            if let resumeAfter {
                if entry.timestamp < resumeAfter { continue }
                if entry.timestamp == resumeAfter, alreadyHave(entry) { continue }
                if entry.timestamp > resumeAfter { self.resumeAfter = nil }
            }
            entry.id = nextID
            nextID += 1
            processResolver.stamp(&entry, now: now)
            lastTimestamp = entry.timestamp
            entries.append(entry)
        }
        applySignalChanges(signals.ingest(entries[start...]))
        trimIfNeeded()
        updateSignalSummary()
        if processResolver.needsLookup { requestProcessNames() }
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
        applySignalChanges(signals.removeEntries(before: firstID, remaining: entries))
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
        rowsGeneration += 1
        errorRows.removeFront(removedRows)
        fatalAnchorRows.removeFront(removedRows)
        warningAnchorRows.removeFront(removedRows)
        visibilityGeneration += 1
        find.rowsRemovedFront(removedRows)
        updateNavigationTargets()
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
        let start = rows.count
        let anchorRowCount = fatalAnchorRows.count + warningAnchorRows.count
        let hasAnchors = !fatalAnchorIDs.isEmpty || !warningAnchorIDs.isEmpty
        for entry in entries[startIndex...] where filter.matches(entry, context: context) {
            matched += 1
            let row = start + newRows.count
            errorRows.note(entry, firstRow: row)
            if hasAnchors { noteAnchor(entry.id, row: row) }
            Self.appendRows(for: entry, to: &newRows)
        }
        lastFilteredID = nextID - 1
        guard !newRows.isEmpty else { return }
        rows.append(contentsOf: newRows)
        rowsGeneration += 1
        visibleCount += matched
        if fatalAnchorRows.count + warningAnchorRows.count != anchorRowCount { visibilityGeneration += 1 }
        find.rowsAppended()
        updateNavigationTargets()
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

    // MARK: Signals

    private func updateSignalSummary() {
        guard signals.generation != signalSummaryGeneration else { return }
        signalSummaryGeneration = signals.generation
        let summary = SignalSummary(signals)
        if summary != signalSummary { signalSummary = summary }
        visibilityGeneration += 1
        updateNavigationTargets()
    }

    /// Keeps the anchor sets and rows in step with what the index added and trimmed, so no flush walks the
    /// occurrences. Promotions move an occurrence's id but not its anchor entries, so they change nothing here.
    private func applySignalChanges(_ changes: SignalIndexChanges) {
        for anchor in changes.removedAnchors {
            // Their rows were trimmed from the front with the entries, and `removeFront` drops them.
            if anchor.kind.isFatal { fatalAnchorIDs.remove(anchor.entryID) } else { warningAnchorIDs.remove(anchor.entryID) }
        }
        for anchor in changes.addedAnchors {
            if anchor.kind.isFatal { fatalAnchorIDs.insert(anchor.entryID) } else { warningAnchorIDs.insert(anchor.entryID) }
            // The index reports anchors as their entries arrive, so `flushRows` notes their rows. An entry that
            // already has a row joins in order instead. A refilter in flight is fine either way: it took its
            // snapshot of the sets with the entries, and flushes what came after.
            if anchor.entryID <= lastFilteredID, !refilterInFlight,
               let row = rowIndex(of: Row(entryID: anchor.entryID, line: 0)) {
                if anchor.kind.isFatal { fatalAnchorRows.insert(row) } else { warningAnchorRows.insert(row) }
            }
        }
    }

    private func noteAnchor(_ entryID: Int, row: Int) {
        if fatalAnchorIDs.contains(entryID) {
            fatalAnchorRows.insert(row)
        } else if warningAnchorIDs.contains(entryID) {
            warningAnchorRows.insert(row)
        }
    }

    /// Ascending rows, one per occurrence of `kinds` the filter shows: the first visible row among its anchor
    /// entries, so a filter that hides one report of a burst (InputDispatcher's) still finds another
    /// (ActivityManager's). Built from the anchor rows when asked, for navigation, so it costs the visible
    /// anchor rows of `kinds` and flushes never pay for it.
    func visibleSignalRows(kinds: Set<SignalKind>) -> [Int] {
        let fatal = kinds.isDisjoint(with: SignalKind.fatal) ? [] : fatalAnchorRows.rows
        let warnings = kinds.isDisjoint(with: SignalKind.warnings) ? [] : warningAnchorRows.rows
        let candidates = fatal.isEmpty ? warnings : warnings.isEmpty ? fatal : (fatal + warnings).sorted()
        var seen = Set<Int>()
        var result: [Int] = []
        for row in candidates where row < rows.count {
            guard let id = signals.occurrenceID(forEntryID: rows[row].entryID), seen.insert(id).inserted,
                  let occurrence = signals.occurrence(id: id), kinds.contains(occurrence.kind)
            else { continue }
            result.append(row)
        }
        return result
    }

    /// The occurrence's first visible row among its anchor entries, or nil when the filter hides them all.
    func visibleRow(ofOccurrence id: Int) -> Int? {
        guard let occurrence = signals.occurrence(id: id) else { return nil }
        for anchor in occurrence.anchorEntryIDs {
            if let row = rowIndex(of: Row(entryID: anchor, line: 0)) { return row }
        }
        return nil
    }

    /// Whether the filter shows any of the occurrence's anchor entries.
    func occurrenceIsVisible(_ occurrence: SignalOccurrence) -> Bool {
        occurrenceIsVisible(id: occurrence.id)
    }

    func occurrenceIsVisible(id: Int) -> Bool {
        visibleRow(ofOccurrence: id) != nil
    }

    /// Whether `entryID` reported a crash, native crash or ANR, for the row tint.
    func isFatalAnchor(_ entryID: Int) -> Bool {
        fatalAnchorIDs.contains(entryID)
    }

    private func updateNavigationTargets() {
        // Every anchor belongs to an occurrence, so any visible one is somewhere to go.
        let crashes = !fatalAnchorRows.isEmpty
        if crashes != hasCrashTargets { hasCrashTargets = crashes }
        let errors = !errorRows.isEmpty
        if errors != hasErrorTargets { hasErrorTargets = errors }
    }

    // MARK: Navigation

    /// Selects and reveals the next or previous visible occurrence of `kinds`, wrapping around, from the
    /// selection or the visible rows. Leaves the filter alone and stops following new logs, as find does.
    func navigateSignal(_ direction: FindDirection, kinds: Set<SignalKind>) {
        reveal(FindResults.target(in: visibleSignalRows(kinds: kinds), direction, from: navigationAnchor))
    }

    /// Selects and reveals the next or previous visible error or assert entry.
    func navigateError(_ direction: FindDirection) {
        reveal(errorRows.target(direction, from: navigationAnchor))
    }

    /// Jumps to one occurrence, for the signals popover. Beeps when the filter hides it.
    func revealOccurrence(id: Int) {
        reveal(visibleRow(ofOccurrence: id))
    }

    private var navigationAnchor: FindAnchor {
        find.table?.findAnchor ?? .none
    }

    private func reveal(_ row: Int?) {
        guard let row, let table = find.table else {
            NSSound.beep()
            return
        }
        table.revealFindMatch(row: row, highlight: nil)
    }

    /// One line for `LOGCATNIP_DEBUG`. Rebuilds the index from the buffer and compares occurrence and anchor
    /// ids, so it shows whether incremental ingest and trims kept it exact (see ``SignalIndex`` for when a trim
    /// through a burst can't). Rebuilt once per state.
    func signalDebugSummary() -> String {
        let key = [signals.generation, firstID, entries.count]
        if signalDebugCheck?.key != key {
            var expected = SignalIndex()
            expected.ingest(entries)
            let actualIDs = signals.occurrences.map(\.anchorEntryIDs)
            let expectedIDs = expected.occurrences.map(\.anchorEntryIDs)
            let verdict = actualIDs == expectedIDs ? "ok" : "MISMATCH(\(expectedIDs.count) vs \(actualIDs.count))"
            signalDebugCheck = (key, verdict)
        }
        let counts: [(String, SignalKind)] = [
            ("crash", .crash), ("native", .nativeCrash), ("anr", .anr), ("leak", .leak), ("oom", .outOfMemory),
            ("jank", .performance),
        ]
        let text = counts.map { "\($0.0)=\(signals.count(of: $0.1))" }.joined(separator: " ")
        return "signals: \(text) groups=\(signals.groups.count) check=\(signalDebugCheck?.verdict ?? "-")"
    }

    // MARK: Filtering

    private func filterContext() -> FilterContext {
        FilterContext(myPackages: Defaults.myPackages, now: Date().timeIntervalSince1970)
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
        let fatalIDs = fatalAnchorIDs
        let warningIDs = warningAnchorIDs
        refilterInFlight = true

        Task { [weak self] in
            let (rows, visible, errorRows, fatalRows, warningRows) = await Task.detached(priority: .userInitiated) {
                var errors = IncrementalRowIndex.errors
                var fatalRows = IncrementalRowIndex()
                var warningRows = IncrementalRowIndex()
                let hasAnchors = !fatalIDs.isEmpty || !warningIDs.isEmpty
                var rows: [Row] = []
                var visible = 0
                for entry in snapshot where filter.matches(entry, context: context) {
                    visible += 1
                    errors.note(entry, firstRow: rows.count)
                    if hasAnchors {
                        if fatalIDs.contains(entry.id) {
                            fatalRows.insert(rows.count)
                        } else if warningIDs.contains(entry.id) {
                            warningRows.insert(rows.count)
                        }
                    }
                    LogSession.appendRows(for: entry, to: &rows)
                }
                return (rows, visible, errors, fatalRows, warningRows)
            }.value
            guard let self, generation == self.filterGeneration else { return }
            self.refilterInFlight = false
            // Entries may have been trimmed while filtering.
            let firstValid = rows.firstIndex { $0.entryID >= self.firstID } ?? rows.count
            self.rows = firstValid == 0 ? rows : Array(rows[firstValid...])
            self.rowsGeneration += 1
            self.errorRows = errorRows
            self.errorRows.removeFront(firstValid)
            self.fatalAnchorRows = fatalRows
            self.fatalAnchorRows.removeFront(firstValid)
            self.warningAnchorRows = warningRows
            self.warningAnchorRows.removeFront(firstValid)
            self.visibilityGeneration += 1
            self.visibleCount = firstValid == 0 ? visible : Set(self.rows.map(\.entryID)).count
            self.lastFilteredID = lastID
            self.find.rowsReplaced()
            self.updateNavigationTargets()
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
        rowsGeneration += 1
        errorRows.reset()
        fatalAnchorRows.reset()
        warningAnchorRows.reset()
        fatalAnchorIDs.removeAll()
        warningAnchorIDs.removeAll()
        visibilityGeneration += 1
        signals.reset()
        updateSignalSummary()
        appVersions.removeAll()
        firstID = nextID
        lastFilteredID = nextID - 1
        filterGeneration += 1
        refilterInFlight = false
        totalCount = 0
        visibleCount = 0
        find.rowsReplaced()
        updateNavigationTargets()
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
            if self.processRefreshQueued || (names != nil && self.processResolver.needsLookup) {
                self.processRefreshQueued = false
                self.requestProcessNames()
            }
        }
    }

    private func applyProcessNames(_ names: [Int32: String], from lookup: ProcessNameResolver.Lookup) {
        let update = processResolver.applySnapshot(names, from: lookup, now: ProcessInfo.processInfo.systemUptime)
        // Cells only change when entries got a name, so skip the refresh otherwise.
        guard update.apply(to: &entries) > 0 else { return }
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

    // MARK: Text output

    func formattedLine(for entry: LogEntry) -> String {
        entry.formattedLine()
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

    // MARK: Crash reports

    /// The crash, native crash or ANR the Copy Crash Report command means: the selected row's, otherwise the
    /// newest one before the selection, otherwise the newest in the buffer. Leaks, out of memory and jank are
    /// copied from their row or popover menus (Copy Report), so the command title always fits.
    func reportOccurrenceID(nearRow rowIndex: Int?) -> Int? {
        guard let rowIndex, rowIndex < rows.count else {
            return signals.occurrence(atOrBefore: Int.max, kinds: SignalKind.fatal)?.id
        }
        let entryID = rows[rowIndex].entryID
        if let id = signals.occurrenceID(forEntryID: entryID), signals.occurrence(id: id)?.kind.isFatal == true {
            return id
        }
        return (signals.occurrence(atOrBefore: entryID, kinds: SignalKind.fatal)
            ?? signals.occurrence(atOrBefore: Int.max, kinds: SignalKind.fatal))?.id
    }

    /// Markdown for one occurrence, with the device's model and build and the app's installed version. The
    /// version comes from the device, so it's the one installed now; it's looked up once per package.
    func crashReport(for occurrenceID: Int) async -> String? {
        guard let occurrence = signals.occurrence(id: occurrenceID) else { return nil }
        let context = CrashReport.contextEntries(
            for: occurrence, in: entries, firstID: firstID, lines: Defaults.crashReportContextLinesValue
        )
        let anchorProcess = context.first { $0.id == occurrence.id }?.processName
        let package = occurrence.package ?? anchorProcess.map(LogEntry.packageName(forProcess:))
        var device: DeviceInfo?
        var source: String?
        switch self.source {
        case let .device(serial, _):
            device = model?.device(serial: serial)?.properties.map(DeviceInfo.init(properties:)) ?? DeviceInfo()
        case let .file(url):
            source = url.lastPathComponent
        case .simulator:
            source = baseTitle
        }
        let app = await appVersion(of: package)
        return CrashReport(
            occurrence: occurrence, device: device, source: source, app: app, package: package, context: context
        ).markdown()
    }

    func copyCrashReport(for occurrenceID: Int) {
        Task {
            guard let report = await crashReport(for: occurrenceID) else {
                NSSound.beep()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    private func appVersion(of package: String?) async -> AppVersion? {
        // The name goes into a shell command, so only package-name characters are let through.
        guard let package, let serial, let adb, !package.isEmpty,
              package.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") })
        else { return nil }
        if let cached = appVersions[package], cached.fetched.duration(to: .now) < Self.appVersionLifetime {
            return cached.version
        }
        let output = try? await adb.shell(serial: serial, "dumpsys package \(package)", timeout: .seconds(2))
        let version = output.flatMap { AppVersion.parse(dumpsysPackage: $0) }
        // A timeout or adb error is tried again next time; a package the device doesn't know isn't, until it expires.
        if output != nil { appVersions[package] = (version, .now) }
        return version
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
