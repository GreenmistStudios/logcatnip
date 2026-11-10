import Foundation

/// How far a read has got, for a progress bar.
public struct LogFileProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case extracting
        case reading
    }

    public var phase: Phase
    /// 0 to 1, or nil when unknown (while unzipping or decoding JSON).
    public var fraction: Double?

    public init(phase: Phase, fraction: Double?) {
        self.phase = phase
        self.fraction = fraction
    }
}

public enum LogFileEvent: Sendable {
    /// First event: what the file turned out to be.
    case format(LogFileFormat)
    /// `.logcat` files, before their entries.
    case metadata(LogcatFileMetadata)
    /// Bug reports, after their last entries: device, build and capture time.
    case info(LogFileInfo)
    /// Bug reports, after their last entries: pid to process name, from dumpsys.
    case processNames([Int32: String])
    case entries([LogEntry], section: LogFileSection)
    case progress(LogFileProgress)
}

public enum LogFileError: Error, LocalizedError, Equatable {
    case unrecognized(String)
    case noBugreport(String)
    case unzipFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unrecognized(name): "“\(name)” isn't a log file Logcatnip can read."
        case let .noBugreport(name): "“\(name)” has no bugreport-*.txt."
        case let .unzipFailed(message): "Couldn't unzip the bug report: \(message)"
        }
    }
}

/// Reads a saved log in chunks and hands it over piece by piece. The handler is awaited, so a busy consumer slows
/// reading down instead of letting entries pile up, and the UI stays responsive with files of hundreds of
/// megabytes. It does not hop threads itself: run it in a detached task, off the main actor.
public struct LogFileReader: Sendable {
    /// Bytes per read.
    public var chunkSize = 1 << 20
    /// Most entries per `.entries` event.
    public var batchSize = 10_000

    /// Files this big and zips show a progress bar and Cancel. Smaller ones load before anyone could use them.
    public static let progressThreshold: Int64 = 50_000_000

    public init() {}

    /// Throws `CancellationError` when the task is cancelled; what was handed over before stays valid.
    public func read(_ url: URL, handler: @Sendable (LogFileEvent) async -> Void) async throws {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        // Threadtime lines have no year; the file's date stands in, as it does for `LogFileImporter.load`.
        let referenceDate = values?.contentModificationDate ?? Date()

        let prefix: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            prefix = try handle.read(upToCount: LogFileFormat.sniffLength) ?? Data()
        }
        guard let format = LogFileFormat.detect(prefix: prefix, pathExtension: url.pathExtension) else {
            throw LogFileError.unrecognized(url.lastPathComponent)
        }
        await handler(.format(format))

        switch format {
        case .bugreportZip:
            await handler(.progress(LogFileProgress(phase: .extracting, fraction: nil)))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Logcatnip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let report = try await BugreportArchive.extractReport(from: url, to: directory)
            try await readText(report, format: .bugreport, referenceDate: referenceDate, handler: handler)
        case .logcatJSON:
            try await readJSON(url, handler: handler)
        case .threadtime, .long, .brief, .bugreport:
            try await readText(url, format: format, referenceDate: referenceDate, handler: handler)
        }
    }

    // MARK: JSON

    /// JSON can't be streamed with Foundation, and a `.logcat` file is bounded by Android Studio's buffer, so it
    /// is decoded in one piece. The entries still go out in batches, so the consumer stays responsive.
    private func readJSON(_ url: URL, handler: @Sendable (LogFileEvent) async -> Void) async throws {
        await handler(.progress(LogFileProgress(phase: .reading, fraction: nil)))
        let (metadata, entries) = try LogcatFile.decode(try Data(contentsOf: url))
        if let metadata { await handler(.metadata(metadata)) }
        var delivered = 0
        for start in stride(from: 0, to: entries.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(entries.count, start + batchSize)
            await handler(.entries(Array(entries[start..<end]), section: .main))
            delivered = end
            await handler(.progress(LogFileProgress(phase: .reading, fraction: Double(delivered) / Double(entries.count))))
        }
        if entries.isEmpty { await handler(.progress(LogFileProgress(phase: .reading, fraction: 1))) }
    }

    // MARK: Text

    private func readText(
        _ url: URL, format: LogFileFormat, referenceDate: Date, handler: @Sendable (LogFileEvent) async -> Void
    ) async throws {
        let size = Double(max(1, (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var parser = TextLogParser(format: format, referenceDate: referenceDate)
        var bytesRead = 0.0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            bytesRead += Double(chunk.count)
            await deliver(parser.feed(chunk), handler: handler)
            await handler(.progress(LogFileProgress(phase: .reading, fraction: min(1, bytesRead / size))))
        }
        await deliver(parser.finish(), handler: handler)
        await handler(.progress(LogFileProgress(phase: .reading, fraction: 1)))
        if format == .bugreport {
            await handler(.info(parser.info))
            if !parser.processNames.isEmpty { await handler(.processNames(parser.processNames)) }
        }
    }

    private func deliver(_ output: [LogFileSection: [LogEntry]], handler: @Sendable (LogFileEvent) async -> Void) async {
        for section in LogFileSection.allCases {
            guard let entries = output[section], !entries.isEmpty else { continue }
            for start in stride(from: 0, to: entries.count, by: batchSize) {
                await handler(.entries(Array(entries[start..<min(entries.count, start + batchSize)]), section: section))
            }
        }
    }
}

/// The parser for each text format, fed in chunks of bytes.
private struct TextLogParser {
    private let format: LogFileFormat
    private let referenceDate: Date
    private var long: LogcatLongParser
    private var splitter = LineSplitter()
    private var merger = RecordMerger()
    private var brief: BriefTextParser
    private var bugreport: BugreportParser

    /// Valid after `finish`, for bug reports.
    var info: LogFileInfo { bugreport.info }
    var processNames: [Int32: String] { bugreport.processNames }

    init(format: LogFileFormat, referenceDate: Date) {
        self.format = format
        self.referenceDate = referenceDate
        long = LogcatLongParser(referenceDate: referenceDate)
        brief = BriefTextParser(referenceDate: referenceDate)
        bugreport = BugreportParser(fallbackReference: referenceDate)
    }

    mutating func feed(_ chunk: Data) -> [LogFileSection: [LogEntry]] {
        var output: [LogFileSection: [LogEntry]] = [:]
        // The splitter's callbacks touch the other parsers, so work on a copy to keep the accesses disjoint.
        var splitter = self.splitter
        self.splitter = LineSplitter()
        defer { self.splitter = splitter }
        switch format {
        case .long:
            output[.main] = long.feed(chunk)
        case .threadtime:
            var main: [LogEntry] = []
            splitter.feed(chunk) { consumeThreadtime($0, into: &main) }
            output[.main] = main
        case .brief:
            var main: [LogEntry] = []
            splitter.feed(chunk) { if let entry = brief.consume(Substring($0)) { main.append(entry) } }
            output[.main] = main
        case .bugreport:
            splitter.feed(chunk) { bugreport.consume($0, into: &output) }
        case .logcatJSON, .bugreportZip:
            break
        }
        return output
    }

    mutating func finish() -> [LogFileSection: [LogEntry]] {
        var output: [LogFileSection: [LogEntry]] = [:]
        var splitter = self.splitter
        self.splitter = LineSplitter()
        defer { self.splitter = splitter }
        switch format {
        case .long:
            output[.main] = long.finish()
        case .threadtime:
            var main: [LogEntry] = []
            splitter.finish { consumeThreadtime($0, into: &main) }
            if let last = merger.flush() { main.append(last) }
            output[.main] = main
        case .brief:
            var main: [LogEntry] = []
            splitter.finish { if let entry = brief.consume(Substring($0)) { main.append(entry) } }
            if let last = brief.finish() { main.append(last) }
            output[.main] = main
        case .bugreport:
            splitter.finish { bugreport.consume($0, into: &output) }
            bugreport.finish(into: &output)
        case .logcatJSON, .bugreportZip:
            break
        }
        return output
    }

    private mutating func consumeThreadtime(_ line: String, into main: inout [LogEntry]) {
        if line.hasPrefix("--------- ") {
            // A buffer banner ends the record in progress.
            if let last = merger.flush() { main.append(last) }
            return
        }
        guard let entry = LogcatThreadtimeFormat.parseLine(Substring(line), referenceDate: referenceDate),
              let finished = merger.add(entry)
        else { return }
        main.append(finished)
    }
}
