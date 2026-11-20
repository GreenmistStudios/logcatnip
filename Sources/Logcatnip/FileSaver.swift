import AppKit
import Foundation
import LogcatKit
import Observation

/// One save of a session to a file: runs `LogFileWriter` off the main actor and exposes progress for the status bar.
@MainActor
@Observable
final class FileSaver {
    enum State: Equatable {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    let url: URL
    let format: LogSaveFormat
    let visibleOnly: Bool
    private(set) var state: State = .running
    private(set) var fraction: Double = 0
    /// Big saves (estimated at `LogFileWriter.progressThreshold` or more) show a progress bar and Cancel; smaller
    /// ones are done before anyone could use them.
    private(set) var showsProgress = false
    /// True for a few seconds after a save succeeds, for the status bar's "Saved" note.
    private(set) var showsSavedNotice = false

    @ObservationIgnored private(set) var result: LogSaveResult?
    @ObservationIgnored private(set) var elapsed: TimeInterval?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var writerTask: Task<Result<LogSaveResult, Error>, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(url: URL, format: LogSaveFormat, visibleOnly: Bool) {
        self.url = url
        self.format = format
        self.visibleOnly = visibleOnly
    }

    func start(_ request: LogSaveRequest) {
        startedAt = Date()
        let url = url
        // A detached task, so that formatting and writing stay off the main actor. Each event is awaited here, which
        // makes a busy main actor slow the writer down instead of letting events pile up.
        let sink: @Sendable (LogSaveEvent) async -> Void = { [weak self] event in await self?.handle(event) }
        let writer = Task.detached(priority: .userInitiated) { () -> Result<LogSaveResult, Error> in
            do {
                return .success(try await LogFileWriter().write(request, to: url, handler: sink))
            } catch {
                return .failure(error)
            }
        }
        writerTask = writer
        task = Task { [weak self] in
            let outcome = await writer.value
            self?.finish(outcome)
        }
    }

    /// Cancelling the outer task would not reach the detached one, so cancel both. The old file, if any, is left as it was.
    func cancel() {
        writerTask?.cancel()
        task?.cancel()
    }

    private func handle(_ event: LogSaveEvent) {
        switch event {
        case let .estimated(bytes):
            showsProgress = bytes >= LogFileWriter.progressThreshold
        case let .progress(value):
            fraction = value
        }
    }

    private func finish(_ outcome: Result<LogSaveResult, Error>) {
        elapsed = Date().timeIntervalSince(startedAt)
        switch outcome {
        case let .success(result):
            self.result = result
            state = .finished
            showsSavedNotice = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.showsSavedNotice = false
            }
        case let .failure(error):
            if error is CancellationError {
                state = .cancelled
                return
            }
            state = .failed(error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = "Couldn’t save “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
