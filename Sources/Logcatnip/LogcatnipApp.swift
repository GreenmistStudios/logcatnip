import AppKit
import LogcatKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LogcatnipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        Defaults.register()
    }

    var body: some Scene {
        Window("Logcatnip", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 500)
                .task {
                    appDelegate.model = model
                    model.start()
                }
        }
        .commands {
            LogcatCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct FocusedSessionKey: FocusedValueKey {
    typealias Value = LogSession
}

extension FocusedValues {
    var session: LogSession? {
        get { self[FocusedSessionKey.self] }
        set { self[FocusedSessionKey.self] = newValue }
    }
}

struct LogcatCommands: Commands {
    let model: AppModel
    @FocusedValue(\.session) private var session
    @AppStorage(SettingsKey.wrapLines) private var wrapLines = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New Session") {
                ForEach(model.devices.filter(\.isOnline)) { device in
                    Button(device.displayName) { model.openSession(serial: device.serial) }
                }
                if model.devices.filter(\.isOnline).isEmpty {
                    Text("No devices connected")
                }
            }
            Button("Open Log File…") { FilePanels.openLogFile(model: model) }
                .keyboardShortcut("o")
            Divider()
            Button("Close Session") {
                if let session { model.close(session) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(session == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export Visible Logs…") {
                if let session { FilePanels.export(session, visibleOnly: true) }
            }
            .keyboardShortcut("s")
            .disabled(session == nil)
            Button("Export All Logs…") {
                if let session { FilePanels.export(session, visibleOnly: false) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session == nil)
        }
        CommandMenu("Logcat") {
            Button(session?.isPaused == true ? "Resume" : "Pause") { session?.isPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Clear") { session?.clear() }
                .keyboardShortcut("k")
                .disabled(session == nil)
            Button("Clear Device Log Buffer") { session?.clearDeviceBuffer() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(session?.serial == nil)
            Button("Restart Logcat") { session?.restart() }
                .keyboardShortcut("r")
                .disabled(session?.serial == nil)
            Divider()
            Button("Find / Filter") { session?.focusFilterRequest += 1 }
                .keyboardShortcut("f")
                .disabled(session == nil)
            Button("Scroll to End") { session?.autoScroll = true }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(session == nil)
            Toggle("Wrap Lines", isOn: $wrapLines)
            Divider()
            Menu("Minimum Level") {
                Button("Any") { session?.setMinimumLevel(nil) }
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button(level.name.capitalized) { session?.setMinimumLevel(level) }
                }
            }
            .disabled(session == nil)
        }
    }
}

@MainActor
enum FilePanels {
    static func openLogFile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .log, .data]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.openFile(url)
        }
    }

    static func export(_ session: LogSession, visibleOnly: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = LogcatTime.format(Date().timeIntervalSince1970).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(session.baseTitle) \(stamp).logcat.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = session.exportText(visibleOnly: visibleOnly)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension UTType {
    static let log = UTType(filenameExtension: "log") ?? .plainText
}
