import Foundation
import Testing
@testable import LogcatKit

/// The fixture's entries with ids from `firstID`, as a session numbers them, and the app's process name on
/// entries logged by its uid, as the resolver would stamp it.
private func fixture(_ name: String, firstID: Int = 0) throws -> [LogEntry] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "logcat", subdirectory: "Fixtures"))
    let entries = LogcatLongParser.parse(try String(contentsOf: url, encoding: .utf8))
    return entries.enumerated().map { offset, entry in
        var entry = entry
        entry.id = firstID + offset
        if entry.uid == "10234" { entry.processName = "com.example.app" }
        return entry
    }
}

private func allFixtures() throws -> [LogEntry] {
    var entries: [LogEntry] = []
    for name in ["java-crash", "native-crash", "anr", "leaks", "performance"] {
        entries += try fixture(name, firstID: entries.count)
    }
    return entries
}

private func index(_ entries: [LogEntry]) -> SignalIndex {
    var index = SignalIndex()
    index.ingest(entries)
    return index
}

/// A fresh index over `entries`, for tests whose own `index` variable hides ``index(_:)``.
private func rebuild(_ entries: [LogEntry]) -> SignalIndex {
    index(entries)
}

private func entry(
    _ id: Int, at timestamp: Double, _ tag: String, _ level: LogLevel, _ message: String, pid: Int32 = 100
) -> LogEntry {
    LogEntry(id: id, timestamp: timestamp, pid: pid, tid: pid, level: level, tag: tag, message: message)
}

private let fatalSignal = "Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 101 (RenderThread), pid 100 (com.example.app)"
private let inputTimeout = "Window 4f2b1c9 com.example.app/com.example.app.MainActivity (server) is unresponsive: 4f2b1c9 com.example.app/com.example.app.MainActivity (server) is not responding. Waited 5001ms for KeyEvent"
private let anrReport = """
    ANR in com.example.app (com.example.app/.MainActivity)
    PID: 16110
    Reason: Input dispatching timed out (4f2b1c9 com.example.app/com.example.app.MainActivity (server) is not responding. Waited 5001ms for KeyEvent)
    """
private let fatalException = """
    FATAL EXCEPTION: main
    Process: com.example.app, PID: 100
    java.lang.IllegalStateException: boom
    \tat com.example.app.MainActivity.onCreate(MainActivity.kt:42)
    """

@Suite struct SignalIndexTests {
    @Test func identicalJavaCrashesGroup() throws {
        let index = index(try fixture("java-crash"))
        #expect(index.count(of: .crash) == 3)
        #expect(index.groups.count == 2)
        let repeated = try #require(index.groups.first { $0.count == 2 })
        #expect(repeated.signature.title == "java.lang.IllegalStateException")
        #expect(repeated.signature.detail == "ProfileRepository.requireProfile (ProfileRepository.kt:58)")
        #expect(repeated.lastTimestamp - repeated.firstTimestamp > 10)
        // Most recent first: the NullPointerException crashed last.
        #expect(index.groups.first?.signature.title == "java.lang.NullPointerException")
    }

    @Test func nativeCrashBurstIsOneOccurrence() throws {
        let entries = try fixture("native-crash")
        let index = index(entries)
        #expect(index.count(of: .nativeCrash) == 1)
        let occurrence = try #require(index.occurrences.first)
        #expect(entries.first { $0.id == occurrence.id }?.tag == "libc")
        #expect(occurrence.package == "com.example.app")
        #expect(occurrence.signature.title == "SIGSEGV (SEGV_MAPERR)")
        // The `#00 pc` line in the app's library, which arrives after the anchor.
        #expect(occurrence.signature.detail == "libnative.so (crashMe+20)")
        // The DEBUG header plus Cmdline, pid, signal and seven frames.
        #expect(occurrence.relatedEntryIDs.count == 11)
        #expect(index.groups.map(\.count) == [1])
    }

    @Test func tombstoneWithoutLibcLineTakesPackageFromPidLine() throws {
        let entries = try fixture("native-crash").filter { $0.tag != "libc" }
        let index = index(entries)
        let occurrence = try #require(index.occurrences.first)
        #expect(index.occurrences.count == 1)
        #expect(entries.first { $0.id == occurrence.id }?.tag == "DEBUG")
        #expect(occurrence.package == "com.example.app")
        #expect(occurrence.signature.detail == "libnative.so (crashMe+20)")
        // The group follows the signature as it's enriched; nothing is left under the bare header.
        #expect(index.groups.map(\.id) == [occurrence.signature.key])
    }

    @Test func anrBurstIsOneOccurrence() throws {
        let entries = try fixture("anr")
        let index = index(entries)
        #expect(index.count(of: .anr) == 1)
        let occurrence = try #require(index.occurrences.first)
        #expect(entries.first { $0.id == occurrence.id }?.tag == "InputDispatcher")
        #expect(occurrence.package == "com.example.app")
        #expect(occurrence.signature.title == "Input dispatching timed out")
        #expect(occurrence.relatedEntryIDs.count == 2)
        #expect(occurrence.anchorEntryIDs.map { (id: Int) in entries[id].tag } == ["InputDispatcher", "WindowManager", "ActivityManager"])
        #expect(index.fatalCount == 1)
    }

    @Test func allFixturesCountsAndGroups() throws {
        let index = index(try allFixtures())
        #expect(index.count(of: .crash) == 3)
        #expect(index.count(of: .nativeCrash) == 1)
        #expect(index.count(of: .anr) == 1)
        #expect(index.count(of: .leak) == 4)
        #expect(index.count(of: .outOfMemory) == 2)
        #expect(index.count(of: .performance) == 4)
        #expect(index.fatalCount == 5)
        #expect(index.groups.count == 14)
        #expect(index.occurrences.map(\.id) == index.occurrences.map(\.id).sorted())
        let summary = SignalSummary(index)
        #expect(summary.count(of: .leak) == 4)
        #expect(summary.fatalCount == 5)
        #expect(summary.groups == index.groups)
    }

    @Test func mergeWindowBoundary() {
        var index = SignalIndex()
        index.ingest([
            entry(0, at: 100, "libc", .assert, fatalSignal),
            entry(1, at: 111, "libc", .assert, fatalSignal),
            entry(2, at: 120, "libc", .assert, fatalSignal),
        ])
        // 11 s apart starts a new occurrence; 9 s after that joins it.
        #expect(index.occurrences.map(\.id) == [0, 1])
        #expect(index.occurrence(id: 1)?.relatedEntryIDs == [2])
        #expect(index.groups.map(\.count) == [2])
    }

    /// The ANR window is longer: the stack dump can take a while between the input timeout and `ANR in`.
    @Test func anrMergeWindow() {
        let index = index([
            entry(0, at: 100, "InputDispatcher", .warn, inputTimeout, pid: 1523),
            entry(1, at: 115, "ActivityManager", .error, anrReport, pid: 1523),
            entry(2, at: 200, "InputDispatcher", .warn, inputTimeout, pid: 1523),
            entry(3, at: 231, "ActivityManager", .error, anrReport, pid: 1523),
        ])
        // 15 s apart merges; 31 s apart doesn't.
        #expect(index.occurrences.map(\.id) == [0, 2, 3])
        #expect(index.occurrence(id: 0)?.anchorEntryIDs == [0, 1])
        #expect(index.count(of: .anr) == 3)
    }

    @Test func otherAppsDontMerge() {
        let other = fatalSignal.replacingOccurrences(of: "(com.example.app)", with: "(com.example.other)")
        let index = index([
            entry(0, at: 100, "libc", .assert, fatalSignal),
            entry(1, at: 101, "libc", .assert, other, pid: 200),
        ])
        #expect(index.occurrences.count == 2)
        #expect(index.groups.count == 2)
    }

    @Test func javaCrashesNeverMerge() {
        let index = index([
            entry(0, at: 100, "AndroidRuntime", .error, fatalException),
            entry(1, at: 101, "AndroidRuntime", .error, fatalException),
        ])
        #expect(index.count(of: .crash) == 2)
        #expect(index.groups.map(\.count) == [2])
    }

    @Test func detailWithoutOpenOccurrenceIsIgnored() {
        let index = index([entry(0, at: 100, "DEBUG", .assert, "    #00 pc 0000000000001a2c  /system/lib64/libc.so (abort+12)")])
        #expect(index.occurrences.isEmpty)
        #expect(index.generation == 0)
    }

    @Test func removeEntriesAcrossGroup() throws {
        let entries = try fixture("java-crash")
        var index = index(entries)
        let ids = index.occurrences.map(\.id)
        let generation = index.generation

        index.removeEntries(before: ids[0], remaining: entries[ids[0]...])
        #expect(index.generation == generation)

        index.removeEntries(before: ids[0] + 1, remaining: entries[(ids[0] + 1)...])
        #expect(index.occurrences.map(\.id) == Array(ids.dropFirst()))
        #expect(index.count(of: .crash) == 2)
        let repeated = try #require(index.groups.first { $0.signature.title == "java.lang.IllegalStateException" })
        #expect(repeated.occurrenceIDs == [ids[1]])
        #expect(repeated.firstTimestamp == index.occurrence(id: ids[1])?.timestamp)
        #expect(index.generation > generation)

        index.removeEntries(before: ids[2], remaining: entries[ids[2]...])
        #expect(index.groups.map(\.signature.title) == ["java.lang.NullPointerException"])
        index.removeEntries(before: entries.count, remaining: entries[entries.count...])
        #expect(index.occurrences.isEmpty)
        #expect(index.groups.isEmpty)
        #expect(index.count(of: .crash) == 0)
    }

    @Test func changesReportAnchors() throws {
        let entries = try fixture("anr")
        var index = SignalIndex()
        let added = index.ingest(entries)
        let anchors = try #require(index.occurrences.first?.anchorEntryIDs)
        #expect(added.addedAnchors == anchors.map { SignalAnchor(entryID: $0, kind: .anr) })
        #expect(added.removedAnchors.isEmpty && added.promotions.isEmpty)
        #expect(index.ingest(entries).isEmpty)

        let removed = index.removeEntries(before: entries.count, remaining: entries[entries.count...])
        #expect(removed.removedAnchors == added.addedAnchors)
        #expect(removed.addedAnchors.isEmpty && removed.promotions.isEmpty)
    }

    /// A trim that takes the InputDispatcher line leaves WindowManager's and ActivityManager's reports, so the
    /// ANR is still there, now anchored where a rebuild over what's left would anchor it.
    @Test func trimThroughANRBurstPromotesNextAnchor() throws {
        let entries = try fixture("anr")
        var index = index(entries)
        let anchors = try #require(index.occurrences.first?.anchorEntryIDs)
        let generation = index.generation
        let cut = anchors[0] + 1
        let changes = index.removeEntries(before: cut, remaining: entries[cut...])

        #expect(changes.removedAnchors == [SignalAnchor(entryID: anchors[0], kind: .anr)])
        #expect(changes.promotions == [SignalPromotion(from: anchors[0], to: anchors[1])])
        #expect(index.generation > generation)
        let rebuilt = rebuild(Array(entries[cut...]))
        #expect(index.occurrences == rebuilt.occurrences)
        #expect(index.groups == rebuilt.groups)
        #expect(index.occurrences.first?.signature.title == "Input dispatching timed out")
        #expect(index.count(of: .anr) == 1)
    }

    /// Every line of a burst finds its occurrence, under the new id after a trim promotes another anchor.
    @Test func occurrenceOfEntryFollowsPromotion() throws {
        let entries = try fixture("anr")
        var index = index(entries)
        let occurrence = try #require(index.occurrences.first)
        #expect(index.occurrenceID(forEntryID: occurrence.id) == occurrence.id)
        for id in occurrence.relatedEntryIDs + occurrence.anchorEntryIDs {
            #expect(index.occurrenceID(forEntryID: id) == occurrence.id)
        }
        #expect(index.occurrenceID(forEntryID: 0) == nil)

        let cut = occurrence.anchorEntryIDs[0] + 1
        index.removeEntries(before: cut, remaining: entries[cut...])
        let moved = try #require(index.occurrences.first)
        #expect(moved.id == occurrence.anchorEntryIDs[1])
        for id in [moved.id] + moved.relatedEntryIDs {
            #expect(index.occurrenceID(forEntryID: id) == moved.id)
        }
        #expect(index.occurrenceID(forEntryID: occurrence.id) == nil)

        index.reset()
        #expect(index.occurrenceID(forEntryID: moved.id) == nil)
    }

    @Test func trimThroughNativeBurstRebuildsSignature() throws {
        let entries = try fixture("native-crash")
        var index = index(entries)
        let anchors = try #require(index.occurrences.first?.anchorEntryIDs)
        #expect(anchors.map { entries[$0].tag } == ["libc", "DEBUG"])

        let cut = anchors[0] + 1
        index.removeEntries(before: cut, remaining: entries[cut...])
        let rebuilt = rebuild(Array(entries[cut...]))
        #expect(index.occurrences == rebuilt.occurrences)
        #expect(index.groups == rebuilt.groups)
        #expect(index.occurrences.first?.signature.detail == "libnative.so (crashMe+20)")

        // Past the last anchor only backtrace lines are left, which a rebuild ignores.
        let past = anchors[1] + 1
        let changes = index.removeEntries(before: past, remaining: entries[past...])
        #expect(changes.removedAnchors == [SignalAnchor(entryID: anchors[1], kind: .nativeCrash)])
        #expect(changes.promotions.isEmpty)
        #expect(index.occurrences.isEmpty && index.groups.isEmpty && index.count(of: .nativeCrash) == 0)
        #expect(rebuild(Array(entries[past...])).occurrences.isEmpty)
    }

    @Test func resetForgetsEverything() throws {
        let entries = try allFixtures()
        var index = index(entries)
        index.reset()
        #expect(index.occurrences.isEmpty && index.groups.isEmpty && index.fatalCount == 0)
        index.ingest(entries)
        #expect(index.occurrences.count == 15)
    }

    @Test func reingestingIsIgnored() throws {
        let entries = try fixture("anr")
        var index = index(entries)
        let generation = index.generation
        index.ingest(entries)
        #expect(index.generation == generation)
        #expect(index.occurrences.count == 1)
    }

    /// Random interleavings of the fixtures, retimed so bursts overlap the window in different ways, must give
    /// the same index whether ingested at once or in random chunks, and trimming anywhere, bursts included, must
    /// give what a rebuild over the surviving entries gives.
    @Test func chunkedIngestMatchesOneShot() throws {
        let pool = try allFixtures()
        var generator = SeededGenerator(seed: 75)
        var promotions = 0
        for _ in 0..<60 {
            var time = 1_000.0
            let entries = (0..<300).map { id -> LogEntry in
                var entry = pool.randomElement(using: &generator)!
                entry.id = id
                time += Double.random(in: 0...4, using: &generator)
                entry.timestamp = time
                return entry
            }
            let whole = index(entries)

            var chunked = SignalIndex()
            var reference = SignalIndex()
            var anchors = Set<SignalAnchor>()
            var position = 0
            var firstID = 0
            while position < entries.count {
                let end = min(entries.count, position + Int.random(in: 1...40, using: &generator))
                anchors.formUnion(chunked.ingest(entries[position..<end]).addedAnchors)
                reference.ingest(entries[position..<end])
                position = end
                // Trim before the next batch, as the session does, so later entries merge the same way.
                let cut = min(position, firstID + Int.random(in: 0...20, using: &generator))
                if Bool.random(using: &generator) {
                    firstID = cut
                    let changes = chunked.removeEntries(before: firstID, remaining: entries[firstID...])
                    anchors.subtract(changes.removedAnchors)
                    promotions += changes.promotions.count
                }
                try expectMatchesRebuild(chunked, Array(entries[firstID..<position]))
                let expectedAnchors = chunked.occurrences.flatMap { occurrence in
                    occurrence.anchorEntryIDs.map { SignalAnchor(entryID: $0, kind: occurrence.kind) }
                }
                #expect(anchors == Set(expectedAnchors))
            }
            #expect(reference.occurrences == whole.occurrences)
            #expect(Set(reference.groups) == Set(whole.groups))
        }
        #expect(promotions > 0)
    }

    private func expectMatchesRebuild(_ index: SignalIndex, _ survivors: [LogEntry]) throws {
        let rebuilt = rebuild(survivors)
        #expect(index.occurrences == rebuilt.occurrences)
        for kind in SignalKind.allCases {
            #expect(index.count(of: kind) == rebuilt.count(of: kind))
        }
        // A group keeps the newest signature among equal keys, which depends on arrival order.
        let shape = { (groups: [SignalGroup]) in
            groups.map { [$0.id, "\($0.occurrenceIDs)", "\($0.firstTimestamp)", "\($0.lastTimestamp)"] }
        }
        #expect(shape(index.groups) == shape(rebuilt.groups))
    }
}

/// SplitMix64, so the property test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
