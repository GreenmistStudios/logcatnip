import Foundation
import Testing
@testable import LogcatKit

@Suite struct MessageScrollTests {
    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    @Test func clampsOnInit() {
        #expect(MessageScroll(contentWidth: 1000, viewportWidth: 300, offset: 900).offset == 700)
        #expect(MessageScroll(contentWidth: 1000, viewportWidth: 300, offset: -5).offset == 0)
    }

    @Test func maxOffsetIsContentBeyondViewport() {
        let wide = MessageScroll(contentWidth: 1000, viewportWidth: 300)
        #expect(wide.maxOffset == 700)
        #expect(wide.isScrollable)
        let narrow = MessageScroll(contentWidth: 200, viewportWidth: 300)
        #expect(narrow.maxOffset == 0)
        #expect(!narrow.isScrollable)
    }

    @Test func lessThanHalfAPointIsNotScrollable() {
        #expect(!MessageScroll(contentWidth: 300.4, viewportWidth: 300).isScrollable)
        #expect(MessageScroll(contentWidth: 300.5, viewportWidth: 300).isScrollable)
    }

    @Test func scrollClamps() {
        var scroll = MessageScroll(contentWidth: 1000, viewportWidth: 300)
        var changed = scroll.scroll(to: -5)
        #expect(!changed)
        #expect(scroll.offset == 0)
        changed = scroll.scroll(to: 10_000)
        #expect(changed)
        #expect(scroll.offset == 700)
        changed = scroll.scroll(by: -100)
        #expect(changed)
        #expect(scroll.offset == 600)
        changed = scroll.scroll(by: 0)
        #expect(!changed)
        #expect(scroll.offset == 600)
    }

    @Test func resizeKeepsOffsetInRange() {
        var scroll = MessageScroll(contentWidth: 1000, viewportWidth: 300, offset: 700)
        scroll.resize(contentWidth: 1000, viewportWidth: 500)
        #expect(scroll.offset == 500)
        scroll.resize(contentWidth: 2000, viewportWidth: 500)
        #expect(scroll.offset == 500)
        scroll.resize(contentWidth: 100, viewportWidth: 500)
        #expect(scroll.offset == 0)
    }

    @Test func arrowMoves() {
        var scroll = MessageScroll(contentWidth: 1000, viewportWidth: 300, offset: 100)
        #expect(close(scroll.offset(after: .left, step: 59.36), 40.64))
        #expect(close(scroll.offset(after: .right, step: 59.36), 159.36))
        #expect(scroll.offset(after: .start, step: 59.36) == 0)
        #expect(scroll.offset(after: .end, step: 59.36) == 700)
        scroll.scroll(to: 0)
        #expect(scroll.offset(after: .left, step: 59.36) == 0)
        scroll.scroll(to: 690)
        #expect(scroll.offset(after: .right, step: 59.36) == 700)
    }

    @Test func revealIsNilWhenVisible() {
        let scroll = MessageScroll(contentWidth: 2000, viewportWidth: 300, offset: 100)
        #expect(scroll.offsetRevealing(x: 150, width: 50, margin: 40) == nil)
        // The exact edges still count as visible.
        #expect(scroll.offsetRevealing(x: 100, width: 300, margin: 40) == nil)
    }

    @Test func revealScrollsRightWithMargin() {
        let scroll = MessageScroll(contentWidth: 2000, viewportWidth: 300, offset: 100)
        #expect(scroll.offsetRevealing(x: 800, width: 30, margin: 40) == 760)
    }

    @Test func revealScrollsLeft() {
        let scroll = MessageScroll(contentWidth: 2000, viewportWidth: 300, offset: 500)
        #expect(scroll.offsetRevealing(x: 100, width: 10, margin: 40) == 60)
    }

    @Test func revealClampsToTheEdges() {
        var scroll = MessageScroll(contentWidth: 1000, viewportWidth: 300)
        #expect(scroll.offsetRevealing(x: 990, width: 5, margin: 40) == 700)
        scroll.scroll(to: 200)
        #expect(scroll.offsetRevealing(x: 10, width: 5, margin: 40) == 0)
    }

    @Test func twoThousandCharacterLineReachesItsEnd() {
        let charWidth = 7.42
        let viewport = 800.0
        var scroll = MessageScroll(contentWidth: 2010 * charWidth + 8, viewportWidth: viewport)
        scroll.scroll(to: scroll.offset(after: .end, step: 8 * charWidth))
        let x = 4 + 2009 * charWidth
        #expect(x >= scroll.offset)
        #expect(x + charWidth <= scroll.offset + viewport)
        #expect(scroll.offsetRevealing(x: x, width: charWidth, margin: 40) == nil)
    }
}

@Suite struct ScrollAxisLockTests {
    private typealias Lock = ScrollAxisLock

    /// `#expect` cannot call a mutating method, so each event goes through here.
    private func axis(
        _ lock: inout Lock, _ deltaX: Double, _ deltaY: Double, _ phase: Lock.Phase = .none, _ momentum: Lock.Phase = .none
    ) -> Lock.Axis {
        lock.axis(deltaX: deltaX, deltaY: deltaY, phase: phase, momentumPhase: momentum)
    }

    @Test func wheelPicksTheLargerDelta() {
        var lock = Lock()
        #expect(axis(&lock, 3, 1, .none, .none) == .horizontal)
        #expect(lock.locked == nil)
        #expect(axis(&lock, 1, 3, .none, .none) == .vertical)
        #expect(lock.locked == nil)
        #expect(axis(&lock, 0, 0, .none, .none) == .vertical)
        #expect(lock.locked == nil)
        #expect(axis(&lock, 2, 2, .none, .none) == .vertical)
        #expect(lock.locked == nil)
    }

    @Test func gestureKeepsItsFirstAxis() {
        var lock = Lock()
        #expect(axis(&lock, -20, 2, .began, .none) == .horizontal)
        #expect(axis(&lock, -1, 15, .changed, .none) == .horizontal)
        #expect(axis(&lock, 0, 0, .ended, .none) == .horizontal)
        #expect(axis(&lock, -5, 9, .none, .began) == .horizontal)
        #expect(axis(&lock, 0, 9, .none, .changed) == .horizontal)
        #expect(axis(&lock, 0, 0, .none, .ended) == .horizontal)
        #expect(lock.locked == nil)
    }

    @Test func verticalGestureStaysVertical() {
        var lock = Lock()
        #expect(axis(&lock, 2, -20, .began, .none) == .vertical)
        #expect(axis(&lock, 30, 0, .changed, .none) == .vertical)
    }

    @Test func newGestureResetsTheLock() {
        var lock = Lock()
        _ = axis(&lock, -20, 0, .began, .none)
        _ = axis(&lock, 0, 0, .ended, .none)
        #expect(axis(&lock, 0, 10, .began, .none) == .vertical)
    }

    @Test func mayBeginPassesThrough() {
        var lock = Lock()
        #expect(axis(&lock, 0, 0, .mayBegin, .none) == .vertical)
        #expect(lock.locked == nil)
    }

    @Test func cancelledClearsTheLock() {
        var lock = Lock()
        #expect(axis(&lock, -20, 0, .began, .none) == .horizontal)
        #expect(axis(&lock, 0, 0, .cancelled, .none) == .horizontal)
        #expect(lock.locked == nil)
    }

    @Test func momentumWithoutLockDecidesOnItsOwn() {
        var lock = Lock()
        #expect(axis(&lock, -8, 1, .none, .began) == .horizontal)
        #expect(lock.locked == .horizontal)
        #expect(axis(&lock, 0, 4, .none, .changed) == .horizontal)
    }

    @Test func wheelAfterGestureClearsTheLock() {
        var lock = Lock()
        _ = axis(&lock, -20, 0, .began, .none)
        #expect(axis(&lock, 0, 5, .none, .none) == .vertical)
        #expect(lock.locked == nil)
    }
}
