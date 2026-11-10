import AppKit

/// A Message column cell. It clips its label so text scrolled sideways never draws over the columns beside
/// it, which is what keeps Time, PID, Tag, Package and Level in place while only the message moves. It is an
/// `NSTableCellView` with the label as its `textField` so the table still restyles the label when the row is
/// selected, as it did when the label was the cell itself.
final class MessageCellView: NSTableCellView {
    let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        label.autoresizingMask = []
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }()

    /// Wrapped text fills the cell and has nothing to scroll.
    var wraps = false {
        didSet { if wraps != oldValue { layoutLabel() } }
    }

    /// Width of the text when it does not wrap: as wide as the widest line, so every line is whole inside the
    /// label and scrolling only moves it.
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { layoutLabel() } }
    }

    /// Moves the label only, with no layout pass, so sideways scrolling stays cheap.
    var offset: CGFloat = 0 {
        didSet {
            if offset != oldValue, !wraps { label.setFrameOrigin(NSPoint(x: -offset, y: 0)) }
        }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        // On macOS 14 views do not clip by default, and the scrolled label would draw over the pinned columns.
        clipsToBounds = true
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLabel()
    }

    override func layout() {
        super.layout()
        layoutLabel()
    }

    private func layoutLabel() {
        let frame = wraps
            ? bounds
            : NSRect(x: -offset, y: 0, width: max(contentWidth, bounds.width), height: bounds.height)
        if label.frame != frame { label.frame = frame }
    }
}

/// A horizontal scroller for the Message column alone: a scroll view with an empty document laid over (or,
/// with legacy scrollers, under) the column, so the system draws, fades and drags it like any other scroller.
/// The log's own scroll view never scrolls sideways while the table fits, so it has no scroller to use.
final class MessageScrollerView: NSScrollView {
    private var travel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        contentView.drawsBackground = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        borderType = .noBorder
        documentView = NSView(frame: .zero)
        contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The document is as wide as the strip plus the travel, so the clip view's x runs over exactly
    /// 0...travel, the message offset, even when the strip is narrower than the column.
    func setTravel(_ travel: CGFloat) {
        self.travel = travel
        applyTravel()
    }

    private func applyTravel() {
        let size = NSSize(width: bounds.width + travel, height: bounds.height)
        guard let document = documentView, document.frame.size != size else { return }
        document.setFrameSize(size)
        reflectScrolledClipView(contentView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyTravel()
    }

    /// Only the scroller takes clicks; the rest of the strip lets them through to the rows under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSScroller ? hit : nil
    }

    /// Wheel events over the scroller go to the log's scroll view (the event monitor has already taken the
    /// sideways ones).
    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }
}
