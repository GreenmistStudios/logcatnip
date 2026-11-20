import Foundation
import Observation

/// The steps of an update that touch the network or the installed app, so `UpdateController` can be driven by
/// fakes in tests.
public protocol UpdateServices: Sendable {
    /// The newest release above `current`, or nil when there is none.
    func newestRelease(newerThan current: SemanticVersion) async throws -> UpdateRelease?
    /// Downloads and verifies `release`, returning the unpacked app.
    func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Starts replacing the running app with `app` once it quits. The controller quits right after.
    @MainActor func startInstall(of app: URL) throws
    /// Deletes a prepared app that will not be installed, because a newer release replaced it.
    func discard(_ app: URL)
}

/// The real services: GitHub Releases, `UpdateInstaller` and the app bundle at `appURL`.
public struct GitHubUpdateServices: UpdateServices {
    public var feed: URL
    public var bundleIdentifier: String
    public var appURL: URL
    /// The team updates must be signed by; nil accepts any valid signature (see `UpdateInstaller.signingTeam`).
    public var team: String?

    public init(
        feed: URL = UpdateFeed.latestReleaseURL, bundleIdentifier: String, appURL: URL, team: String? = nil
    ) {
        self.feed = feed
        self.bundleIdentifier = bundleIdentifier
        self.appURL = appURL
        self.team = team
    }

    public func newestRelease(newerThan current: SemanticVersion) async throws -> UpdateRelease? {
        try await UpdateFeed.fetchNewestRelease(newerThan: current, feed: feed)
    }

    public func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await UpdateInstaller.prepare(release, bundleIdentifier: bundleIdentifier, team: team, progress: progress)
    }

    @MainActor public func startInstall(of app: URL) throws {
        try UpdateInstaller.installAndRelaunch(newApp: app, replacing: appURL, pid: getpid())
    }

    public func discard(_ app: URL) {
        UpdateInstaller.discard(app)
    }
}

/// The update flow: check, offer, download, install. Background checks run once a day when the user allows them
/// and stay quiet about a skipped version; user-initiated checks always report. `presentRequest` is bumped
/// whenever the update window should come forward.
@MainActor @Observable
public final class UpdateController {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease, progress: Double)
        case ready(UpdateRelease, app: URL)
        case failed(String)
    }

    /// UserDefaults keys. The app registers `automaticChecks` as true.
    public enum Keys {
        public static let automaticChecks = "checkForUpdates"
        /// When the last check finished; background checks run `checkInterval` after it.
        public static let lastChecked = "lastUpdateCheck"
        public static let skippedVersion = "skippedUpdateVersion"
    }

    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public private(set) var phase: Phase = .idle
    public private(set) var lastChecked: Date?
    public private(set) var presentRequest = 0

    /// The running version, or nil for a development build with nothing to compare.
    public let currentVersion: SemanticVersion?
    /// Why this copy can't replace itself, or nil.
    public let installBlocker: String?

    /// Downloads and installs whatever a check finds, without asking. Only for `LOGCATNIP_UPDATE_INSTALL`.
    @ObservationIgnored public var installWithoutAsking = false
    /// Called after the install has been handed off; the app terminates here.
    @ObservationIgnored public var quit: @MainActor () -> Void = {}
    @ObservationIgnored public var log: @MainActor (String) -> Void = { _ in }

    @ObservationIgnored private let services: any UpdateServices
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    /// A verified download waiting to install. Kept apart from `phase` so a check started from `.ready` can return
    /// to it, or replace it when it finds a newer release.
    @ObservationIgnored private var staged: (release: UpdateRelease, app: URL)?

    public init(
        currentVersion: SemanticVersion?, installBlocker: String?, services: any UpdateServices,
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.installBlocker = installBlocker
        self.services = services
        self.defaults = defaults
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    /// Runs `checkIfDue` after `initialDelay`, then every `interval`. Safe to call more than once.
    public func startSchedule(initialDelay: Duration = .seconds(10), interval: Duration = .seconds(60 * 60)) {
        guard schedule == nil, currentVersion != nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopSchedule() {
        schedule?.cancel()
        schedule = nil
    }

    /// Starts a background check when automatic checks are on and the last one is a day old. Returns whether it
    /// started one.
    @discardableResult
    public func checkIfDue(now: Date = Date()) -> Bool {
        guard defaults.bool(forKey: Keys.automaticChecks), currentVersion != nil, !isBusy else { return false }
        let due = (lastChecked ?? .distantPast).addingTimeInterval(Self.checkInterval)
        guard due <= now else { return false }
        check(userInitiated: false)
        return true
    }

    public func check(userInitiated: Bool) {
        if userInitiated { presentRequest += 1 }
        // A check or download in flight is kept rather than redone.
        if isBusy { return }
        guard let currentVersion else {
            if userInitiated {
                phase = .failed("This is a development build without a version, so it can't be compared with releases.")
            }
            return
        }
        phase = .checking
        log("checking for releases above \(currentVersion)")
        let services = services
        work = Task { [weak self] in
            let result: Result<UpdateRelease?, Error>
            do {
                result = .success(try await services.newestRelease(newerThan: currentVersion))
            } catch {
                result = .failure(error)
            }
            self?.finishCheck(result, userInitiated: userInitiated)
        }
    }

    private func finishCheck(_ result: Result<UpdateRelease?, Error>, userInitiated: Bool) {
        switch result {
        case .success(let release):
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            if let staged {
                // Nothing newer than the downloaded update: go back to offering it.
                guard let release, release.version > staged.release.version else {
                    phase = .ready(staged.release, app: staged.app)
                    log("still ready to install \(staged.release.version)")
                    return
                }
                services.discard(staged.app)
                self.staged = nil
                log("discarded \(staged.release.version) for \(release.version)")
            }
            guard let release else {
                phase = .upToDate
                log("up to date")
                return
            }
            phase = .available(release)
            log("found \(release.version)")
            if !userInitiated, defaults.string(forKey: Keys.skippedVersion) != release.version.description {
                presentRequest += 1
            }
            if installWithoutAsking { download() }
        case .failure(let error):
            if let staged {
                // The verified download is still good.
                phase = .ready(staged.release, app: staged.app)
            } else {
                // A failed background check stays silent and is retried at the next due time.
                phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
            log("check failed: \(error.localizedDescription)")
        }
    }

    public func download() {
        guard case .available(let release) = phase, installBlocker == nil else { return }
        phase = .downloading(release, progress: 0)
        log("downloading \(release.asset.url.absoluteString)")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.reportProgress(fraction, for: release) }
        }
        let services = services
        work = Task { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await services.prepare(release, progress: report))
            } catch {
                result = .failure(error)
            }
            self?.finishDownload(result, release: release)
        }
    }

    private func reportProgress(_ fraction: Double, for release: UpdateRelease) {
        guard case .downloading(let current, _) = phase, current == release else { return }
        phase = .downloading(release, progress: min(1, max(0, fraction)))
    }

    private func finishDownload(_ result: Result<URL, Error>, release: UpdateRelease) {
        switch result {
        case .success(let app):
            staged = (release, app)
            phase = .ready(release, app: app)
            log("ready at \(app.path)")
            if installWithoutAsking { installAndRelaunch() }
        case .failure(let error) where error is CancellationError:
            phase = .available(release)
            log("download cancelled")
        case .failure(let error):
            phase = .failed(error.localizedDescription)
            log("download failed: \(error.localizedDescription)")
        }
    }

    public func cancelDownload() {
        guard case .downloading = phase else { return }
        work?.cancel()
    }

    public func installAndRelaunch() {
        guard case .ready(_, let app) = phase else { return }
        do {
            try services.startInstall(of: app)
            log("installing; quitting")
            quit()
        } catch {
            phase = .failed("The update could not be installed: \(error.localizedDescription)")
        }
    }

    public func skip(_ release: UpdateRelease) {
        defaults.set(release.version.description, forKey: Keys.skippedVersion)
        phase = .idle
    }

    /// Closing the window forgets a finished check, but not one in flight (its result still arrives, and resetting
    /// would let a second check race it), a download in progress, or one waiting to install.
    public func dismiss() {
        switch phase {
        case .checking, .downloading, .ready: break
        default: phase = .idle
        }
    }

    /// Waits for the current check or download, and any step it chains. For tests and the debug hooks.
    public func waitUntilIdle() async {
        while let task = work {
            await task.value
            if work == task { break }
        }
    }
}
