import Foundation

/// What makes two occurrences of a signal "the same problem", so they can be grouped and counted.
///
/// Builders keep only stable parts (exception types, frames, signal names, normalised reasons) and drop
/// pids, addresses, timestamps and other numbers that change from run to run.
public struct CrashSignature: Sendable, Hashable {
    public var kind: SignalKind
    /// The exception type, signal, leaking class or rule name: `java.lang.IllegalStateException`,
    /// `SIGSEGV (SEGV_MAPERR)`, `Input dispatching timed out`.
    public var title: String
    /// The frame or reason that locates it: `MainActivity.onCreate (MainActivity.kt:42)`.
    public var detail: String?
    public var package: String?
    /// Whether `detail` came from an app frame, so a later system frame doesn't replace it. Not part of the
    /// identity.
    private var hasAppFrame = false

    public init(kind: SignalKind, title: String, detail: String? = nil, package: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.package = package
    }

    public static func == (lhs: CrashSignature, rhs: CrashSignature) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.package == rhs.package
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(title)
        hasher.combine(detail)
        hasher.combine(package)
    }

    /// A stable string for grouping and persisting: equal signatures have equal keys.
    public var key: String {
        [kind.rawValue, package ?? "", title, detail ?? ""].joined(separator: "|")
    }

    /// `IllegalStateException · MainActivity.onCreate (MainActivity.kt:42)`.
    public var displayText: String {
        let shortTitle = switch kind {
        case .crash, .leak: Self.simpleName(title)
        default: title
        }
        return detail.map { "\(shortTitle) · \($0)" } ?? shortTitle
    }

    // MARK: - Builders

    /// The signature for the signal an entry matched. `package` defaults to the entry's process; pass the
    /// crashing app when the entry comes from a system process (ActivityManager, crash_dump).
    public static func make(for match: SignalMatch, entry: LogEntry, package: String? = nil) -> CrashSignature {
        let package = package ?? entry.processName.map(LogEntry.packageName(forProcess:))
        switch match.kind {
        case .crash:
            return javaCrash(message: entry.message, package: package)
        case .nativeCrash:
            var signature = native(header: entry)
            if match.rule == SignalRules.ID.tombstoneDetail { signature.enrich(with: entry) }
            return signature
        case .anr:
            var signature = anr(message: entry.message)
            if signature.package == nil { signature.package = package }
            return signature
        case .outOfMemory:
            return outOfMemory(message: entry.message, package: package)
        case .leak:
            return leak(message: entry.message, package: package)
        case .performance:
            return performance(rule: match.rule, message: entry.message, package: package)
        }
    }

    /// The root exception type (the last `Caused by:`, else the first exception line) and the top app frame:
    /// the first frame in the crashing package, else the first frame.
    public static func javaCrash(message: String, package: String?) -> CrashSignature {
        var package = package
        var firstException: Substring?
        var lastCause: Substring?
        var frames: [JavaFrame] = []
        message.enumerateLines { rawLine, _ in
            let line = Substring(rawLine).drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("at ") {
                if let frame = JavaFrame.parse(line) { frames.append(frame) }
            } else if line.hasPrefix("Caused by: ") {
                lastCause = exceptionType(line.dropFirst("Caused by: ".count))
            } else if line.hasPrefix("Process: ") {
                if package == nil {
                    let process = line.dropFirst("Process: ".count).prefix { $0 != "," }
                    package = LogEntry.packageName(forProcess: String(process))
                }
            } else if firstException == nil, !line.hasPrefix("FATAL EXCEPTION"), !line.hasPrefix("..."),
                      !line.hasPrefix("Suppressed: "), let type = exceptionType(line) {
                firstException = type
            }
        }
        let title = (lastCause ?? firstException).map(String.init) ?? "Unknown exception"
        let frame = topAppFrame(of: frames, package: package)
        return CrashSignature(kind: .crash, title: title, detail: frame?.displayText, package: package)
    }

    /// The frame a Java crash signature names, for Open Top Frame: the first frame in `package`, else the
    /// first frame. `package` is the signature's, so this agrees with ``detail``.
    public static func topAppFrame(in message: String, package: String?) -> JavaFrame? {
        var frames: [JavaFrame] = []
        message.enumerateLines { line, _ in
            if let frame = JavaFrame.parse(line) { frames.append(frame) }
        }
        return topAppFrame(of: frames, package: package)
    }

    static func topAppFrame(of frames: [JavaFrame], package: String?) -> JavaFrame? {
        package.flatMap { package in
            frames.first { $0.className.hasPrefix(package + ".") }
        } ?? frames.first
    }

    /// Starts a native crash signature from libc's `Fatal signal` line or the tombstone's `*** *** ***`
    /// header. ``enrich(with:)`` fills in the rest from the tombstone lines that follow.
    public static func native(header: LogEntry) -> CrashSignature {
        var signature = CrashSignature(kind: .nativeCrash, title: "Native crash")
        let message = header.message
        guard message.hasPrefix("Fatal signal ") else { return signature }
        // Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 15051 (RenderThread), pid 15020 (com.example.app)
        signature.title = signalTitle(message.dropFirst("Fatal signal ".count)) ?? "Native crash"
        if let pid = message.range(of: ", pid "), let open = message[pid.upperBound...].firstIndex(of: "("),
           let close = message[open...].firstIndex(of: ")") {
            let process = message[message.index(after: open)..<close]
            signature.package = LogEntry.packageName(forProcess: String(process))
        } else {
            signature.package = header.processName.map(LogEntry.packageName(forProcess:))
        }
        return signature
    }

    /// Adds what a later entry of the same occurrence says: a tombstone's process, signal and first app frame,
    /// or an ANR's reason.
    public mutating func enrich(with entry: LogEntry) {
        switch kind {
        case .nativeCrash:
            for line in entry.message.split(separator: "\n") { enrichNative(line: line) }
        case .anr:
            let other = Self.anr(message: entry.message)
            if package == nil { package = other.package }
            if title == Self.unknownANRReason || (other.title != Self.unknownANRReason && entry.message.contains("Reason: ")) {
                title = other.title
            }
        default:
            break
        }
    }

    private mutating func enrichNative(line: Substring) {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("pid: "), package == nil,
           let open = trimmed.range(of: ">>> "), let close = trimmed.range(of: " <<<") {
            package = LogEntry.packageName(forProcess: String(trimmed[open.upperBound..<close.lowerBound]))
        } else if trimmed.hasPrefix("signal "), let title = Self.signalTitle(trimmed.dropFirst("signal ".count)) {
            self.title = title
        } else if trimmed.hasPrefix("#"), let frame = NativeFrame.parse(trimmed) {
            if detail == nil || (!hasAppFrame && frame.isAppLibrary) {
                detail = frame.displayText
                hasAppFrame = frame.isAppLibrary
            }
        }
    }

    static let unknownANRReason = "ANR"

    /// The package and the first line of the reason, cut before any parenthesised detail and without numbers,
    /// from an `ANR in` report, its `Reason:` line or an input dispatcher timeout.
    public static func anr(message: String) -> CrashSignature {
        var signature = CrashSignature(kind: .anr, title: unknownANRReason)
        var reason: Substring?
        message.enumerateLines { line, stop in
            let line = Substring(line)
            if line.hasPrefix("ANR in "), !line.hasPrefix("ANR in Window{"), !line.hasPrefix("ANR in input window") {
                let process = line.dropFirst("ANR in ".count).prefix { $0 != " " }
                signature.package = LogEntry.packageName(forProcess: String(process))
            } else if line.hasPrefix("Reason: ") {
                reason = line.dropFirst("Reason: ".count)
                stop = true
            }
        }
        if let reason {
            signature.title = normalisedReason(reason)
        } else if message.contains("Input dispatching timed out") || message.contains(" is unresponsive")
                    || message.contains("is not responding") {
            signature.title = "Input dispatching timed out"
        }
        if signature.package == nil {
            signature.package = componentPackage(in: message)
        }
        return signature
    }

    /// ART's `Throwing OutOfMemoryError` or lmkd's `Kill '<process>'`, grouped per package.
    public static func outOfMemory(message: String, package: String?) -> CrashSignature {
        if message.hasPrefix("Kill '") {
            // Kill 'com.example.app' (16302), uid 10234, oom_score_adj 905 to free 178432kB rss, …; reason: low watermark is breached …
            let process = message.dropFirst("Kill '".count).prefix { $0 != "'" }
            let reason = message.range(of: "; reason: ").map { normalisedReason(message[$0.upperBound...]) }
            return CrashSignature(
                kind: .outOfMemory, title: "Killed by lmkd", detail: reason,
                package: LogEntry.packageName(forProcess: String(process))
            )
        }
        return CrashSignature(kind: .outOfMemory, title: "OutOfMemoryError", package: package)
    }

    /// The leaking class: LeakCanary's `╰→` object, the StrictMode violation, or the activity WindowManager
    /// blames.
    public static func leak(message: String, package: String?) -> CrashSignature {
        if let violation = SignalRules.strictModeViolation(in: message) {
            return CrashSignature(kind: .leak, title: violation, detail: topFrame(in: message, package: package)?.displayText, package: package)
        }
        if let arrow = message.range(of: "╰→ ") {
            let object = message[arrow.upperBound...].prefix { $0 != "\n" }
            let className = object.hasSuffix(" instance") ? object.dropLast(" instance".count) : object
            return CrashSignature(kind: .leak, title: String(className), detail: "LeakCanary", package: package)
        }
        for kind in ["window", "IntentReceiver", "ServiceConnection"] {
            // Activity com.example.app.MainActivity has leaked window DecorView@8b6f2a1[MainActivity] that was …
            guard let leaked = message.range(of: " has leaked \(kind) ") else { continue }
            let lineStart = message[..<leaked.lowerBound].lastIndex(of: "\n").map(message.index(after:)) ?? message.startIndex
            var owner = message[lineStart..<leaked.lowerBound]
            if let colon = owner.range(of: ": ") { owner = owner[colon.upperBound...] }
            if let space = owner.lastIndex(of: " ") { owner = owner[owner.index(after: space)...] }
            return CrashSignature(kind: .leak, title: String(owner), detail: "leaked \(kind)", package: package)
        }
        return CrashSignature(kind: .leak, title: "Leak", package: package)
    }

    /// The rule name only, grouped per package: every skipped-frames warning in an app is the same problem.
    public static func performance(rule: String, message: String, package: String?) -> CrashSignature {
        let title = switch rule {
        case SignalRules.ID.skippedFrames: "Skipped frames"
        case SignalRules.ID.davey: "Davey"
        case SignalRules.ID.monitorContention: "Long monitor contention"
        case SignalRules.ID.strictModeViolation:
            SignalRules.strictModeViolation(in: message).map { "StrictMode \($0)" } ?? "StrictMode"
        default: rule
        }
        return CrashSignature(kind: .performance, title: title, package: package)
    }

    // MARK: - Helpers

    /// `java.lang.IllegalStateException` from `java.lang.IllegalStateException: boom`, if the line starts
    /// with something shaped like a class name.
    static func exceptionType(_ line: Substring) -> Substring? {
        let type = line.prefix { $0 != ":" && $0 != " " }
        guard type.contains("."), type.first?.isLetter == true,
              type.endIndex == line.endIndex || line[type.endIndex] == ":"
        else { return nil }
        return type
    }

    /// `SIGSEGV (SEGV_MAPERR)` from `11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr …`.
    static func signalTitle(_ text: Substring) -> String? {
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        let name = text[text.index(after: open)..<close]
        guard let code = text.range(of: "code "), let codeOpen = text[code.upperBound...].firstIndex(of: "("),
              let codeClose = text[codeOpen...].firstIndex(of: ")")
        else { return String(name) }
        return "\(name) (\(text[text.index(after: codeOpen)..<codeClose]))"
    }

    /// The first line of a reason, cut before ` (` and with hex values and digits removed, so
    /// `executing service com.example.app/.SyncService` stays readable but window tokens and timings go.
    static func normalisedReason<S: StringProtocol>(_ reason: S) -> String {
        var text = Substring(reason).prefix { $0 != "\n" }
        if let paren = text.range(of: " (") { text = text[..<paren.lowerBound] }
        let words = text.split(separator: " ").compactMap { word -> String? in
            if word.hasPrefix("0x") { return nil }
            let stripped = String(word.filter { !$0.isNumber })
            return stripped.isEmpty ? nil : stripped
        }
        return words.joined(separator: " ")
    }

    /// The package of the first `pkg/Component` token, as in `com.example.app/com.example.app.MainActivity`.
    static func componentPackage(in message: String) -> String? {
        for word in message.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "{" }) {
            guard let slash = word.firstIndex(of: "/") else { continue }
            let candidate = word[..<slash]
            if candidate.contains("."), candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                return String(candidate)
            }
        }
        return nil
    }

    /// The first frame in `package`, with no fallback: what a StrictMode leak signature names.
    public static func topFrame(in message: String, package: String?) -> JavaFrame? {
        guard let package else { return nil }
        var found: JavaFrame?
        message.enumerateLines { line, stop in
            if let frame = JavaFrame.parse(line), frame.className.hasPrefix(package + ".") {
                found = frame
                stop = true
            }
        }
        return found
    }

    static func simpleName(_ className: String) -> String {
        className.lastIndex(of: ".").map { String(className[className.index(after: $0)...]) } ?? className
    }
}
