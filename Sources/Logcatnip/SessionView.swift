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
            if session.find.isVisible {
                FindBar(find: session.find)
                Divider()
            }
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
    @FocusState private var focused: Bool
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

            TextField("Filter: tag:MyTag level:WARN package:mine is:crash -tag:Noisy …", text: $session.filterQuery)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit {
                    session.applyFilterNow()
                    FilterLibrary.remember(session.filterQuery)
                    libraryVersion += 1
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(session.filterError == nil ? Color(nsColor: .separatorColor) : .red, lineWidth: 1)
                )
                .help(session.filterError?.message ?? "Android Studio logcat query syntax. Click ? for help.")

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
                Text("Any Level").tag(LogLevel?.none)
                Divider()
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.name.capitalized).tag(LogLevel?.some(level))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Minimum log level (edits the level: term)")

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
        .onChange(of: session.focusFilterRequest) { focused = true }
    }

    private var isFavorite: Bool {
        _ = libraryVersion
        return FilterLibrary.isFavorite(session.filterQuery)
    }

    private var levelBinding: Binding<LogLevel?> {
        Binding(
            get: { session.minimumLevel },
            set: { session.setMinimumLevel($0) }
        )
    }

    @ViewBuilder
    private var filterLibraryMenu: some View {
        let _ = libraryVersion
        let favorites = FilterLibrary.favorites
        let history = FilterLibrary.history
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites, id: \.self) { query in
                    Button(query) { use(query) }
                }
            }
        }
        if !history.isEmpty {
            Section("Recent") {
                ForEach(history, id: \.self) { query in
                    Button(query) { use(query) }
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

    private var countText: String {
        let total = session.totalCount.formatted()
        if session.filter.matchesEverything {
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
        ("pid:123  tid:456", "Process or thread id"),
        ("name:\"My filter\"", "Names the filter"),
        ("foo bar  \"foo bar\"", "Free text anywhere in the line"),
        ("&  |  ( )", "AND, OR and grouping; & binds tighter than |"),
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
            Text("Without operators, terms with the same key are ORed and everything else is ANDed: `tag:a tag:b level:W` means `(tag:a | tag:b) & level:W`. Quote values that contain spaces, & or |. Right-click a log line to filter by its tag, package or process.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 560)
    }
}
