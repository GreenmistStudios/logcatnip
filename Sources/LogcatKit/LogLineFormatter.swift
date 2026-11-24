import Foundation

/// What a card shows for one entry. A nil field belongs to a hidden column (or to a marker, which has no
/// level or tag), so the card leaves that part out.
public struct LogCardText: Sendable, Equatable {
    public var level: String?
    public var tag: String?
    public var time: String?
    /// PID/TID, package and process joined by " · "; empty when none is shown.
    public var footer: String

    public init(level: String?, tag: String?, time: String?, footer: String) {
        self.level = level
        self.tag = tag
        self.time = time
        self.footer = footer
    }
}

/// The text of each table cell, of a copied line and of a card for a set of view options. The table, Copy
/// and the card layout all read their fields from here, so they agree on every one.
public struct LogLineFormatter: Sendable {
    public let options: LogViewOptions
    private let zone: TimeZone

    public init(options: LogViewOptions, localTimeZone: TimeZone = .current) {
        self.options = options
        // Built once: this runs for every visible cell.
        zone = options.timeZone == .utc ? (TimeZone(identifier: "UTC") ?? .gmt) : localTimeZone
    }

    /// One cell of an entry's first line. `previous` is the entry of the visible row above, nil at the top
    /// (the first row of a trimmed or filtered view has no neighbor, so it shows everything). Repeated tags,
    /// packages and processes come back empty when the options hide them. `.message` is the whole message
    /// and `.level` the letter. Markers have a time and a message only.
    public func text(
        _ column: LogColumn,
        for entry: LogEntry,
        previous: LogEntry?,
        sessionStart: Double?,
        processName: (LogEntry) -> String?
    ) -> String {
        cell(column, for: entry, previous: previous, sessionStart: sessionStart, processName: processName, hidingRepeats: true)
    }

    /// One copied line: `columns` (the visible ones, in table order) joined by single spaces, empty fields
    /// left out. Values are in full and nothing is blanked as repeated, so every copied line stands alone.
    /// A marker is `--------- <text>`, as in the log export.
    public func copyLine(
        for entry: LogEntry,
        previous: LogEntry?,
        sessionStart: Double?,
        processName: (LogEntry) -> String?,
        columns: [LogColumn]
    ) -> String {
        if entry.kind == .marker { return "--------- \(entry.message)" }
        var fields: [String] = []
        for column in columns {
            let text = cell(column, for: entry, previous: previous, sessionStart: sessionStart, processName: processName, hidingRepeats: false)
            if !text.isEmpty { fields.append(text) }
        }
        return fields.joined(separator: " ")
    }

    /// The fields of an entry's card. A card stands alone, like a copied line: repeated tags, packages and
    /// processes are never blanked, and `previous` only feeds the delta time. The footer spells out
    /// `PID 1234 · TID 5678` because, unlike a table column, nothing above it says what the numbers are, and it
    /// leaves out a process that only repeats the package shown next to it.
    public func card(
        for entry: LogEntry,
        previous: LogEntry?,
        sessionStart: Double?,
        processName: (LogEntry) -> String?
    ) -> LogCardText {
        func field(_ column: LogColumn) -> String? {
            options.isVisible(column)
                ? cell(column, for: entry, previous: previous, sessionStart: sessionStart, processName: processName, hidingRepeats: false)
                : nil
        }
        let time = field(.time)
        guard entry.kind == .log else { return LogCardText(level: nil, tag: nil, time: time, footer: "") }

        var parts: [String] = []
        if options.isVisible(.pid) {
            parts.append(options.pidStyle == .pid ? "PID \(entry.pid)" : "PID \(entry.pid) · TID \(entry.tid)")
        }
        var packageShown: String?
        if let package = field(.package), !package.isEmpty {
            parts.append(package)
            packageShown = package
        }
        if let process = field(.process), !process.isEmpty, process != packageShown {
            parts.append(process)
        }
        return LogCardText(level: field(.level), tag: field(.tag), time: time, footer: parts.joined(separator: " · "))
    }

    /// The package cell: the package of the process, `pid-N` while the process is unknown, nothing for pid 0.
    public static func packageText(process: String?, pid: Int32) -> String {
        if let process, !process.isEmpty { return LogEntry.packageName(forProcess: process) }
        return pid > 0 ? "pid-\(pid)" : ""
    }

    /// Whether drawing this column looks at the previous entry with these options (delta time, or a
    /// column that hides repeats), so the table fetches it only when it matters.
    public func needsPrevious(_ column: LogColumn) -> Bool {
        switch column {
        case .time: options.timestampStyle == .delta
        case .tag: options.hideRepeatedTags
        case .package: options.hideRepeatedPackages
        case .process: options.hideRepeatedProcesses
        case .pid, .level, .message: false
        }
    }

    private func cell(
        _ column: LogColumn,
        for entry: LogEntry,
        previous: LogEntry?,
        sessionStart: Double?,
        processName: (LogEntry) -> String?,
        hidingRepeats: Bool
    ) -> String {
        switch column {
        case .time:
            return LogcatTime.format(
                entry.timestamp, style: options.timestampStyle, timeZone: zone,
                sessionStart: sessionStart, previous: previous?.timestamp
            )
        case .message:
            return entry.message
        default:
            break
        }
        guard entry.kind == .log else { return "" }
        // Compared with the entry above only when that one is a log line: a marker has no tag or package,
        // so what follows it shows its own again.
        let above = hidingRepeats ? previous.flatMap { $0.kind == .log ? $0 : nil } : nil
        switch column {
        case .level:
            return entry.level.letter
        case .pid:
            return options.pidStyle == .pid ? "\(entry.pid)" : "\(entry.pid)-\(entry.tid)"
        case .tag:
            if options.hideRepeatedTags, let above, !entry.tag.isEmpty, above.tag == entry.tag { return "" }
            return entry.tag
        case .package:
            let text = Self.packageText(process: processName(entry), pid: entry.pid)
            if options.hideRepeatedPackages, let above, !text.isEmpty,
               Self.packageText(process: processName(above), pid: above.pid) == text
            {
                return ""
            }
            return text
        case .process:
            let text = processName(entry) ?? ""
            if options.hideRepeatedProcesses, let above, !text.isEmpty, (processName(above) ?? "") == text { return "" }
            return text
        case .time, .message:
            return ""
        }
    }
}
