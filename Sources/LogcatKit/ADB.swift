import Foundation

/// Runs a child process and delivers its stdout incrementally.
///
/// With `stopsWithParent`, the command runs under a small `sh` watchdog that kills it when this process
/// goes away (quit, crash or SIGKILL): the watchdog blocks reading our stdin pipe, which the kernel closes
/// when we exit. Without it, a long-running `adb logcat` would outlive the app, because adb keeps its
/// server connection open even after nobody reads its output.
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let stdin: Pipe?
    private let lock = NSLock()
    private var stderrData = Data()

    static let watchdogScript = """
    exec 3<&0
    "$@" </dev/null 3<&- &
    child=$!
    ( cat <&3 >/dev/null 2>&1; kill -TERM "$child" 2>/dev/null ) >/dev/null 2>&1 &
    exec 3<&-
    trap 'kill -TERM "$child" 2>/dev/null' TERM INT HUP
    wait "$child"
    status=$?
    wait "$child" 2>/dev/null
    exit $status
    """

    init(executable: URL, arguments: [String], stopsWithParent: Bool = false) {
        if stopsWithParent {
            let stdin = Pipe()
            self.stdin = stdin
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.watchdogScript, "logcatnip-watchdog", executable.path] + arguments
            process.standardInput = stdin
        } else {
            stdin = nil
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdout
        process.standardError = stderr
        // Children must not inherit our ends of other children's pipes, or a watchdog would hold its own
        // stdin open and never see EOF.
        for pipe in [stdout, stderr, stdin].compactMap({ $0 }) {
            Self.setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
            Self.setCloseOnExec(pipe.fileHandleForWriting.fileDescriptor)
        }
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    /// Starts the process. `onData` runs serially on a background queue; `onExit` runs once, after stdout
    /// reached EOF and the process terminated, with the exit status and captured stderr.
    func start(onData: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        let group = DispatchGroup()
        group.enter() // stdout EOF
        group.enter() // stderr EOF
        group.enter() // termination

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                onData(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else if let self {
                self.lock.withLock { self.stderrData.append(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            // Let the watchdog's reader see EOF so it exits too.
            self?.closeStdin()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        group.notify(queue: .global()) { [self] in
            let errorText = lock.withLock { String(decoding: stderrData, as: UTF8.self) }
            onExit(process.terminationStatus, errorText)
        }
    }

    private var stdinClosed = false

    private func closeStdin() {
        guard let stdin else { return }
        let shouldClose = lock.withLock {
            defer { stdinClosed = true }
            return !stdinClosed
        }
        if shouldClose {
            try? stdin.fileHandleForWriting.close()
        }
    }

    func terminate() {
        // The watchdog kills the command as soon as its stdin closes.
        closeStdin()
        if process.isRunning {
            process.terminate()
        }
    }
}

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public var output: String { String(decoding: stdout, as: UTF8.self) }
}

public struct ADBError: Error, Sendable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// A thin wrapper over the `adb` executable.
public struct ADB: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Candidate locations for `adb`, in priority order.
    public static func candidatePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                paths.append((root as NSString).appendingPathComponent("platform-tools/adb"))
            }
        }
        paths.append((NSHomeDirectory() as NSString).appendingPathComponent("Library/Android/sdk/platform-tools/adb"))
        paths += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/usr/local/share/android-commandlinetools/platform-tools/adb",
        ]
        if let path = environment["PATH"] {
            paths += path.split(separator: ":").map { ($0 as NSString).appendingPathComponent("adb") }
        }
        return paths
    }

    /// Finds `adb`, preferring `overridePath` when it points at an executable.
    public static func locate(overridePath: String? = nil) -> ADB? {
        let fileManager = FileManager.default
        var candidates = candidatePaths()
        if let overridePath, !overridePath.isEmpty {
            candidates.insert((overridePath as NSString).expandingTildeInPath, at: 0)
        }
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return ADB(executable: URL(fileURLWithPath: path))
        }
        return nil
    }

    /// Runs `adb <arguments>` to completion.
    public func run(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> CommandResult {
        let process = StreamingProcess(executable: executable, arguments: arguments)
        let collected = DataBox()
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                do {
                    try process.start(
                        onData: { collected.append($0) },
                        onExit: { status, stderr in
                            continuation.resume(returning: CommandResult(status: status, stdout: collected.data, stderr: stderr))
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    public func startServer() async throws {
        let result = try await run(["start-server"])
        guard result.status == 0 else { throw ADBError(result.stderr.isEmpty ? "adb start-server failed" : result.stderr) }
    }

    public func shell(serial: String, _ command: String) async throws -> String {
        let result = try await run(["-s", serial, "shell", command])
        guard result.status == 0 else {
            throw ADBError(result.stderr.isEmpty ? "adb shell \(command) failed (\(result.status))" : result.stderr)
        }
        return result.output
    }

    public func properties(serial: String) async throws -> DeviceProperties {
        DeviceProperties.parse(try await shell(serial: serial, "getprop"))
    }

    /// pid -> process name for every running process.
    public func processes(serial: String) async throws -> [Int32: String] {
        let modern = ProcessListParser.parse(try await shell(serial: serial, "ps -A -o PID,NAME 2>/dev/null || ps"))
        if !modern.isEmpty { return modern }
        return ProcessListParser.parse(try await shell(serial: serial, "ps"))
    }

    /// Clears the device's log buffers (`logcat -c`).
    public func clearLogcat(serial: String, buffers: [String] = []) async throws {
        var arguments = ["-s", serial, "logcat"]
        for buffer in buffers {
            arguments += ["-b", buffer]
        }
        arguments.append("-c")
        let result = try await run(arguments)
        guard result.status == 0 else { throw ADBError(result.stderr.isEmpty ? "logcat -c failed" : result.stderr) }
    }

    // MARK: Streams

    public enum TrackEvent: Sendable {
        case devices([DeviceDescriptor])
        case failed(String)
    }

    /// Follows `adb track-devices -l`, restarting it if adb exits (for example when the server is killed).
    public func trackDevices(restartDelay: Duration = .seconds(2)) -> AsyncStream<TrackEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await startServer()
                    } catch {
                        continuation.yield(.failed("\(error)"))
                    }
                    let process = StreamingProcess(executable: executable, arguments: ["track-devices", "-l"], stopsWithParent: true)
                    let decoder = DecoderBox()
                    let exited: String? = await withTaskCancellationHandler {
                        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                            do {
                                try process.start(
                                    onData: { data in
                                        for snapshot in decoder.feed(data) {
                                            continuation.yield(.devices(snapshot))
                                        }
                                    },
                                    onExit: { status, stderr in
                                        done.resume(returning: status == 0 ? nil : stderr)
                                    }
                                )
                            } catch {
                                done.resume(returning: "\(error)")
                            }
                        }
                    } onCancel: {
                        process.terminate()
                    }
                    if Task.isCancelled { break }
                    continuation.yield(.devices([]))
                    if let exited, !exited.isEmpty {
                        continuation.yield(.failed(exited))
                    }
                    try? await Task.sleep(for: restartDelay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public struct LogcatOptions: Sendable {
        /// `-b` buffers; empty uses logcat's default (main, system, crash).
        public var buffers: [String] = []
        /// Only records at or after this time (`-T`), seconds since 1970.
        public var since: Double?
        /// Use `-v epoch` and `-v uid`. Both need Android 7.0 (API 24) or later.
        public var modernFormat = true

        public init(buffers: [String] = [], since: Double? = nil, modernFormat: Bool = true) {
            self.buffers = buffers
            self.since = since
            self.modernFormat = modernFormat
        }
    }

    public enum LogcatEvent: Sendable {
        case entries([LogEntry])
        /// logcat exited; the stream finishes after this.
        case ended(status: Int32, error: String)
    }

    public static func logcatArguments(serial: String, options: LogcatOptions) -> [String] {
        var arguments = ["-s", serial, "logcat", "-v", "long"]
        if options.modernFormat {
            arguments += ["-v", "epoch", "-v", "uid"]
        }
        for buffer in options.buffers {
            arguments += ["-b", buffer]
        }
        if let since = options.since {
            arguments += ["-T", String(format: "%.3f", since)]
        }
        return arguments
    }

    /// Streams parsed records from `adb logcat`. Cancelling the consuming task stops logcat.
    public func logcat(serial: String, options: LogcatOptions = LogcatOptions()) -> AsyncStream<LogcatEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let process = StreamingProcess(
                executable: executable,
                arguments: Self.logcatArguments(serial: serial, options: options),
                stopsWithParent: true
            )
            let parser = ParserBox()
            do {
                try process.start(
                    onData: { data in
                        let entries = parser.feed(data)
                        if !entries.isEmpty { continuation.yield(.entries(entries)) }
                    },
                    onExit: { status, stderr in
                        let rest = parser.finish()
                        if !rest.isEmpty { continuation.yield(.entries(rest)) }
                        continuation.yield(.ended(status: status, error: stderr))
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
}

// Boxes for state touched only from a process's serial readability queue.

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.withLock { storage.append(data) } }
    var data: Data { lock.withLock { storage } }
}

private final class DecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = TrackDevicesDecoder()
    func feed(_ data: Data) -> [[DeviceDescriptor]] { lock.withLock { decoder.feed(data) } }
}

private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = LogcatLongParser()
    func feed(_ data: Data) -> [LogEntry] { lock.withLock { parser.feed(data) } }
    func finish() -> [LogEntry] { lock.withLock { parser.finish() } }
}
