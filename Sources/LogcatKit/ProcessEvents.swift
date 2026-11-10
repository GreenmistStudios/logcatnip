import Foundation

/// A process lifecycle line that ActivityManager writes to the system buffer. Seen in the stream, it names a
/// pid before any `ps` can, which is the only way to name a process that exits within a poll interval.
public enum ProcessEvent: Sendable, Equatable {
    /// `Start proc <pid>:<process>/<uid> …` (Android 5.1+) or `Start proc <process> … pid=<pid> uid=<uid> …`
    /// (Android 5.0). `uid` is the full uid (user × 100000 + appId), nil when it cannot be read.
    case started(pid: Int32, process: String, uid: Int?)

    /// Parses an ActivityManager entry. Cheap for everything else: kind, tag and a message prefix are checked
    /// before any parsing, because this runs for every ingested entry.
    public init?(_ entry: LogEntry) {
        guard entry.kind == .log, entry.tag == "ActivityManager", entry.message.hasPrefix(Self.startPrefix) else {
            return nil
        }
        self.init(activityManagerMessage: entry.message)
    }

    /// Parses the message of an ActivityManager entry.
    public init?(activityManagerMessage message: String) {
        guard message.hasPrefix(Self.startPrefix) else { return nil }
        let body = message.dropFirst(Self.startPrefix.count)
        guard let event = Self.parseStart(body) else { return nil }
        self = event
    }

    private static let startPrefix = "Start proc "

    private static func parseStart(_ body: Substring) -> ProcessEvent? {
        guard let colon = body.firstIndex(of: ":"), let pid = positiveInt(body[..<colon]) else {
            return parseLollipopStart(body)
        }
        // `<pid>:<process>/<uid> [<entry point>] for <hosting type> <hosting name>`
        let rest = body[body.index(after: colon)...]
        let nameEnd = rest.firstIndex { $0 == "/" || $0 == " " } ?? rest.endIndex
        let process = rest[..<nameEnd]
        guard !process.isEmpty else { return nil }
        var uid: Int?
        if nameEnd < rest.endIndex, rest[nameEnd] == "/" {
            let afterSlash = rest[rest.index(after: nameEnd)...]
            let uidEnd = afterSlash.firstIndex(of: " ") ?? afterSlash.endIndex
            uid = Self.uid(formatted: afterSlash[..<uidEnd])
        }
        return .started(pid: pid, process: String(process), uid: uid)
    }

    /// `<process> [<entry point>] for <hosting type> <hosting name>: pid=<pid> uid=<uid> gids={…}`
    private static func parseLollipopStart(_ body: Substring) -> ProcessEvent? {
        guard let pidRange = body.range(of: ": pid=", options: .backwards) else { return nil }
        let process = body.prefix { $0 != " " }
        guard !process.isEmpty else { return nil }
        let afterPid = body[pidRange.upperBound...]
        let pidEnd = afterPid.firstIndex { !$0.isASCII || !$0.isNumber } ?? afterPid.endIndex
        guard let pid = positiveInt(afterPid[..<pidEnd]) else { return nil }
        var uid: Int?
        let afterPidText = afterPid[pidEnd...]
        if afterPidText.hasPrefix(" uid=") {
            let uidText = afterPidText.dropFirst(" uid=".count).prefix { $0.isASCII && $0.isNumber }
            uid = digits(uidText)
        }
        return .started(pid: pid, process: String(process), uid: uid)
    }

    /// Reads `UserHandle.formatUid` output: `1000`, `u0a233`, `u10a5`, `u0i5`, `u0ai9000`, `u0s1000`.
    static func uid(formatted text: Substring) -> Int? {
        if let plain = digits(text) { return plain }
        guard text.first == "u" else { return nil }
        let afterU = text.dropFirst()
        let userDigits = afterU.prefix { $0.isASCII && $0.isNumber }
        guard let user = digits(userDigits) else { return nil }
        let kind = afterU.dropFirst(userDigits.count)
        let base = user * 100_000
        if kind.hasPrefix("ai") { return digits(kind.dropFirst(2)).map { base + 90_000 + $0 } }
        if kind.hasPrefix("a") { return digits(kind.dropFirst()).map { base + 10_000 + $0 } }
        if kind.hasPrefix("i") { return digits(kind.dropFirst()).map { base + 99_000 + $0 } }
        if kind.hasPrefix("s") { return digits(kind.dropFirst()).map { base + $0 } }
        return nil
    }

    /// `Int(_:)` also accepts a sign; a uid or pid in a log line never has one.
    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func positiveInt(_ text: Substring) -> Int32? {
        guard let value = digits(text), value > 0 else { return nil }
        return Int32(exactly: value)
    }
}
