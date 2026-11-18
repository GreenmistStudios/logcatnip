import CryptoKit
import Foundation
import Security

/// A `major.minor.patch` version, as the release workflow tags it (`v1.2.3`) and writes it into
/// `CFBundleShortVersionString`. Pre-release and build suffixes (`-beta.1`, `+42`) are dropped: the feed only
/// offers full releases.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts `1.2.3`, `v1.2.3`, `1.2` and `1`; missing parts are zero.
    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = text[..<suffix] }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A published release that can replace the running app.
public struct UpdateRelease: Sendable, Equatable, Identifiable {
    public struct Asset: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var size: Int
        /// Lowercase hex SHA-256 from the asset's `digest` (GitHub adds it to every upload), if present.
        public var sha256: String?
        /// A `<name>.sha256` asset next to the zip, used when `digest` is missing.
        public var checksumURL: URL?

        public init(name: String, url: URL, size: Int, sha256: String? = nil, checksumURL: URL? = nil) {
            self.name = name
            self.url = url
            self.size = size
            self.sha256 = sha256
            self.checksumURL = checksumURL
        }
    }

    public var version: SemanticVersion
    public var tag: String
    public var title: String
    /// Release notes in GitHub Markdown.
    public var notes: String
    public var pageURL: URL
    public var publishedAt: Date?
    public var asset: Asset

    public var id: String { tag }

    public init(
        version: SemanticVersion, tag: String, title: String, notes: String, pageURL: URL, publishedAt: Date?,
        asset: Asset
    ) {
        self.version = version
        self.tag = tag
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.asset = asset
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case http(Int)
    case badFeed(String)
    case download(String)
    case checksumMismatch
    case missingChecksum
    case sizeMismatch(expected: Int, actual: Int)
    case unpack(String)
    case invalidBundle(String)
    case notInstallable(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status): "The update server answered with HTTP \(status)."
        case .badFeed(let detail): "The release feed could not be read: \(detail)"
        case .download(let detail): "The download failed: \(detail)"
        case .checksumMismatch: "The downloaded update does not match its published checksum."
        case .missingChecksum: "The release has no checksum, so the download cannot be verified."
        case .sizeMismatch(let expected, let actual): "The download is \(actual) bytes; the release lists \(expected)."
        case .unpack(let detail): "The update could not be unpacked: \(detail)"
        case .invalidBundle(let detail): "The downloaded app is not valid: \(detail)"
        case .notInstallable(let detail): detail
        }
    }
}

/// The GitHub Releases feed. The release workflow tags every release `vX.Y.Z` and uploads
/// `Logcatnip-X.Y.Z.zip`; drafts and pre-releases are never offered.
public enum UpdateFeed {
    public static let repository = "GreenmistStudios/logcatnip"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases")!

    private struct APIRelease: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: URL
        var draft: Bool?
        var prerelease: Bool?
        var published_at: Date?
        var assets: [APIAsset]
    }

    private struct APIAsset: Decodable {
        var name: String
        var browser_download_url: URL
        var size: Int
        var digest: String?
    }

    /// Decodes `/releases/latest` (one object) or `/releases` (an array, newest first). Releases without a zip,
    /// drafts, pre-releases and tags that are not versions are left out.
    public static func releases(from data: Data) throws -> [UpdateRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw: [APIRelease]
        do {
            if let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }), first == UInt8(ascii: "[") {
                raw = try decoder.decode([APIRelease].self, from: data)
            } else {
                raw = [try decoder.decode(APIRelease.self, from: data)]
            }
        } catch {
            throw UpdateError.badFeed(String(describing: error))
        }
        return raw.compactMap { release in
            guard release.draft != true, release.prerelease != true,
                  let version = SemanticVersion(release.tag_name),
                  let zip = release.assets.first(where: { isAppArchive($0.name) })
            else { return nil }
            let checksum = release.assets.first { $0.name == zip.name + ".sha256" }
            return UpdateRelease(
                version: version,
                tag: release.tag_name,
                title: release.name?.isEmpty == false ? release.name! : "Logcatnip \(version)",
                notes: release.body ?? "",
                pageURL: release.html_url,
                publishedAt: release.published_at,
                asset: .init(
                    name: zip.name, url: zip.browser_download_url, size: zip.size,
                    sha256: zip.digest.flatMap(sha256(fromDigest:)), checksumURL: checksum?.browser_download_url
                )
            )
        }
    }

    /// The newest release above `current`, or nil when the app is up to date.
    public static func newestRelease(in data: Data, newerThan current: SemanticVersion) throws -> UpdateRelease? {
        try releases(from: data).filter { $0.version > current }.max { $0.version < $1.version }
    }

    public static func fetchNewestRelease(
        newerThan current: SemanticVersion, feed: URL = latestReleaseURL, session: URLSession = .shared
    ) async throws -> UpdateRelease? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Logcatnip/\(current)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // No release published yet.
            if http.statusCode == 404 { return nil }
            throw UpdateError.http(http.statusCode)
        }
        return try newestRelease(in: data, newerThan: current)
    }

    static func isAppArchive(_ name: String) -> Bool {
        name.hasPrefix("Logcatnip") && name.hasSuffix(".zip")
    }

    /// GitHub writes digests as `sha256:<hex>`.
    static func sha256(fromDigest digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256", parts[1].count == 64,
              parts[1].allSatisfy(\.isHexDigit)
        else { return nil }
        return parts[1].lowercased()
    }

    /// The first word of a `shasum -a 256` line.
    static func sha256(fromChecksumFile text: String) -> String? {
        guard let word = text.split(whereSeparator: \.isWhitespace).first, word.count == 64,
              word.allSatisfy(\.isHexDigit)
        else { return nil }
        return word.lowercased()
    }
}

/// Downloads, verifies and installs an update. Nothing here touches the running app until
/// `installAndRelaunch`, which hands the swap to a shell that waits for the app to quit.
public enum UpdateInstaller {
    /// Why the running app can't replace itself, or nil when it can.
    public static func installBlocker(for appURL: URL, fileManager: FileManager = .default) -> String? {
        guard appURL.pathExtension == "app" else {
            return "Updates install only into Logcatnip.app. Run the app bundle to update in place."
        }
        if appURL.path.contains("/AppTranslocation/") {
            return "macOS is running Logcatnip from a temporary location. Move it to the Applications folder and open it again to install updates."
        }
        let parent = appURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent), fileManager.isWritableFile(atPath: appURL.path) else {
            return "Logcatnip can't write to \(parent). Download the update from the release page instead."
        }
        return nil
    }

    /// Downloads the release zip, checks its size and SHA-256, unpacks it and validates the app inside. Returns
    /// the unpacked `.app`, in a fresh temporary folder.
    /// `configuration` and `stagingRoot` are for tests: a mocked URL protocol and a folder they clean up.
    public static func prepare(
        _ release: UpdateRelease, bundleIdentifier: String, team: String? = nil,
        configuration: URLSessionConfiguration = .ephemeral,
        stagingRoot: URL = FileManager.default.temporaryDirectory,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let expected = try await expectedChecksum(for: release.asset, configuration: configuration)
        let folder = stagingRoot
            .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent(release.asset.name)
        do {
            try await Downloader.download(
                release.asset.url, to: zip, expectedSize: release.asset.size, configuration: configuration,
                progress: progress
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? -1
            if release.asset.size > 0, size != release.asset.size {
                throw UpdateError.sizeMismatch(expected: release.asset.size, actual: size)
            }
            guard try sha256(of: zip) == expected else { throw UpdateError.checksumMismatch }
            let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], failure: UpdateError.unpack)
            try? FileManager.default.removeItem(at: zip)
            let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first else {
                throw UpdateError.invalidBundle("expected one app in \(release.asset.name), found \(apps.count)")
            }
            try validate(app: app, bundleIdentifier: bundleIdentifier, version: release.version, team: team)
            return app
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The architecture this process runs as: an Intel build under Rosetta needs x86_64 even on Apple silicon.
    public static var runningArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    /// Checks the bundle identifier, the version, that it runs on `architecture`, and the code signature, so a
    /// mislabelled, damaged or wrong-architecture zip is never swapped in over a working app. With `team`, the
    /// app must also carry an Apple-issued signature from that team, so a Developer ID build only ever updates to
    /// another build by the same developer.
    public static func validate(
        app: URL, bundleIdentifier: String, version: SemanticVersion, architecture: Int = runningArchitecture,
        team: String? = nil
    ) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.invalidBundle("no Info.plist") }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.invalidBundle("bundle identifier is \(plist["CFBundleIdentifier"] ?? "missing")")
        }
        guard let short = plist["CFBundleShortVersionString"] as? String, SemanticVersion(short) == version else {
            throw UpdateError.invalidBundle("version is \(plist["CFBundleShortVersionString"] ?? "missing"), expected \(version)")
        }
        let executable = plist["CFBundleExecutable"] as? String ?? ""
        guard !executable.isEmpty,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { throw UpdateError.invalidBundle("no executable") }
        let architectures = Bundle(url: app)?.executableArchitectures?.map(\.intValue) ?? []
        guard architectures.contains(architecture) else {
            throw UpdateError.invalidBundle("it doesn't run on this Mac's architecture")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) {
            UpdateError.invalidBundle("code signature: \($0)")
        }
        if let team, !isSigned(app, byTeam: team) {
            throw UpdateError.invalidBundle("it isn't signed by this app's developer (team \(team))")
        }
    }

    /// The team whose Apple-issued certificate (Developer ID, say) signed `app`, or nil for an ad-hoc signed,
    /// unsigned or invalid app. The updater pins updates to the running app's team; ad-hoc builds, such as
    /// releases before Developer ID signing and local `scripts/build-app.sh` builds, pin nothing.
    public static func signingTeam(of app: URL) -> String? {
        guard let code = staticCode(app), let requirement = requirement("anchor apple generic"),
              SecStaticCodeCheckValidity(code, codeValidityFlags, requirement) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func isSigned(_ app: URL, byTeam team: String) -> Bool {
        // Only letters and digits, so the team can't change the requirement it is interpolated into.
        guard !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let code = staticCode(app),
              let requirement = requirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        else { return false }
        return SecStaticCodeCheckValidity(code, codeValidityFlags, requirement) == errSecSuccess
    }

    private static let codeValidityFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    )

    private static func staticCode(_ app: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess ? requirement : nil
    }

    /// Starts a detached shell that waits for `pid` to exit, moves `newApp` over `appURL` (keeping the old app
    /// until the new one is in place), and opens it. If the swap fails it puts the old app back and reveals the
    /// new one in Finder. The caller quits right after.
    public static func installAndRelaunch(newApp: URL, replacing appURL: URL, pid: Int32) throws {
        // The whole download folder from `prepare`, or just the folder holding the app.
        var staging = newApp.deletingLastPathComponent()
        if staging.deletingLastPathComponent().lastPathComponent.hasPrefix(stagingPrefix) {
            staging = staging.deletingLastPathComponent()
        }
        let backup = appURL.deletingLastPathComponent()
            .appendingPathComponent(".\(appURL.deletingPathExtension().lastPathComponent)-previous-\(UUID().uuidString).app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "logcatnip-update", String(pid), newApp.path, appURL.path, backup.path, staging.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static let stagingPrefix = "logcatnip-update-"

    /// Deletes the download folder `prepare` made for `app`, when an update is replaced by a newer one.
    public static func discard(_ app: URL) {
        let folder = app.deletingLastPathComponent().deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(stagingPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes downloads left by a run that quit without installing. Call at launch, before any download starts;
    /// an installed update's folder is already gone by then, removed by the swap script before it relaunches.
    public static func removeStaleDownloads(in root: URL = FileManager.default.temporaryDirectory) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Arguments: pid, new app, target, backup, staging folder to delete afterwards. Waits at most a minute for
    /// the app to quit.
    static let swapScript = #"""
    pid="$1"; new="$2"; target="$3"; backup="$4"; staging="$5"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -gt 300 ] && exit 1
      sleep 0.2
    done
    if mv "$target" "$backup" && mv "$new" "$target"; then
      rm -rf "$backup" "$staging"
      xattr -dr com.apple.quarantine "$target" 2>/dev/null
      open "$target"
    else
      [ -d "$backup" ] && [ ! -e "$target" ] && mv "$backup" "$target"
      open -R "$new"
    fi
    """#

    static func expectedChecksum(
        for asset: UpdateRelease.Asset, configuration: URLSessionConfiguration
    ) async throws -> String {
        if let sha256 = asset.sha256 { return sha256 }
        guard let url = asset.checksumURL else { throw UpdateError.missingChecksum }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        guard let sha256 = UpdateFeed.sha256(fromChecksumFile: String(decoding: data, as: UTF8.self)) else {
            throw UpdateError.missingChecksum
        }
        return sha256
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ arguments: [String], failure: (String) -> UpdateError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(message.isEmpty ? "\(tool) exited with \(process.terminationStatus)" : message)
        }
    }
}

/// One download with progress. URLSession calls the delegate on its own queue, and cancellation can finish the
/// task before the continuation is registered (a Swift task cancelled on entry cancels the URLSession task at
/// once). So `continuation` and `result` are guarded by `lock`: whichever of registering and finishing comes
/// second resumes the continuation, exactly once.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// Set once by `finish`; a continuation registered after it is resumed with it immediately.
    private var result: Result<Void, Error>?

    init(destination: URL, expectedSize: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    static func download(
        _ url: URL, to destination: URL, expectedSize: Int, configuration: URLSessionConfiguration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = Downloader(destination: destination, expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.register(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func register(_ continuation: CheckedContinuation<Void, Error>) {
        let finished: Result<Void, Error>? = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        if let finished { continuation.resume(with: finished) }
    }

    func finish(_ result: Result<Void, Error>) {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedSize)
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.http(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(UpdateError.download(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(UpdateError.download(error.localizedDescription)))
            }
        }
    }
}
