import AppKit
import LogcatKit

/// Tick marks drawn over the vertical scroller's track, one set of rows per layer. Find uses two
/// layers; the crash navigator adds its own later by extending `Layer`.
final class ScrollMarkersView: NSView {
    /// Drawn in raw-value order, so later layers sit on top of earlier ones.
    enum Layer: Int, CaseIterable, Comparable {
        case findMatches
        case currentFindMatch

        static func < (lhs: Layer, rhs: Layer) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Style {
        var color: NSColor
        var minLength: Int
    }

    private struct Marks {
        var rows: [Int]
        var style: Style
    }

    private var marks: [Layer: Marks] = [:]

    /// Number of rows the track stands for.
    var rowCount = 0 {
        didSet { if rowCount != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// Ticks are display only; clicks reach the scroller underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `rows` must be sorted ascending.
    func setRows(_ rows: [Int], for layer: Layer, style: Style) {
        if rows.isEmpty, marks[layer] == nil { return }
        marks[layer] = rows.isEmpty ? nil : Marks(rows: rows, style: style)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackLength = Int(bounds.height)
        for layer in Layer.allCases {
            guard let marks = marks[layer] else { continue }
            marks.style.color.setFill()
            // Cheap enough to compute on every draw (see ScrollMarkerLayout), so nothing is cached.
            let runs = ScrollMarkerLayout.runs(
                rows: marks.rows,
                rowCount: rowCount,
                trackLength: trackLength,
                minLength: marks.style.minLength
            )
            for run in runs {
                NSRect(x: 0, y: CGFloat(run.lowerBound), width: bounds.width, height: CGFloat(run.count)).fill()
            }
        }
    }
}

/// A scroll view that keeps a `ScrollMarkersView` over its vertical scroller, and the Message column's own
/// horizontal scroller over (or, with legacy scrollers, under) the bottom of that column. An overlay view
/// rather than a scroller subclass, because overlay scrollers fade out and would take the ticks with them.
final class LogScrollView: NSScrollView {
    /// Where the Message column is, in document (table) coordinates. Nil hides the Message scroller.
    struct MessageSpan: Equatable {
        var minX: CGFloat
        var width: CGFloat
    }

    let markers = ScrollMarkersView()
    let messageScroller = MessageScrollerView()

    var messageSpan: MessageSpan? {
        didSet { if messageSpan != oldValue { tile() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(messageScroller)
        addSubview(markers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tile() {
        super.tile()
        // Subview order: content, Message scroller, then the ticks on top of both.
        if subviews.last !== markers || subviews.dropLast().last !== messageScroller {
            addSubview(messageScroller, positioned: .above, relativeTo: nil)
            addSubview(markers, positioned: .above, relativeTo: nil)
        }
        layoutMessageScroller()
        let track: NSRect
        if let scroller = verticalScroller, !scroller.isHidden, !scroller.frame.isEmpty {
            track = scroller.convert(scroller.rect(for: .knobSlot), to: self)
        } else {
            let content = contentView.frame
            track = NSRect(x: content.maxX, y: content.minY, width: 0, height: content.height)
        }
        markers.frame = NSRect(x: track.maxX - 7, y: track.minY, width: 6, height: track.height)
    }

    /// Whether the log's own horizontal scroller is showing (the table is wider than the view).
    private var isMainHorizontalScrollerVisible: Bool {
        guard hasHorizontalScroller, let scroller = horizontalScroller else { return false }
        return !scroller.isHidden
    }

    /// Puts the Message scroller at the bottom of the Message column. With overlay scrollers it floats over
    /// the last rows like the system's own. Legacy scrollers take room of their own, so the rows are made
    /// shorter by one scroller and the Message scroller sits in the band that frees, unless the log's own
    /// horizontal scroller already makes that band.
    private func layoutMessageScroller() {
        guard let span = messageSpan else {
            messageScroller.isHidden = true
            return
        }
        let thickness = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let insets = contentView.contentInsets
        var content = contentView.frame
        let stripY: CGFloat
        if scrollerStyle == .legacy, !isMainHorizontalScrollerVisible {
            // The bottom edge is the larger y in a flipped view.
            content.size.height = max(0, content.height - thickness)
            if !isFlipped { content.origin.y += thickness }
            contentView.frame = content
            if let scroller = verticalScroller, !scroller.isHidden {
                var frame = scroller.frame
                frame.size.height = max(0, frame.height - thickness)
                if !isFlipped { frame.origin.y += thickness }
                scroller.frame = frame
            }
            stripY = isFlipped ? content.maxY : content.minY - thickness
        } else if isMainHorizontalScrollerVisible, let scroller = horizontalScroller {
            // Just above the log's own scroller.
            stripY = isFlipped ? scroller.frame.minY - thickness : scroller.frame.maxY
        } else {
            let bottomInset = insets.bottom
            stripY = isFlipped ? content.maxY - thickness - bottomInset : content.minY + bottomInset
        }
        let left = content.minX + span.minX - contentView.bounds.minX
        let visible = NSRect(x: left, y: stripY, width: span.width, height: thickness)
            .intersection(NSRect(x: content.minX, y: stripY, width: content.width, height: thickness))
        guard !visible.isNull, visible.width > 0 else {
            messageScroller.isHidden = true
            return
        }
        messageScroller.frame = visible
        messageScroller.isHidden = false
    }
}
