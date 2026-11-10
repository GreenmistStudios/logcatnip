/// A main-actor loop that calls `tick` on its owner every `interval`, for state that goes stale as time passes
/// (`age:` filters). It holds the owner weakly and never across a sleep, so the loop ends when the owner is
/// released even if nobody cancelled it, instead of waking forever.
@MainActor
public enum PeriodicRefresh {
    /// Why a loop ended.
    public enum Ending: Sendable, Equatable {
        case cancelled
        case ownerReleased
    }

    /// Starts the loop. The first tick comes one `interval` after the call. `sleep` is replaceable so tests do
    /// not wait on real time.
    @discardableResult
    public static func start<Owner: AnyObject & Sendable>(
        every interval: Duration,
        owner: Owner,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        tick: @escaping @MainActor (Owner) -> Void
    ) -> Task<Ending, Never> {
        Task { [weak owner] in
            while true {
                try? await sleep(interval)
                if Task.isCancelled { return .cancelled }
                guard let owner else { return .ownerReleased }
                tick(owner)
            }
        }
    }
}
