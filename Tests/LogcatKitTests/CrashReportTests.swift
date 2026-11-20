import Foundation
import Testing
@testable import LogcatKit

/// The fixture's entries numbered from `firstID`, with the app's process name on entries logged by its uid
/// unless `processNames` is false, as for an imported file.
private func fixture(_ name: String, firstID: Int = 0, processNames: Bool = true) throws -> [LogEntry] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "logcat", subdirectory: "Fixtures"))
    let entries = LogcatLongParser.parse(try String(contentsOf: url, encoding: .utf8))
    return entries.enumerated().map { offset, entry in
        var entry = entry
        entry.id = firstID + offset
        if processNames, entry.uid == "10234" { entry.processName = "com.example.app" }
        return entry
    }
}

private func golden(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "report.md", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func occurrences(_ entries: [LogEntry]) -> [SignalOccurrence] {
    var index = SignalIndex()
    index.ingest(entries)
    return index.occurrences
}

private let utc = TimeZone(identifier: "UTC")!
private let pixel8 = DeviceInfo(
    manufacturer: "Google", model: "Pixel 8", release: "14", apiLevel: 34,
    fingerprint: "google/shiba/shiba:14/UQ1A.240205.004/11269751:user/release-keys"
)
private let appVersion = AppVersion(versionName: "1.2.3", versionCode: 10203, targetSdk: 34, installerPackage: "com.android.vending")

private func logEntry(_ id: Int, pid: Int32, _ tag: String, _ level: LogLevel, _ message: String) -> LogEntry {
    LogEntry(id: id, timestamp: 1_763_460_000 + Double(id), pid: pid, tid: pid, level: level, tag: tag, message: message, processName: "com.example.app")
}

@Suite struct CrashReportTests {
    @Test func javaCrashGolden() throws {
        let entries = try fixture("java-crash")
        let occurrence = try #require(occurrences(entries).first)
        let report = CrashReport(
            occurrence: occurrence, device: pixel8, app: appVersion,
            context: CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        )
        #expect(report.markdown(timeZone: utc) == (try golden("java-crash")))
    }

    @Test func nativeCrashGolden() throws {
        let entries = try fixture("native-crash")
        let occurrence = try #require(occurrences(entries).first)
        let report = CrashReport(
            occurrence: occurrence, device: pixel8, app: appVersion,
            context: CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        )
        #expect(report.markdown(timeZone: utc) == (try golden("native-crash")))
    }

    @Test func fenceOutgrowsBacktickRuns() throws {
        let entries = [
            logEntry(0, pid: 100, "Markdown", .debug, "rendering ```kotlin\nfun main() {}\n``` then ````"),
            logEntry(1, pid: 100, "AndroidRuntime", .error, "FATAL EXCEPTION: main\nProcess: com.example.app, PID: 100\njava.lang.IllegalStateException: boom\n\tat com.example.app.MainActivity.onCreate(MainActivity.kt:42)"),
        ]
        let occurrence = try #require(occurrences(entries).first)
        let markdown = CrashReport(
            occurrence: occurrence, context: CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 10)
        ).markdown(timeZone: utc)
        #expect(markdown.contains("\n`````text\n"))
        #expect(markdown.hasSuffix("\n`````\n"))
    }

    @Test func unknownValuesLeaveRowsOut() throws {
        let entries = try fixture("java-crash")
        let occurrence = try #require(occurrences(entries).first)
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 0)

        let partial = CrashReport(
            occurrence: occurrence, device: DeviceInfo(model: "sdk_gphone64_arm64", apiLevel: 35), context: context
        ).markdown(timeZone: utc)
        #expect(partial.contains("| App | com.example.app |\n"))
        #expect(partial.contains("| Device | sdk_gphone64_arm64, API 35 |\n"))
        #expect(!partial.contains("| Build |"))
        #expect(!partial.contains("| Target SDK |"))
        #expect(!partial.contains("| Installer |"))
        #expect(!partial.contains("| Source |"))

        let file = CrashReport(occurrence: occurrence, source: "crash.logcat", context: context).markdown(timeZone: utc)
        #expect(file.contains("| Source | crash.logcat |\n"))
        #expect(!file.contains("| Device |"))
        #expect(file.contains("| Time | 2025-11-18 10:02:01.405 |\n"))

        let empty = CrashReport(occurrence: occurrence, device: DeviceInfo(), context: context).markdown(timeZone: utc)
        #expect(!empty.contains("| Device |"))
        #expect(!empty.contains("| Source |"))
    }

    @Test func contextStopsAtLinesAndSkipsOtherPids() throws {
        var entries: [LogEntry] = []
        for id in 0..<10 {
            entries.append(logEntry(id, pid: id.isMultiple(of: 2) ? 100 : 200, "Worker", .debug, "step \(id)"))
        }
        entries.append(logEntry(10, pid: 100, "AndroidRuntime", .error, "FATAL EXCEPTION: main\nProcess: com.example.app, PID: 100\njava.lang.IllegalStateException: boom"))
        entries.append(logEntry(11, pid: 100, "Process", .info, "Sending signal. PID: 100 SIG: 9"))
        let occurrence = try #require(occurrences(entries).first)

        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 3)
        #expect(context.map(\.id) == [4, 6, 8, 10])

        // A trimmed buffer: ids start at 5, so the walk stops there.
        let trimmed = CrashReport.contextEntries(for: occurrence, in: entries[5...], firstID: 5, lines: 50)
        #expect(trimmed.map(\.id) == [6, 8, 10])

        #expect(CrashReport.contextEntries(for: occurrence, in: entries[11...], firstID: 11, lines: 50).isEmpty)
    }

    @Test func nativeContextKeepsTheTombstoneFromOtherPids() throws {
        let entries = try fixture("native-crash")
        let occurrence = try #require(occurrences(entries).first)
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        let pids = Set(context.map(\.pid))
        // The app (15020) and crash_dump (15102), but not tombstoned (642), which isn't part of the tombstone.
        #expect(pids == [15020, 15102])
        #expect(Set(occurrence.relatedEntryIDs).isSubset(of: Set(context.map(\.id))))
        #expect(context.contains { $0.message == "Cause: null pointer dereference" })
    }

    @Test func anrContextLeadsUpWithTheAppsLines() throws {
        let entries = try fixture("anr")
        let occurrence = try #require(occurrences(entries).first { $0.kind == .anr })
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        #expect(context.first?.message == "Loading feed from disk")
        #expect(context.contains { $0.tag == "ActivityManager" && $0.message.hasPrefix("ANR in") })
    }

    @Test func importedAnrLeadsUpWithTheReportedPid() throws {
        let entries = try fixture("anr", processNames: false)
        let occurrence = try #require(occurrences(entries).first { $0.kind == .anr })
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        #expect(context.first?.message == "Loading feed from disk")
        #expect(context.first?.pid == 16110)
    }

    @Test func importedJavaCrashLeadsUpWithTheAnchorPid() throws {
        let entries = try fixture("java-crash", processNames: false)
        let occurrence = try #require(occurrences(entries).first)
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        let anchorIndex = try #require(context.firstIndex { $0.id == occurrence.id })
        #expect(anchorIndex > 0)
        #expect(context[..<anchorIndex].allSatisfy { $0.pid == occurrence.pid })
    }

    @Test func importedNativeCrashLeadsUpWithTheTombstonePid() throws {
        // Without the libc line the tombstone header anchors the crash, logged by crash_dump's pid.
        let entries = try fixture("native-crash", processNames: false).map { entry in
            guard entry.tag == "libc" else { return entry }
            var entry = entry
            entry.tag = "NativeBridge"
            entry.level = .debug
            entry.message = "render: frame submitted"
            return entry
        }
        let occurrence = try #require(occurrences(entries).first)
        #expect(occurrence.pid == 15102)
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        let preceding = context.prefix { $0.id < occurrence.id }
        #expect(preceding.map(\.message) == ["render: surface 0x7a4c3f2e10 1080x2400", "render: frame submitted"])
    }

    @Test func importedLowMemoryKillLeadsUpWithTheKilledPid() throws {
        func entry(_ id: Int, pid: Int32, _ tag: String, _ level: LogLevel, _ message: String) -> LogEntry {
            LogEntry(id: id, timestamp: 1_763_460_000 + Double(id), pid: pid, tid: pid, level: level, tag: tag, message: message)
        }
        let entries = [
            entry(0, pid: 4100, "ImageCache", .debug, "decoded 24 bitmaps"),
            entry(1, pid: 512, "lmkd", .info, "Reclaiming memory"),
            entry(2, pid: 512, "lmkd", .info, "Kill 'com.example.app' (4100), uid 10234, oom_score_adj 900 to free 182340kB rss, 61224kB swap; reason: low watermark is breached"),
        ]
        let occurrence = try #require(occurrences(entries).first)
        #expect(occurrence.kind == .outOfMemory)
        let context = CrashReport.contextEntries(for: occurrence, in: entries, firstID: 0, lines: 50)
        #expect(context.map(\.id) == [0, 2])
    }

    @Test func appPidFromReportLines() {
        #expect(CrashReport.appPid(in: "ANR in com.example.app\nPID: 16110\nReason: Input dispatching timed out") == 16110)
        #expect(CrashReport.appPid(in: "FATAL EXCEPTION: main\nProcess: com.example.app, PID: 14211") == 14211)
        #expect(CrashReport.appPid(in: "pid: 15020, tid: 15051, name: RenderThread  >>> com.example.app <<<") == 15020)
        #expect(CrashReport.appPid(in: "Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 15051 (RenderThread), pid 15020 (com.example.app)") == 15020)
        #expect(CrashReport.appPid(in: "Kill 'com.example.app' (4100), uid 10234, oom_score_adj 900") == 4100)
        #expect(CrashReport.appPid(in: "Shutting down VM") == nil)
    }

    @Test func headingShowsTheSignatureAsCode() throws {
        let entries = [
            logEntry(0, pid: 100, "AndroidRuntime", .error, "FATAL EXCEPTION: main\nProcess: com.example.app, PID: 100\njava.lang.IllegalStateException: boom\n\tat com.example.app.Store_Impl.<init>(Store_Impl.kt:12)"),
        ]
        let occurrence = try #require(occurrences(entries).first)
        let heading = try #require(CrashReport(occurrence: occurrence, context: entries).markdown(timeZone: utc).split(separator: "\n").first)
        #expect(heading == "### Crash: `\(occurrence.signature.displayText)`")
        #expect(heading.contains("Store_Impl.<init>"))

        #expect(CrashReport.codeSpan("a_b <init>") == "`a_b <init>`")
        #expect(CrashReport.codeSpan("uses `x` here") == "``uses `x` here``")
        #expect(CrashReport.codeSpan("`edge`") == "`` `edge` ``")
    }

    @Test func deviceDisplayText() {
        #expect(pixel8.displayText == "Google Pixel 8, Android 14 (API 34)")
        #expect(DeviceInfo(manufacturer: "samsung", model: "SM-S918B", release: "14", apiLevel: 34).displayText == "Samsung SM-S918B, Android 14 (API 34)")
        #expect(DeviceInfo(manufacturer: "OnePlus", model: "OnePlus 12").displayText == "OnePlus 12")
        #expect(DeviceInfo().displayText == nil)
        let properties = DeviceProperties.parse("""
            [ro.build.fingerprint]: [google/shiba/shiba:14/UQ1A.240205.004/11269751:user/release-keys]
            [ro.build.version.release]: [14]
            [ro.build.version.sdk]: [34]
            [ro.product.manufacturer]: [Google]
            [ro.product.model]: [Pixel 8]
            """)
        #expect(DeviceInfo(properties: properties) == pixel8)
    }

    @Test func tableCellsEscapePipes() throws {
        let entries = try fixture("java-crash")
        let occurrence = try #require(occurrences(entries).first)
        let markdown = CrashReport(occurrence: occurrence, source: "a|b.logcat", context: []).markdown(timeZone: utc)
        #expect(markdown.contains("| Source | a\\|b.logcat |"))
    }
}

@Suite struct SignalIndexLookupTests {
    @Test func relatedEntriesFindTheirOccurrence() throws {
        let entries = try fixture("native-crash")
        var index = SignalIndex()
        index.ingest(entries)
        let occurrence = try #require(index.occurrences.first)
        #expect(index.occurrenceID(forEntryID: occurrence.id) == occurrence.id)
        for related in occurrence.relatedEntryIDs {
            #expect(index.occurrenceID(forEntryID: related) == occurrence.id)
        }
        // The NativeBridge line before the crash isn't part of it.
        #expect(index.occurrenceID(forEntryID: 0) == nil)

        // Trimming the libc line moves the crash to the tombstone header; its lines follow it.
        let lastRelated = try #require(occurrence.relatedEntryIDs.last)
        index.removeEntries(before: occurrence.id + 1, remaining: entries.filter { $0.id > occurrence.id })
        let promoted = try #require(index.occurrences.first)
        #expect(promoted.id > occurrence.id)
        #expect(index.occurrenceID(forEntryID: lastRelated) == promoted.id)
        #expect(index.occurrenceID(forEntryID: occurrence.id) == nil)

        // Trimming past the whole burst forgets its lines.
        index.removeEntries(before: lastRelated + 1, remaining: entries.filter { $0.id > lastRelated })
        #expect(index.occurrenceID(forEntryID: lastRelated) == nil)
    }

    @Test func occurrenceAtOrBefore() throws {
        let entries = try fixture("java-crash")
        var index = SignalIndex()
        index.ingest(entries)
        let crashes = index.occurrences
        #expect(crashes.count == 3)
        #expect(index.occurrence(atOrBefore: crashes[0].id - 1) == nil)
        #expect(index.occurrence(atOrBefore: crashes[0].id)?.id == crashes[0].id)
        #expect(index.occurrence(atOrBefore: crashes[1].id + 1)?.id == crashes[1].id)
        #expect(index.occurrence(atOrBefore: .max)?.id == crashes[2].id)
        #expect(index.occurrence(atOrBefore: .max, kinds: [.leak]) == nil)
    }
}
