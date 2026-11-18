import Foundation

/// What kind of problem a log entry reports.
public enum SignalKind: String, Sendable, Hashable, CaseIterable {
    case crash
    case nativeCrash
    case anr
    case outOfMemory
    case leak
    case performance

    /// Whether the app died or froze, as opposed to a warning it can keep running through.
    public var isFatal: Bool {
        switch self {
        case .crash, .nativeCrash, .anr: true
        case .outOfMemory, .leak, .performance: false
        }
    }

    /// Crashes, native crashes and ANRs: what Next Crash visits and the status bar counts in red.
    public static let fatal: Set<SignalKind> = Set(allCases.filter(\.isFatal))
    /// Out of memory, leaks and jank.
    public static let warnings: Set<SignalKind> = Set(allCases.filter { !$0.isFatal })

    public var title: String {
        switch self {
        case .crash: "Crash"
        case .nativeCrash: "Native crash"
        case .anr: "ANR"
        case .outOfMemory: "Out of memory"
        case .leak: "Leak"
        case .performance: "Jank"
        }
    }
}

/// The rule an entry matched.
public struct SignalMatch: Sendable, Hashable {
    public var kind: SignalKind
    /// The matching rule's ``SignalRule/id``.
    public var rule: String
    /// False for entries that only add detail to an occurrence an earlier entry started, such as a DEBUG
    /// backtrace line or an ANR `Reason:` line, so they aren't counted on their own.
    public var isAnchor: Bool

    public init(kind: SignalKind, rule: String, isAnchor: Bool) {
        self.kind = kind
        self.rule = rule
        self.isAnchor = isAnchor
    }
}

/// One way of recognising a signal. Rules are data so new ones can be added without touching the code that
/// indexes them.
public struct SignalRule: Sendable {
    public var id: String
    public var kind: SignalKind
    /// Tags the rule applies to, or `nil` for any tag. Checked before `matches`, so keep it set where the
    /// source has a fixed tag.
    public var tags: Set<String>?
    public var minLevel: LogLevel
    public var isAnchor: Bool
    /// The message check. Runs only for entries that pass the tag and level gates; use `hasPrefix` and
    /// `contains`, not regular expressions, since it can run for every ingested entry.
    public var matches: @Sendable (LogEntry) -> Bool

    public init(
        id: String,
        kind: SignalKind,
        tags: Set<String>?,
        minLevel: LogLevel,
        isAnchor: Bool = true,
        matches: @escaping @Sendable (LogEntry) -> Bool
    ) {
        self.id = id
        self.kind = kind
        self.tags = tags
        self.minLevel = minLevel
        self.isAnchor = isAnchor
        self.matches = matches
    }

    public func evaluate(_ entry: LogEntry) -> Bool {
        entry.level >= minLevel && (tags?.contains(entry.tag) ?? true) && matches(entry)
    }

    var match: SignalMatch { SignalMatch(kind: kind, rule: id, isAnchor: isAnchor) }
}

/// Rules grouped by tag, so classifying an entry costs one dictionary lookup plus the rules for its tag.
public struct SignalRuleSet: Sendable {
    public let rules: [SignalRule]
    /// For each tag some rule names: the rules that apply to it, anchors first, then in array order.
    private let byTag: [String: [SignalRule]]
    /// The rules for any other tag (those with `tags == nil`), in the same order.
    private let untagged: [SignalRule]
    private let minLevel: LogLevel

    public init(_ rules: [SignalRule]) {
        self.rules = rules
        let ordered = rules.filter(\.isAnchor) + rules.filter { !$0.isAnchor }
        untagged = ordered.filter { $0.tags == nil }
        var byTag: [String: [SignalRule]] = [:]
        for tag in Set(rules.flatMap { $0.tags ?? [] }) {
            byTag[tag] = ordered.filter { $0.tags?.contains(tag) ?? true }
        }
        self.byTag = byTag
        minLevel = rules.map(\.minLevel).min() ?? .assert
    }

    public static let `default` = SignalRuleSet(SignalRules.default)

    public func match(_ entry: LogEntry) -> SignalMatch? {
        guard entry.kind == .log, entry.level >= minLevel else { return nil }
        for rule in byTag[entry.tag] ?? untagged where entry.level >= rule.minLevel && rule.matches(entry) {
            return rule.match
        }
        return nil
    }
}

/// The built-in rules. See `Plan.md` for the sources each one covers.
public enum SignalRules {
    /// Rule ids, so signatures and tests can refer to them.
    public enum ID {
        public static let fatalException = "crash.fatalException"
        public static let fatalSignal = "nativeCrash.fatalSignal"
        public static let tombstone = "nativeCrash.tombstone"
        public static let tombstoneDetail = "nativeCrash.detail"
        public static let anrReport = "anr.activityManager"
        public static let inputDispatchTimeout = "anr.inputDispatch"
        public static let anrReason = "anr.reason"
        public static let throwingOutOfMemory = "outOfMemory.art"
        public static let lowMemoryKill = "outOfMemory.lmkd"
        public static let leakCanary = "leak.leakCanary"
        public static let strictModeLeak = "leak.strictMode"
        public static let leakedRegistration = "leak.leakedRegistration"
        public static let skippedFrames = "performance.skippedFrames"
        public static let davey = "performance.davey"
        public static let strictModeViolation = "performance.strictMode"
        public static let monitorContention = "performance.monitorContention"
    }

    /// Choreographer prints from 30 skipped frames by default; a lower `debug.choreographer.skipwarning`
    /// shouldn't turn every hiccup into a signal.
    public static let skippedFramesThreshold = 30

    static let nativeCrashTags: Set<String> = ["DEBUG", "crash_dump", "crash_dump32", "crash_dump64", "tombstoned"]

    /// StrictMode violation classes (`android.os.strictmode.*`) that report leaked objects rather than slow
    /// work. `detectLeakedRegistrationObjects` reports the receiver and service connection ones.
    static let strictModeLeakViolations: Set<String> = [
        "LeakedClosableViolation", "InstanceCountViolation", "IntentReceiverLeakedViolation",
        "ServiceConnectionLeakedViolation", "SqliteObjectLeakedViolation",
    ]

    public static let `default`: [SignalRule] = [
        SignalRule(id: ID.fatalException, kind: .crash, tags: ["AndroidRuntime"], minLevel: .error) { entry in
            entry.message.hasPrefix("FATAL EXCEPTION") || entry.message.contains("\nFATAL EXCEPTION")
        },
        SignalRule(id: ID.fatalSignal, kind: .nativeCrash, tags: ["libc"], minLevel: .assert) { entry in
            entry.message.hasPrefix("Fatal signal ")
        },
        SignalRule(id: ID.tombstone, kind: .nativeCrash, tags: nativeCrashTags, minLevel: .assert) { entry in
            entry.message.hasPrefix("*** *** ***")
        },
        SignalRule(id: ID.tombstoneDetail, kind: .nativeCrash, tags: nativeCrashTags, minLevel: .assert, isAnchor: false) { entry in
            isTombstoneDetail(entry.message)
        },
        SignalRule(id: ID.anrReport, kind: .anr, tags: ["ActivityManager"], minLevel: .error) { entry in
            entry.message.hasPrefix("ANR in ")
        },
        SignalRule(id: ID.inputDispatchTimeout, kind: .anr, tags: ["InputDispatcher", "ActivityManager", "WindowManager"], minLevel: .info) { entry in
            isInputDispatchTimeout(tag: entry.tag, message: entry.message)
        },
        SignalRule(id: ID.anrReason, kind: .anr, tags: ["ActivityManager"], minLevel: .error, isAnchor: false) { entry in
            entry.message.hasPrefix("Reason: ")
        },
        // ART logs with the process name as its tag since Android 9 (`art` and `dalvikvm` before), so this
        // rule can't gate on the tag.
        SignalRule(id: ID.throwingOutOfMemory, kind: .outOfMemory, tags: nil, minLevel: .warn) { entry in
            entry.message.hasPrefix("Throwing OutOfMemoryError")
        },
        SignalRule(id: ID.lowMemoryKill, kind: .outOfMemory, tags: ["lowmemorykiller", "lmkd"], minLevel: .info) { entry in
            entry.message.hasPrefix("Kill '")
        },
        SignalRule(id: ID.leakCanary, kind: .leak, tags: ["LeakCanary"], minLevel: .debug) { entry in
            isLeakCanaryLeak(entry.message)
        },
        SignalRule(id: ID.strictModeLeak, kind: .leak, tags: ["StrictMode"], minLevel: .debug) { entry in
            strictModeViolation(in: entry.message).map(strictModeLeakViolations.contains) ?? false
        },
        SignalRule(id: ID.leakedRegistration, kind: .leak, tags: ["WindowManager", "ActivityThread"], minLevel: .error) { entry in
            entry.message.contains(" has leaked window ")
                || entry.message.contains(" has leaked IntentReceiver ")
                || entry.message.contains(" has leaked ServiceConnection ")
        },
        SignalRule(id: ID.skippedFrames, kind: .performance, tags: ["Choreographer"], minLevel: .info) { entry in
            skippedFrames(in: entry.message).map { $0 >= skippedFramesThreshold } ?? false
        },
        SignalRule(id: ID.davey, kind: .performance, tags: ["OpenGLRenderer", "HWUI"], minLevel: .info) { entry in
            entry.message.hasPrefix("Davey! duration=")
        },
        SignalRule(id: ID.strictModeViolation, kind: .performance, tags: ["StrictMode"], minLevel: .debug) { entry in
            strictModeViolation(in: entry.message) != nil
        },
        // Tagged with the process name, like the out-of-memory rule.
        SignalRule(id: ID.monitorContention, kind: .performance, tags: nil, minLevel: .warn) { entry in
            entry.message.hasPrefix("Long monitor contention")
        },
    ]

    /// The tombstone lines that identify a native crash: the process, the signal, the abort message and
    /// backtrace frames. Register dumps and memory maps are left out.
    static func isTombstoneDetail(_ message: String) -> Bool {
        let line = message.drop { $0 == " " || $0 == "\t" }
        return line.hasPrefix("pid: ") || line.hasPrefix("signal ") || line.hasPrefix("Abort message: ")
            || line.hasPrefix("Cmdline: ") || (line.hasPrefix("#") && line.contains(" pc "))
    }

    /// Android 12+ prints `Window … is unresponsive` from InputDispatcher and `Input dispatching timed out`
    /// as the ANR reason; older releases print `Application is not responding` from InputDispatcher. A lone
    /// `Reason:` line (an ANR report split by a threadtime import) only enriches the report it belongs to.
    static func isInputDispatchTimeout(tag: String, message: String) -> Bool {
        if message.hasPrefix("Reason: ") { return false }
        if message.contains("Input dispatching timed out") || message.contains("Application is not responding") {
            return true
        }
        switch tag {
        case "InputDispatcher": return message.hasPrefix("Window ") && message.contains(" is unresponsive: ")
        case "WindowManager": return message.hasPrefix("ANR in ")
        default: return false
        }
    }

    /// A LeakCanary heap analysis that found application leaks (`N APPLICATION LEAKS` with N > 0), or a leak
    /// trace logged on its own when LeakCanary split a long result into one line per record.
    static func isLeakCanaryLeak(_ message: String) -> Bool {
        if message.contains("HEAP ANALYSIS RESULT") {
            guard let range = message.range(of: " APPLICATION LEAKS") else { return false }
            let lineStart = message[..<range.lowerBound].lastIndex(of: "\n").map(message.index(after:)) ?? message.startIndex
            return Int(message[lineStart..<range.lowerBound]).map { $0 > 0 } ?? false
        }
        return message.hasPrefix("┬───")
    }

    /// The violation class (`DiskReadViolation`) of a `StrictMode policy violation` record.
    static func strictModeViolation(in message: String) -> String? {
        guard message.hasPrefix("StrictMode policy violation"),
              let range = message.range(of: "android.os.strictmode.")
        else { return nil }
        let name = message[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    /// N in `Skipped N frames!  The application may be doing too much work on its main thread.`
    static func skippedFrames(in message: String) -> Int? {
        guard message.hasPrefix("Skipped ") else { return nil }
        let digits = message.dropFirst("Skipped ".count).prefix { $0.isASCII && $0.isNumber }
        guard message.dropFirst("Skipped ".count + digits.count).hasPrefix(" frames!") else { return nil }
        return Int(digits)
    }
}
