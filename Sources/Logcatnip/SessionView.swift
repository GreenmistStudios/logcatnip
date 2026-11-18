import LogcatKit
import SwiftUI

struct SessionView: View {
    let session: LogSession
    @AppStorage(SettingsKey.fontSize) private var fontSize = Defaults.fontSize
    @AppStorage("showDate") private var showDate = false
    @AppStorage(SettingsKey.wrapLines) private var wrapLines = false

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(session: session)
            Divider()
            LogTableView(session: session, fontSize: fontSize, showDate: showDate, wrapLines: wrapLines)
            Divider()
            StatusBar(session: session)
        }
        .focusedSceneValue(\.session, session)
        .toolbar { SessionToolbar(session: session, showDate: $showDate, wrapLines: $wrapLines) }
    }
}

private struct SessionToolbar: ToolbarContent {
    @Bindable var session: LogSession
    @Binding var showDate: Bool
    @Binding var wrapLines: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $wrapLines) {
                Label("Wrap Lines", systemImage: "arrow.turn.down.left")
            }
            .help(wrapLines ? "Stop wrapping long lines" : "Wrap long lines to the window width")

            Button {
                session.isPaused.toggle()
            } label: {
                Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .help(session.isPaused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)")

            Button {
                session.autoScroll = true
            } label: {
                Label("Scroll to End", systemImage: session.autoScroll ? "arrow.down.to.line.compact" : "arrow.down.to.line")
            }
            .help("Scroll to the end and follow new logs (⌘↓)")
            .disabled(session.autoScroll)

            Menu {
                Button("Clear View") { session.clear() }
                Button("Clear Device Log Buffer") { session.clearDeviceBuffer() }
                    .disabled(session.serial == nil)
            } label: {
                Label("Clear", systemImage: "trash")
            } primaryAction: {
                session.clear()
            }
            .help("Clear the view (⌘K). Hold for more options.")

            if session.serial != nil {
                Button {
                    session.restart()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .help("Restart logcat (⌘R)")
            }

            Menu {
                Toggle("Show Date", isOn: $showDate)
                Divider()
                Button("Export Visible Logs…") { FilePanels.export(session, visibleOnly: true) }
                Button("Export All Logs…") { FilePanels.export(session, visibleOnly: false) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

struct FilterBar: View {
    @Bindable var session: LogSession
    @State private var showingHelp = false
    @State private var libraryVersion = 0

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                filterLibraryMenu
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Favorite and recent filters")

            FilterField(
                text: $session.filterQuery,
                placeholder: "Filter: tag:MyTag level:WARN package:mine is:crash -tag:Noisy … (⌃Space for suggestions)",
                focusRequest: session.focusFilterRequest,
                suggestions: { session.completionSuggestions(query: $0, cursor: $1) },
                onSubmit: {
                    session.applyFilterNow()
                    FilterLibrary.remember(session.filterQuery)
                    libraryVersion += 1
                }
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(session.filterError == nil ? Color(nsColor: .separatorColor) : .red, lineWidth: 1)
            )

            if !session.filterQuery.isEmpty {
                Button {
                    session.filterQuery = ""
                    session.applyFilterNow()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
            }

            Button {
                FilterLibrary.toggleFavorite(session.filterQuery)
                libraryVersion += 1
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(session.filterQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Save filter as favorite")

            Toggle(isOn: $session.caseSensitive) {
                Text("Aa")
                    .font(.system(.body, design: .monospaced))
            }
            .toggleStyle(.button)
            .help("Match case")

            Picker("Level", selection: levelBinding) {
                Text("Any Level").tag(LevelSelection.any)
                Divider()
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.name.capitalized).tag(LevelSelection.minimum(level))
                }
                // Without a matching tag the pop-up would show nothing for a level the picker cannot express.
                if session.levelSelection == .mixed {
                    Divider()
                    Text("Mixed").tag(LevelSelection.mixed)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Minimum log level (edits the top-level level: term; Mixed when the level comes from is: or a group)")

            Button {
                showingHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                FilterHelpView()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var isFavorite: Bool {
        _ = libraryVersion
        return FilterLibrary.isFavorite(session.filterQuery)
    }

    private var levelBinding: Binding<LevelSelection> {
        Binding(
            get: { session.levelSelection },
            set: { selection in
                switch selection {
                case .any: session.setMinimumLevel(nil)
                case let .minimum(level): session.setMinimumLevel(level)
                case .mixed: break
                }
            }
        )
    }

    @ViewBuilder
    private var filterLibraryMenu: some View {
        let _ = libraryVersion
        let favorites = FilterLibrary.favorites
        let history = FilterLibrary.history
        let flagged = FilterLibrary.precedenceChanged
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites, id: \.self) { query in
                    Button(flagged.contains(query) ? "⚠︎ \(query)" : query) { use(query) }
                }
            }
        }
        if !history.isEmpty {
            Section("Recent") {
                ForEach(history, id: \.self) { query in
                    Button(flagged.contains(query) ? "⚠︎ \(query)" : query) { use(query) }
                }
            }
            Divider()
            Button("Clear Recent Filters") {
                FilterLibrary.clearHistory()
                libraryVersion += 1
            }
        }
        if favorites.isEmpty && history.isEmpty {
            Text("No saved filters")
        }
        if !flagged.isEmpty {
            Divider()
            Text("⚠︎ Meaning changed: spaces now bind looser than & and |")
            Button("Dismiss ⚠︎ Warnings") {
                FilterLibrary.dismissPrecedenceWarnings()
                libraryVersion += 1
            }
        }
        Divider()
        Section("Examples") {
            ForEach(FilterHelpView.examples, id: \.query) { example in
                Button("\(example.query)  —  \(example.description)") { use(example.query) }
            }
        }
    }

    private func use(_ query: String) {
        session.filterQuery = query
        session.applyFilterNow()
        FilterLibrary.remember(query)
        libraryVersion += 1
    }
}

struct StatusBar: View {
    let session: LogSession

    var body: some View {
        HStack(spacing: 12) {
            if let error = session.filterError {
                Label(error.message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let name = session.filter.name {
                Label(name, systemImage: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            } else if !session.autoScroll {
                Text("Not following")
                    .foregroundStyle(.secondary)
            }
            if session.ignoredCount > 0 || session.showIgnored {
                ignoredButton
            }
            Text(session.status.label)
                .foregroundStyle(statusColor)
            Text(countText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Shows or hides the entries on the ignore lists in this session only.
    private var ignoredButton: some View {
        let count = session.ignoredCount.formatted()
        return Button {
            session.showIgnored.toggle()
        } label: {
            Label(
                session.showIgnored ? "Showing \(count) ignored" : "\(count) ignored",
                systemImage: session.showIgnored ? "eye" : "eye.slash"
            )
        }
        .buttonStyle(.borderless)
        .foregroundStyle(session.showIgnored ? Color.orange : Color.secondary)
        .help(session.showIgnored
            ? "Hide entries on the ignore lists again"
            : "Entries hidden by the ignore lists in Settings › Filtering. Click to show them in this session.")
    }

    private var countText: String {
        let total = session.totalCount.formatted()
        if session.filter.matchesEverything, session.ignoredCount == 0 || session.showIgnored {
            return "\(total) entries"
        }
        return "\(session.visibleCount.formatted()) of \(total) entries"
    }

    private var statusColor: Color {
        switch session.status {
        case .streaming: .green
        case .disconnected, .failed: .red
        default: .secondary
        }
    }
}

struct FilterHelpView: View {
    struct Example {
        let query: String
        let description: String
    }

    static let examples: [Example] = [
        Example(query: "package:mine", description: "your app's packages (set in Settings)"),
        Example(query: "level:WARN", description: "warnings and above"),
        Example(query: "is:crash", description: "crashes and ANRs"),
        Example(query: "is:stacktrace", description: "entries with stack traces"),
        Example(query: "tag:Activity -tag=:ActivityTaskManager", description: "tag contains / not equal"),
        Example(query: "tag~:^(Okhttp|Retrofit)", description: "tag regex"),
        Example(query: "age:5m", description: "logged in the last 5 minutes"),
        Example(query: "(tag:Net | tag:Http) & level:ERROR", description: "operators and grouping"),
        Example(query: "level:ERROR tag:Net | tag:Http", description: "errors from either tag"),
    ]

    private let rows: [(String, String)] = [
        ("tag:foo", "Tag contains foo"),
        ("tag=:foo", "Tag is exactly foo"),
        ("tag~:fo+", "Tag matches a regular expression"),
        ("-tag:foo", "Negate any term with a leading -"),
        ("package: process:", "Package (process name before :) or full process name"),
        ("message: line:", "Message, or the whole line"),
        ("package:mine", "Packages listed in Settings"),
        ("level:WARN", "WARN and above (V, D, I, W, E, A also work)"),
        ("age:30s age:5m age:2h age:1d", "Recent entries only"),
        ("is:crash  is:stacktrace", "Crashes / entries containing stack traces"),
        ("is:error  is:firebase", "Exactly one level / Firebase SDK tags"),
        ("pid:123  tid:456", "Process or thread id"),
        ("name:\"My filter\"", "Names the filter"),
        ("foo bar  \"foo bar\"", "Free text anywhere in the line"),
        ("&  |  ( )", "AND, OR and grouping; & binds tighter than |, spaces loosest"),
        ("⌃Space  ⌥Esc", "Suggest keys and values; ↑↓ choose, Tab or Return accept"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter Syntax")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.system(.body, design: .monospaced))
                        Text(row.1).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Spaces separate terms with the lowest precedence: `foo bar tag:a | tag:b` means `\"foo bar\" & (tag:a | tag:b)`. Among them, terms with the same key are ORed and the rest ANDed: `tag:a tag:b level:W` means `(tag:a | tag:b) & level:W`. Quote values that contain spaces, & or |. Right-click a log line to show only or hide its tag, package or process; the new term applies to the whole query. Ignore Tag or Package Everywhere hides it in every session; manage the lists in Settings › Filtering.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 560)
    }
}
