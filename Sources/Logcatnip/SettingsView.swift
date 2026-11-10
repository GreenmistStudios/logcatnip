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
    @AppStorage(SettingsKey.defaultViewOptions) private var viewOptionsJSON = ""
    @State private var customizingView = false

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

            Section("Log View") {
                PresetPicker(title: "New sessions", options: defaultViewOptions)
                    .pickerStyle(.menu)
                Button("Customize…") { customizingView = true }
                Text("The view a session starts with, as a table or as cards. Each session can change its own with View › Modify View….")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical)
        .sheet(isPresented: $customizingView) {
            VStack(spacing: 0) {
                ViewOptionsForm(options: defaultViewOptions)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { customizingView = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 460, height: 620)
        }
    }

    /// The saved default, as options. Standard is stored as nothing, which is also the registered default.
    private var defaultViewOptions: Binding<LogViewOptions> {
        Binding(
            get: { LogViewOptions(json: viewOptionsJSON) ?? .standard },
            set: { viewOptionsJSON = $0 == .standard ? "" : $0.json }
        )
    }
}
