import Testing
@testable import LogcatKit

@MainActor
private final class Owner {
    var ticks = 0
}

/// Polls with real 1 ms sleeps, for up to about two seconds, so a broken loop fails instead of hanging the run.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
@Suite struct PeriodicRefreshTests {
    @Test func ticksUntilCancelled() async {
        let owner = Owner()
        let task = PeriodicRefresh.start(every: .milliseconds(1), owner: owner) { $0.ticks += 1 }
        await waitUntil { owner.ticks >= 3 }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(owner.ticks >= 3)
    }

    @Test func endsWhenTheOwnerIsReleased() async {
        var owner: Owner? = Owner()
        weak var released = owner
        let task = PeriodicRefresh.start(every: .milliseconds(1), owner: owner!) { $0.ticks += 1 }
        await waitUntil { (released?.ticks ?? 0) >= 1 }
        #expect((released?.ticks ?? 0) >= 1)
        owner = nil
        // The loop is asleep on the main actor here, so it holds no reference and the owner goes away now.
        #expect(released == nil)
        #expect(await task.value == .ownerReleased)
    }

    @Test func cancellingInterruptsTheSleep() async {
        let owner = Owner()
        let task = PeriodicRefresh.start(every: .seconds(3600), owner: owner) { $0.ticks += 1 }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(owner.ticks == 0)
    }

    @Test func injectedSleepDrivesTheTicks() async {
        let owner = Owner()
        let task = PeriodicRefresh.start(every: .seconds(5), owner: owner, sleep: { _ in await Task.yield() }) {
            $0.ticks += 1
        }
        await waitUntil { owner.ticks >= 2 }
        #expect(owner.ticks >= 2)
        task.cancel()
        #expect(await task.value == .cancelled)
    }
}
