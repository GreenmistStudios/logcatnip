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
                let online = model.deviceGroups.filter(\.isOnline)
                ForEach(online) { group in
                    Button(group.displayName) { model.openSession(serial: group.primary.serial) }
                }
                if online.isEmpty {
                    Text("No devices connected")
                }
            }
            Button("Connect over Wi-Fi…") { model.wireless.presentSheet(tab: .qrCode) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.adb == nil)
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
            Button("Save Visible Logs As…") {
                if let session { FilePanels.save(session, visibleOnly: true) }
            }
            .keyboardShortcut("s")
            .disabled(session == nil || session?.isSaving == true)
            Button("Save All Logs As…") {
                if let session { FilePanels.save(session, visibleOnly: false) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session == nil || session?.isSaving == true)
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
        panel.allowedContentTypes = [.logcatFile, .plainText, .log, .data]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.openFile(url)
        }
    }

    /// Save As…: the panel offers the format and whether to save what is visible or everything. The format is
    /// remembered for next time; the entries preset follows the menu item that was used.
    static func save(_ session: LogSession, visibleOnly: Bool) {
        guard !session.isSaving else { return }
        let remembered = LogSaveFormat(rawValue: UserDefaults.standard.string(forKey: SettingsKey.saveFormat) ?? "") ?? .logcat
        let panel = NSSavePanel()
        panel.title = visibleOnly ? "Save Visible Logs" : "Save All Logs"
        panel.allowedContentTypes = [remembered.contentType]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = remembered.suggestedFileName(base: session.baseTitle, date: Date())
        let accessory = SaveOptionsAccessory(
            panel: panel, format: remembered, visibleOnly: visibleOnly,
            visibleCount: session.visibleCount, totalCount: session.totalCount
        )
        panel.accessoryView = accessory.view
        let response = withExtendedLifetime(accessory) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(accessory.format.rawValue, forKey: SettingsKey.saveFormat)
        session.save(to: url, format: accessory.format, visibleOnly: accessory.visibleOnly)
    }
}

/// The Format and Entries popups under the save panel. Changing the format switches the panel's file type and the
/// extension of the name typed so far.
@MainActor
final class SaveOptionsAccessory: NSObject {
    let view: NSView
    private(set) var format: LogSaveFormat
    private(set) var visibleOnly: Bool
    private weak var panel: NSSavePanel?
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let entriesPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSSavePanel, format: LogSaveFormat, visibleOnly: Bool, visibleCount: Int, totalCount: Int) {
        self.panel = panel
        self.format = format
        self.visibleOnly = visibleOnly

        formatPopup.addItems(withTitles: LogSaveFormat.allCases.map(\.title))
        formatPopup.selectItem(at: LogSaveFormat.allCases.firstIndex(of: format) ?? 0)
        entriesPopup.addItems(withTitles: [
            "Visible entries (\(visibleCount.formatted()))", "All entries (\(totalCount.formatted()))",
        ])
        entriesPopup.selectItem(at: visibleOnly ? 0 : 1)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), formatPopup],
            [NSTextField(labelWithString: "Entries:"), entriesPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        view = container

        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        entriesPopup.target = self
        entriesPopup.action = #selector(entriesChanged(_:))
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard LogSaveFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        format = LogSaveFormat.allCases[sender.indexOfSelectedItem]
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format.fileName(switching: panel.nameFieldStringValue)
    }

    @objc private func entriesChanged(_ sender: NSPopUpButton) {
        visibleOnly = sender.indexOfSelectedItem == 0
    }
}

extension LogSaveFormat {
    var contentType: UTType {
        self == .logcat ? .logcatFile : .plainText
    }
}

extension UTType {
    static let log = UTType(filenameExtension: "log") ?? .plainText
    /// Android Studio's `.logcat` JSON. Inside the app bundle this is the type declared in Info.plist; without it
    /// (`swift run`) it is a dynamic type that still carries the extension.
    static let logcatFile = UTType(filenameExtension: "logcat", conformingTo: .json) ?? .json
}
