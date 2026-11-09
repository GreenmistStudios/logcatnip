import Foundation

/// Android log priority, ordered from least to most severe.
public enum LogLevel: Int, Sendable, CaseIterable, Comparable, Codable, Hashable {
    case verbose = 2
    case debug
    case info
    case warn
    case error
    case assert

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Parses the single-letter priority logcat prints (`V D I W E F A`). `F` (fatal) maps to `.assert`,
    /// matching Android Studio, which shows both as "A".
    public init?(letter: Character) {
        switch letter {
        case "V": self = .verbose
        case "D": self = .debug
        case "I": self = .info
        case "W": self = .warn
        case "E": self = .error
        case "F", "A": self = .assert
        default: return nil
        }
    }

    /// Parses a level as typed in a filter: full name (`WARN`, `warning`) or letter (`w`), case-insensitive.
    public init?(name: String) {
        switch name.lowercased() {
        case "v", "verbose": self = .verbose
        case "d", "debug": self = .debug
        case "i", "info": self = .info
        case "w", "warn", "warning": self = .warn
        case "e", "error": self = .error
        case "a", "f", "assert", "fatal": self = .assert
        default: return nil
        }
    }

    public var letter: String {
        switch self {
        case .verbose: "V"
        case .debug: "D"
        case .info: "I"
        case .warn: "W"
        case .error: "E"
        case .assert: "A"
        }
    }

    public var name: String {
        switch self {
        case .verbose: "VERBOSE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        case .assert: "ASSERT"
        }
    }
}
