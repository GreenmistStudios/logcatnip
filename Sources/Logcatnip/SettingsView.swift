import LogcatKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.adbPath) private var adbPath = ""
    @AppStorage(SettingsKey.myPackages) private var myPackages = ""
    @AppStorage(SettingsKey.maxEntries) private var maxEntries = Defaults.maxEntries
    @AppStorage(SettingsKey.fontSize) private var fontSize = Defaults.fontSize
    @AppStorage(SettingsKey.logcatBuffers) private var logcatBuffers = ""
    @AppStorage(SettingsKey.autoOpenSessions) private var autoOpenSessions = true
    @AppStorage(SettingsKey.filterHistoryAutocomplete) private var filterHistoryAutocomplete = false
    @AppStorage(SettingsKey.defaultFilter) private var defaultFilter: String?
    @AppStorage(SettingsKey.mostRecentlyUsedFilterIsDefault) private var mostRecentlyUsedFilterIsDefault = false

    var body: some View {
        Form {
            Section("adb") {
                TextField("adb path", text: $adbPath, prompt: Text("Detect automatically"))
                    .onSubmit { model.connectADB() }
                HStack {
                    Text(model.adb?.executable.path ?? "Not found")
                        .font(.caption)
                        .foregroundStyle(model.adb == nil ? .red : .secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reconnect") { model.connectADB() }
                }
                Toggle("Open a session when a device connects", isOn: $autoOpenSessions)
            }

            Section("Filtering") {
                TextField("My packages", text: $myPackages, prompt: Text("com.example.app, com.example.debug"))
                Text("Used by the package:mine filter. Separate with commas or spaces. When empty, package:mine shows everything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                defaultFilterEditor
                Toggle("Use the most recently used filter", isOn: $mostRecentlyUsedFilterIsDefault)
                Text("New sessions start with the last filter applied in any session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                IgnoreListEditor(
                    title: "Ignored tags",
                    prompt: "Add a tag",
                    values: model.ignoreList.tags,
                    onChange: model.setIgnoredTags
                )
                IgnoreListEditor(
                    title: "Ignored packages",
                    prompt: "Add a package",
                    values: model.ignoreList.packages,
                    onChange: model.setIgnoredPackages
                )
                Text("Hidden in every session before the filter applies. Exact, case-sensitive match on the tag or package. Right-click a log line to ignore its tag or package; click “N ignored” in the status bar to show them in one session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include filter history in autocomplete", isOn: $filterHistoryAutocomplete)
                Text("Suggests favorite and recent filters while you type, like Android Studio's \"Add filters from history to autocomplete\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logcat") {
                TextField("Buffers", text: $logcatBuffers, prompt: Text("main, system, crash (logcat default)"))
                Text("Passed to logcat -b, e.g. main,system,crash,events or all. Applies to new and restarted sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Keep up to", selection: $maxEntries) {
                    ForEach([50_000, 100_000, 250_000, 500_000, 1_000_000], id: \.self) { count in
                        Text("\(count.formatted()) entries").tag(count)
                    }
                }
            }

            Section("Appearance") {
                Stepper(value: $fontSize, in: 9...20, step: 1) {
                    Text("Font size: \(Int(fontSize)) pt")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical)
    }

    /// What the field shows: the saved default, or the one the app would use until the user sets one.
    private var defaultFilterText: String {
        defaultFilter ?? DefaultFilter.fallback(myPackages: Defaults.myPackages)
    }

    private var defaultFilterError: FilterError? {
        do {
            _ = try LogFilter(defaultFilterText)
            return nil
        } catch {
            return error
        }
    }

    @ViewBuilder
    private var defaultFilterEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Default filter")
            FilterField(
                text: Binding(get: { defaultFilterText }, set: { defaultFilter = $0 }),
                placeholder: "Empty: new sessions show everything",
                focusRequest: 0,
                suggestions: { query, cursor in
                    model.selectedSession?.completionSuggestions(query: query, cursor: cursor)
                        ?? FilterCompletion.suggestions(
                            query: query, cursor: cursor,
                            source: FilterCompletionSource(myPackages: Defaults.myPackages.sorted())
                        )
                },
                onSubmit: {},
                isEditable: !mostRecentlyUsedFilterIsDefault
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(defaultFilterError == nil ? Color(nsColor: .separatorColor) : .red, lineWidth: 1)
            )
        }
        if let error = defaultFilterError {
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.red)
        }
        HStack {
            Text("New device sessions start with this filter. Until you change it, it is package:mine when My packages is set. Opened files start unfiltered.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if defaultFilter != nil {
                Spacer()
                Button("Use Default") { defaultFilter = nil }
            }
        }
    }
}

/// A list of values with a remove button each and a field to add one.
private struct IgnoreListEditor: View {
    let title: String
    let prompt: String
    let values: [String]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    private var newValue: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if values.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(values, id: \.self) { value in
                HStack {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        onChange(values.filter { $0 != value })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop ignoring \(value)")
                }
            }
            HStack {
                TextField(title, text: $draft, prompt: Text(prompt))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newValue.isEmpty)
            }
        }
    }

    private func add() {
        guard !newValue.isEmpty else { return }
        onChange(values + [newValue])
        draft = ""
    }
}
