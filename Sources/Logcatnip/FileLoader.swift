import Foundation
import LogcatKit
import Observation

/// Loads one log file into its sessions: the file's own session, plus one per extra bug report buffer (Events,
/// Radio), created when that buffer's first entries arrive. Reading happens off the main actor; this class only
/// routes events and exposes progress for the status bar.
@MainActor
@Observable
final class FileLoader {
    enum State: Equatable {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    let url: URL
    /// Big files and zips show a progress bar and Cancel; smaller ones load before anyone could use them.
    let showsProgress: Bool
    private(set) var state: State = .running
    private(set) var progress: LogFileProgress?
    private(set) var format: LogFileFormat?

    /// Entries handed to each section's session, before the buffer limit trimmed any.
    @ObservationIgnored private(set) var delivered: [LogFileSection: Int] = [:]
    @ObservationIgnored private(set) var elapsed: TimeInterval?
    @ObservationIgnored private var startedAt = Date()
    /// Dropped when the load ends: sessions hold their loader, so keeping them here as well would be a cycle.
    @ObservationIgnored private var sessions: [LogFileSection: LogSession] = [:]
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var info: LogFileInfo?
    @ObservationIgnored private var readerTask: Task<Result<Void, Error>, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(url: URL, primary: LogSession, model: AppModel) {
        self.url = url
        self.model = model
        sessions[.main] = primary
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        showsProgress = url.pathExtension.lowercased() == "zip" || Int64(size) >= LogFileReader.progressThreshold
    }

    func start() {
        startedAt = Date()
        sessions[.main]?.beginLoading(self)
        let url = url
        // A detached task, so that reading and parsing stay off the main actor. Each event is awaited here, which
        // makes a busy main actor slow the reader down instead of letting entries pile up.
        let sink: @Sendable (LogFileEvent) async -> Void = { [weak self] event in await self?.handle(event) }
        let reader = Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                try await LogFileReader().read(url, handler: sink)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        readerTask = reader
        task = Task { [weak self] in
            let outcome = await reader.value
            self?.finish(outcome)
        }
    }

    /// Cancelling the outer task would not reach the detached one, so cancel both.
    func cancel() {
        readerTask?.cancel()
        task?.cancel()
    }

    private func handle(_ event: LogFileEvent) {
        switch event {
        case let .format(format):
            self.format = format
        case let .metadata(metadata):
            sessions[.main]?.applyFileMetadata(metadata)
        case let .info(info):
            self.info = info
            for session in sessions.values { session.setFileInfo(info) }
        case let .processNames(names):
            for session in sessions.values { session.adoptProcessNames(names) }
        case let .progress(progress):
            self.progress = progress
        case let .entries(batch, section):
            let session = sessions[section] ?? makeSession(section)
            session.ingestLoaded(batch)
            delivered[section, default: 0] += batch.count
        }
    }

    private func makeSession(_ section: LogFileSection) -> LogSession {
        guard let model else { return sessions[.main]! }
        let session = model.addFileSession(url: url, section: section)
        session.beginLoading(self)
        if let info { session.setFileInfo(info) }
        sessions[section] = session
        return session
    }

    private func finish(_ outcome: Result<Void, Error>) {
        elapsed = Date().timeIntervalSince(startedAt)
        switch outcome {
        case .success:
            state = .finished
        case let .failure(error):
            state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
        }
        for (section, session) in sessions {
            session.finishLoading(delivered: delivered[section] ?? 0, state: state, fraction: progress?.fraction)
        }
        sessions = [:]
    }
}
