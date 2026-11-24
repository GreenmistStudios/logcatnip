import AppKit
import LogcatKit
import SwiftUI

extension UpdateController {
    /// The controller for this app: GitHub Releases, the running bundle, and the `LOGCATNIP_UPDATE_*` debug hooks.
    static func forApp(
        bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UpdateController {
        let info = bundle.infoDictionary ?? [:]
        // LOGCATNIP_UPDATE_VERSION pretends to be another version, so a check finds the latest release.
        let version = (environment["LOGCATNIP_UPDATE_VERSION"] ?? info["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.init)
        // LOGCATNIP_UPDATE_FEED reads releases from another URL or a file holding a copy of the API response.
        let feed = environment["LOGCATNIP_UPDATE_FEED"].flatMap { value in
            value.contains("://") ? URL(string: value) : URL(fileURLWithPath: value)
        } ?? UpdateFeed.latestReleaseURL
        let blocker = bundle.bundleIdentifier == nil
            ? "Updates install only into Logcatnip.app. Build it with scripts/build-app.sh."
            : UpdateInstaller.installBlocker(for: bundle.bundleURL)
        // A download from a run that quit without installing will not be used.
        UpdateInstaller.removeStaleDownloads()
        let controller = UpdateController(
            currentVersion: version,
            installBlocker: blocker,
            services: GitHubUpdateServices(
                feed: feed, bundleIdentifier: bundle.bundleIdentifier ?? "studio.greenmist.logcatnip",
                appURL: bundle.bundleURL
            )
        )
        controller.quit = { NSApp.terminate(nil) }
        if environment["LOGCATNIP_DEBUG"] == "1" {
            controller.log = { FileHandle.standardError.write(Data("[logcatnip] update: \($0)\n".utf8)) }
        }
        // LOGCATNIP_UPDATE_CHECK=1 runs Check for Updates… at launch; LOGCATNIP_UPDATE_INSTALL=1 also installs.
        if environment["LOGCATNIP_UPDATE_CHECK"] == "1" {
            controller.installWithoutAsking = environment["LOGCATNIP_UPDATE_INSTALL"] == "1"
            Task {
                try? await Task.sleep(for: .seconds(1))
                controller.check(userInitiated: true)
            }
        }
        return controller
    }

    var versionDescription: String {
        guard let currentVersion else { return "Development build" }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "Version \(currentVersion) (\($0))" } ?? "Version \(currentVersion)"
    }
}

/// Check for Updates… only asks; `UpdatePresenter` opens the window when the controller bumps `presentRequest`.
struct UpdateCommands: Commands {
    let updater: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.check(userInitiated: true) }
        }
    }
}

/// Brings the update window forward when a check asks for it. Attached to the main window, which can open
/// windows; the model can't.
struct UpdatePresenter: ViewModifier {
    let updater: UpdateController
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: updater.presentRequest) {
            openWindow(id: UpdateView.windowID)
        }
    }
}

struct UpdateView: View {
    static let windowID = "update"

    @Environment(UpdateController.self) private var updater
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
        case .upToDate:
            Text("Logcatnip is up to date").font(.headline)
            Text("\(updater.versionDescription) is the newest version available.")
                .foregroundStyle(.secondary)
            buttons { Button("OK") { close() }.keyboardShortcut(.defaultAction) }
        case .failed(let message):
            Text("Couldn't update Logcatnip").font(.headline)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            buttons {
                Button("Open Releases Page") { openURL(UpdateFeed.releasesPageURL) }
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            header(release)
            notes(release)
            if let blocker = updater.installBlocker {
                Text(blocker).font(.callout).foregroundStyle(.orange)
            }
            buttons {
                Button("Skip This Version") {
                    updater.skip(release)
                    close()
                }
                Spacer()
                Button("Remind Me Later") { close() }.keyboardShortcut(.cancelAction)
                if updater.installBlocker == nil {
                    Button("Download Update") { updater.download() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Release Page") { openURL(release.pageURL) }.keyboardShortcut(.defaultAction)
                }
            }
        case .downloading(let release, let progress):
            header(release)
            ProgressView(value: progress) {
                Text("Downloading \(release.asset.name)…").font(.callout)
            }
            buttons { Button("Cancel") { updater.cancelDownload() }.keyboardShortcut(.cancelAction) }
        case .ready(let release, _):
            header(release)
            Text("The update is downloaded and verified. Logcatnip will quit, install it and open again; open sessions and their logs are not kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
            buttons {
                Button("Later") { close() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.installAndRelaunch() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func header(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Logcatnip \(release.version.description) is available").font(.headline)
            Text("You have \(updater.currentVersion?.description ?? "a development build").")
                .foregroundStyle(.secondary)
        }
    }

    private func notes(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Release notes").font(.subheadline.weight(.semibold))
                Spacer()
                Link("View on GitHub", destination: release.pageURL).font(.callout)
            }
            ScrollView {
                Text(Self.markdown(release.notes))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }

    private func close() {
        updater.dismiss()
        dismissWindow(id: Self.windowID)
    }

    /// Inline Markdown only, keeping line breaks: block syntax such as `##` headings stays as typed, which reads
    /// fine for GitHub's generated notes.
    static func markdown(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString("No release notes.") }
        return (try? AttributedString(
            markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(trimmed)
    }
}
