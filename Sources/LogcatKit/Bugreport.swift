import Foundation

/// Which logcat buffer a bug report section holds. Other files have only `.main`.
public enum LogFileSection: String, Sendable, CaseIterable {
    /// The `SYSTEM LOG`: main, system and crash together, as dumpstate prints them.
    case main
    case events
    case radio

    /// Appended to the title of the extra sessions: nil, "Events", "Radio".
    public var title: String? {
        switch self {
        case .main: nil
        case .events: "Events"
        case .radio: "Radio"
        }
    }
}

/// Reads the text of a bug report (dumpstate) line by line. Android Studio reads only the SYSTEM LOG sections;
/// this also keeps EVENT LOG and RADIO LOG apart, takes the year from the dumpstate time, and reads the device's
/// properties and process names, so a report opens with a device name and package names where it can.
struct BugreportParser {
    private enum Mode {
        case header
        case log(LogFileSection)
        case properties
        case other
    }

    /// An entry as dumpstate may print it twice. Time, ids, tag and message are what logcat itself prints.
    private struct Key: Hashable {
        let milliseconds: Int64
        let pid: Int32
        let tid: Int32
        let tag: String
        let message: String

        init(_ entry: LogEntry) {
            milliseconds = LogcatTime.milliseconds(entry.timestamp)
            pid = entry.pid
            tid = entry.tid
            tag = entry.tag
            message = entry.message
        }
    }

    /// The keys of the most recent entries, oldest dropped first.
    private struct KeyRing {
        static let capacity = 4096
        private var counts: [Key: Int] = [:]
        private var order: [Key] = []
        private var oldest = 0

        func contains(_ key: Key) -> Bool { counts[key] != nil }

        mutating func insert(_ key: Key) {
            if order.count < Self.capacity {
                order.append(key)
            } else {
                let evicted = order[oldest]
                if let count = counts[evicted], count > 1 { counts[evicted] = count - 1 } else { counts[evicted] = nil }
                order[oldest] = key
                oldest = (oldest + 1) % Self.capacity
            }
            counts[key, default: 0] += 1
        }
    }

    /// What is kept per buffer. dumpstate prints SYSTEM LOG a second time at the end (`-T <time>`), and its first
    /// lines repeat the end of the first one, so later occurrences are checked against what was already emitted.
    private struct Buffer {
        var merger = RecordMerger()
        var ring = KeyRing()
        var occurrences = 0

        /// False for an entry of a repeated section that was already emitted.
        mutating func admit(_ entry: LogEntry) -> Bool {
            let key = Key(entry)
            if occurrences > 1, ring.contains(key) { return false }
            ring.insert(key)
            return true
        }
    }

    private static let processRecord = try! NSRegularExpression(pattern: #"ProcessRecord\{[0-9a-f]+ (\d+):([^/}\s]+)/"#)

    private var mode = Mode.header
    private var buffers: [LogFileSection: Buffer] = [:]
    private var propertyLines: [String] = []
    private var referenceDate: Date
    private var capturedAt: Date?
    private var build: String?
    private var fingerprint: String?
    private var headerApiLevel: Int?

    /// Valid after `finish`.
    private(set) var info = LogFileInfo()
    /// pid to the full name of an app process, from the `ProcessRecord{…}` lines dumpsys activity prints. Native
    /// daemons aren't listed there and stay `pid-N`. Valid after `finish`.
    private(set) var processNames: [Int32: String] = [:]

    /// `fallbackReference` supplies the year until (and unless) the dumpstate time says better.
    init(fallbackReference: Date) {
        referenceDate = fallbackReference
    }

    /// Feeds one line, without its newline. Entries it completes are appended to `output`.
    mutating func consume(_ line: String, into output: inout [LogFileSection: [LogEntry]]) {
        if line.hasPrefix("------ ") {
            consumeSectionLine(line, into: &output)
            return
        }
        switch mode {
        case let .log(section):
            consumeLogLine(line, section: section, into: &output)
        case .header:
            consumeHeaderLine(line)
        case .properties:
            propertyLines.append(line)
        case .other:
            consumeOtherLine(line)
        }
    }

    /// Call once, after the last line.
    mutating func finish(into output: inout [LogFileSection: [LogEntry]]) {
        endSection(into: &output)
        let properties = DeviceProperties.parse(propertyLines.joined(separator: "\n"))
        var info = properties.values.isEmpty ? LogFileInfo() : LogFileInfo(properties: properties)
        info.fingerprint = fingerprint
        info.build = build
        info.capturedAt = capturedAt
        if info.apiLevel == nil { info.apiLevel = headerApiLevel }
        self.info = info
    }

    /// For tests and anything holding the whole text.
    static func parse(_ text: String, fallbackReference: Date) -> (
        entries: [LogFileSection: [LogEntry]], info: LogFileInfo, processNames: [Int32: String]
    ) {
        var parser = BugreportParser(fallbackReference: fallbackReference)
        var output: [LogFileSection: [LogEntry]] = [:]
        text.enumerateLines { line, _ in
            parser.consume(line, into: &output)
        }
        parser.finish(into: &output)
        return (output, parser.info, parser.processNames)
    }

    // MARK: Sections

    /// `------ SYSTEM LOG (logcat …) ------` starts a section; `------ 0.6s was the duration of 'SYSTEM LOG' ------`
    /// ends one. Old reports have no end lines, so a start always ends the previous section too.
    private mutating func consumeSectionLine(_ line: String, into output: inout [LogFileSection: [LogEntry]]) {
        if line.contains(" was the duration of '") {
            endSection(into: &output)
            mode = .other
            return
        }
        guard line.hasSuffix(" ------") else {
            // Not a section line after all; a log message can't start like this, so it is some other text.
            if case let .log(section) = mode { consumeLogLine(line, section: section, into: &output) }
            return
        }
        endSection(into: &output)
        let title = line.dropFirst(7).dropLast(7)
        let name = title.range(of: " (").map { title[..<$0.lowerBound] } ?? title
        switch name {
        case "SYSTEM LOG": startLog(.main)
        case "EVENT LOG": startLog(.events)
        case "RADIO LOG": startLog(.radio)
        case "SYSTEM PROPERTIES": mode = .properties
        default: mode = .other
        }
    }

    private mutating func startLog(_ section: LogFileSection) {
        buffers[section, default: Buffer()].occurrences += 1
        mode = .log(section)
    }

    /// Hands over the record in progress, so that nothing merges across sections.
    private mutating func endSection(into output: inout [LogFileSection: [LogEntry]]) {
        if case let .log(section) = mode, let last = buffers[section]?.merger.flush() {
            emit(last, section: section, into: &output)
        }
    }

    // MARK: Lines

    private mutating func consumeLogLine(_ line: String, section: LogFileSection, into output: inout [LogFileSection: [LogEntry]]) {
        if line.hasPrefix("--------- ") {
            // "--------- beginning of main": the buffer changes, so the record in progress is complete.
            if let last = buffers[section]?.merger.flush() { emit(last, section: section, into: &output) }
            return
        }
        // "*** command … failed" and other noise. Android Studio throws on it; being lenient costs nothing.
        guard let entry = LogcatThreadtimeFormat.parseLine(Substring(line), referenceDate: referenceDate) else { return }
        if let finished = buffers[section]?.merger.add(entry) { emit(finished, section: section, into: &output) }
    }

    private mutating func emit(_ entry: LogEntry, section: LogFileSection, into output: inout [LogFileSection: [LogEntry]]) {
        // Mutated in place: copying a buffer would copy its 4,096 keys for every entry.
        guard buffers[section, default: Buffer()].admit(entry) else { return }
        output[section, default: []].append(entry)
    }

    private mutating func consumeHeaderLine(_ line: String) {
        if line.hasPrefix("== dumpstate: ") {
            let parts = line.dropFirst(14).split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let time = LogcatTime.parse(date: parts[0], time: parts[1] + ".000") {
                capturedAt = Date(timeIntervalSince1970: time)
                referenceDate = Date(timeIntervalSince1970: time)
            }
        } else if line.hasPrefix("Build fingerprint: ") {
            fingerprint = line.dropFirst(19).trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        } else if line.hasPrefix("Build: ") {
            build = String(line.dropFirst(7))
        } else if line.hasPrefix("Android SDK version: ") {
            headerApiLevel = Int(line.dropFirst(21).trimmingCharacters(in: .whitespaces))
        }
    }

    private mutating func consumeOtherLine(_ line: String) {
        guard line.contains("ProcessRecord{") else { return }
        let range = NSRange(line.startIndex..., in: line)
        for match in Self.processRecord.matches(in: line, range: range) {
            guard let pidRange = Range(match.range(at: 1), in: line), let nameRange = Range(match.range(at: 2), in: line),
                  let pid = Int32(line[pidRange])
            else { continue }
            processNames[pid] = String(line[nameRange])
        }
    }
}

/// Bug report zips from `adb bugreport`. The logs are in a `bugreport-*.txt` entry, which `main_entry.txt` names.
/// Uses `/usr/bin/unzip`, which ships with macOS, so there is no zip code to maintain here.
enum BugreportArchive {
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")

    /// Extracts the report text into `directory` and returns its URL. Throws `CancellationError` when the task is
    /// cancelled, after stopping `unzip`.
    static func extractReport(from zip: URL, to directory: URL) async throws -> URL {
        let entry = try await reportEntry(in: zip)
        // A zip chooses its own entry names. Only the last component goes on disk, so a hostile `main_entry.txt`
        // can't write outside `directory`.
        let destination = directory.appendingPathComponent((entry as NSString).lastPathComponent)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LogFileError.unzipFailed("couldn't create \(destination.lastPathComponent)")
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let sink = OutputSink(file: file)
        let result = try await run(["-p", zip.path, escapedAsPattern(entry)], sink: sink)
        if let error = sink.writeError { throw LogFileError.unzipFailed(error.localizedDescription) }
        guard result.status == 0 else { throw LogFileError.unzipFailed(failureText(result)) }
        return destination
    }

    /// The entry holding the report: the one `main_entry.txt` names, else the first top-level `bugreport-*.txt`,
    /// which is Android Studio's rule.
    private static func reportEntry(in zip: URL) async throws -> String {
        let probe = OutputSink()
        let named = try await run(["-p", zip.path, "main_entry.txt"], sink: probe)
        // Exit 11 is "no matching entry"; any other failure shows up again when the entries are listed.
        if named.status == 0 {
            let name = String(decoding: probe.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // A leading "-" would read as an option.
            if !name.isEmpty, !name.hasPrefix("-") { return name }
        }
        let listing = OutputSink()
        let listed = try await run(["-Z1", zip.path], sink: listing)
        guard listed.status == 0 else { throw LogFileError.unzipFailed(failureText(listed)) }
        let found = String(decoding: listing.data, as: UTF8.self).split(whereSeparator: \.isNewline).first {
            !$0.contains("/") && $0.hasPrefix("bugreport-") && $0.hasSuffix(".txt")
        }
        guard let found else { throw LogFileError.noBugreport(zip.lastPathComponent) }
        return String(found)
    }

    /// unzip reads its file arguments as patterns; `[`, `*` and `?` in an entry name must match themselves.
    private static func escapedAsPattern(_ name: String) -> String {
        name.map { character -> String in
            switch character {
            case "[": "[[]"
            case "*": "[*]"
            case "?": "[?]"
            default: String(character)
            }
        }.joined()
    }

    private static func failureText(_ result: (status: Int32, stderr: String)) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "unzip exited with status \(result.status)" : text
    }

    private static func run(_ arguments: [String], sink: OutputSink) async throws -> (status: Int32, stderr: String) {
        try Task.checkCancellation()
        let process = StreamingProcess(executable: unzip, arguments: arguments, stopsWithParent: true)
        let result: (status: Int32, stderr: String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.start(
                        onData: { sink.write($0) },
                        onExit: { status, stderr in continuation.resume(returning: (status, stderr)) }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        return result
    }

    /// Where `unzip`'s stdout goes: a file for the report, memory for the small probes. `StreamingProcess` calls
    /// `onData` on a background queue, so the lock orders those writes against the read after the process exits.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private let file: FileHandle?
        private var buffer = Data()
        private var failure: Error?

        init(file: FileHandle? = nil) {
            self.file = file
        }

        func write(_ data: Data) {
            lock.withLock {
                guard let file else {
                    buffer.append(data)
                    return
                }
                guard failure == nil else { return }
                do { try file.write(contentsOf: data) } catch { failure = error }
            }
        }

        var data: Data { lock.withLock { buffer } }
        var writeError: Error? { lock.withLock { failure } }
    }
}
