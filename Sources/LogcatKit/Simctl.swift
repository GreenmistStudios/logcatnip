import Foundation

/// A thin wrapper over Xcode's `simctl`, for listing simulators and streaming their unified logs.
public struct Simctl: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public enum LocateResult: Sendable {
        case found(Simctl)
        /// Xcode is missing; the message says what to install.
        case unavailable(String)
    }

    /// Finds `simctl` in the selected developer directory.
    ///
    /// It never runs `xcrun` without a developer directory: on a Mac without developer tools that opens the
    /// "install command line tools" dialog, and Android users without Xcode must not see it.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) async -> LocateResult {
        var developerDirectory = environment["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if developerDirectory == nil {
            let result = try? await StreamingProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                arguments: ["-p"],
                timeout: .seconds(5)
            )
            if let result, result.status == 0 {
                let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                developerDirectory = path.isEmpty ? nil : path
            }
        }
        guard let developerDirectory else {
            return .unavailable("Install Xcode to see iOS Simulator logs.")
        }
        let path = (developerDirectory as NSString).appendingPathComponent("usr/bin/simctl")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .unavailable(
                "iOS Simulator logs need Xcode, but the selected developer directory (\(developerDirectory)) has no simctl. "
                    + "Install Xcode, or select it with: sudo xcode-select -s /Applications/Xcode.app"
            )
        }
        return .found(Simctl(executable: URL(fileURLWithPath: path)))
    }

    public func run(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> CommandResult {
        try await StreamingProcess.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Every simulator simctl knows about, booted or not.
    public func devices() async throws -> [SimulatorDevice] {
        let result = try await run(["list", "devices", "--json"])
        guard result.status == 0 else {
            throw ADBError(result.stderr.isEmpty ? "simctl list devices failed (\(result.status))" : result.stderr)
        }
        return try SimulatorList.decode(result.stdout)
    }

    public enum TrackEvent: Sendable {
        case devices([SimulatorDevice])
        case failed(String)
    }

    /// Polls for booted simulators and yields the list whenever it changes. simctl has no equivalent of
    /// `adb track-devices`, and a list takes about 0.2 s, so a short interval is cheap.
    public func trackBootedDevices(interval: Duration = .seconds(2)) -> AsyncStream<TrackEvent> {
        AsyncStream { continuation in
            let task = Task {
                var last: [SimulatorDevice]?
                var lastError: String?
                while !Task.isCancelled {
                    do {
                        let booted = try await devices().filter { $0.isBooted && $0.isAvailable }
                        lastError = nil
                        if booted != last {
                            last = booted
                            continuation.yield(.devices(booted))
                        }
                    } catch {
                        let message = "\(error)"
                        if message != lastError, !Task.isCancelled {
                            lastError = message
                            continuation.yield(.failed(message))
                        }
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func logStreamArguments(udid: String) -> [String] {
        // --level debug matches logcat, which shows every level; filters narrow it down.
        ["spawn", udid, "log", "stream", "--style", "ndjson", "--level", "debug"]
    }

    /// Streams parsed records from `log stream` inside the simulator. Cancelling the consuming task stops it.
    public func logStream(udid: String) -> AsyncStream<LogStreamEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let process = StreamingProcess(
                executable: executable,
                arguments: Self.logStreamArguments(udid: udid),
                stopsWithParent: true
            )
            let parser = UnifiedParserBox()
            do {
                try process.start(
                    onData: { data in
                        let entries = parser.feed(data)
                        if !entries.isEmpty { continuation.yield(.entries(entries)) }
                    },
                    onExit: { status, stderr in
                        let rest = parser.finish()
                        if !rest.isEmpty { continuation.yield(.entries(rest)) }
                        continuation.yield(.ended(status: status, error: Self.meaningfulErrors(stderr)))
                        continuation.finish()
                    }
                )
            } catch {
                continuation.yield(.ended(status: -1, error: "\(error)"))
                continuation.finish()
            }
            continuation.onTermination = { _ in process.terminate() }
        }
    }

    /// Drops the noise `log` prints inside a simulator, where the host user's uid has no passwd entry.
    static func meaningfulErrors(_ stderr: String) -> String {
        stderr.split(separator: "\n")
            .filter { !$0.hasPrefix("getpwuid_r did not find a match") }
            .joined(separator: "\n")
    }
}

/// Events from a log stream: logcat or a simulator's `log stream`.
public typealias LogStreamEvent = ADB.LogcatEvent

// Touched only from the process's serial readability queue; the lock keeps the compiler and TSan happy.
private final class UnifiedParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = UnifiedLogParser()
    func feed(_ data: Data) -> [LogEntry] { lock.withLock { parser.feed(data) } }
    func finish() -> [LogEntry] { lock.withLock { parser.finish() } }
}
