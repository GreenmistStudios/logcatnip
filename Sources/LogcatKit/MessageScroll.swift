import Foundation

/// The sideways position of the Message column's text while lines do not wrap. The table itself never scrolls
/// sideways, so the other columns stay where they are and only this offset moves the text inside its column.
public struct MessageScroll: Equatable, Sendable {
    public private(set) var offset: Double
    /// Width of the widest message text, in points.
    public private(set) var contentWidth: Double
    /// Width of the Message column, which is what shows of the text at once.
    public private(set) var viewportWidth: Double

    /// Clamps `offset` into 0...maxOffset.
    public init(contentWidth: Double = 0, viewportWidth: Double = 0, offset: Double = 0) {
        self.contentWidth = contentWidth
        self.viewportWidth = viewportWidth
        self.offset = 0
        self.offset = clamped(offset)
    }

    /// How far the text can move left before its end reaches the right edge of the column.
    public var maxOffset: Double { max(0, contentWidth - viewportWidth) }

    /// Less than half a point of travel counts as nothing to scroll, so rounding in a column width does not
    /// turn a scroller on.
    public var isScrollable: Bool { maxOffset >= 0.5 }

    private func clamped(_ value: Double) -> Double {
        min(max(0, value), maxOffset)
    }

    /// New sizes; the offset is pulled back into range (narrower content, wider viewport).
    public mutating func resize(contentWidth: Double, viewportWidth: Double) {
        self.contentWidth = contentWidth
        self.viewportWidth = viewportWidth
        offset = clamped(offset)
    }

    /// Moves to `offset`, kept in 0...maxOffset. Returns whether the offset changed.
    @discardableResult
    public mutating func scroll(to offset: Double) -> Bool {
        let target = clamped(offset)
        guard target != self.offset else { return false }
        self.offset = target
        return true
    }

    @discardableResult
    public mutating func scroll(by delta: Double) -> Bool {
        scroll(to: offset + delta)
    }

    public enum Move: Sendable {
        case left, right, start, end
    }

    /// Where ←/→ (`step` points) and ⌘←/⌘→ (the edges) lead, clamped.
    public func offset(after move: Move, step: Double) -> Double {
        switch move {
        case .left: clamped(offset - step)
        case .right: clamped(offset + step)
        case .start: 0
        case .end: maxOffset
        }
    }

    /// The offset that brings `x..<x+width` (content coordinates) into view, leaving `margin` before it, or nil
    /// when it is fully visible already. Clamped to 0...maxOffset.
    public func offsetRevealing(x: Double, width: Double, margin: Double) -> Double? {
        if x >= offset, x + width <= offset + viewportWidth { return nil }
        return clamped(x - margin)
    }
}

/// Decides whether a scroll gesture moves the Message column sideways or the table up and down. A gesture
/// keeps the axis its first movement chose, through its momentum, like NSScrollView's own axis locking, so a
/// mostly vertical swipe never drifts sideways and the table's scroll view only ever sees whole gestures.
public struct ScrollAxisLock: Equatable, Sendable {
    public enum Axis: Sendable, Equatable {
        case horizontal, vertical
    }

    /// `NSEvent.Phase` without AppKit.
    public enum Phase: Sendable, Equatable {
        case none, mayBegin, began, changed, stationary, ended, cancelled
    }

    /// The axis the gesture in progress chose; nil between gestures.
    public private(set) var locked: Axis?

    public init() {}

    /// The axis this event belongs to. A tie, or no movement, goes vertical so the table's scroll view keeps
    /// what it did before the Message column learned to scroll.
    public mutating func axis(deltaX: Double, deltaY: Double, phase: Phase, momentumPhase: Phase) -> Axis {
        let dominant: Axis = abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
        let result: Axis
        if phase == .none, momentumPhase == .none {
            // A plain mouse wheel (shift turns it sideways): every event stands alone.
            locked = nil
            return dominant
        } else if phase == .mayBegin {
            // Fingers down, nothing moved yet.
            locked = nil
            return .vertical
        } else if phase == .began {
            locked = dominant
            result = dominant
        } else {
            if momentumPhase == .began, locked == nil { locked = dominant }
            result = locked ?? dominant
        }
        // A gesture that ends without momentum keeps its lock until the next event; `.mayBegin`, `.began` and
        // a plain wheel event reset it.
        if phase == .cancelled || momentumPhase == .ended || momentumPhase == .cancelled { locked = nil }
        return result
    }
}
