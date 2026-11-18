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
}
