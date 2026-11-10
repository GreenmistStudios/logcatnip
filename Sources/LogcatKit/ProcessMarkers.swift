import Foundation

/// Why a process ended, when the log says.
public enum ProcessEndReason: Sendable, Hashable {
    case crashed
    case forceStopped

    /// Reads the reason ActivityManager gives in `Killing <pid>:<process>/<uid> (adj <n>): <reason>`. Other
    /// reasons (`empty #17`, `remove task`, memory pressure) say nothing a marker should repeat.
    init?(killReason: Substring) {
        // `crash` is what ActivityManager uses once an app has crashed too often.
        if killReason.hasPrefix("crash") {
            self = .crashed
        } else if killReason.hasPrefix("stop ") {
            self = .forceStopped
        } else {
            return nil
        }
    }
}
