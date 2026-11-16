import CryptoKit
import Foundation
import Testing
@testable import LogcatKit

/// The feed request and the download, verify and unpack steps against a mocked HTTP server.
@Suite struct UpdateNetworkTests {
    private static func feedJSON(version: String, host: String, size: Int, digest: String?) -> Data {
        let digestField = digest.map { #", "digest": "sha256:\#($0)""# } ?? ""
        return Data("""
            {"tag_name": "v\(version)", "name": "Logcatnip \(version)", "body": "notes",
             "html_url": "https://\(host)/releases/tag/v\(version)", "draft": false, "prerelease": false,
             "assets": [{"name": "Logcatnip-\(version).zip", "size": \(size),
                         "browser_download_url": "https://\(host)/download/Logcatnip-\(version).zip"\(digestField)}]}
            """.utf8)
    }

    private func uniqueHost() -> String { "\(UUID().uuidString.lowercased()).test" }

    // MARK: Feed

    @Test func fetchesTheNewestReleaseWithGitHubHeaders() async throws {
        let host = uniqueHost()
        let feed = URL(string: "https://\(host)/releases/latest")!
        MockURLProtocol.serve(feed, .init(body: Self.feedJSON(version: "0.3.0", host: host, size: 10, digest: nil)))

        let release = try await UpdateFeed.fetchNewestRelease(
            newerThan: SemanticVersion("0.2.0")!, feed: feed, session: MockURLProtocol.session()
        )
        #expect(release?.version == SemanticVersion("0.3.0"))

        let request = try #require(MockURLProtocol.requests(to: host).first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Logcatnip/0.2.0")
    }

    @Test func reportsUpToDate() async throws {
        let host = uniqueHost()
        let feed = URL(string: "https://\(host)/releases/latest")!
        MockURLProtocol.serve(feed, .init(body: Self.feedJSON(version: "0.3.0", host: host, size: 10, digest: nil)))
        let release = try await UpdateFeed.fetchNewestRelease(
            newerThan: SemanticVersion("0.3.0")!, feed: feed, session: MockURLProtocol.session()
        )
        #expect(release == nil)
    }

    @Test func treatsNoPublishedReleaseAsUpToDate() async throws {
        let feed = URL(string: "https://\(uniqueHost())/releases/latest")!
        MockURLProtocol.serve(feed, .init(status: 404, body: Data(#"{"message": "Not Found"}"#.utf8)))
        let release = try await UpdateFeed.fetchNewestRelease(
            newerThan: SemanticVersion("0.1.0")!, feed: feed, session: MockURLProtocol.session()
        )
        #expect(release == nil)
    }

    @Test func surfacesServerAndTransportErrors() async throws {
        let host = uniqueHost()
        let limited = URL(string: "https://\(host)/limited")!
        let offline = URL(string: "https://\(host)/offline")!
        let garbage = URL(string: "https://\(host)/garbage")!
        MockURLProtocol.serve(limited, .init(status: 403, body: Data(#"{"message": "API rate limit exceeded"}"#.utf8)))
        MockURLProtocol.serve(offline, .init(error: URLError(.notConnectedToInternet)))
        MockURLProtocol.serve(garbage, .init(body: Data("<html>".utf8)))
        let current = SemanticVersion("0.1.0")!

        await #expect(throws: UpdateError.http(403)) {
            try await UpdateFeed.fetchNewestRelease(newerThan: current, feed: limited, session: MockURLProtocol.session())
        }
        await #expect {
            try await UpdateFeed.fetchNewestRelease(newerThan: current, feed: offline, session: MockURLProtocol.session())
        } throws: { error in
            if case .download = error as? UpdateError { true } else { false }
        }
        await #expect {
            try await UpdateFeed.fetchNewestRelease(newerThan: current, feed: garbage, session: MockURLProtocol.session())
        } throws: { error in
            if case .badFeed = error as? UpdateError { true } else { false }
        }
    }

    // MARK: Download

    /// A signed app for `version`, zipped and served at the release's asset URL.
    private struct Served {
        let scratch: UpdateScratch
        let staging: URL
        let release: UpdateRelease
        let zip: Data
        let sha256: String

        init(
            appVersion: String, releaseVersion: String? = nil, identifier: String = FakeApp.bundleIdentifier,
            useChecksumFile: Bool = false, publishedSHA256: String? = nil, publishedSize: Int? = nil,
            downloadStatus: Int = 200
        ) throws {
            scratch = try UpdateScratch()
            staging = try scratch.folder("staging")
            let app = try FakeApp.make(in: try scratch.folder("build"), identifier: identifier, version: appVersion)
            zip = try FakeApp.zip(app, to: scratch.url.appendingPathComponent("served.zip"))
            sha256 = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()

            let host = "\(UUID().uuidString.lowercased()).test"
            let version = releaseVersion ?? appVersion
            let checksumURL = URL(string: "https://\(host)/download/Logcatnip-\(version).zip.sha256")!
            release = .fixture(
                version, host: host, size: publishedSize ?? zip.count,
                sha256: useChecksumFile ? nil : (publishedSHA256 ?? sha256),
                checksumURL: useChecksumFile ? checksumURL : nil
            )
            MockURLProtocol.serve(release.asset.url, .init(status: downloadStatus, body: zip))
            MockURLProtocol.serve(checksumURL, .init(body: Data("\(publishedSHA256 ?? sha256)  Logcatnip-\(version).zip\n".utf8)))
        }

        func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
            try await UpdateInstaller.prepare(
                release, bundleIdentifier: FakeApp.bundleIdentifier, configuration: MockURLProtocol.configuration(),
                stagingRoot: staging, progress: progress
            )
        }

        var stagingIsEmpty: Bool { scratch.contents(of: staging).isEmpty }
    }

    /// Collects progress callbacks, which arrive on URLSession's delegate queue.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ value: Double) { lock.withLock { values.append(value) } }
        var all: [Double] { lock.withLock { values } }
    }

    @Test func downloadsVerifiesAndUnpacksTheApp() async throws {
        let served = try Served(appVersion: "1.4.0")
        let progress = ProgressLog()
        let app = try await served.prepare { progress.append($0) }

        #expect(app.lastPathComponent == "Logcatnip.app")
        #expect(app.resolvingSymlinksInPath().path.hasPrefix(served.staging.resolvingSymlinksInPath().path + "/"), "\(app.path)")
        try UpdateInstaller.validate(app: app, bundleIdentifier: FakeApp.bundleIdentifier, version: SemanticVersion("1.4.0")!)
        // The zip is deleted once unpacked; only the app stays.
        #expect(!FileManager.default.fileExists(atPath: app.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(served.release.asset.name).path))
        #expect(!progress.all.isEmpty)
        #expect(progress.all.allSatisfy { (0...1).contains($0) })
        #expect(progress.all.last == 1)
    }

    /// Cancelled before the download starts, URLSession can finish the task before the continuation exists. The
    /// download must still end, as a cancellation, rather than hang.
    @Test(arguments: 0..<20)
    func aDownloadCancelledOnEntryEnds(_ attempt: Int) async throws {
        let served = try Served(appVersion: "1.4.0")
        let finished = Finished()
        let release = served.release
        let staging = served.staging
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await UpdateInstaller.prepare(
                    release, bundleIdentifier: FakeApp.bundleIdentifier,
                    configuration: MockURLProtocol.configuration(), stagingRoot: staging, progress: { _ in }
                )
                finished.set("returned")
            } catch is CancellationError {
                finished.set("cancelled")
            } catch {
                finished.set("\(error)")
            }
        }
        for _ in 0..<500 where finished.value == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let outcome = try #require(finished.value, "the download hung after cancellation")
        #expect(outcome == "cancelled")
        await task.value
        #expect(served.stagingIsEmpty)
    }

    /// The race above, forced: the download finishes before the continuation is registered. Polled with a
    /// deadline, because the bug is a continuation that is never resumed.
    @Test func aContinuationRegisteredAfterTheDownloadEndedIsResumed() async throws {
        let downloader = Downloader(destination: URL(fileURLWithPath: "/dev/null"), expectedSize: 0, progress: { _ in })
        downloader.finish(.failure(CancellationError()))
        let outcome = Finished()
        Task {
            do {
                try await withCheckedThrowingContinuation { downloader.register($0) }
                outcome.set("returned")
            } catch {
                outcome.set(error is CancellationError ? "cancelled" : "\(error)")
            }
        }
        for _ in 0..<200 where outcome.value == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(outcome.value == "cancelled")
        // A second finish is ignored rather than resuming twice.
        downloader.finish(.success(()))
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: String?
        func set(_ value: String) { lock.withLock { outcome = value } }
        var value: String? { lock.withLock { outcome } }
    }

    @Test func verifiesAgainstTheChecksumFileWhenThereIsNoDigest() async throws {
        let served = try Served(appVersion: "1.4.0", useChecksumFile: true)
        let app = try await served.prepare()
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @Test func rejectsAChecksumMismatchAndCleansUp() async throws {
        let served = try Served(appVersion: "1.4.0", publishedSHA256: String(repeating: "0", count: 64))
        await #expect(throws: UpdateError.checksumMismatch) { try await served.prepare() }
        #expect(served.stagingIsEmpty)
    }

    @Test func rejectsAMismatchedChecksumFile() async throws {
        let served = try Served(appVersion: "1.4.0", useChecksumFile: true, publishedSHA256: String(repeating: "1", count: 64))
        await #expect(throws: UpdateError.checksumMismatch) { try await served.prepare() }
        #expect(served.stagingIsEmpty)
    }

    @Test func refusesAReleaseWithoutAnyChecksum() async throws {
        let served = try Served(appVersion: "1.4.0")
        var release = served.release
        release.asset.sha256 = nil
        release.asset.checksumURL = nil
        await #expect(throws: UpdateError.missingChecksum) {
            try await UpdateInstaller.prepare(
                release, bundleIdentifier: FakeApp.bundleIdentifier, configuration: MockURLProtocol.configuration(),
                stagingRoot: served.staging, progress: { _ in }
            )
        }
        #expect(MockURLProtocol.requests(to: release.asset.url.host!).isEmpty)
    }

    @Test func rejectsATruncatedDownload() async throws {
        let served = try Served(appVersion: "1.4.0", publishedSize: 999_999)
        await #expect {
            try await served.prepare()
        } throws: { error in
            if case .sizeMismatch(let expected, let actual) = error as? UpdateError {
                expected == 999_999 && actual == served.zip.count
            } else { false }
        }
        #expect(served.stagingIsEmpty)
    }

    @Test func surfacesAFailedDownload() async throws {
        let served = try Served(appVersion: "1.4.0", downloadStatus: 404)
        await #expect(throws: UpdateError.http(404)) { try await served.prepare() }
        #expect(served.stagingIsEmpty)
    }

    @Test func rejectsAZipWhoseAppIsAnotherVersion() async throws {
        let served = try Served(appVersion: "1.3.0", releaseVersion: "1.4.0")
        await #expect {
            try await served.prepare()
        } throws: { error in
            if case .invalidBundle(let detail) = error as? UpdateError { detail.contains("1.3.0") } else { false }
        }
        #expect(served.stagingIsEmpty)
    }

    @Test func rejectsAZipWithAnotherApp() async throws {
        let served = try Served(appVersion: "1.4.0", identifier: "com.example.impostor")
        await #expect {
            try await served.prepare()
        } throws: { error in
            if case .invalidBundle(let detail) = error as? UpdateError { detail.contains("com.example.impostor") } else { false }
        }
        #expect(served.stagingIsEmpty)
    }

    @Test func rejectsAZipThatIsNotAZip() async throws {
        let served = try Served(appVersion: "1.4.0")
        let junk = Data("not a zip".utf8)
        var release = served.release
        release.asset.size = junk.count
        release.asset.sha256 = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        MockURLProtocol.serve(release.asset.url, .init(body: junk))
        await #expect {
            try await UpdateInstaller.prepare(
                release, bundleIdentifier: FakeApp.bundleIdentifier, configuration: MockURLProtocol.configuration(),
                stagingRoot: served.staging, progress: { _ in }
            )
        } throws: { error in
            if case .unpack = error as? UpdateError { true } else { false }
        }
        #expect(served.stagingIsEmpty)
    }
}
