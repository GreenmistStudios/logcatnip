import Foundation

/// Works out which process wrote each log entry from `ps` snapshots, so a pid that exits and is reused
/// by another app does not keep the old name, and a process that starts during a lookup is not given up on.
///
/// Positions are entry sequence numbers (`LogEntry.id`), not clocks: an entry ingested before a `ps`
/// request started came from a process that existed before `ps` ran, whatever the device and host clocks
/// say. `now` (host seconds) only paces retries. The owner serializes calls and runs one lookup at a time.
public struct ProcessNameResolver: Sendable {
    /// An in-flight `ps` request.
    public struct Lookup: Sendable, Equatable {
        /// Entries with a lower sequence number were ingested before the request started.
        public let startSeq: Int
        let previousStartSeq: Int?
        let hadTentativeRetry: Bool
    }

    /// A name for a pid whose entries were waiting, valid for its entries from `firstSeq` on.
    public struct Assignment: Sendable, Equatable {
        public var name: String
        public var firstSeq: Int

        public init(name: String, firstSeq: Int) {
            self.name = name
            self.firstSeq = firstSeq
        }
    }

    /// Names to fill in on entries that were ingested before their process was known.
    public struct Update: Sendable, Equatable {
        public var assignments: [Int32: Assignment]
        public var isEmpty: Bool { assignments.isEmpty }

        public init(assignments: [Int32: Assignment] = [:]) {
            self.assignments = assignments
        }

        /// Adds another update's assignments; for a pid in both, the other's wins.
        public mutating func merge(_ other: Update) {
            assignments.merge(other.assignments) { _, new in new }
        }

        /// Stamps unnamed entries of the assigned pids, newest first, looking at most `scanLimit` entries
        /// back so a huge buffer does not stall the main thread. Returns how many entries changed.
        @discardableResult
        public func apply(to entries: inout [LogEntry], scanLimit: Int = 50_000) -> Int {
            guard let lowest = assignments.values.map(\.firstSeq).min() else { return 0 }
            var changed = 0
            var index = entries.count - 1
            let stop = max(0, entries.count - scanLimit)
            while index >= stop, entries[index].id >= lowest {
                let entry = entries[index]
                if entry.kind == .log, entry.processName == nil,
                   let assignment = assignments[entry.pid], entry.id >= assignment.firstSeq {
                    entries[index].processName = assignment.name
                    changed += 1
                }
                index -= 1
            }
            return changed
        }
    }

    public struct Stats: Sendable, Equatable {
        public var running: Int
        public var pending: Int
        public var unresolvable: Int
    }

    /// `fromEvent` bindings come from an authoritative process-start event at `since`; the others from
    /// the `ps` request that started at `since`.
    private struct Binding: Sendable {
        var name: String
        var since: Int
        var fromEvent: Bool

        /// Whether a `ps` request that started at `start` saw this process's current state. A snapshot
        /// binding is superseded by any later request, even one that started at the same sequence
        /// number (nothing was ingested in between). An event at or after `start` may postdate what
        /// `ps` read, so the request cannot speak for it.
        func isSuperseded(byLookupStartingAt start: Int) -> Bool {
            fromEvent ? since < start : since <= start
        }
    }

    /// What `ps` shows for a process that was forked from a zygote (or taken from its pre-forked pool)
    /// and has not renamed itself to the app yet. Seen in a snapshot, such a name says nothing about
    /// which app the pid will be.
    static let forkNames: Set<String> = [
        "zygote", "zygote32", "zygote64", "webview_zygote", "usap32", "usap64", "<pre-initialized>",
    ]

    private struct Pending: Sendable { var oldest: Int; var newest: Int; var strikes: Int }
    private struct Dead: Sendable { var strikes: Int; var retryAt: Double }

    private var running: [Int32: Binding] = [:]
    private var pending: [Int32: Pending] = [:]
    private var dead: [Int32: Dead] = [:]
    /// Pids that one snapshot showed under a `forkNames` name. They stay unnamed until a later snapshot
    /// shows the pid again: the same name means it really is a zygote, another name is the app.
    private var tentative: Set<Int32> = []
    /// Set while a tentative pid has waiting entries that no new entry will prompt a lookup for.
    private var tentativeRetry = false
    private var lastLookupStart: Int?
    private var newestPendingSeq: Int?
    private let retryDelays: [Double]

    /// `retryDelays` are the seconds to wait before looking again for a pid that `ps` did not list,
    /// indexed by how many times that has happened in a row (the last value repeats). The first retry is
    /// immediate so a reused pid is looked up straight away; the rest stop a live process that `ps`
    /// cannot see from being polled every few seconds forever.
    public init(retryDelays: [Double] = [0, 5, 30, 120, 300]) {
        precondition(!retryDelays.isEmpty)
        self.retryDelays = retryDelays
    }

    public var stats: Stats { Stats(running: running.count, pending: pending.count, unresolvable: dead.count) }

    /// Whether another `ps` could name a waiting entry: one arrived after the last lookup started, or a
    /// pid is waiting for a second look at its zygote name. The owner spaces lookups out (the session
    /// throttles to 1.5 s), which is what gives a forked process time to rename itself.
    public var needsLookup: Bool {
        if tentativeRetry { return true }
        guard let newestPendingSeq else { return false }
        guard let lastLookupStart else { return true }
        return newestPendingSeq >= lastLookupStart
    }

    /// The name for an entry of `pid` ingested at `seq`, or nil if it is not known yet (the pid then
    /// waits for the next lookup) or the pid is unresolvable.
    public mutating func name(forPid pid: Int32, seq: Int, now: Double) -> String? {
        if let binding = running[pid] { return binding.name }
        if var waiting = pending[pid] {
            waiting.newest = seq
            pending[pid] = waiting
        } else {
            var strikes = 0
            if let gone = dead[pid] {
                guard now >= gone.retryAt else { return nil }
                strikes = gone.strikes
                dead[pid] = nil
            }
            pending[pid] = Pending(oldest: seq, newest: seq, strikes: strikes)
        }
        newestPendingSeq = max(newestPendingSeq ?? seq, seq)
        return nil
    }

    /// Stamps `entry.processName` when its process is known. Skips markers, pid 0 and named entries.
    public mutating func stamp(_ entry: inout LogEntry, now: Double) {
        guard entry.kind == .log, entry.processName == nil, entry.pid > 0 else { return }
        entry.processName = name(forPid: entry.pid, seq: entry.id, now: now)
    }

    /// Call when a `ps` request starts. `seq` is the sequence number the next ingested entry will get.
    public mutating func beginLookup(seq: Int) -> Lookup {
        let lookup = Lookup(startSeq: seq, previousStartSeq: lastLookupStart, hadTentativeRetry: tentativeRetry)
        lastLookupStart = seq
        tentativeRetry = false
        return lookup
    }

    /// Call when a lookup failed, so the pids it covered still count as needing one.
    public mutating func cancelLookup(_ lookup: Lookup) {
        if lastLookupStart == lookup.startSeq { lastLookupStart = lookup.previousStartSeq }
        if lookup.hadTentativeRetry { tentativeRetry = true }
    }

    /// Applies a complete pid -> name snapshot taken by `lookup`. The snapshot is authoritative for
    /// running pids, except names from process-start events newer than the request.
    public mutating func applySnapshot(_ names: [Int32: String], from lookup: Lookup, now: Double) -> Update {
        let start = lookup.startSeq
        for (pid, binding) in running where names[pid] == nil && binding.isSuperseded(byLookupStartingAt: start) {
            running[pid] = nil
        }
        tentative = tentative.filter { names[$0] != nil }
        var update = Update()
        for (pid, name) in names {
            if let binding = running[pid], !binding.isSuperseded(byLookupStartingAt: start) { continue }
            // ps caught the process before it renamed itself; the start event already named it.
            if Self.forkNames.contains(name), running[pid]?.fromEvent == true { continue }
            if Self.forkNames.contains(name), !(tentative.contains(pid) || running[pid]?.name == name) {
                // First sighting under a zygote name: wait for a second look instead of trusting it.
                running[pid] = nil
                tentative.insert(pid)
                dead[pid] = nil
                continue
            }
            running[pid] = Binding(name: name, since: start, fromEvent: false)
            tentative.remove(pid)
            dead[pid] = nil
            if let waiting = pending.removeValue(forKey: pid) {
                update.assignments[pid] = Assignment(name: name, firstSeq: waiting.oldest)
            }
        }
        // Entries ingested before the request started were written by processes that already existed
        // when `ps` ran, so a pid missing from the snapshot had exited. Newer entries might come from a
        // process that started after `ps` read /proc; they wait for the next snapshot.
        for (pid, waiting) in pending where waiting.newest < start && !tentative.contains(pid) {
            pending[pid] = nil
            let strikes = waiting.strikes + 1
            dead[pid] = Dead(strikes: strikes, retryAt: now + retryDelays[min(strikes, retryDelays.count) - 1])
        }
        newestPendingSeq = pending.values.map(\.newest).max()
        tentativeRetry = tentative.contains { pending[$0] != nil }
        return update
    }

    /// An authoritative process start (ActivityManager `Start proc`). Names the pid from `seq` on and fills
    /// in its waiting entries, so a process that exits before any `ps` still has a name.
    public mutating func processStarted(pid: Int32, name: String, seq: Int) -> Update {
        running[pid] = Binding(name: name, since: seq, fromEvent: true)
        tentative.remove(pid)
        dead[pid] = nil
        var update = Update()
        if let waiting = pending.removeValue(forKey: pid) {
            update.assignments[pid] = Assignment(name: name, firstSeq: waiting.oldest)
            newestPendingSeq = pending.values.map(\.newest).max()
            tentativeRetry = tentative.contains { pending[$0] != nil }
        }
        return update
    }

    /// An authoritative process death (ActivityManager `has died` / `Killing`, issue #15). Later entries
    /// for the pid wait for a new name instead of reusing this one.
    public mutating func processEnded(pid: Int32, seq: Int) {
        if let binding = running[pid], binding.since <= seq { running[pid] = nil }
    }
}
