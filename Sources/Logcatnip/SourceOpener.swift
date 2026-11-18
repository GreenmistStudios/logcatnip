import AppKit
import LogcatKit
import SwiftUI

/// Open in Editor: the source folders, their `SourceLocator`, and launching the chosen editor.
///
/// Lookups that might walk a folder run in a detached task; menus only ask ``lookup(_:)``, which reads the
/// index as it is.
@MainActor
@Observable
final class SourceOpener {
    /// Folder paths, in the order they were added.
    private(set) var roots: [String]
    /// Bumped to ask the main window to open Settings, which AppKit code can't do itself.
    private(set) var settingsRequest = 0

    @ObservationIgnored private(set) var locator: SourceLocator?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexTaskID = 0

    /// How old the index may get before a menu that uses it starts a fresh walk in the background.
    static let indexLifetime: TimeInterval = 60

    init(roots: [String] = Defaults.sourceRoots) {
        self.roots = roots
        rebuildLocator()
    }

    var hasRoots: Bool { !roots.isEmpty }

    func addRoots(_ urls: [URL]) {
        let new = urls.map(\.standardizedFileURL.path).filter { !roots.contains($0) }
        guard !new.isEmpty else { return }
        setRoots(roots + new)
    }

    func removeRoots(_ paths: Set<String>) {
        setRoots(roots.filter { !paths.contains($0) })
    }

    private func setRoots(_ paths: [String]) {
        roots = paths
        UserDefaults.standard.set(paths, forKey: SettingsKey.sourceRoots)
        rebuildLocator()
    }

    private func rebuildLocator() {
        indexTask?.cancel()
        indexTask = nil
        locator = roots.isEmpty ? nil : SourceLocator(roots: roots.map { URL(fileURLWithPath: $0, isDirectory: true) })
        reindex(fresh: false)
    }

    /// Walks the folders in the background: the first time, or again with `fresh` to pick up new files.
    ///
    /// The walk runs in the detached task itself so ``rebuildLocator()``'s cancel reaches it and stops it early.
    /// A cancelled task still finishes after its replacement has started, so it only clears `indexTask` while
    /// its id is still the current one.
    private func reindex(fresh: Bool) {
        guard let locator, indexTask == nil else { return }
        indexTaskID += 1
        let id = indexTaskID
        indexTask = Task.detached(priority: .utility) { [weak self] in
            if fresh { locator.rebuild() } else { locator.prepare() }
            await self?.indexTaskFinished(id)
        }
    }

    private func indexTaskFinished(_ id: Int) {
        if id == indexTaskID { indexTask = nil }
    }

    /// What a menu shows for `reference`, without touching the disk. Nil when no folder is set. A stale index
    /// still answers, and a fresh walk starts so the next menu sees new files.
    func lookup(_ reference: SourceReference) -> SourceLocator.Lookup? {
        guard let locator else { return nil }
        if let date = locator.indexDate, Date().timeIntervalSince(date) > Self.indexLifetime {
            reindex(fresh: true)
        }
        return locator.cachedLookup(reference)
    }

    func showSettings() {
        settingsRequest += 1
    }

    /// Finds the file off the main thread, then opens it in the chosen editor.
    func open(_ reference: SourceReference) {
        guard let locator else {
            showSettings()
            return
        }
        Task {
            let location = await Task.detached(priority: .userInitiated) { locator.locate(reference) }.value
            guard let location else {
                Self.alert(
                    "\(reference.fileName) Not Found",
                    "None of your source folders has \(reference.fileName). Add the project's folder in Settings."
                )
                return
            }
            open(location)
        }
    }

    func open(_ location: SourceLocation) {
        let editor = Defaults.editor
        let launch = editor.launch(
            location, customTemplate: Defaults.customEditorTemplate, studioExecutable: Self.runningStudioExecutable(editor)
        )
        guard let launch else {
            Self.alert("No Custom Editor", "Enter a URL or command for the custom editor in Settings.")
            showSettings()
            return
        }
        Self.run(launch, editor: editor)
    }

    /// Android Studio's own launcher, when Studio is running: it hands the file to the open IDE and exits. When
    /// Studio isn't running, `open` starts it properly through Launch Services instead of as our child.
    private static func runningStudioExecutable(_ editor: Editor) -> URL? {
        guard editor == .androidStudio,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Editor.androidStudioBundleIdentifier).first,
              let bundle = app.bundleURL
        else { return nil }
        let studio = bundle.appending(path: "Contents/MacOS/studio")
        return FileManager.default.isExecutableFile(atPath: studio.path) ? studio : nil
    }

    private static func run(_ launch: EditorLaunch, editor: Editor) {
        switch launch {
        case let .url(url):
            if !NSWorkspace.shared.open(url) {
                alert("Couldn't Open \(editor.title)", "No app opens \(url.scheme ?? "these"):// links. Is \(editor.title) installed?")
            }
        case let .process(executable, arguments):
            // An argument array, never a shell: file names come from device logs.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let title = editor.title
            process.terminationHandler = { process in
                guard process.terminationStatus != 0 else { return }
                let status = process.terminationStatus
                Task { @MainActor in
                    alert("Couldn't Open \(title)", "\((executable as NSString).lastPathComponent) exited with status \(status). Is \(title) installed?")
                }
            }
            do {
                try process.run()
            } catch {
                alert("Couldn't Open \(title)", error.localizedDescription)
            }
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// The source reference an occurrence's top frame names, for Open Top Frame.
extension LogSession {
    func topFrameReference(for occurrence: SignalOccurrence) -> SourceReference? {
        let ids = [occurrence.id] + occurrence.relatedEntryIDs
        let entries = ids.compactMap { entry(id: $0) }
        guard let anchor = entries.first else { return nil }
        switch occurrence.kind {
        case .crash:
            return CrashSignature.topAppFrame(in: anchor.message, package: occurrence.package).flatMap(SourceReference.init(frame:))
        case .leak:
            return CrashSignature.topFrame(in: anchor.message, package: occurrence.package).flatMap(SourceReference.init(frame:))
        case .nativeCrash:
            // The first frame with a source file, from the app's own libraries if any has one.
            var first: SourceReference?
            for entry in entries {
                for line in entry.message.split(separator: "\n") {
                    guard let reference = SourceReference(nativeLine: line) else { continue }
                    if NativeFrame.parse(line)?.isAppLibrary == true { return reference }
                    if first == nil { first = reference }
                }
            }
            return first
        case .anr, .outOfMemory, .performance:
            return nil
        }
    }

    /// Whether Open Top Frame applies to this kind of signal at all.
    static func hasTopFrame(_ kind: SignalKind) -> Bool {
        switch kind {
        case .crash, .leak, .nativeCrash: true
        case .anr, .outOfMemory, .performance: false
        }
    }
}
