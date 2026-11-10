import Foundation

/// Why a process ended, when the log says.
public enum ProcessEndReason: Sendable, Hashable {
    case crashed
    case forceStopped

    /// Reads the reason ActivityManager gives in `Killing <pid>:<process>/<uid> (adj <n>): <reason>`. Other
    /// reasons (`empty #17`, `remove task`, memory pressure) say nothing a marker should repeat.
    init?(killReason: Substring) {
        // `crash` is what ActivityManager uses once an app has crashed too often.
        if killReason.hasPrefix("crash") {
            self = .crashed
        } else if killReason.hasPrefix("stop ") {
            self = .forceStopped
        } else {
            return nil
        }
    }
}

/// What a process marker entry says.
public enum ProcessMarker: Sendable, Hashable {
    case started
    case ended(ProcessEndReason?)
}

/// Which apps' process markers to show.
public enum ProcessMarkerScope: String, Sendable, CaseIterable {
    /// Only markers of the user's own packages. With no packages configured, none show.
    case mine
    case all
}

extension ProcessEvent {
    var pid: Int32 {
        switch self {
        case let .started(pid, _, _), let .ended(pid, _, _), let .crashed(pid, _): pid
        }
    }
}

/// Decides which PROCESS STARTED / ENDED markers to insert, so each run of a process gets one of each whichever
/// source reports it first (ActivityManager lines and events-buffer entries, `ps` snapshots, and `adb track-jdwp`).
///
/// Positions are entry sequence numbers, as in `ProcessNameResolver`: a `ps` snapshot never overrides what a
/// report newer than the request said. The owner serializes calls.
public struct ProcessMarkerTracker: Sendable {
    /// A marker to insert. `entry(at:)` makes the row.
    public struct Marker: Sendable, Equatable {
        public var pid: Int32
        public var process: String
        public var uid: Int?
        public var marker: ProcessMarker

        public init(pid: Int32, process: String, uid: Int?, marker: ProcessMarker) {
            self.pid = pid
            self.process = process
            self.uid = uid
            self.marker = marker
        }

        public var package: String { LogEntry.packageName(forProcess: process) }

        /// `PROCESS STARTED (<pid>) for package <package>`; a process other than the package's main one is
        /// named, and an end says `(crashed)` or `(force stopped)` when the log did.
        public var text: String {
            var text: String
            switch marker {
            case .started: text = "PROCESS STARTED (\(pid)) for package \(package)"
            case .ended: text = "PROCESS ENDED (\(pid)) for package \(package)"
            }
            if process != package { text += ", process \(process)" }
            if case let .ended(reason?) = marker {
                text += reason == .crashed ? " (crashed)" : " (force stopped)"
            }
            return text
        }

        /// The marker as a table row. It carries the pid, process and uid so filters can match it.
        public func entry(at timestamp: Double) -> LogEntry {
            LogEntry(
                kind: .process(marker), timestamp: timestamp, uid: uid.map(String.init), pid: pid, tid: 0,
                level: .info, tag: "", message: text, processName: process)
        }
    }

    private struct Record: Sendable {
        var process: String
        var uid: Int?
        /// Sequence number of the report this record is based on.
        var since: Int
        var alive: Bool
        /// Seen running by the baseline snapshot, which inserts no marker. A start report for the same
        /// process (history in the first batch) still gets its marker.
        var silent = false
    }

    private var records: [Int32: Record] = [:]
    /// Pids that logged a crash since their start; their next end report says so.
    private var crashed: Set<Int32> = []
    private var hasBaseline = false
    private var deadCount = 0

    /// Dead records kept so a late second report of the same death is recognized; older ones are dropped.
    private static let deadLimit = 2048
    private static let deadKept = 1024
    private static let crashedLimit = 4096

    public init() {}

    /// Processes currently believed alive. For tests and debug output.
    public var liveCount: Int { records.count - deadCount }
    public var recordCount: Int { records.count }

    /// Remembers that a process crashed, so its end says so: crash lines come before ActivityManager's report
    /// that the process died. Cheap for ordinary entries, since this runs for every ingested one.
    public mutating func note(_ entry: LogEntry) {
        guard Self.isFatalCrash(entry) else { return }
        if crashed.count >= Self.crashedLimit { crashed.removeAll() }
        crashed.insert(entry.pid)
    }

    /// A Java crash (`AndroidRuntime` E `FATAL EXCEPTION`) or a native one (`libc` F `Fatal signal`). Both are
    /// written by the dying process itself, so the entry's pid is the process that ends.
    static func isFatalCrash(_ entry: LogEntry) -> Bool {
        guard entry.kind == .log else { return false }
        switch entry.level {
        case .error:
            return entry.tag == "AndroidRuntime"
                && (entry.message.hasPrefix("FATAL EXCEPTION") || entry.message.contains("\nFATAL EXCEPTION"))
        case .assert:
            return entry.tag == "libc" && entry.message.hasPrefix("Fatal signal")
        default:
            return false
        }
    }

    /// Remembers that a process crashed, from an `am_crash` event, so its end says so. `am_crash` is written by
    /// system_server with the pid of the caller; for a native crash that is system_server's own pid, so a live
    /// record under another name is left alone.
    public mutating func noteCrash(pid: Int32, process: String) {
        if let record = records[pid], record.alive, record.process != process { return }
        if crashed.count >= Self.crashedLimit { crashed.removeAll() }
        crashed.insert(pid)
    }

    /// Applies a parsed ActivityManager or events-buffer report.
    public mutating func apply(_ event: ProcessEvent, seq: Int) -> [Marker] {
        switch event {
        case let .started(pid, process, uid):
            return started(pid: pid, process: process, uid: uid, seq: seq)
        case let .ended(pid, process, reason):
            return ended(pid: pid, process: process, reason: reason, seq: seq).map { [$0] } ?? []
        case let .crashed(pid, process):
            noteCrash(pid: pid, process: process)
            return []
        }
    }

    /// A start report. Returns the markers to insert: none when the process is already known to be running
    /// under that name, an ended marker first when the pid was reused without a death being seen.
    public mutating func started(pid: Int32, process: String, uid: Int?, seq: Int) -> [Marker] {
        var markers: [Marker] = []
        if let record = records[pid], record.alive {
            if record.process == process {
                guard record.silent else {
                    if record.uid == nil, let uid { records[pid]?.uid = uid }
                    return []
                }
                store(Record(process: process, uid: uid ?? record.uid, since: seq, alive: true), for: pid)
                return [Marker(pid: pid, process: process, uid: uid ?? record.uid, marker: .started)]
            }
            markers.append(end(pid: pid, record: record, reason: nil, seq: seq))
        }
        store(Record(process: process, uid: uid, since: seq, alive: true), for: pid)
        crashed.remove(pid)
        markers.append(Marker(pid: pid, process: process, uid: uid, marker: .started))
        return markers
    }

    /// An end report. `process` may be nil when the source knows only the pid. Nil is returned for a pid already
    /// reported dead, and for a pid nothing is known about when `process` is nil.
    public mutating func ended(pid: Int32, process: String?, reason: ProcessEndReason?, seq: Int) -> Marker? {
        let record = records[pid]
        if let record, !record.alive { return nil }
        guard let name = process ?? record?.process else { return nil }
        return end(pid: pid, record: Record(process: name, uid: record?.uid, since: seq, alive: true),
                   reason: reason, seq: seq)
    }

    /// A complete pid -> name snapshot from `ps`, requested when the entry with sequence number
    /// `lookupStartSeq` had not been ingested yet. Reports changes of processes whose package passes
    /// `isTracked` (`ps` also lists daemons and kernel threads, which are not apps).
    ///
    /// The first snapshot only records what is running. Pids that look like a freshly forked app (still under
    /// a zygote name) wait for the next snapshot, and reports newer than the request are left alone.
    public mutating func applySnapshot(
        _ names: [Int32: String],
        lookupStartSeq start: Int,
        isTracked: (String) -> Bool
    ) -> [Marker] {
        let baseline = !hasBaseline
        hasBaseline = true
        var markers: [Marker] = []
        for pid in records.keys.sorted() {
            guard let record = records[pid], record.alive, record.since < start,
                  isTracked(LogEntry.packageName(forProcess: record.process)) else { continue }
            if let current = names[pid], current == record.process || ProcessNameResolver.forkNames.contains(current) {
                continue
            }
            markers.append(end(pid: pid, record: record, reason: nil, seq: start))
        }
        for pid in names.keys.sorted() {
            guard let name = names[pid], !ProcessNameResolver.forkNames.contains(name),
                  isTracked(LogEntry.packageName(forProcess: name)) else { continue }
            if let record = records[pid], record.since >= start || record.process == name { continue }
            store(Record(process: name, uid: nil, since: start, alive: true, silent: baseline), for: pid)
            crashed.remove(pid)
            if !baseline { markers.append(Marker(pid: pid, process: name, uid: nil, marker: .started)) }
        }
        return markers
    }

    /// Marks `record` dead and returns its ended marker.
    private mutating func end(pid: Int32, record: Record, reason: ProcessEndReason?, seq: Int) -> Marker {
        let reason = crashed.contains(pid) ? .crashed : reason
        crashed.remove(pid)
        store(Record(process: record.process, uid: record.uid, since: seq, alive: false), for: pid)
        pruneDead()
        return Marker(pid: pid, process: record.process, uid: record.uid, marker: .ended(reason))
    }

    /// Replaces a pid's record, keeping the dead count right.
    private mutating func store(_ record: Record, for pid: Int32) {
        if records[pid]?.alive == false { deadCount -= 1 }
        records[pid] = record
        if !record.alive { deadCount += 1 }
    }

    private mutating func pruneDead() {
        guard deadCount > Self.deadLimit else { return }
        let newest = records.values.filter { !$0.alive }.map(\.since).sorted(by: >)
        let cutoff = newest[Self.deadKept - 1]
        records = records.filter { $0.value.alive || $0.value.since >= cutoff }
        deadCount = records.values.filter { !$0.alive }.count
    }

    /// For a batch of entries, where a `Start proc` line is placed: the child logs a few lines before
    /// system_server writes the line, so the marker goes above the first entry the pid logged earlier in the
    /// same batch (at most `window` entries back, never across an earlier start or end report of the same pid).
    /// Returns the batch index of that entry -> the index of the `Start proc` line. `events` holds the batch's
    /// ActivityManager events by index. Entries are append-only, so a marker cannot move above entries of an
    /// earlier batch.
    public static func hoistedStarts(
        in batch: [LogEntry],
        events: [Int: ProcessEvent],
        window: Int = 256
    ) -> [Int: Int] {
        var hoisted: [Int: Int] = [:]
        let ordered = events.keys.sorted()
        for (position, index) in ordered.enumerated() {
            guard case let .started(pid, _, _)? = events[index] else { continue }
            var lower = max(0, index - window)
            if let earlier = ordered[..<position].last(where: { events[$0]?.pid == pid }) {
                lower = max(lower, earlier + 1)
            }
            for candidate in lower..<index where batch[candidate].kind == .log && batch[candidate].pid == pid {
                hoisted[candidate] = index
                break
            }
        }
        return hoisted
    }
}
