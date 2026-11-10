import Foundation

/// Decodes the `adb track-jdwp` stream: each update is a 4-hex-digit length followed by that many bytes listing
/// the pids of debuggable processes, one per line. adb repeats a list that has not changed.
public struct JDWPTrackDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [Set<Int32>] {
        buffer.append(contentsOf: data)
        var lists: [Set<Int32>] = []
        while buffer.count >= 4 {
            guard let length = Int(String(decoding: buffer[0..<4], as: UTF8.self), radix: 16) else {
                // Out of sync; drop everything rather than misreading.
                buffer.removeAll()
                break
            }
            guard buffer.count >= 4 + length else { break }
            let payload = String(decoding: buffer[4..<(4 + length)], as: UTF8.self)
            buffer.removeFirst(4 + length)
            var pids: Set<Int32> = []
            for line in payload.split(whereSeparator: \.isNewline) {
                if let pid = Int32(line), pid > 0 { pids.insert(pid) }
            }
            lists.append(pids)
        }
        return lists
    }
}

/// Turns successive `track-jdwp` lists into added and removed pids. The first list only records what is
/// running, so a session that starts mid-run does not report every debuggable app as new.
public struct JDWPProcessSet: Sendable {
    public struct Change: Sendable, Equatable {
        public var added: [Int32] = []
        public var removed: [Int32] = []

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    public private(set) var pids: Set<Int32> = []
    private var hasBaseline = false

    public init() {}

    public mutating func apply(_ list: Set<Int32>) -> Change {
        defer {
            pids = list
            hasBaseline = true
        }
        guard hasBaseline else { return Change() }
        return Change(added: list.subtracting(pids).sorted(), removed: pids.subtracting(list).sorted())
    }
}

extension ADB {
    public enum JDWPEvent: Sendable {
        /// The pids of the debuggable processes running now.
        case pids(Set<Int32>)
        /// track-jdwp exited; the stream finishes after this.
        case ended(status: Int32, error: String)
    }

    /// Follows `adb -s <serial> track-jdwp`. Cancelling the consuming task stops it.
    ///
    /// It lists only debuggable processes (debug builds, and every app on an emulator image that allows it),
    /// and only their pids: names would need a JDWP handshake. Android Studio uses the same tracker to know
    /// when its app's process goes away.
    public func trackJDWP(serial: String) -> AsyncStream<JDWPEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let process = StreamingProcess(
                executable: executable, arguments: ["-s", serial, "track-jdwp"], stopsWithParent: true)
            let decoder = JDWPDecoderBox()
            do {
                try process.start(
                    onData: { data in
                        for list in decoder.feed(data) { continuation.yield(.pids(list)) }
                    },
                    onExit: { status, stderr in
                        continuation.yield(.ended(status: status, error: stderr))
                        continuation.finish()
                    }
                )
            } catch {
                continuation.yield(.ended(status: -1, error: "\(error)"))
                continuation.finish()
            }
            continuation.onTermination = { _ in process.terminate() }
        }
    }
}

/// Holds the decoder for a process's readability queue. The lock keeps the type honestly `Sendable`; only that
/// serial queue calls it.
private final class JDWPDecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = JDWPTrackDecoder()
    func feed(_ data: Data) -> [Set<Int32>] { lock.withLock { decoder.feed(data) } }
}
