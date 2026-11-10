import Foundation
import Testing
@testable import LogcatKit

/// Mimics what `LogSession` does with the resolver: stamp entries at ingestion, run lookups, apply snapshots.
private struct Harness {
    var resolver = ProcessNameResolver()
    var entries: [LogEntry] = []
    var now = 0.0

    @discardableResult
    mutating func log(_ pid: Int32) -> Int {
        var entry = LogEntry(id: entries.count, timestamp: 0, pid: pid, tid: pid, level: .info, tag: "T", message: "m")
        resolver.stamp(&entry, now: now)
        entries.append(entry)
        return entry.id
    }

    mutating func begin() -> ProcessNameResolver.Lookup {
        resolver.beginLookup(seq: entries.count)
    }

    mutating func finish(_ lookup: ProcessNameResolver.Lookup, _ names: [Int32: String]) {
        let update = resolver.applySnapshot(names, from: lookup, now: now)
        update.apply(to: &entries)
    }

    /// Starts and finishes a lookup with nothing logged in between.
    mutating func snapshot(_ names: [Int32: String]) {
        finish(begin(), names)
    }

    func name(_ id: Int) -> String? { entries[id].processName }
}

@Suite struct ProcessNameResolverTests {
    @Test func reusedPidResolvesToNewProcess() {
        var h = Harness()
        h.snapshot([1234: "com.a"])
        let a = h.log(1234)
        #expect(h.name(a) == "com.a")

        h.snapshot([:])
        #expect(h.resolver.stats.running == 0)
        let b = h.log(1234)
        #expect(h.name(b) == nil)
        #expect(h.resolver.needsLookup)

        h.snapshot([1234: "com.b"])
        #expect(h.name(b) == "com.b")
        #expect(h.name(a) == "com.a")
        let c = h.log(1234)
        #expect(h.name(c) == "com.b")
    }

    @Test func reusedPidRenamedBetweenSnapshots() {
        var h = Harness()
        h.snapshot([1234: "com.a"])
        let a = h.log(1234)
        h.snapshot([1234: "com.b"])
        let b = h.log(1234)
        #expect(h.name(a) == "com.a")
        #expect(h.name(b) == "com.b")
    }

    @Test func processThatLogsDuringLookupIsResolvedByNextSnapshot() {
        var h = Harness()
        let lookup = h.begin()
        let e1 = h.log(4321)
        h.finish(lookup, [:])
        #expect(h.name(e1) == nil)
        #expect(h.resolver.stats.unresolvable == 0)
        #expect(h.resolver.stats.pending == 1)
        #expect(h.resolver.needsLookup)

        h.snapshot([4321: "com.fast"])
        #expect(h.name(e1) == "com.fast")
        let e2 = h.log(4321)
        #expect(h.name(e2) == "com.fast")
    }

    @Test func exitedProcessIsMarkedUnresolvable() {
        var h = Harness()
        let e = h.log(777)
        h.snapshot([:])
        #expect(h.name(e) == nil)
        #expect(h.resolver.stats.unresolvable == 1)
        #expect(!h.resolver.needsLookup)
    }

    @Test func unresolvablePidIsLookedUpAgainWhenReused() {
        var h = Harness()
        let e = h.log(777)
        h.snapshot([:])
        #expect(h.resolver.stats.unresolvable == 1)

        let f = h.log(777)
        #expect(h.resolver.needsLookup)
        h.snapshot([777: "com.new"])
        #expect(h.name(f) == "com.new")
        // The entry from the dead incarnation is not renamed.
        #expect(h.name(e) == nil)
        #expect(h.resolver.stats.unresolvable == 0)
    }

    @Test func repeatedMissesBackOff() {
        var h = Harness()
        h.resolver = ProcessNameResolver(retryDelays: [0, 5])
        h.now = 0
        h.log(555)
        h.snapshot([:])

        h.now = 1
        h.log(555)
        #expect(h.resolver.needsLookup)
        h.snapshot([:])

        h.now = 2
        h.log(555)
        #expect(!h.resolver.needsLookup)
        #expect(h.resolver.stats.pending == 0)

        h.now = 7
        let late = h.log(555)
        #expect(h.resolver.needsLookup)
        h.snapshot([555: "com.late"])
        #expect(h.name(late) == "com.late")
    }

    @Test func snapshotPrunesExitedPids() {
        var h = Harness()
        h.snapshot([1: "a", 2: "b"])
        #expect(h.resolver.stats.running == 2)
        h.snapshot([2: "b"])
        #expect(h.resolver.stats.running == 1)
        let e = h.log(1)
        #expect(h.name(e) == nil)
    }

    @Test func backToBackSnapshotsWithNothingLoggedBetweenStillReplaceNames() {
        var h = Harness()
        h.snapshot([1: "com.a"])
        h.snapshot([1: "com.b"])
        let e = h.log(1)
        #expect(h.name(e) == "com.b")
    }

    @Test func forkedAppIsNotNamedAfterItsZygote() {
        // `ps` shows a freshly forked app under its zygote's name until it renames itself.
        var h = Harness()
        let lookup = h.begin()
        let e1 = h.log(500)
        h.finish(lookup, [500: "zygote64"])
        #expect(h.name(e1) == nil)
        #expect(h.resolver.stats.running == 0)
        #expect(h.resolver.stats.unresolvable == 0)
        #expect(h.resolver.needsLookup)

        let e2 = h.log(500)
        #expect(h.name(e2) == nil)
        h.snapshot([500: "com.app"])
        #expect(h.name(e1) == "com.app")
        #expect(h.name(e2) == "com.app")
        let e3 = h.log(500)
        #expect(h.name(e3) == "com.app")
    }

    @Test func zygoteNameIsTrustedOnceASecondSnapshotRepeatsIt() {
        var h = Harness()
        let e1 = h.log(384)
        h.snapshot([384: "zygote64"])
        #expect(h.name(e1) == nil)
        #expect(h.resolver.needsLookup)

        h.snapshot([384: "zygote64"])
        #expect(h.name(e1) == "zygote64")
        let e2 = h.log(384)
        #expect(h.name(e2) == "zygote64")
        #expect(!h.resolver.needsLookup)
    }

    @Test func reusedPidCaughtInForkWindowDropsOldName() {
        var h = Harness()
        h.snapshot([9: "com.a"])
        let a = h.log(9)
        h.snapshot([9: "zygote64"])
        #expect(h.resolver.stats.running == 0)
        let b = h.log(9)
        #expect(h.name(b) == nil)
        h.snapshot([9: "com.b"])
        #expect(h.name(a) == "com.a")
        #expect(h.name(b) == "com.b")
    }

    @Test func forkedProcessThatExitsBeforeRenamingIsMarkedUnresolvable() {
        var h = Harness()
        let e = h.log(500)
        h.snapshot([500: "zygote64"])
        h.snapshot([:])
        #expect(h.name(e) == nil)
        #expect(h.resolver.stats.unresolvable == 1)
        #expect(!h.resolver.needsLookup)
    }

    @Test func zygoteNameLookupIsRequestedOnceWithoutNewEntries() {
        var h = Harness()
        h.log(500)
        h.snapshot([500: "zygote64"])
        #expect(h.resolver.needsLookup)
        let lookup = h.begin()
        #expect(!h.resolver.needsLookup)
        h.resolver.cancelLookup(lookup)
        #expect(h.resolver.needsLookup)
    }

    @Test func cancelledLookupStillNeedsLookup() {
        var h = Harness()
        h.log(42)
        let lookup = h.begin()
        #expect(!h.resolver.needsLookup)
        h.resolver.cancelLookup(lookup)
        #expect(h.resolver.needsLookup)
    }

    @Test func processStartFillsWaitingEntriesAndSurvivesOlderSnapshot() {
        var h = Harness()
        let lookup = h.begin()
        let e = h.log(900)
        let update = h.resolver.processStarted(pid: 900, name: "com.x", seq: h.entries.count)
        update.apply(to: &h.entries)
        #expect(h.name(e) == "com.x")

        // The request started before the start event, so its snapshot cannot speak for pid 900.
        h.finish(lookup, [:])
        let f = h.log(900)
        #expect(h.name(f) == "com.x")

        // A request that started after the event is authoritative.
        h.snapshot([:])
        let g = h.log(900)
        #expect(h.name(g) == nil)
    }

    @Test func processEndDropsName() {
        var h = Harness()
        h.snapshot([5: "com.a"])
        h.resolver.processEnded(pid: 5, seq: h.entries.count)
        let e = h.log(5)
        #expect(h.name(e) == nil)
        #expect(h.resolver.needsLookup)
    }

    @Test func applySkipsMarkersNamedEntriesAndOlderSeqs() {
        func make(_ id: Int, pid: Int32, name: String? = nil) -> LogEntry {
            LogEntry(id: id, timestamp: 0, pid: pid, tid: pid, level: .info, tag: "T", message: "m", processName: name)
        }
        var marker = LogEntry.marker("restarted")
        marker.id = 1
        var entries = [make(0, pid: 7), marker, make(2, pid: 7, name: "file.proc"), make(3, pid: 7), make(4, pid: 8)]
        let update = ProcessNameResolver.Update(assignments: [7: .init(name: "com.n", firstSeq: 1)])
        #expect(update.apply(to: &entries) == 1)
        #expect(entries[0].processName == nil)
        #expect(entries[1].processName == nil)
        #expect(entries[2].processName == "file.proc")
        #expect(entries[3].processName == "com.n")
        #expect(entries[4].processName == nil)

        var short = [make(0, pid: 7), make(1, pid: 7), make(2, pid: 7)]
        let all = ProcessNameResolver.Update(assignments: [7: .init(name: "com.n", firstSeq: 0)])
        #expect(all.apply(to: &short, scanLimit: 2) == 2)
        #expect(short[0].processName == nil)
        #expect(short[1].processName == "com.n")
        #expect(short[2].processName == "com.n")
    }
}
