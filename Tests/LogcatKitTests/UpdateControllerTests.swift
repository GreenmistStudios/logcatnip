import Foundation
import Testing
@testable import LogcatKit

/// Scripted stand-ins for the network and the installer. Each step's behavior is a closure the test sets; calls
/// are recorded. Tests set the closures before driving the controller and the calls come from its tasks, so both
/// are guarded by `lock`.
private final class FakeServices: UpdateServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetch: @Sendable (SemanticVersion) async throws -> UpdateRelease? = { _ in nil }
    private var _prepare: @Sendable (UpdateRelease, @escaping @Sendable (Double) -> Void) async throws -> URL = { release, _ in
        URL(fileURLWithPath: "/tmp/staged/\(release.version)/Logcatnip.app")
    }
    private var _install: @Sendable (URL) throws -> Void = { _ in }
    private var _fetches: [SemanticVersion] = []
    private var _prepared: [UpdateRelease] = []
    private var _installed: [URL] = []

    var fetch: @Sendable (SemanticVersion) async throws -> UpdateRelease? {
        get { lock.withLock { _fetch } }
        set { lock.withLock { _fetch = newValue } }
    }
    var prepare: @Sendable (UpdateRelease, @escaping @Sendable (Double) -> Void) async throws -> URL {
        get { lock.withLock { _prepare } }
        set { lock.withLock { _prepare = newValue } }
    }
    var install: @Sendable (URL) throws -> Void {
        get { lock.withLock { _install } }
        set { lock.withLock { _install = newValue } }
    }
    var fetches: [SemanticVersion] { lock.withLock { _fetches } }
    var prepared: [UpdateRelease] { lock.withLock { _prepared } }
    var installed: [URL] { lock.withLock { _installed } }

    func newestRelease(newerThan current: SemanticVersion) async throws -> UpdateRelease? {
        lock.withLock { _fetches.append(current) }
        return try await fetch(current)
    }

    func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { _prepared.append(release) }
        return try await prepare(release, progress)
    }

    @MainActor func startInstall(of app: URL) throws {
        try install(app)
        lock.withLock { _installed.append(app) }
    }
}

/// A one-shot latch a fake step can wait on, so a test can look at the controller mid-download.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            opened = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
@Suite final class UpdateControllerTests {
    private let services = FakeServices()
    private let suite = "logcatnip-update-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let release = UpdateRelease.fixture("0.3.0")

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: UpdateController.Keys.automaticChecks)
    }

    deinit {
        // A fresh handle: `defaults` is main-actor state and deinit is nonisolated.
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func controller(
        version: String? = "0.2.0", blocker: String? = nil
    ) -> (UpdateController, QuitCounter) {
        let controller = UpdateController(
            currentVersion: version.flatMap(SemanticVersion.init), installBlocker: blocker,
            services: services, defaults: defaults
        )
        let quits = QuitCounter()
        controller.quit = { quits.count += 1 }
        return (controller, quits)
    }

    @MainActor private final class QuitCounter { var count = 0 }

    /// Polls until `condition` holds, for states reached through hops to the main actor.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func check(_ controller: UpdateController, userInitiated: Bool) async {
        controller.check(userInitiated: userInitiated)
        await controller.waitUntilIdle()
    }

    // MARK: Checking

    @Test func findsANewerRelease() async {
        let release = release
        services.fetch = { _ in release }
        let (controller, _) = controller()
        await check(controller, userInitiated: true)

        #expect(controller.phase == .available(release))
        #expect(services.fetches == [SemanticVersion("0.2.0")!])
        #expect(controller.presentRequest == 1)
        #expect(controller.lastChecked != nil)
        #expect(defaults.object(forKey: UpdateController.Keys.lastChecked) as? Date == controller.lastChecked)
    }

    @Test func reportsUpToDate() async {
        let (controller, _) = controller()
        await check(controller, userInitiated: true)
        #expect(controller.phase == .upToDate)
        #expect(controller.presentRequest == 1)
    }

    @Test func backgroundChecksStayQuietUnlessThereIsAnUpdate() async {
        let (controller, _) = controller()
        await check(controller, userInitiated: false)
        #expect(controller.phase == .upToDate)
        #expect(controller.presentRequest == 0)

        let release = release
        services.fetch = { _ in release }
        await check(controller, userInitiated: false)
        #expect(controller.phase == .available(release))
        #expect(controller.presentRequest == 1)
    }

    @Test func skippedVersionsAreOnlyShownWhenAsked() async {
        let release = release
        services.fetch = { _ in release }
        let (controller, _) = controller()
        await check(controller, userInitiated: true)
        controller.skip(release)
        #expect(controller.phase == .idle)
        #expect(defaults.string(forKey: UpdateController.Keys.skippedVersion) == "0.3.0")

        await check(controller, userInitiated: false)
        #expect(controller.phase == .available(release))
        #expect(controller.presentRequest == 1)

        await check(controller, userInitiated: true)
        #expect(controller.presentRequest == 2)

        // A newer release than the skipped one is offered again.
        let newer = UpdateRelease.fixture("0.4.0")
        services.fetch = { _ in newer }
        await check(controller, userInitiated: false)
        #expect(controller.phase == .available(newer))
        #expect(controller.presentRequest == 3)
    }

    @Test func failuresAreReportedOnlyWhenAsked() async {
        services.fetch = { _ in throw Boom() }
        let (controller, _) = controller()
        await check(controller, userInitiated: false)
        #expect(controller.phase == .idle)
        #expect(controller.presentRequest == 0)
        #expect(controller.lastChecked == nil)

        await check(controller, userInitiated: true)
        #expect(controller.phase == .failed("boom"))
        #expect(controller.presentRequest == 1)
    }

    @Test func developmentBuildsDoNotCheck() async {
        let (controller, _) = controller(version: nil)
        await check(controller, userInitiated: false)
        #expect(controller.phase == .idle)
        await check(controller, userInitiated: true)
        if case .failed = controller.phase {} else { Issue.record("expected failed, got \(controller.phase)") }
        #expect(services.fetches.isEmpty)
        #expect(!controller.checkIfDue())
    }

    @Test func aSecondCheckWhileCheckingIsIgnored() async {
        let gate = Gate()
        services.fetch = { _ in
            await gate.wait()
            return nil
        }
        let (controller, _) = controller()
        controller.check(userInitiated: false)
        controller.check(userInitiated: true)
        #expect(controller.phase == .checking)
        #expect(controller.presentRequest == 1)
        gate.open()
        await controller.waitUntilIdle()
        #expect(services.fetches.count == 1)
        #expect(controller.phase == .upToDate)
    }

    // MARK: Schedule

    @Test func checksWhenADayHasPassed() async {
        let (controller, _) = controller()
        #expect(controller.checkIfDue(now: Date()))
        await controller.waitUntilIdle()
        let checked = try! #require(controller.lastChecked)

        #expect(!controller.checkIfDue(now: checked.addingTimeInterval(UpdateController.checkInterval - 60)))
        #expect(controller.checkIfDue(now: checked.addingTimeInterval(UpdateController.checkInterval + 1)))
        await controller.waitUntilIdle()
        #expect(services.fetches.count == 2)
    }

    @Test func remembersTheLastCheckAcrossLaunches() async {
        let recent = Date().addingTimeInterval(-60)
        defaults.set(recent, forKey: UpdateController.Keys.lastChecked)
        let (controller, _) = controller()
        #expect(controller.lastChecked == recent)
        #expect(!controller.checkIfDue())
        #expect(services.fetches.isEmpty)
    }

    @Test func automaticChecksCanBeTurnedOff() async {
        defaults.set(false, forKey: UpdateController.Keys.automaticChecks)
        let (controller, _) = controller()
        #expect(!controller.checkIfDue())
        await check(controller, userInitiated: true)
        #expect(services.fetches.count == 1)
    }

    @Test func theScheduleRunsTheDueCheck() async {
        let (controller, _) = controller()
        controller.startSchedule(initialDelay: .zero, interval: .seconds(3600))
        defer { controller.stopSchedule() }
        await eventually { controller.phase == .upToDate }
        #expect(services.fetches.count == 1)
    }

    // MARK: Downloading

    private func available(blocker: String? = nil) async -> (UpdateController, QuitCounter) {
        let release = release
        services.fetch = { _ in release }
        let (controller, quits) = controller(blocker: blocker)
        await check(controller, userInitiated: true)
        return (controller, quits)
    }

    @Test func downloadsWithProgressThenWaitsToInstall() async {
        let gate = Gate()
        services.prepare = { release, progress in
            progress(0.5)
            await gate.wait()
            progress(1)
            return URL(fileURLWithPath: "/tmp/staged/Logcatnip.app")
        }
        let (controller, quits) = await available()
        controller.download()
        await eventually { controller.phase == .downloading(release, progress: 0.5) }
        #expect(controller.phase == .downloading(release, progress: 0.5))
        #expect(controller.isBusy)

        gate.open()
        await controller.waitUntilIdle()
        #expect(controller.phase == .ready(release, app: URL(fileURLWithPath: "/tmp/staged/Logcatnip.app")))
        // Late progress from the finished download does not knock it back to downloading.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.phase == .ready(release, app: URL(fileURLWithPath: "/tmp/staged/Logcatnip.app")))
        #expect(services.installed.isEmpty)
        #expect(quits.count == 0)

        // Closing the window or checking again keeps the verified download.
        controller.dismiss()
        await check(controller, userInitiated: true)
        #expect(controller.phase == .ready(release, app: URL(fileURLWithPath: "/tmp/staged/Logcatnip.app")))
        #expect(services.fetches.count == 1)
        #expect(!controller.checkIfDue(now: .distantFuture))
    }

    @Test func aFailedDownloadIsReported() async {
        services.prepare = { _, _ in throw UpdateError.checksumMismatch }
        let (controller, _) = await available()
        controller.download()
        await controller.waitUntilIdle()
        #expect(controller.phase == .failed(UpdateError.checksumMismatch.localizedDescription))
    }

    @Test func cancellingADownloadOffersTheUpdateAgain() async {
        services.prepare = { _, _ in
            try await Task.sleep(for: .seconds(30))
            return URL(fileURLWithPath: "/never")
        }
        let (controller, _) = await available()
        controller.download()
        #expect(controller.phase == .downloading(release, progress: 0))
        controller.cancelDownload()
        await controller.waitUntilIdle()
        #expect(controller.phase == .available(release))
    }

    @Test func aBlockedCopyDoesNotDownload() async {
        let (controller, _) = await available(blocker: "read-only")
        controller.download()
        await controller.waitUntilIdle()
        #expect(controller.phase == .available(release))
        #expect(services.prepared.isEmpty)
    }

    @Test func dismissingForgetsAnOfferButNotADownload() async {
        let gate = Gate()
        services.prepare = { _, _ in
            await gate.wait()
            return URL(fileURLWithPath: "/tmp/staged/Logcatnip.app")
        }
        let (controller, _) = await available()
        controller.download()
        controller.dismiss()
        #expect(controller.phase == .downloading(release, progress: 0))
        gate.open()
        await controller.waitUntilIdle()

        let (other, _) = await available()
        other.dismiss()
        #expect(other.phase == .idle)
    }

    // MARK: Installing

    @Test func installsTheVerifiedAppAndQuits() async {
        let (controller, quits) = await available()
        controller.download()
        await controller.waitUntilIdle()
        controller.installAndRelaunch()
        #expect(services.installed == [URL(fileURLWithPath: "/tmp/staged/0.3.0/Logcatnip.app")])
        #expect(quits.count == 1)
    }

    @Test func aFailedInstallKeepsTheAppRunning() async {
        services.install = { _ in throw Boom() }
        let (controller, quits) = await available()
        controller.download()
        await controller.waitUntilIdle()
        controller.installAndRelaunch()
        #expect(controller.phase == .failed("The update could not be installed: boom"))
        #expect(quits.count == 0)
    }

    @Test func installDoesNothingBeforeTheDownloadIsReady() async {
        let (controller, quits) = await available()
        controller.installAndRelaunch()
        #expect(services.installed.isEmpty)
        #expect(quits.count == 0)
    }

    @Test func installWithoutAskingRunsTheWholeFlow() async {
        let release = release
        services.fetch = { _ in release }
        let (controller, quits) = controller()
        controller.installWithoutAsking = true
        await check(controller, userInitiated: true)

        #expect(services.prepared == [release])
        #expect(services.installed == [URL(fileURLWithPath: "/tmp/staged/0.3.0/Logcatnip.app")])
        #expect(quits.count == 1)
    }
}
