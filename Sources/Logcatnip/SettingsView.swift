import LogcatKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updater
    @AppStorage(SettingsKey.adbPath) private var adbPath = ""
    @AppStorage(SettingsKey.myPackages) private var myPackages = ""
    @AppStorage(SettingsKey.maxEntries) private var maxEntries = Defaults.maxEntries
    @AppStorage(SettingsKey.fontSize) private var fontSize = Defaults.fontSize
    @AppStorage(SettingsKey.logcatBuffers) private var logcatBuffers = ""
    @AppStorage(SettingsKey.autoOpenSessions) private var autoOpenSessions = true
    @AppStorage(SettingsKey.showSimulators) private var showSimulators = true
    @AppStorage(SettingsKey.checkForUpdates) private var checkForUpdates = true
    @AppStorage(SettingsKey.crashReportContextLines) private var crashReportContextLines = Defaults.crashReportContextLines
    @AppStorage(SettingsKey.editor) private var editor = Editor.androidStudio
    @AppStorage(SettingsKey.customEditorTemplate) private var customEditorTemplate = ""

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

            Section("iOS Simulators") {
                Toggle("Show booted simulators", isOn: $showSimulators)
                    .onChange(of: showSimulators) { model.connectSimulators() }
                if showSimulators {
                    if let error = model.simctlError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } else {
                        Text(model.simctl?.executable.path ?? "Looking for Xcode…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text("Streams each simulator's unified log with simctl, which comes with Xcode. Android devices work without Xcode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Filtering") {
                TextField("My packages", text: $myPackages, prompt: Text("com.example.app, com.example.debug"))
                Text("Used by the package:mine filter. Separate with commas or spaces. When empty, package:mine shows everything.")
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
                Stepper(value: $crashReportContextLines, in: 0...500, step: 10) {
                    Text("Crash report context: \(crashReportContextLines) lines")
                }
            }

            SourceCodeSettings(
                editor: $editor,
                customTemplate: $customEditorTemplate,
                roots: model.sourceOpener.roots,
                add: addSourceRoots,
                remove: { model.sourceOpener.removeRoots($0) }
            )

            Section("Appearance") {
                Stepper(value: $fontSize, in: 9...20, step: 1) {
                    Text("Font size: \(Int(fontSize)) pt")
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updater.versionDescription)
                        if let lastChecked = updater.lastChecked {
                            Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Check Now") { updater.check(userInitiated: true) }
                    .disabled(updater.isBusy)
                }
                if let blocker = updater.installBlocker {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical)
    }

    private func addSourceRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the folders of your Android projects."
        guard panel.runModal() == .OK else { return }
        model.sourceOpener.addRoots(panel.urls)
    }
}

/// Open in Editor settings. Takes its values as arguments so screenshot tests can render it.
struct SourceCodeSettings: View {
    @Binding var editor: Editor
    @Binding var customTemplate: String
    let roots: [String]
    let add: () -> Void
    let remove: (Set<String>) -> Void
    @State private var selection: Set<String> = []

    var body: some View {
        Section("Source Code") {
            Picker("Open stack frames in", selection: $editor) {
                ForEach(Editor.allCases) { editor in
                    Text(editor.title).tag(editor)
                }
            }
            if editor == .custom {
                TextField("Command or URL", text: $customTemplate, prompt: Text("zed {file}:{line}"))
                Text("{file} and {line} are replaced with the path and line. A command is run without a shell; a URL such as subl://open?url=file://{file}&line={line} is opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Source folders")
                List(roots, id: \.self, selection: $selection) { root in
                    Text(root)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(root)
                }
                .frame(height: 90)
                .overlay {
                    if roots.isEmpty {
                        Text("No folders")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Add…", action: add)
                    Button("Remove") {
                        remove(selection)
                        selection = []
                    }
                    .disabled(selection.isEmpty)
                }
            }
            Text("Right-click a stack frame to open its file. Folders are searched for the file at its package path; build output is skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
