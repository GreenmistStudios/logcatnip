import Foundation
import Testing
@testable import LogcatKit

@Suite struct SemanticVersionTests {
    @Test func parsesTagsAndBundleVersions() {
        #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("0.4") == SemanticVersion(major: 0, minor: 4, patch: 0))
        #expect(SemanticVersion("2") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion("1.2.3-beta.1+7") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion(" v0.10.0\n")?.description == "0.10.0")
    }

    @Test func rejectsGarbage() {
        for text in ["", "v", "1..2", "1.2.3.4", "one.two", "1.-2.3", "latest", "1.2.x"] {
            #expect(SemanticVersion(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumerically() {
        #expect(SemanticVersion("0.10.0")! > SemanticVersion("0.9.9")!)
        #expect(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        #expect(SemanticVersion("1.2.10")! > SemanticVersion("1.2.9")!)
        #expect(!(SemanticVersion("1.2.3")! < SemanticVersion("v1.2.3")!))
    }
}

@Suite struct UpdateFeedTests {
    private func release(
        tag: String, draft: Bool = false, prerelease: Bool = false, assets: String? = nil
    ) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assetList = assets ?? """
            {"name": "Logcatnip-\(version).zip", "size": 1234,
             "browser_download_url": "https://github.com/GreenmistStudios/logcatnip/releases/download/\(tag)/Logcatnip-\(version).zip",
             "digest": "sha256:\(String(repeating: "AB", count: 32))"},
            {"name": "Logcatnip-\(version).zip.sha256", "size": 90,
             "browser_download_url": "https://github.com/GreenmistStudios/logcatnip/releases/download/\(tag)/Logcatnip-\(version).zip.sha256"}
            """
        return """
            {"tag_name": "\(tag)", "name": "Logcatnip \(version)", "body": "## What's Changed\\n* feat: things",
             "html_url": "https://github.com/GreenmistStudios/logcatnip/releases/tag/\(tag)",
             "draft": \(draft), "prerelease": \(prerelease), "published_at": "2026-11-16T10:00:00Z",
             "assets": [\(assetList)]}
            """
    }

    @Test func readsTheLatestReleaseObject() throws {
        let releases = try UpdateFeed.releases(from: Data(release(tag: "v0.3.1").utf8))
        let only = try #require(releases.first)
        #expect(releases.count == 1)
        #expect(only.version == SemanticVersion("0.3.1"))
        #expect(only.title == "Logcatnip 0.3.1")
        #expect(only.notes.contains("feat: things"))
        #expect(only.asset.name == "Logcatnip-0.3.1.zip")
        #expect(only.asset.size == 1234)
        #expect(only.asset.sha256 == String(repeating: "ab", count: 32))
        #expect(only.asset.checksumURL?.lastPathComponent == "Logcatnip-0.3.1.zip.sha256")
        #expect(only.publishedAt == Date(timeIntervalSince1970: 1_794_823_200))
    }

    @Test func offersOnlyNewerFullReleases() throws {
        let list = "[\(release(tag: "v0.5.0", prerelease: true)), \(release(tag: "v0.4.0", draft: true)), \(release(tag: "v0.3.0")), \(release(tag: "v0.2.0")), \(release(tag: "nightly"))]"
        let data = Data(list.utf8)
        #expect(try UpdateFeed.newestRelease(in: data, newerThan: SemanticVersion("0.2.0")!)?.version == SemanticVersion("0.3.0"))
        #expect(try UpdateFeed.newestRelease(in: data, newerThan: SemanticVersion("0.3.0")!) == nil)
        #expect(try UpdateFeed.newestRelease(in: data, newerThan: SemanticVersion("1.0.0")!) == nil)
    }

    @Test func skipsReleasesWithoutAnAppZip() throws {
        let data = Data(release(tag: "v1.0.0", assets: #"{"name": "notes.txt", "size": 1, "browser_download_url": "https://example.com/notes.txt"}"#).utf8)
        #expect(try UpdateFeed.releases(from: data).isEmpty)
    }

    @Test func fallsBackToTheChecksumAsset() throws {
        let assets = """
            {"name": "Logcatnip-1.0.0.zip", "size": 10, "browser_download_url": "https://example.com/Logcatnip-1.0.0.zip"},
            {"name": "Logcatnip-1.0.0.zip.sha256", "size": 90, "browser_download_url": "https://example.com/Logcatnip-1.0.0.zip.sha256"}
            """
        let only = try #require(try UpdateFeed.releases(from: Data(release(tag: "v1.0.0", assets: assets).utf8)).first)
        #expect(only.asset.sha256 == nil)
        #expect(only.asset.checksumURL == URL(string: "https://example.com/Logcatnip-1.0.0.zip.sha256"))
    }

    @Test func rejectsMalformedFeeds() {
        #expect(throws: UpdateError.self) { try UpdateFeed.releases(from: Data(#"{"message": "Not Found"}"#.utf8)) }
        #expect(throws: UpdateError.self) { try UpdateFeed.releases(from: Data("<html>".utf8)) }
    }

    @Test func readsChecksums() {
        let hex = String(repeating: "0f", count: 32)
        #expect(UpdateFeed.sha256(fromDigest: "sha256:\(hex.uppercased())") == hex)
        #expect(UpdateFeed.sha256(fromDigest: "sha512:\(hex)") == nil)
        #expect(UpdateFeed.sha256(fromDigest: "sha256:abc") == nil)
        #expect(UpdateFeed.sha256(fromChecksumFile: "\(hex)  Logcatnip-1.0.0.zip\n") == hex)
        #expect(UpdateFeed.sha256(fromChecksumFile: "not a checksum") == nil)
    }
}

@Suite struct UpdateInstallerTests {
    private let id = FakeApp.bundleIdentifier

    @Test func acceptsAMatchingSignedBundle() throws {
        let scratch = try UpdateScratch()
        let app = try FakeApp.make(in: scratch.url, version: "1.2.3")
        try UpdateInstaller.validate(app: app, bundleIdentifier: id, version: SemanticVersion("1.2.3")!)
    }

    @Test func rejectsTheWrongVersionOrIdentifier() throws {
        let scratch = try UpdateScratch()
        let app = try FakeApp.make(in: scratch.url, version: "1.2.3")
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.validate(app: app, bundleIdentifier: id, version: SemanticVersion("1.2.4")!)
        }
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.validate(app: app, bundleIdentifier: "com.example.other", version: SemanticVersion("1.2.3")!)
        }
    }

    @Test func rejectsATamperedBundle() throws {
        let scratch = try UpdateScratch()
        let app = try FakeApp.make(in: scratch.url, version: "1.2.3")
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Logcatnip"))
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.validate(app: app, bundleIdentifier: id, version: SemanticVersion("1.2.3")!)
        }
    }

    @Test func rejectsAnAppForAnotherArchitecture() throws {
        let scratch = try UpdateScratch()
        let app = try FakeApp.make(in: scratch.url, version: "1.2.3")
        let running = UpdateInstaller.runningArchitecture
        let other = running == NSBundleExecutableArchitectureARM64 ? "x86_64" : "arm64e"
        // The universal test binary runs here; thinned to the other architecture it must not.
        try UpdateInstaller.validate(app: app, bundleIdentifier: id, version: SemanticVersion("1.2.3")!)
        let executable = app.appendingPathComponent("Contents/MacOS/Logcatnip")
        try FakeApp.run("/usr/bin/lipo", [executable.path, "-thin", other, "-output", executable.path])
        try FakeApp.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        #expect {
            try UpdateInstaller.validate(app: app, bundleIdentifier: id, version: SemanticVersion("1.2.3")!)
        } throws: { error in
            if case .invalidBundle(let detail) = error as? UpdateError { detail.contains("architecture") } else { false }
        }
        // And a universal app is accepted for either architecture.
        let universal = try FakeApp.make(in: try scratch.folder("universal"), version: "1.2.3")
        try UpdateInstaller.validate(
            app: universal, bundleIdentifier: id, version: SemanticVersion("1.2.3")!,
            architecture: NSBundleExecutableArchitectureX86_64
        )
    }

    @Test func removesStaleAndDiscardedDownloads() throws {
        let scratch = try UpdateScratch()
        let stale = try scratch.folder("logcatnip-update-OLD")
        let unrelated = try scratch.folder("something-else")
        let staged = try scratch.folder("logcatnip-update-NEW")
        let app = try FakeApp.make(in: try scratch.folder("logcatnip-update-NEW/unpacked"), version: "1.0.0")

        UpdateInstaller.discard(app)
        #expect(!FileManager.default.fileExists(atPath: staged.path))

        UpdateInstaller.removeStaleDownloads(in: scratch.url)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))

        // Never deletes outside a download folder.
        let elsewhere = try FakeApp.make(in: try scratch.folder("mine/unpacked"), version: "1.0.0")
        UpdateInstaller.discard(elsewhere)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test func hashesFiles() throws {
        let scratch = try UpdateScratch()
        let file = scratch.url.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func installsOnlyFromAWritableAppBundle() throws {
        let scratch = try UpdateScratch()
        let app = try FakeApp.make(in: scratch.url, version: "1.0.0")
        #expect(UpdateInstaller.installBlocker(for: app) == nil)
        #expect(UpdateInstaller.installBlocker(for: scratch.url.appendingPathComponent("Logcatnip")) != nil)
        #expect(UpdateInstaller.installBlocker(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Logcatnip.app")) != nil)
        #expect(UpdateInstaller.installBlocker(for: URL(fileURLWithPath: "/System/Applications/Logcatnip.app")) != nil)
    }
}

/// The real swap script, with `open` replaced by markers so nothing launches.
@Suite struct SwapScriptTests {
    private struct Layout {
        let root: URL
        let target: URL
        let staging: URL
        let new: URL
        let backup: URL

        init(_ scratch: UpdateScratch, createNew: Bool = true) throws {
            root = scratch.url
            target = root.appendingPathComponent("Target.app")
            staging = root.appendingPathComponent("logcatnip-update-staging")
            new = staging.appendingPathComponent("unpacked/New.app")
            backup = root.appendingPathComponent(".Target-previous.app")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
            if createNew {
                try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
                try Data("new".utf8).write(to: new.appendingPathComponent("marker"))
            } else {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            }
        }

        func marker() throws -> String {
            try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func start(waitingFor pid: Int32) throws -> Process {
            let script = UpdateInstaller.swapScript
                .replacingOccurrences(of: "open \"$target\"", with: "echo > \"$target/relaunched\"")
                .replacingOccurrences(of: "open -R \"$new\"", with: "echo > \"$(dirname \"$target\")/revealed\"")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script, "test", String(pid), new.path, target.path, backup.path, staging.path]
            try process.run()
            return process
        }
    }

    /// A pid that has already exited.
    private func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func swapsTheBundleAndRelaunches() throws {
        let scratch = try UpdateScratch()
        let layout = try Layout(scratch)
        let script = try layout.start(waitingFor: deadPID())
        script.waitUntilExit()

        #expect(script.terminationStatus == 0)
        #expect(try layout.marker() == "new")
        #expect(layout.exists(layout.target.appendingPathComponent("relaunched")))
        #expect(!layout.exists(layout.backup))
        #expect(!layout.exists(layout.staging))
    }

    @Test func waitsForTheAppToQuit() async throws {
        let scratch = try UpdateScratch()
        let layout = try Layout(scratch)
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        // Runs until the test quits it, so a slow runner can't let it exit before the checks below.
        app.arguments = ["60"]
        try app.run()
        defer { if app.isRunning { app.terminate() } }
        let script = try layout.start(waitingFor: app.processIdentifier)

        try await Task.sleep(for: .milliseconds(400))
        #expect(app.isRunning)
        #expect(try layout.marker() == "old")

        app.terminate()
        app.waitUntilExit()
        script.waitUntilExit()
        #expect(try layout.marker() == "new")
        #expect(layout.exists(layout.target.appendingPathComponent("relaunched")))
    }

    @Test func putsTheOldAppBackWhenTheSwapFails() throws {
        let scratch = try UpdateScratch()
        let layout = try Layout(scratch, createNew: false)
        let script = try layout.start(waitingFor: deadPID())
        script.waitUntilExit()

        #expect(try layout.marker() == "old")
        #expect(!layout.exists(layout.backup))
        #expect(!layout.exists(layout.target.appendingPathComponent("relaunched")))
        #expect(layout.exists(scratch.url.appendingPathComponent("revealed")))
    }
}
