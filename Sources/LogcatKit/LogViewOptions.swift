import Foundation

/// A table column. Raw values are stable: they are saved in the default view options.
public enum LogColumn: String, Codable, CaseIterable, Sendable {
    case time, pid, tag, package, process, level, message
}

public enum TimestampStyle: String, Codable, CaseIterable, Sendable {
    /// `2026-11-09 18:15:32.663`
    case dateTime
    /// `18:15:32.663`
    case time
    /// Seconds since 1970, `1794248132.663`.
    case epoch
    /// Seconds since the session's first entry, `+12.345s`.
    case sinceStart
    /// Time since the previous visible row, `Δ 3 ms`.
    case delta

    /// Character cells of the widest text the style prints, for sizing the Time column in a monospaced font.
    public var sampleCells: Int {
        switch self {
        case .dateTime: 23
        case .time: 12
        case .epoch: 14
        case .sinceStart: 11  // "+99999.999s"
        case .delta: 13  // "Δ 99999.999 s"
        }
    }
}

public enum TimestampZone: String, Codable, CaseIterable, Sendable {
    case local, utc
}

public enum PidStyle: String, Codable, CaseIterable, Sendable {
    case pid, pidTid

    /// Cells of the widest text the style prints in practice (Android's default `pid_max` is 32768).
    public var sampleCells: Int {
        switch self {
        case .pid: 6
        case .pidTid: 12
        }
    }
}

/// How a session lays out its entries: the column table, or one card per entry (Wirecat's layout).
public enum LogLayout: String, Codable, CaseIterable, Sendable {
    case table, cards
}

/// How a session's table shows its entries, after Android Studio's `FormattingOptions`. Two presets are
/// defined; any option that differs from both makes the view Custom, and picking a preset copies it back.
/// The layout is the exception: it is not part of a preset, so Standard and Compact choose the fields and
/// the layout chooses how they are drawn.
public struct LogViewOptions: Codable, Sendable, Hashable {
    public enum Preset: String, CaseIterable, Sendable {
        case standard, compact

        public var options: LogViewOptions {
            switch self {
            case .standard: .standard
            case .compact: .compact
            }
        }
    }

    /// Tag, package and process widths are kept in characters, within these bounds (Android Studio's).
    public static let widthRange = 10...100

    /// Always contains `.message`: a table without it would show nothing readable.
    public var visibleColumns: Set<LogColumn>
    public var timestampStyle: TimestampStyle
    public var timeZone: TimestampZone
    public var pidStyle: PidStyle
    public private(set) var tagWidth: Int
    public private(set) var packageWidth: Int
    public private(set) var processWidth: Int
    public var hideRepeatedTags: Bool
    public var hideRepeatedPackages: Bool
    public var hideRepeatedProcesses: Bool
    public var colorTags: Bool
    public var layout: LogLayout

    public init(
        visibleColumns: Set<LogColumn>,
        timestampStyle: TimestampStyle,
        timeZone: TimestampZone = .local,
        pidStyle: PidStyle = .pidTid,
        tagWidth: Int = 23,
        packageWidth: Int = 35,
        processWidth: Int = 35,
        hideRepeatedTags: Bool = false,
        hideRepeatedPackages: Bool = false,
        hideRepeatedProcesses: Bool = false,
        colorTags: Bool = true,
        layout: LogLayout = .table
    ) {
        self.visibleColumns = visibleColumns.union([.message])
        self.timestampStyle = timestampStyle
        self.timeZone = timeZone
        self.pidStyle = pidStyle
        self.tagWidth = Self.clamp(tagWidth)
        self.packageWidth = Self.clamp(packageWidth)
        self.processWidth = Self.clamp(processWidth)
        self.hideRepeatedTags = hideRepeatedTags
        self.hideRepeatedPackages = hideRepeatedPackages
        self.hideRepeatedProcesses = hideRepeatedProcesses
        self.colorTags = colorTags
        self.layout = layout
    }

    /// Date and time, PID-TID, tag, package, level and message, like Android Studio's Standard view.
    public static let standard = LogViewOptions(
        visibleColumns: [.time, .pid, .tag, .package, .level, .message],
        timestampStyle: .dateTime
    )

    /// Time, tag, level and message. Android Studio's Compact view drops the tag too; the issue keeps it.
    public static let compact = LogViewOptions(
        visibleColumns: [.time, .tag, .level, .message],
        timestampStyle: .time
    )

    /// The preset these options equal, or nil for a Custom view. The layout is ignored: a card view with
    /// Compact's fields is still Compact.
    public var preset: Preset? {
        var copy = self
        copy.layout = .table
        if copy == .standard { return .standard }
        if copy == .compact { return .compact }
        return nil
    }

    /// Switches to a preset's fields and keeps the layout, so picking Compact while in cards stays in cards.
    public mutating func apply(_ preset: Preset) {
        let layout = self.layout
        self = preset.options
        self.layout = layout
    }

    /// Whether a card has a first line: it holds the level badge, tag and time, so it exists when any shows.
    public var cardHasHeader: Bool {
        isVisible(.level) || isVisible(.tag) || isVisible(.time)
    }

    /// Whether a card has a last line: it holds the PID/TID, package and process.
    public var cardHasFooter: Bool {
        isVisible(.pid) || isVisible(.package) || isVisible(.process)
    }

    public func isVisible(_ column: LogColumn) -> Bool {
        visibleColumns.contains(column)
    }

    /// Shows or hides a column. The message column cannot be hidden.
    public mutating func setVisible(_ column: LogColumn, _ visible: Bool) {
        if visible || column == .message {
            visibleColumns.insert(column)
        } else {
            visibleColumns.remove(column)
        }
    }

    /// Width in characters of the columns that have one (tag, package, process); nil for the others.
    public func width(of column: LogColumn) -> Int? {
        switch column {
        case .tag: tagWidth
        case .package: packageWidth
        case .process: processWidth
        default: nil
        }
    }

    /// Sets a column's width, clamped to `widthRange`. Columns without a stored width are left alone.
    public mutating func setWidth(_ characters: Int, of column: LogColumn) {
        let width = Self.clamp(characters)
        switch column {
        case .tag: tagWidth = width
        case .package: packageWidth = width
        case .process: processWidth = width
        default: break
        }
    }

    /// Whether `other` differs from these options in the three widths at most, so the table can resize
    /// columns without reloading its rows.
    public func differsOnlyInWidths(from other: LogViewOptions) -> Bool {
        var copy = self
        copy.tagWidth = other.tagWidth
        copy.packageWidth = other.packageWidth
        copy.processWidth = other.processWidth
        return copy == other
    }

    private static func clamp(_ width: Int) -> Int {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// One line for the debug output: the preset, the options, and nothing that needs the UI.
    public var summary: String {
        let columns = LogColumn.allCases.filter(isVisible).map(\.rawValue).joined(separator: ",")
        let hide = [
            hideRepeatedTags ? "tag" : "-",
            hideRepeatedPackages ? "pkg" : "-",
            hideRepeatedProcesses ? "proc" : "-",
        ].joined(separator: "/")
        return "preset=\(preset?.rawValue ?? "custom") columns=\(columns) "
            + "time=\(timestampStyle.rawValue)/\(timeZone.rawValue) pid=\(pidStyle.rawValue) "
            + "widths=\(tagWidth)/\(packageWidth)/\(processWidth) hide=\(hide) colors=\(colorTags ? "on" : "off") "
            + "layout=\(layout.rawValue)"
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case visibleColumns, timestampStyle, timeZone, pidStyle, tagWidth, packageWidth, processWidth
        case hideRepeatedTags, hideRepeatedPackages, hideRepeatedProcesses, colorTags, layout
    }

    /// Lenient on purpose: the options are saved as a Settings value that a newer or older build may have
    /// written, so a missing key, an unknown column or an unknown style falls back to Standard's value
    /// instead of failing the whole decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, as type: T.Type = T.self) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let standard = LogViewOptions.standard
        let names: [String]? = value(.visibleColumns)
        self.init(
            visibleColumns: names.map { Set($0.compactMap(LogColumn.init(rawValue:))) } ?? standard.visibleColumns,
            timestampStyle: value(.timestampStyle) ?? standard.timestampStyle,
            timeZone: value(.timeZone) ?? standard.timeZone,
            pidStyle: value(.pidStyle) ?? standard.pidStyle,
            tagWidth: value(.tagWidth) ?? standard.tagWidth,
            packageWidth: value(.packageWidth) ?? standard.packageWidth,
            processWidth: value(.processWidth) ?? standard.processWidth,
            hideRepeatedTags: value(.hideRepeatedTags) ?? standard.hideRepeatedTags,
            hideRepeatedPackages: value(.hideRepeatedPackages) ?? standard.hideRepeatedPackages,
            hideRepeatedProcesses: value(.hideRepeatedProcesses) ?? standard.hideRepeatedProcesses,
            colorTags: value(.colorTags) ?? standard.colorTags,
            layout: value(.layout) ?? standard.layout
        )
    }

    /// Writes the columns in `LogColumn.allCases` order so the same options always encode to the same JSON.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(LogColumn.allCases.filter(isVisible).map(\.rawValue), forKey: .visibleColumns)
        try container.encode(timestampStyle, forKey: .timestampStyle)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(pidStyle, forKey: .pidStyle)
        try container.encode(tagWidth, forKey: .tagWidth)
        try container.encode(packageWidth, forKey: .packageWidth)
        try container.encode(processWidth, forKey: .processWidth)
        try container.encode(hideRepeatedTags, forKey: .hideRepeatedTags)
        try container.encode(hideRepeatedPackages, forKey: .hideRepeatedPackages)
        try container.encode(hideRepeatedProcesses, forKey: .hideRepeatedProcesses)
        try container.encode(colorTags, forKey: .colorTags)
        try container.encode(layout, forKey: .layout)
    }
}
