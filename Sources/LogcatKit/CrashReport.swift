import Foundation

/// What a crash report says about the device. The serial is left out on purpose: reports get pasted into
/// public issues, and the serial identifies the user's phone without helping anyone fix the crash.
public struct DeviceInfo: Sendable, Hashable {
    public var manufacturer: String?
    public var model: String?
    public var release: String?
    public var apiLevel: Int?
    public var fingerprint: String?

    public init(manufacturer: String? = nil, model: String? = nil, release: String? = nil, apiLevel: Int? = nil, fingerprint: String? = nil) {
        self.manufacturer = manufacturer
        self.model = model
        self.release = release
        self.apiLevel = apiLevel
        self.fingerprint = fingerprint
    }

    public init(properties: DeviceProperties) {
        self.init(
            manufacturer: properties.manufacturer, model: properties.model, release: properties.release,
            apiLevel: properties.apiLevel, fingerprint: properties.fingerprint
        )
    }

    /// `Google Pixel 8, Android 14 (API 34)`. The manufacturer is dropped when the model already starts with
    /// it (`samsung` / `Samsung Galaxy`).
    public var displayText: String? {
        var name = model
        if let manufacturer, !manufacturer.isEmpty {
            let capitalized = manufacturer.prefix(1).uppercased() + manufacturer.dropFirst()
            if let model, !model.isEmpty {
                if !model.lowercased().hasPrefix(manufacturer.lowercased()) { name = "\(capitalized) \(model)" }
            } else {
                name = capitalized
            }
        }
        let android: String? = switch (release, apiLevel) {
        case let (release?, api?): "Android \(release) (API \(api))"
        case let (release?, nil): "Android \(release)"
        case let (nil, api?): "API \(api)"
        case (nil, nil): nil
        }
        let parts = [name, android].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A signal occurrence as Markdown for a GitHub issue: a heading, a table of what's known about the app and
/// device, and the log around it in a code block.
public struct CrashReport: Sendable {
    public var occurrence: SignalOccurrence
    /// Nil for log files, which don't say what device they came from.
    public var device: DeviceInfo?
    /// Shown as `Source` when there's no device, such as the log file's name.
    public var source: String?
    public var app: AppVersion?
    public var package: String?
    public var context: [LogEntry]

    public init(
        occurrence: SignalOccurrence, device: DeviceInfo? = nil, source: String? = nil, app: AppVersion? = nil,
        package: String? = nil, context: [LogEntry]
    ) {
        self.occurrence = occurrence
        self.device = device
        self.source = source
        self.app = app
        self.package = package ?? occurrence.package
        self.context = context
    }

    public func markdown(timeZone: TimeZone = .current) -> String {
        var rows: [(String, String)] = []
        if let package {
            rows.append(("App", [package, app?.displayText].compactMap { $0 }.joined(separator: " ")))
            if let targetSdk = app?.targetSdk { rows.append(("Target SDK", "\(targetSdk)")) }
            if let installer = app?.installerPackage { rows.append(("Installer", installer)) }
        }
        if let device {
            if let text = device.displayText { rows.append(("Device", text)) }
            if let fingerprint = device.fingerprint, !fingerprint.isEmpty { rows.append(("Build", fingerprint)) }
        } else if let source, !source.isEmpty {
            rows.append(("Source", source))
        }
        rows.append(("Time", LogcatTime.format(occurrence.timestamp, timeZone: timeZone)))

        var output = "### \(occurrence.kind.title): \(Self.codeSpan(occurrence.signature.displayText))\n"
        output += "| | |\n|---|---|\n"
        for (label, value) in rows {
            output += "| \(label) | \(Self.tableCell(value)) |\n"
        }
        let log = context.map { $0.formattedLine(timeZone: timeZone) }.joined(separator: "\n")
        let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: log) + 1))
        output += "\n\(fence)text\n\(log)\n\(fence)\n"
        return output
    }

    /// Up to `lines` entries from the app's pid before the anchor, then the anchor and its related entries.
    /// Native crashes and ANRs are reported by other processes (crash_dump, system_server), so the related
    /// entries are taken by id rather than by the anchor's pid, along with the entries between them that
    /// share a related entry's pid and tag. When another process reported the signal, the lines before it
    /// come from the app's pid as the report states it (`PID: N`, `pid: N`), or from the app's processes when
    /// process names are known. Walks back no further than the front of the buffer.
    ///
    /// `entries` holds the buffer with ids `firstID, firstID + 1, ...`.
    public static func contextEntries(
        for occurrence: SignalOccurrence, in entries: some RandomAccessCollection<LogEntry>, firstID: Int, lines: Int
    ) -> [LogEntry] {
        func entry(_ id: Int) -> LogEntry? {
            let offset = id - firstID
            guard offset >= 0, offset < entries.count else { return nil }
            return entries[entries.index(entries.startIndex, offsetBy: offset)]
        }
        guard let anchor = entry(occurrence.id) else { return [] }
        let package = occurrence.package
        let reportedPid = ([occurrence.id] + occurrence.relatedEntryIDs).lazy
            .compactMap { entry($0).flatMap { appPid(in: $0.message) } }.first
        let reportedBySystem = isReportedBySystem(anchor, kind: occurrence.kind, package: package, appPid: reportedPid)
        // System_server's and crash_dump's own earlier lines say nothing about the app, so a signal they
        // reported leads up with the app's lines instead. Without a pid in the report or process names (an
        // imported file), nothing before it can be tied to the app.
        let leadPid: Int32? = reportedBySystem ? reportedPid : anchor.pid
        func leadsUp(_ candidate: LogEntry) -> Bool {
            guard candidate.kind == .log else { return false }
            if candidate.pid == leadPid { return true }
            guard reportedBySystem, let package, let process = candidate.processName else { return false }
            return LogEntry.packageName(forProcess: process) == package
        }
        var preceding: [LogEntry] = []
        var id = occurrence.id - 1
        while preceding.count < lines, id >= firstID {
            if let candidate = entry(id), leadsUp(candidate) {
                preceding.append(candidate)
            }
            id -= 1
        }
        // Related entries are only the lines a rule matched. The rest of a tombstone (registers, abort message,
        // the frames after #00) comes from the same process and tag, so take those lines in the burst too.
        var burst: [LogEntry] = []
        if let last = occurrence.relatedEntryIDs.last {
            let related = Set(occurrence.relatedEntryIDs)
            var sources = Set([Source(anchor)])
            for id in occurrence.relatedEntryIDs {
                if let related = entry(id) { sources.insert(Source(related)) }
            }
            for id in (occurrence.id + 1)...last {
                guard let candidate = entry(id) else { continue }
                if related.contains(id) || (candidate.kind == .log && sources.contains(Source(candidate))) {
                    burst.append(candidate)
                }
            }
        }
        return preceding.reversed() + [anchor] + burst
    }

    /// Tags that only report on other processes. WindowManager also logs inside apps (leaked windows), so it
    /// counts only for ANRs.
    private static let systemReporterTags: Set<String> = ["ActivityManager", "InputDispatcher", "lmkd", "lowmemorykiller"]

    /// Whether another process logged `anchor` about the app. libc's and crash_dump's lines count when their
    /// pid isn't the one the report names; otherwise a known process name decides, and without one (imported
    /// files) the tag does.
    static func isReportedBySystem(_ anchor: LogEntry, kind: SignalKind, package: String?, appPid: Int32?) -> Bool {
        let nativeReporter = anchor.tag == "libc" || SignalRules.nativeCrashTags.contains(anchor.tag)
        if nativeReporter, let appPid { return appPid != anchor.pid }
        if let package, let process = anchor.processName {
            return LogEntry.packageName(forProcess: process) != package
        }
        if systemReporterTags.contains(anchor.tag) || (kind == .anr && anchor.tag == "WindowManager") { return true }
        // libc logs the fatal signal from inside the crashing process; DEBUG and crash_dump never do.
        return nativeReporter && anchor.tag != "libc"
    }

    /// The app's pid as a report line states it: `PID: 16110` (ActivityManager's ANR, AndroidRuntime's
    /// `Process:` line), `pid: 15020, tid: ...` (tombstone), `..., pid 15020 (com.example.app)` (libc) or
    /// `Kill 'com.example.app' (12345), ...` (lmkd).
    static func appPid(in message: String) -> Int32? {
        for line in message.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = line.drop { $0 == " " || $0 == "\t" }
            for marker in ["PID: ", "pid: "] where line.hasPrefix(marker) {
                if let pid = leadingPid(line.dropFirst(marker.count)) { return pid }
            }
            if line.hasPrefix("Process: "), let range = line.range(of: ", PID: ") {
                if let pid = leadingPid(line[range.upperBound...]) { return pid }
            }
            if line.hasPrefix("Fatal signal "), let range = line.range(of: ", pid ") {
                if let pid = leadingPid(line[range.upperBound...]) { return pid }
            }
            if line.hasPrefix("Kill '"), let range = line.range(of: "' (") {
                if let pid = leadingPid(line[range.upperBound...]) { return pid }
            }
        }
        return nil
    }

    private static func leadingPid(_ text: Substring) -> Int32? {
        Int32(text.prefix { $0.isASCII && $0.isNumber })
    }

    /// The signature as an inline code span, so `<init>`, `_` and `*` in class and method names show as
    /// written instead of turning into HTML or emphasis. The fence outgrows any backtick run inside it.
    static func codeSpan(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "\n", with: " ")
        let fence = String(repeating: "`", count: longestBacktickRun(in: text) + 1)
        // A span that starts or ends with a backtick needs a space so the fence isn't read as longer.
        let padding = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return fence + padding + text + padding + fence
    }

    private struct Source: Hashable {
        let pid: Int32
        let tag: String
        init(_ entry: LogEntry) {
            pid = entry.pid
            tag = entry.tag
        }
    }

    /// Pipes would end the cell and newlines the row.
    private static func tableCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text.utf8 {
            if character == UInt8(ascii: "`") {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
