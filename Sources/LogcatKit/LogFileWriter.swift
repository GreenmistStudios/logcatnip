import Foundation

/// What to save: a snapshot taken on the main actor. `entries` is the session buffer (copy-on-write, so taking it is
/// free); `onlyEntryIDs` are the ids of the table's rows when saving only what is visible.
public struct LogSaveRequest: Sendable {
    public var format: LogSaveFormat
    public var entries: [LogEntry]
    /// Row entry ids in row order. A multi-line entry has several rows with the same id; repeats are skipped.
    /// Nil saves every entry.
    public var onlyEntryIDs: [Int]?
    /// pid -> process name, for entries that arrived before their process was known.
    public var processNames: [Int32: String]
    /// Used by `.logcat` only.
    public var metadata: LogcatFileMetadata
    public var timeZone: TimeZone

    public init(
        format: LogSaveFormat, entries: [LogEntry], onlyEntryIDs: [Int]? = nil, processNames: [Int32: String] = [:],
        metadata: LogcatFileMetadata = LogcatFileMetadata(device: nil, filter: "", projectApplicationIds: []),
        timeZone: TimeZone = .current
    ) {
        self.format = format
        self.entries = entries
        self.onlyEntryIDs = onlyEntryIDs
        self.processNames = processNames
        self.metadata = metadata
        self.timeZone = timeZone
    }

    /// The entries to write, in order: the selection (if any), and no markers unless the format keeps them.
    public func selectedEntries() -> [LogEntry] {
        var selected: [LogEntry]
        if let ids = onlyEntryIDs {
            guard let first = entries.first else { return [] }
            selected = []
            selected.reserveCapacity(ids.count)
            var previous: Int?
            for id in ids where id != previous {
                previous = id
                // Ids are consecutive until something trims or clears the buffer, so the offset is usually exact.
                let guess = id - first.id
                if guess >= 0, guess < entries.count, entries[guess].id == id {
                    selected.append(entries[guess])
                } else if let index = index(ofEntry: id) {
                    selected.append(entries[index])
                }
            }
        } else {
            selected = entries
        }
        if !format.includesMarkers, selected.contains(where: { $0.kind == .marker }) {
            selected.removeAll { $0.kind == .marker }
        }
        return selected
    }

    func processName(for entry: LogEntry) -> String? {
        entry.processName ?? processNames[entry.pid]
    }

    /// Binary search: entries are sorted by id.
    private func index(ofEntry id: Int) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].id < id { low = mid + 1 } else { high = mid }
        }
        return low < entries.count && entries[low].id == id ? low : nil
    }

    /// A cheap estimate of the output size, to decide whether the save shows a progress bar. It only has to be about
    /// right, since the bar is shown for saves of tens of megabytes.
    public static func estimatedBytes(of entries: [LogEntry], format: LogSaveFormat) -> Int64 {
        var total = 0
        for entry in entries where entry.kind == .log || format.includesMarkers {
            let text = entry.message.utf8.count + entry.tag.utf8.count
            switch format {
            case .logcat:
                total += text + 330
            case .long:
                total += text + 40
            case .threadtime:
                var lines = 1
                for byte in entry.message.utf8 where byte == 0x0A { lines += 1 }
                total += text + 45 * lines
            case .plainText:
                total += text + 70
            }
        }
        return Int64(total)
    }
}

public enum LogSaveEvent: Sendable, Equatable {
    /// First event: the estimated size of the output.
    case estimated(bytes: Int64)
    /// 0…1 after each batch; 1 once the file is in place.
    case progress(Double)
}

public struct LogSaveResult: Sendable, Equatable {
    public var entries: Int
    public var bytes: Int64

    public init(entries: Int, bytes: Int64) {
        self.entries = entries
        self.bytes = bytes
    }
}

/// Writes a save request off the main actor a batch at a time. The handler is awaited after each batch, so progress
/// reaches the UI without flooding it. The output goes to a temporary file that replaces the destination only once
/// complete, so a cancelled or failed save leaves an existing file untouched. It does not hop threads itself: run it
/// in a detached task.
public struct LogFileWriter: Sendable {
    /// Entries per write and per progress event.
    public var batchSize = 2_000

    /// Saves estimated at this size or more show a progress bar and Cancel; the same threshold as opening.
    public static let progressThreshold = LogFileReader.progressThreshold

    public init() {}

    /// Throws `CancellationError` when the task is cancelled.
    @discardableResult
    public func write(
        _ request: LogSaveRequest, to url: URL, handler: @Sendable (LogSaveEvent) async -> Void = { _ in }
    ) async throws -> LogSaveResult {
        let selected = request.selectedEntries()
        await handler(.estimated(bytes: LogSaveRequest.estimatedBytes(of: selected, format: request.format)))

        let fileManager = FileManager.default
        // Next to the destination's volume, so that replacing it is an atomic rename rather than a copy.
        let temporaryDirectory = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let temporary = temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        var bytes: Int64 = 0
        func append(_ text: String) throws {
            let data = Data(text.utf8)
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
        }

        if request.format == .logcat { try append(LogcatFileWriter.opening(request.metadata)) }
        var start = 0
        while start < selected.count {
            try Task.checkCancellation()
            let end = min(start + max(1, batchSize), selected.count)
            try append(text(for: selected[start..<end], from: start, request: request))
            start = end
            await handler(.progress(Double(start) / Double(max(1, selected.count))))
        }
        if request.format == .logcat { try append(LogcatFileWriter.closing(hadMessages: !selected.isEmpty)) }

        try Task.checkCancellation()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        await handler(.progress(1))
        return LogSaveResult(entries: selected.count, bytes: bytes)
    }

    /// One batch as a single string, so each write is large. `offset` is the batch's first index in the whole
    /// selection, which tells the `.logcat` writer where the commas go.
    private func text(for batch: ArraySlice<LogEntry>, from offset: Int, request: LogSaveRequest) -> String {
        var output = ""
        switch request.format {
        case .logcat:
            for (index, entry) in zip(offset..., batch) {
                output += LogcatFileWriter.message(entry, processName: request.processName(for: entry), isFirst: index == 0)
            }
        case .long:
            for entry in batch { output += LogcatLongFormat.format(entry) }
        case .threadtime:
            for entry in batch { output += LogcatThreadtimeFormat.format(entry, timeZone: request.timeZone) }
        case .plainText:
            for entry in batch {
                output += LogPlainTextFormat.line(
                    for: entry, processName: request.processName(for: entry), timeZone: request.timeZone
                )
                output += "\n"
            }
        }
        return output
    }
}
