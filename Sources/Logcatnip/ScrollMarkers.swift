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

/// A scroll view that keeps a `ScrollMarkersView` over its vertical scroller. An overlay view rather than a
/// scroller subclass, because overlay scrollers fade out and would take the ticks with them.
final class LogScrollView: NSScrollView {
    let markers = ScrollMarkersView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(markers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tile() {
        super.tile()
        if subviews.last !== markers {
            addSubview(markers, positioned: .above, relativeTo: nil)
        }
        let track: NSRect
        if let scroller = verticalScroller, !scroller.isHidden, !scroller.frame.isEmpty {
            track = scroller.convert(scroller.rect(for: .knobSlot), to: self)
        } else {
            let content = contentView.frame
            track = NSRect(x: content.maxX, y: content.minY, width: 0, height: content.height)
        }
        markers.frame = NSRect(x: track.maxX - 7, y: track.minY, width: 6, height: track.height)
    }
}
