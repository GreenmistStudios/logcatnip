import Foundation
@testable import LogcatKit

/// Serves canned HTTP responses to sessions built from `MockURLProtocol.configuration()`. Routes are keyed by full
/// URL, and each test uses its own host, so suites running in parallel never see each other's routes.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var body = Data()
        var headers: [String: String] = [:]
        /// Fail the request with this error instead of answering.
        var error: URLError?
    }

    /// Routes and recorded requests. URLSession calls `startLoading` on its own threads, so both are guarded by
    /// `lock`.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var routes: [URL: Response] = [:]
        var requests: [URLRequest] = []
    }

    private static let state = State()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    static func session() -> URLSession {
        URLSession(configuration: configuration())
    }

    static func serve(_ url: URL, _ response: Response) {
        state.lock.withLock { state.routes[url] = response }
    }

    static func requests(to host: String) -> [URLRequest] {
        state.lock.withLock { state.requests.filter { $0.url?.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let route = Self.state.lock.withLock {
            Self.state.requests.append(request)
            return Self.state.routes[url]
        }
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if let error = route.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var headers = route.headers
        headers["Content-Length"] = String(route.body.count)
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Several chunks, so download progress is reported more than once.
        let chunk = max(1, route.body.count / 4)
        var offset = 0
        while offset < route.body.count {
            let end = min(route.body.count, offset + chunk)
            client?.urlProtocol(self, didLoad: route.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A temporary folder that goes away with the test.
final class UpdateScratch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("logcatnip-update-tests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Entries left in `folder`, for checking that failed downloads clean up.
    func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }
}

enum FakeApp {
    static let bundleIdentifier = "studio.greenmist.logcatnip"

    /// A minimal ad-hoc signed bundle, like `scripts/build-app.sh` makes.
    static func make(in folder: URL, identifier: String = bundleIdentifier, version: String) throws -> URL {
        let app = folder.appendingPathComponent("Logcatnip.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Logcatnip"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Logcatnip", "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    /// The app zipped the way the release workflow zips it.
    static func zip(_ app: URL, to zip: URL) throws -> Data {
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
        return try Data(contentsOf: zip)
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.unpack("\(tool) exited with \(process.terminationStatus)")
        }
    }
}

extension UpdateRelease {
    static func fixture(
        _ version: String, host: String = "example.com", size: Int = 100, sha256: String? = String(repeating: "a", count: 64),
        checksumURL: URL? = nil
    ) -> UpdateRelease {
        let semantic = SemanticVersion(version)!
        return UpdateRelease(
            version: semantic, tag: "v\(version)", title: "Logcatnip \(version)", notes: "* fix: things",
            pageURL: URL(string: "https://\(host)/releases/tag/v\(version)")!, publishedAt: nil,
            asset: .init(
                name: "Logcatnip-\(version).zip", url: URL(string: "https://\(host)/download/Logcatnip-\(version).zip")!,
                size: size, sha256: sha256, checksumURL: checksumURL
            )
        )
    }
}
