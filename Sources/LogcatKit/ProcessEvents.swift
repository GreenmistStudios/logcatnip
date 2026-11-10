import Foundation

/// A process lifecycle line that ActivityManager writes to the system buffer, or the matching `am_*` entry in the
/// events buffer (when the user streams it). Seen in the stream, it names a pid before any `ps` can, which is
/// the only way to name a process that exits within a poll interval, and it says when a process ended.
public enum ProcessEvent: Sendable, Equatable {
    /// `Start proc <pid>:<process>/<uid> …` (Android 5.1+) or `Start proc <process> … pid=<pid> uid=<uid> …`
    /// (Android 5.0), or the events buffer's `am_proc_start [user,pid,uid,process,type,component]`. `uid` is the
    /// full uid (user × 100000 + appId), nil when it cannot be read.
    case started(pid: Int32, process: String, uid: Int?)
    /// `Killing <pid>:<process>/<uid> (adj <n>): <reason>` (Android 5.0+) or `Process <process> (pid <pid>)
    /// has died…` (5.0+; 9.0+ appends the oom adj and process state, 5.0 also logs `has died and restarted
    /// (pid <new>).`), or the events buffer's `am_proc_died [user,pid,process,adj,procstate]` and `am_kill
    /// [user,pid,process,adj,reason(,rss on Android 15+)]`. `reason` is set only for the kinds a marker names.
    case ended(pid: Int32, process: String, reason: ProcessEndReason?)
    /// `am_crash` in the events buffer: the named process is about to die of an uncaught exception. Useful when
    /// the crash buffer is not streamed, so no `FATAL EXCEPTION` entry says so.
    case crashed(pid: Int32, process: String)

    /// Parses an ActivityManager or events-buffer entry. Cheap for everything else: kind, tag and the first
    /// message byte are checked before any parsing, because this runs for every ingested entry.
    public init?(_ entry: LogEntry) {
        guard entry.kind == .log, let first = entry.message.utf8.first else { return nil }
        if first == UInt8(ascii: "[") {
            guard entry.tag.hasPrefix("am_") else { return nil }
            self.init(eventTag: entry.tag, message: entry.message)
            return
        }
        guard entry.tag == "ActivityManager",
              first == UInt8(ascii: "S") || first == UInt8(ascii: "K") || first == UInt8(ascii: "P")
        else { return nil }
        self.init(activityManagerMessage: entry.message)
    }

    /// Parses an events-buffer entry: `[field,field,…]`. The fifth field onwards is not split, because a kill
    /// reason or a component name may contain commas. Formats are those of AOSP `EventLogTags.logtags`, which
    /// did not change for these tags between Android 8 and 16 apart from fields appended at the end.
    public init?(eventTag tag: String, message: String) {
        var body = Substring(message)
        while body.last == " " || body.last == "\n" { body = body.dropLast() }
        guard body.first == "[", body.last == "]", body.count >= 2 else { return nil }
        body = body.dropFirst().dropLast()
        let fields = body.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
        // The three-field `am_proc_died` of `appDiedLocked`'s "died and restarted" branch names the new, live
        // pid, so requiring five fields also rejects it.
        guard fields.count == 5 else { return nil }
        let event: ProcessEvent?
        switch tag {
        case "am_proc_start":
            event = Self.processName(fields[3]).flatMap { process in
                Self.positiveInt(fields[1]).map { .started(pid: $0, process: process, uid: Self.digits(fields[2])) }
            }
        case "am_proc_died":
            event = Self.processName(fields[2]).flatMap { process in
                Self.positiveInt(fields[1]).map { .ended(pid: $0, process: process, reason: nil) }
            }
        case "am_kill":
            event = Self.processName(fields[2]).flatMap { process in
                Self.positiveInt(fields[1]).map {
                    .ended(pid: $0, process: process, reason: ProcessEndReason(killReason: fields[4]))
                }
            }
        case "am_crash":
            // AOSP writes the pid first and the user second, the reverse of the logtags file.
            event = Self.processName(fields[2]).flatMap { process in
                Self.positiveInt(fields[0]).map { .crashed(pid: $0, process: process) }
            }
        default:
            event = nil
        }
        guard let event else { return nil }
        self = event
    }

    private static func processName(_ text: Substring) -> String? {
        text.isEmpty || text.contains(" ") ? nil : String(text)
    }

    /// Parses the message of an ActivityManager entry.
    public init?(activityManagerMessage message: String) {
        let event: ProcessEvent?
        if message.hasPrefix(Self.startPrefix) {
            event = Self.parseStart(message.dropFirst(Self.startPrefix.count))
        } else if message.hasPrefix(Self.killingPrefix) {
            event = Self.parseKilling(message.dropFirst(Self.killingPrefix.count))
        } else if message.hasPrefix(Self.processPrefix) {
            event = Self.parseDeath(message.dropFirst(Self.processPrefix.count))
        } else {
            event = nil
        }
        guard let event else { return nil }
        self = event
    }

    private static let startPrefix = "Start proc "
    private static let killingPrefix = "Killing "
    private static let processPrefix = "Process "

    /// `<pid>:<process>/<uid> (adj <n>): <reason>`. `Killing processes <reason>` has no pid and is skipped.
    private static func parseKilling(_ body: Substring) -> ProcessEvent? {
        guard let colon = body.firstIndex(of: ":"), let pid = positiveInt(body[..<colon]) else { return nil }
        let rest = body[body.index(after: colon)...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let process = rest[..<slash]
        guard !process.isEmpty, !process.contains(" ") else { return nil }
        // The uid (`u0a233`, `1000`, `u0a57i3`) is not needed: Start proc already carries it.
        let afterUID = rest[slash...].drop { $0 != " " }
        guard afterUID.hasPrefix(" (adj "), let close = afterUID.range(of: "): ") else { return nil }
        let reason = afterUID[close.upperBound...]
        return .ended(pid: pid, process: String(process), reason: ProcessEndReason(killReason: reason))
    }

    /// `<process> (pid <pid>) has died…`. Other `Process …` lines (`early provider death`, `failed to attach`,
    /// `has crashed too many times`) are not process ends.
    private static func parseDeath(_ body: Substring) -> ProcessEvent? {
        guard let marker = body.range(of: " (pid ") else { return nil }
        let process = body[..<marker.lowerBound]
        guard !process.isEmpty, !process.contains(" ") else { return nil }
        let afterMarker = body[marker.upperBound...]
        guard let close = afterMarker.firstIndex(of: ")"), let pid = positiveInt(afterMarker[..<close]) else { return nil }
        guard afterMarker[afterMarker.index(after: close)...].hasPrefix(" has died") else { return nil }
        return .ended(pid: pid, process: String(process), reason: nil)
    }

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
