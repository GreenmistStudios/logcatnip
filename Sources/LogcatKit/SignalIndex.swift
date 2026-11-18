import Foundation

/// One crash, ANR, leak or warning: the entry that reported it and the entries that added detail.
public struct SignalOccurrence: Sendable, Hashable, Identifiable {
    /// The anchor entry's id. Occurrences are keyed by entries rather than rows, so they survive refilters.
    /// It changes when a front trim removes the anchor and a later anchor of the burst takes over.
    public internal(set) var id: Int
    public let kind: SignalKind
    /// The anchor entry's timestamp.
    public internal(set) var timestamp: Double
    /// The anchor entry's pid. For ANRs this is system_server's; use ``package`` for the app.
    public internal(set) var pid: Int32
    public internal(set) var signature: CrashSignature
    /// Later entries of the same burst (other anchors and enrichment lines), ascending. Capped at
    /// ``SignalIndex/maxRelatedEntries`` so a runaway tombstone can't grow it without bound.
    public internal(set) var relatedEntryIDs: [Int]
    /// The entries that matched an anchor rule, ascending: ``id`` first, then the burst's other reports (such
    /// as WindowManager's and ActivityManager's lines of an ANR), so a filter that hides one still shows another.
    /// Capped like ``relatedEntryIDs``.
    public internal(set) var anchorEntryIDs: [Int]
    /// When the occurrence last took an entry, so a burst that keeps logging stays open.
    var lastTimestamp: Double

    /// The app the signal is about, as far as the entries so far tell.
    public var package: String? { signature.package }
}

/// Occurrences with the same signature, so identical crashes show once with a count.
public struct SignalGroup: Sendable, Hashable, Identifiable {
    /// The signature's ``CrashSignature/key``.
    public let id: String
    public internal(set) var signature: CrashSignature
    /// Ascending occurrence ids.
    public internal(set) var occurrenceIDs: [Int]
    public internal(set) var firstTimestamp: Double
    public internal(set) var lastTimestamp: Double

    public var kind: SignalKind { signature.kind }
    public var count: Int { occurrenceIDs.count }
}

/// An entry that matched an anchor rule, with the kind of the occurrence it belongs to.
public struct SignalAnchor: Sendable, Hashable {
    public let entryID: Int
    public let kind: SignalKind
}

/// What one ``SignalIndex/ingest(_:rules:)`` or ``SignalIndex/removeEntries(before:remaining:rules:)`` changed
/// in the set of anchor entries, so callers can keep per-entry indexes in step without rescanning occurrences.
public struct SignalIndexChanges: Sendable, Equatable {
    /// Anchor entries that now belong to an occurrence, ascending.
    public internal(set) var addedAnchors: [SignalAnchor] = []
    /// Anchor entries trimmed with the front of the buffer, ascending.
    public internal(set) var removedAnchors: [SignalAnchor] = []
    /// Occurrences whose anchor was trimmed and that a surviving anchor of the same burst now stands for.
    public internal(set) var promotions: [SignalPromotion] = []

    public var isEmpty: Bool { addedAnchors.isEmpty && removedAnchors.isEmpty && promotions.isEmpty }
}

/// An occurrence id that changed because a front trim removed its anchor entry.
public struct SignalPromotion: Sendable, Hashable {
    public let from: Int
    public let to: Int
}

/// The signals in a session's buffer, maintained as entries are appended and trimmed from the front.
///
/// Native crashes and ANRs log a burst of several entries (libc's `Fatal signal` and the tombstone, or
/// InputDispatcher, WindowManager and ActivityManager), so entries of those kinds that arrive within
/// ``mergeWindow(for:)`` of the open occurrence for the same app join it instead of being counted again. Other
/// kinds report one problem per entry and are never merged, so repeated jank or leaks keep their count.
///
/// A front trim keeps an occurrence while any of its anchor entries survives, so the index matches one built
/// from scratch over the surviving entries. It can still differ when entries ingested after the surviving
/// anchor were merged (or not) using what the trimmed lines had told about the app, or when the burst went
/// past ``maxRelatedEntries``.
public struct SignalIndex: Sendable {
    public static let maxRelatedEntries = 200

    /// Seconds an occurrence of `kind` stays open after its latest entry, or nil for kinds that never merge.
    /// ANRs get longer because the stack dump can sit between the input timeout and ActivityManager's
    /// `ANR in`.
    public static func mergeWindow(for kind: SignalKind) -> Double? {
        switch kind {
        case .nativeCrash: 10
        case .anr: 30
        default: nil
        }
    }

    /// Ascending by id.
    public private(set) var occurrences: [SignalOccurrence] = []
    /// Bumped on every change, so observers can skip work when nothing changed.
    public private(set) var generation = 0
    private var groupsByKey: [String: SignalGroup] = [:]
    private var counts: [SignalKind: Int] = [:]
    /// The latest occurrence of each mergeable kind, by id.
    private var open: [SignalKind: Int] = [:]
    private var lastEntryID = -1
    /// Related entry id -> its occurrence's id, so a row of any line of a burst finds its occurrence.
    private var ownerOfRelated: [Int: Int] = [:]

    public init() {}

    /// Groups, most recent first.
    public var groups: [SignalGroup] {
        groupsByKey.values.sorted { lhs, rhs in
            lhs.occurrenceIDs.last ?? 0 > rhs.occurrenceIDs.last ?? 0
        }
    }

    public func count(of kind: SignalKind) -> Int {
        counts[kind] ?? 0
    }

    /// Crashes, native crashes and ANRs.
    public var fatalCount: Int {
        SignalKind.allCases.lazy.filter(\.isFatal).reduce(0) { $0 + count(of: $1) }
    }

    public func occurrence(id: Int) -> SignalOccurrence? {
        index(of: id).map { occurrences[$0] }
    }

    public func group(id: String) -> SignalGroup? {
        groupsByKey[id]
    }

    /// The occurrence an entry belongs to, as its anchor or one of its related entries.
    public func occurrenceID(forEntryID entryID: Int) -> Int? {
        if index(of: entryID) != nil { return entryID }
        return ownerOfRelated[entryID]
    }

    // MARK: - Updates

    /// Classifies entries appended to the buffer. Entries must come in ascending id order across calls;
    /// ids at or below the last one ingested are skipped, so feeding a batch twice changes nothing.
    @discardableResult
    public mutating func ingest<C: Collection>(
        _ entries: C, rules: SignalRuleSet = .default
    ) -> SignalIndexChanges where C.Element == LogEntry {
        var changes = SignalIndexChanges()
        var changed = false
        for entry in entries where entry.id > lastEntryID {
            lastEntryID = entry.id
            // The only work for the vast majority of entries.
            guard let match = rules.match(entry) else { continue }
            if apply(match, entry: entry, changes: &changes) { changed = true }
        }
        if changed { generation += 1 }
        return changes
    }

    /// Drops what was trimmed from the front of the buffer. An occurrence whose anchor went but another of
    /// whose anchor entries survived moves to the first survivor, as a rebuild would start it there, and its
    /// signature is rebuilt from `remaining` (the buffer from `firstID` on, ascending by id). Enrichment
    /// lines alone don't keep an occurrence: a rebuild would ignore them.
    @discardableResult
    public mutating func removeEntries<C: RandomAccessCollection>(
        before firstID: Int, remaining: C, rules: SignalRuleSet = .default
    ) -> SignalIndexChanges where C.Element == LogEntry {
        var changes = SignalIndexChanges()
        let end = lowerBound(firstID)
        guard end > 0 else { return changes }
        var promoted: [SignalOccurrence] = []
        for occurrence in occurrences[..<end] {
            let survivor = occurrence.anchorEntryIDs.firstIndex { $0 >= firstID } ?? occurrence.anchorEntryIDs.endIndex
            for id in occurrence.anchorEntryIDs[..<survivor] {
                changes.removedAnchors.append(SignalAnchor(entryID: id, kind: occurrence.kind))
            }
            for related in occurrence.relatedEntryIDs {
                ownerOfRelated[related] = nil
            }
            for anchor in occurrence.anchorEntryIDs.dropFirst() {
                ownerOfRelated[anchor] = nil
            }
            removeFromGroup(occurrence)
            if survivor < occurrence.anchorEntryIDs.endIndex,
               let moved = promote(occurrence, from: survivor, remaining: remaining, rules: rules) {
                changes.promotions.append(SignalPromotion(from: occurrence.id, to: moved.id))
                if open[occurrence.kind] == occurrence.id { open[occurrence.kind] = moved.id }
                // The surviving lines now belong to the occurrence under its new id.
                for related in moved.relatedEntryIDs {
                    ownerOfRelated[related] = moved.id
                }
                for anchor in moved.anchorEntryIDs.dropFirst() {
                    ownerOfRelated[anchor] = moved.id
                }
                promoted.append(moved)
            } else {
                counts[occurrence.kind, default: 0] -= 1
                if open[occurrence.kind] == occurrence.id { open[occurrence.kind] = nil }
            }
        }
        occurrences.removeFirst(end)
        // Rare: only bursts cut by the trim. Their new anchors can come after other occurrences.
        for occurrence in promoted {
            occurrences.insert(occurrence, at: lowerBound(occurrence.id))
            addToGroup(occurrence)
        }
        changes.removedAnchors.sort { $0.entryID < $1.entryID }
        generation += 1
        return changes
    }

    public mutating func reset() {
        occurrences.removeAll(keepingCapacity: true)
        groupsByKey.removeAll()
        counts.removeAll()
        open.removeAll()
        ownerOfRelated.removeAll()
        lastEntryID = -1
        generation += 1
    }

    /// The occurrence as a rebuild would make it from its anchor entry at `anchorIndex` on.
    private func promote<C: RandomAccessCollection>(
        _ occurrence: SignalOccurrence, from anchorIndex: Int, remaining: C, rules: SignalRuleSet
    ) -> SignalOccurrence? where C.Element == LogEntry {
        let anchorID = occurrence.anchorEntryIDs[anchorIndex]
        guard let anchor = Self.entry(anchorID, in: remaining), let match = rules.match(anchor),
              match.isAnchor, match.kind == occurrence.kind
        else { return nil }
        var moved = occurrence
        moved.id = anchorID
        moved.timestamp = anchor.timestamp
        moved.pid = anchor.pid
        moved.anchorEntryIDs.removeFirst(anchorIndex)
        moved.relatedEntryIDs.removeAll { $0 <= anchorID }
        moved.signature = CrashSignature.make(for: match, entry: anchor)
        for id in moved.relatedEntryIDs {
            if let entry = Self.entry(id, in: remaining) { moved.signature.enrich(with: entry) }
        }
        return moved
    }

    private static func entry<C: RandomAccessCollection>(_ id: Int, in entries: C) -> LogEntry?
    where C.Element == LogEntry {
        var low = entries.startIndex
        var high = entries.endIndex
        while low < high {
            let mid = entries.index(low, offsetBy: entries.distance(from: low, to: high) / 2)
            if entries[mid].id < id { low = entries.index(after: mid) } else { high = mid }
        }
        return low < entries.endIndex && entries[low].id == id ? entries[low] : nil
    }

    private mutating func apply(_ match: SignalMatch, entry: LogEntry, changes: inout SignalIndexChanges) -> Bool {
        let window = Self.mergeWindow(for: match.kind)
        if let window, let openID = open[match.kind], let position = index(of: openID),
           abs(entry.timestamp - occurrences[position].lastTimestamp) <= window {
            let candidate = match.isAnchor ? CrashSignature.make(for: match, entry: entry) : nil
            if !match.isAnchor || belongsTogether(occurrences[position], candidate!, entry: entry) {
                if attach(entry, isAnchor: match.isAnchor, to: position) {
                    changes.addedAnchors.append(SignalAnchor(entryID: entry.id, kind: match.kind))
                }
                return true
            }
        }
        // Detail lines without an occurrence to add to, such as a tombstone whose header was trimmed.
        guard match.isAnchor else { return false }
        let occurrence = SignalOccurrence(
            id: entry.id, kind: match.kind, timestamp: entry.timestamp, pid: entry.pid,
            signature: CrashSignature.make(for: match, entry: entry), relatedEntryIDs: [],
            anchorEntryIDs: [entry.id], lastTimestamp: entry.timestamp
        )
        occurrences.append(occurrence)
        counts[match.kind, default: 0] += 1
        addToGroup(occurrence)
        if window != nil { open[match.kind] = occurrence.id }
        changes.addedAnchors.append(SignalAnchor(entryID: entry.id, kind: match.kind))
        return true
    }

    /// Whether a second anchor reports the same burst. The tombstone header doesn't name the app until its
    /// `>>> pkg <<<` line, so a native crash with no package yet on either side still matches; ANRs carry
    /// the app in their signature because every ANR line comes from system_server.
    private func belongsTogether(_ occurrence: SignalOccurrence, _ signature: CrashSignature, entry: LogEntry) -> Bool {
        switch (occurrence.package, signature.package) {
        case let (lhs?, rhs?): lhs == rhs
        default: occurrence.kind == .nativeCrash || occurrence.pid == entry.pid
        }
    }

    /// Returns whether the entry was recorded as one of the occurrence's anchors.
    private mutating func attach(_ entry: LogEntry, isAnchor: Bool, to position: Int) -> Bool {
        let oldKey = occurrences[position].signature.key
        if occurrences[position].relatedEntryIDs.count < Self.maxRelatedEntries {
            occurrences[position].relatedEntryIDs.append(entry.id)
            ownerOfRelated[entry.id] = occurrences[position].id
        }
        let recordedAnchor = isAnchor && occurrences[position].anchorEntryIDs.count < Self.maxRelatedEntries
        if recordedAnchor {
            occurrences[position].anchorEntryIDs.append(entry.id)
            // Usually already set above; not when the related list is full.
            ownerOfRelated[entry.id] = occurrences[position].id
        }
        occurrences[position].lastTimestamp = entry.timestamp
        occurrences[position].signature.enrich(with: entry)
        let occurrence = occurrences[position]
        guard occurrence.signature.key != oldKey else {
            // Equal keys can still differ in how the detail was found, so keep the newest signature.
            groupsByKey[oldKey]?.signature = occurrence.signature
            return recordedAnchor
        }
        if var group = groupsByKey[oldKey] {
            group.occurrenceIDs.removeAll { $0 == occurrence.id }
            groupsByKey[oldKey] = group
            refreshBounds(of: oldKey)
        }
        addToGroup(occurrence)
        return recordedAnchor
    }

    private mutating func removeFromGroup(_ occurrence: SignalOccurrence) {
        let key = occurrence.signature.key
        guard var group = groupsByKey[key] else { return }
        // Trimmed occurrences are the oldest, so they usually lead their group.
        if group.occurrenceIDs.first == occurrence.id {
            group.occurrenceIDs.removeFirst()
        } else {
            group.occurrenceIDs.removeAll { $0 == occurrence.id }
        }
        guard let firstID = group.occurrenceIDs.first, let lastID = group.occurrenceIDs.last else {
            groupsByKey[key] = nil
            return
        }
        // The occurrences array still holds the trimmed ones here, so look the bounds up by id.
        groupsByKey[key] = group
        if let first = self.occurrence(id: firstID), let last = self.occurrence(id: lastID) {
            groupsByKey[key]?.firstTimestamp = first.timestamp
            groupsByKey[key]?.lastTimestamp = last.timestamp
        }
    }

    private mutating func addToGroup(_ occurrence: SignalOccurrence) {
        let key = occurrence.signature.key
        guard var group = groupsByKey[key] else {
            groupsByKey[key] = SignalGroup(
                id: key, signature: occurrence.signature, occurrenceIDs: [occurrence.id],
                firstTimestamp: occurrence.timestamp, lastTimestamp: occurrence.timestamp
            )
            return
        }
        // A re-keyed occurrence can be older than the group's newest one.
        let insertAt = group.occurrenceIDs.lastIndex { $0 < occurrence.id }.map { $0 + 1 } ?? 0
        group.occurrenceIDs.insert(occurrence.id, at: insertAt)
        group.signature = occurrence.signature
        groupsByKey[key] = group
        refreshBounds(of: key)
    }

    /// Recomputes a group's timestamps from its first and last occurrence, or drops it when it's empty.
    private mutating func refreshBounds(of key: String) {
        guard var group = groupsByKey[key] else { return }
        guard let firstID = group.occurrenceIDs.first, let lastID = group.occurrenceIDs.last,
              let first = occurrence(id: firstID), let last = occurrence(id: lastID)
        else {
            groupsByKey[key] = nil
            return
        }
        group.firstTimestamp = first.timestamp
        group.lastTimestamp = last.timestamp
        groupsByKey[key] = group
    }

    private func index(of id: Int) -> Int? {
        let index = lowerBound(id)
        return index < occurrences.count && occurrences[index].id == id ? index : nil
    }

    /// Index of the first occurrence whose id is `>= id`.
    private func lowerBound(_ id: Int) -> Int {
        var low = 0
        var high = occurrences.count
        while low < high {
            let mid = (low + high) / 2
            if occurrences[mid].id < id { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// What the UI shows about a session's signals, rebuilt only when the index changes, so observers
/// aren't invalidated on every flush.
public struct SignalSummary: Sendable, Equatable {
    public private(set) var counts: [SignalKind: Int] = [:]
    /// Most recent first.
    public private(set) var groups: [SignalGroup] = []

    public init() {}

    public init(_ index: SignalIndex) {
        for kind in SignalKind.allCases where index.count(of: kind) > 0 {
            counts[kind] = index.count(of: kind)
        }
        groups = index.groups
    }

    public func count(of kind: SignalKind) -> Int {
        counts[kind] ?? 0
    }

    public var fatalCount: Int {
        counts.reduce(0) { $0 + ($1.key.isFatal ? $1.value : 0) }
    }

    public var isEmpty: Bool { counts.isEmpty }

    /// Out of memory, leaks and jank.
    public var warningCount: Int {
        counts.reduce(0) { $0 + ($1.key.isFatal ? 0 : $1.value) }
    }

    /// `2 crashes · 1 ANR` for the status bar, or nil when nothing fatal happened. Native crashes count as
    /// crashes there: the popover tells them apart.
    public var fatalText: String? {
        let crashes = count(of: .crash) + count(of: .nativeCrash)
        let anrs = count(of: .anr)
        let parts = [
            crashes > 0 ? Self.plural(crashes, "crash", "crashes") : nil,
            anrs > 0 ? Self.plural(anrs, "ANR", "ANRs") : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `3 warnings`, or nil when there are none.
    public var warningText: String? {
        let count = warningCount
        return count > 0 ? Self.plural(count, "warning", "warnings") : nil
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}
