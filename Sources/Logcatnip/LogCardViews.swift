import AppKit
import LogcatKit

/// The fonts of a card, built once per font size instead of per cell.
struct LogCardFonts {
    var regular: NSFont
    var bold: NSFont
    /// Time and footer: a point smaller, so the message and tag stand out.
    var small: NSFont
    var badge: NSFont
    /// Advance of one character of `small`, to size the time label without measuring text.
    var smallCharWidth: CGFloat

    init(_ regular: NSFont) {
        let size = regular.pointSize
        self.regular = regular
        bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        small = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        badge = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .bold)
        smallCharWidth = ("M" as NSString).size(withAttributes: [.font: small]).width
    }
}

/// One row of a card: the first row carries the header (level badge, bold tag, right-aligned time), every
/// row its line of the message, the last row the footer (PID/TID, package). Frames are computed from
/// `LogCardLayout` rather than by Auto Layout, because the table reuses and resizes these for every scroll.
final class LogCardCellView: NSView {
    let badge: NSTextField = {
        let badge = NSTextField(labelWithString: "")
        badge.alignment = .center
        badge.drawsBackground = true
        badge.isBezeled = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        return badge
    }()
    let tagLabel = LogCardCellView.singleLineLabel(.byTruncatingMiddle)
    let timeLabel: NSTextField = {
        let label = LogCardCellView.singleLineLabel(.byTruncatingTail)
        label.alignment = .right
        return label
    }()
    let messageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        // The table wraps by character too, so a wrapped row's height can be worked out without layout.
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.lineBreakMode = .byCharWrapping
        label.isSelectable = false
        return label
    }()
    let footerLabel = LogCardCellView.singleLineLabel(.byTruncatingHead)

    private(set) var geometry = LogCardLayout.placeholder
    /// The row's index within its entry.
    private(set) var line = 0
    private(set) var isLastLine = true
    private(set) var isMarker = false
    var badgeWidth: CGFloat = 20
    var timeWidth: CGFloat = 100

    /// Whether this row has the header and footer parts of the card (they may still be empty).
    var showsHeader: Bool { !isMarker && line == 0 && geometry.headerHeight > 0 }
    var showsFooter: Bool { !isMarker && isLastLine && geometry.footerHeight > 0 }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for subview in [badge, tagLabel, timeLabel, messageLabel, footerLabel] { addSubview(subview) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func singleLineLabel(_ lineBreak: NSLineBreakMode) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = lineBreak
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        return label
    }

    /// Positions the row within its card. The caller sets the text, colors and the hidden state of the
    /// header and footer labels, which `layout()` reads.
    func configure(geometry: LogCardLayout, line: Int, isLastLine: Bool, isMarker: Bool) {
        self.geometry = geometry
        self.line = line
        self.isLastLine = isLastLine
        self.isMarker = isMarker
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let g = geometry
        let left = CGFloat(g.inset + g.horizontalPadding)
        let width = max(0, bounds.width - 2 * left)
        // A marker is a plain line: its label takes the whole row above the gap.
        let tail = CGFloat(isMarker ? g.gap : (isLastLine ? g.footerHeight + g.padding + g.gap : 0))
        let top = CGFloat(isMarker ? 0 : g.messageTop(line: line))
        messageLabel.frame = NSRect(x: left, y: top, width: width, height: max(0, bounds.height - top - tail))
        guard !isMarker else { return }

        if showsHeader {
            let headerHeight = CGFloat(g.headerHeight)
            let lineHeight = min(CGFloat(g.lineHeight), headerHeight)
            let rowY = CGFloat(g.padding) + (headerHeight - lineHeight) / 2
            var x = left
            var right = left + width
            if !badge.isHidden {
                badge.frame = NSRect(x: x, y: rowY, width: badgeWidth, height: lineHeight)
                x += badgeWidth + 6
            }
            if !timeLabel.isHidden {
                let timeSpace = min(timeWidth, max(0, right - x))
                timeLabel.frame = NSRect(x: right - timeSpace, y: rowY, width: timeSpace, height: lineHeight)
                right -= timeSpace + 6
            }
            tagLabel.frame = NSRect(x: x, y: rowY, width: max(0, right - x), height: lineHeight)
        }
        if showsFooter {
            let height = CGFloat(g.footerHeight)
            footerLabel.frame = NSRect(
                x: left, y: bounds.height - CGFloat(g.gap + g.padding) - height, width: width, height: height
            )
        }
    }
}

/// Draws the card behind its rows: a rounded rectangle whose top corners are rounded on the entry's first
/// row and whose bottom corners on its last, so the rows of one entry read as a single card.
final class LogCardRowView: NSTableRowView {
    private var geometry = LogCardLayout.placeholder
    private var line = 0
    private var isLastLine = true
    private var isMarker = false

    private static let radius: CGFloat = 6

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(geometry: LogCardLayout, line: Int, isLastLine: Bool, isMarker: Bool) {
        self.geometry = geometry
        self.line = line
        self.isLastLine = isLastLine
        self.isMarker = isMarker
        needsDisplay = true
    }

    /// The card's outline within this row. An edge that continues into the next or previous row is pushed
    /// past the row's bounds, so its rounded corner is clipped away and the sides run on unbroken.
    private func cardPath() -> NSBezierPath {
        let r = Self.radius
        var rect = bounds.insetBy(dx: CGFloat(geometry.inset) + 0.5, dy: 0.5)
        if isLastLine { rect.size.height -= CGFloat(geometry.gap) }
        if line > 0 {
            rect.origin.y -= r
            rect.size.height += r
        }
        if !isLastLine { rect.size.height += r }
        return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    }

    private func draw(fill: NSColor, stroke: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let path = cardPath()
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A marker is a plain line, so only its selection is drawn.
    override func drawBackground(in dirtyRect: NSRect) {
        guard !isMarker else { return }
        draw(fill: .textBackgroundColor, stroke: .separatorColor)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        draw(fill: color, stroke: color)
    }
}

private extension LogCardLayout {
    /// Stands in until the table configures a recycled view.
    static let placeholder = LogCardLayout(
        lineHeight: 18, wrappedLineHeight: 15, headerHeight: 0, footerHeight: 0,
        padding: 0, gap: 0, inset: 0, horizontalPadding: 0
    )
}
