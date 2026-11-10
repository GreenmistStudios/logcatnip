import Foundation

/// How an `adb logcat` run ended and what it printed, so a session can tell an old device that rejects
/// `-v epoch` from a transient adb failure or an option logcat rejected.
public struct LogcatExit: Sendable, Equatable {
    public var status: Int32
    public var stderr: String
    /// stdout that arrived before the first record, at most `leadingOutputLimit` bytes; empty once a record
    /// was parsed. Devices without adb's shell protocol (Android 6.0 and older) send logcat's errors here
    /// and exit 0.
    public var leadingOutput: String
    public var receivedEntries: Bool
    /// Whether this run passed `-v epoch -v uid`.
    public var modernFormat: Bool

    public static let leadingOutputLimit = 8192

    public init(
        status: Int32, stderr: String = "", leadingOutput: String = "",
        receivedEntries: Bool = false, modernFormat: Bool = true
    ) {
        self.status = status
        self.stderr = stderr
        self.leadingOutput = leadingOutput
        self.receivedEntries = receivedEntries
        self.modernFormat = modernFormat
    }

    public var failure: LogcatFailure { diagnosis.failure }

    /// The line that explains the exit: the rejected option, else the first meaningful stderr line, else the
    /// first meaningful line of `leadingOutput`. Nil when logcat printed nothing useful.
    public var detail: String? { diagnosis.line }

    /// `detail`, or "logcat exited (<status>)".
    public var message: String { detail ?? "logcat exited (\(status))" }

    /// What the session should do next. A transient failure is retried a few times; asking again can't fix a
    /// rejected option, so that one is reported at once.
    public func recovery(restartAttempts: Int, deviceOnline: Bool, maxRestarts: Int = 3) -> LogcatRecovery {
        switch failure {
        case .formatUnsupported:
            return .useLegacyFormat
        case let .invalidOption(line):
            return .fail(line)
        case .transient:
            if !deviceOnline { return .waitForDevice }
            return restartAttempts < maxRestarts ? .restart : .fail(message)
        }
    }

    // MARK: Classification

    /// Phrases logcat uses, across releases, when it refuses an option. Lowercased substrings, so the
    /// wording shifts between releases (`Unknown -b buffer`, `Unknown buffer ... listed for -b`) don't matter.
    private static let optionRejections = [
        "unknown -b buffer", "unknown buffer", "unable to open log device", "time format", "unknown option",
        "unrecognized option", "needs an argument", "invalid parameter", "invalid -", "invalid filter expression",
    ]

    private var diagnosis: (failure: LogcatFailure, line: String?) {
        let errorLines = Self.meaningfulLines(stderr)
        let outputLines = Self.meaningfulLines(leadingOutput, dropDividers: true)
        let fallback = errorLines.first ?? outputLines.first
        // logcat validates its options before it prints anything, so an exit after records is never a
        // rejected option.
        if receivedEntries { return (.transient, fallback) }

        let lines = errorLines + outputLines
        if modernFormat, let line = lines.first(where: Self.isFormatRejection) {
            // In a modern run every -v we pass is `long`, `epoch` or `uid`, and `long` exists on every
            // release, so any -v rejection means epoch or uid is unsupported.
            return (.formatUnsupported, line)
        }
        let lowercased = lines.map { $0.lowercased() }
        if let index = lowercased.firstIndex(where: { line in Self.optionRejections.contains { line.contains($0) } }) {
            return (.invalidOption(lines[index]), lines[index])
        }
        return (.transient, fallback)
    }

    private static func isFormatRejection(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("invalid") && (lowercased.contains("-v") || lowercased.contains("--format"))
    }

    /// Trimmed, non-empty lines without adb's own chatter. Buffer dividers (`--------- beginning of main`)
    /// are stdout content, not an explanation, so callers scanning stdout drop them.
    private static func meaningfulLines(_ text: String, dropDividers: Bool = false) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("- waiting for") || line.hasPrefix("* daemon") { return nil }
            if dropDividers, line.hasPrefix("--------- ") { return nil }
            return line
        }
    }
}

public enum LogcatFailure: Sendable, Equatable {
    /// logcat rejected `-v epoch` or `-v uid`: Android 6.0 and older.
    case formatUnsupported
    /// logcat rejected an option, such as an unknown `-b` buffer. Restarting can't help. Carries logcat's line.
    case invalidOption(String)
    /// Anything else: the transport dropped, the adb server restarted, logd hiccuped.
    case transient
}

public enum LogcatRecovery: Sendable, Equatable {
    case useLegacyFormat
    case restart
    case waitForDevice
    case fail(String)
}
