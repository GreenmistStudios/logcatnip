import AppKit
import LogcatKit
import SwiftUI

extension SignalKind {
    /// SF Symbol for the kind, in the badge, popover and anywhere else a signal is listed.
    var symbolName: String {
        switch self {
        case .crash: "exclamationmark.octagon.fill"
        case .nativeCrash: "bolt.trianglebadge.exclamationmark.fill"
        case .anr: "hourglass"
        case .outOfMemory: "memorychip"
        case .leak: "drop.fill"
        case .performance: "tortoise.fill"
        }
    }

    var color: Color { isFatal ? .red : .orange }
}

/// Which signals the popover lists.
enum SignalScope: String, CaseIterable, Identifiable {
    case all
    case fatal
    case warnings

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .fatal: "Fatal"
        case .warnings: "Warnings"
        }
    }

    func includes(_ kind: SignalKind) -> Bool {
        switch self {
        case .all: true
        case .fatal: kind.isFatal
        case .warnings: !kind.isFatal
        }
    }
}

/// The status bar's crash and warning count. Click it for the list of groups.
struct SignalsBadge: View {
    let session: LogSession
    @State private var showingList = false

    var body: some View {
        let summary = session.signalSummary
        let fatal = summary.fatalText
        Button {
            showingList.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: fatal != nil ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(fatal != nil ? Color.red : Color.orange)
                if let fatal {
                    Text(fatal)
                        .foregroundStyle(.red)
                        .fontWeight(.medium)
                }
                if let warnings = summary.warningText {
                    Text(fatal == nil ? warnings : "· \(warnings)")
                        .foregroundStyle(Color.orange.opacity(0.85))
                }
            }
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Crashes, ANRs, leaks and jank in this session. Next Crash: ⌘'")
        .popover(isPresented: $showingList, arrowEdge: .top) {
            SignalsPopover(session: session)
        }
    }
}

/// Groups of identical signals, newest first, each expandable to its occurrences. Clicking an occurrence
/// selects it in the table without touching the filter; ones the filter hides are greyed out.
///
/// Reads only `session.signalSummary` plus per-occurrence lookups, so the body does no more than format.
struct SignalsPopover: View {
    static let size = CGSize(width: 500, height: 340)

    let session: LogSession
    @State private var scope: SignalScope
    @State private var expanded: Set<String>

    init(session: LogSession, scope: SignalScope = .all, expanded: Set<String> = []) {
        self.session = session
        _scope = State(initialValue: scope)
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        // A refilter or trim changes which occurrences are hidden without changing the summary.
        let _ = session.visibilityGeneration
        let summary = session.signalSummary
        let groups = summary.groups.filter { scope.includes($0.kind) }
        VStack(spacing: 0) {
            Picker("Show", selection: $scope) {
                ForEach(SignalScope.allCases) { scope in
                    Text(title(of: scope, in: summary)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if groups.isEmpty {
                Text(scope == .warnings ? "No leaks or jank" : scope == .fatal ? "No crashes or ANRs" : "Nothing found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            groupRows(group)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func title(of scope: SignalScope, in summary: SignalSummary) -> String {
        let count = switch scope {
        case .all: summary.fatalCount + summary.warningCount
        case .fatal: summary.fatalCount
        case .warnings: summary.warningCount
        }
        return "\(scope.title) (\(count))"
    }

    @ViewBuilder
    private func groupRows(_ group: SignalGroup) -> some View {
        let newest = group.occurrenceIDs.last
        // The newest occurrence the filter shows, which a click on the group goes to.
        let target = group.occurrenceIDs.last { session.occurrenceIsVisible(id: $0) }
        let isExpanded = expanded.contains(group.id)
        SignalGroupRow(
            group: group,
            isExpanded: isExpanded,
            isHidden: target == nil,
            toggle: {
                if isExpanded { expanded.remove(group.id) } else { expanded.insert(group.id) }
            },
            select: { if let target { session.revealOccurrence(id: target) } }
        )
        .contextMenu {
            if let newest, let occurrence = session.signals.occurrence(id: newest) {
                SignalOccurrenceMenu(session: session, occurrence: occurrence)
            }
        }
        if isExpanded {
            ForEach(group.occurrenceIDs.reversed(), id: \.self) { id in
                if let occurrence = session.signals.occurrence(id: id) {
                    SignalOccurrenceRow(
                        occurrence: occurrence,
                        isHidden: !session.occurrenceIsVisible(id: id),
                        select: { session.revealOccurrence(id: id) }
                    )
                    .contextMenu { SignalOccurrenceMenu(session: session, occurrence: occurrence) }
                }
            }
        }
    }
}

/// The actions on one occurrence, shown when it's right-clicked in the popover (and on a group, for its
/// newest occurrence).
struct SignalOccurrenceMenu: View {
    let session: LogSession
    let occurrence: SignalOccurrence
    @AppStorage(SettingsKey.editor) private var editor = Editor.androidStudio

    var body: some View {
        if session.occurrenceIsVisible(occurrence) {
            Button("Show in Log") { session.revealOccurrence(id: occurrence.id) }
        }
        Button(occurrence.kind.copyReportTitle) { session.copyCrashReport(for: occurrence.id) }
        Button("Copy Signature") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(occurrence.signature.displayText, forType: .string)
        }
        // The frame is found on click: building the menu only reads settings, since SwiftUI may build it
        // for every row.
        if LogSession.hasTopFrame(occurrence.kind), let opener = session.sourceOpener {
            Divider()
            if opener.hasRoots {
                Button("Open Top Frame in \(editor.menuName)") {
                    if let reference = session.topFrameReference(for: occurrence) {
                        opener.open(reference)
                    } else {
                        NSSound.beep()
                    }
                }
            } else {
                Button("Set Source Folder…") { opener.showSettings() }
            }
        }
    }
}

private struct SignalGroupRow: View {
    let group: SignalGroup
    let isExpanded: Bool
    let isHidden: Bool
    let toggle: () -> Void
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide occurrences" : "Show occurrences")

            Image(systemName: group.kind.symbolName)
                .foregroundStyle(group.kind.color)
                .frame(width: 16)
                .help(group.kind.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.signature.displayText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(group.signature.package ?? group.kind.title)
                    if isHidden { Text("Hidden by filter").italic() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if group.count > 1 {
                Text("×\(group.count)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(LogcatTime.format(group.lastTimestamp, includeDate: false))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(isHidden ? 0.5 : 1)
        .background(hovering && !isHidden ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isHidden { select() } }
        .help(isHidden ? "The filter hides every occurrence" : "Show the latest occurrence")
    }
}

private struct SignalOccurrenceRow: View {
    let occurrence: SignalOccurrence
    let isHidden: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(LogcatTime.format(occurrence.timestamp, includeDate: false))
            // An ANR's pid is system_server's, which says nothing about the app.
            if occurrence.kind != .anr {
                Text(verbatim: "pid \(occurrence.pid)")
                    .foregroundStyle(.secondary)
            }
            if isHidden {
                Text("Hidden by filter")
                    .italic()
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.leading, 50)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .opacity(isHidden ? 0.5 : 1)
        .background(hovering && !isHidden ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isHidden { select() } }
        .help(isHidden ? "The filter hides this occurrence" : "Show in the log")
    }
}

extension SignalKind {
    /// "Crash report" would oversell a leak or a dropped frame, so only fatal kinds get it.
    var copyReportTitle: String {
        isFatal ? "Copy Crash Report" : "Copy Report"
    }
}
