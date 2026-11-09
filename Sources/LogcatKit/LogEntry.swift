import Foundation

/// One logcat record.
public struct LogEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A record read from logcat.
        case log
        /// A marker the app inserts (device disconnected, logcat restarted, ...). Markers always pass filters.
        case marker
    }

    /// Monotonic sequence number within a session. Assigned by the owner of the buffer; parsers leave it at 0.
    public var id: Int
    public var kind: Kind
    /// Seconds since 1970 (device clock).
    public var timestamp: Double
    /// The uid column printed by `-v uid`: numeric (`10388`) or a name (`shell`, `system`).
    public var uid: String?
    public var pid: Int32
    public var tid: Int32
    public var level: LogLevel
    public var tag: String
    public var message: String
    /// Full process name (`com.example.app:remote`) when known at ingestion time.
    public var processName: String?

    public init(
        id: Int = 0,
        kind: Kind = .log,
        timestamp: Double,
        uid: String? = nil,
        pid: Int32,
        tid: Int32,
        level: LogLevel,
        tag: String,
        message: String,
        processName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.uid = uid
        self.pid = pid
        self.tid = tid
        self.level = level
        self.tag = tag
        self.message = message
        self.processName = processName
    }

    public static func marker(_ text: String, at timestamp: Double = Date().timeIntervalSince1970) -> LogEntry {
        LogEntry(kind: .marker, timestamp: timestamp, pid: 0, tid: 0, level: .info, tag: "", message: text)
    }
}

extension LogEntry {
    /// The Android package for a process name: the part before `:` (`com.foo:remote` -> `com.foo`).
    public static func packageName(forProcess process: String) -> String {
        if let colon = process.firstIndex(of: ":") {
            return String(process[..<colon])
        }
        return process
    }
}
