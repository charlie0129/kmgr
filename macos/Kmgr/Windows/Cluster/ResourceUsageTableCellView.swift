import AppKit
import KmgrCore

/// Native compact renderer for `CellTypedValue.usage`. Shape and position are
/// the primary encoding: fill is an area, request is a tick, limit is a double
/// tick, capacity is a capped tick, and overflow adds a terminal chevron.
@MainActor
final class ResourceUsageTableCellView: NSTableCellView {
    let usageTrackView = ResourceUsageTrackView()
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setAccessibilityElement(false)
        usageTrackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(usageTrackView)
        addSubview(valueLabel)
        textField = valueLabel
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            usageTrackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            usageTrackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            usageTrackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            usageTrackView.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func configure(
        presentation: ResourceUsageCellPresentation,
        toolTip: String?,
        alignment: NSTextAlignment,
        textColor: NSColor
    ) {
        valueLabel.stringValue = presentation.text
        valueLabel.alignment = alignment
        valueLabel.textColor = textColor
        valueLabel.toolTip = toolTip
        self.toolTip = toolTip
        usageTrackView.presentation = presentation
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(presentation.accessibilityValue)
        setAccessibilityHelp(toolTip)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        valueLabel.stringValue = ""
        valueLabel.toolTip = nil
        toolTip = nil
        usageTrackView.presentation = nil
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
    }
}

@MainActor
final class ResourceUsageTrackView: NSView {
    enum MarkerStyle: Hashable {
        case tick
        case doubleTick
        case cappedTick
    }

    var presentation: ResourceUsageCellPresentation? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    static func markerStyle(
        for component: ResourceUsageCellPresentation.Component
    ) -> MarkerStyle? {
        switch component {
        case .usage: nil
        case .request: .tick
        case .limit: .doubleTick
        case .capacity: .cappedTick
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let presentation, bounds.width > 1, bounds.height > 1 else { return }

        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.separatorColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        if let ratio = presentation.fillRatio, ratio.isFinite, ratio >= 0 {
            let visibleRatio = min(ratio, 1)
            if visibleRatio > 0 {
                let fill = NSRect(
                    x: track.minX,
                    y: track.minY,
                    width: track.width * visibleRatio,
                    height: track.height
                )
                NSColor.controlAccentColor.withAlphaComponent(0.30).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
        }

        NSColor.secondaryLabelColor.setStroke()
        for marker in presentation.markers {
            draw(marker: marker, in: track)
        }
        if presentation.hasOverflow {
            drawOverflowChevron(in: track)
        }
    }

    private func draw(
        marker: ResourceUsageCellPresentation.Marker,
        in track: NSRect
    ) {
        guard marker.ratio.isFinite, marker.ratio >= 0,
            let style = Self.markerStyle(for: marker.component)
        else { return }
        let markerInset: CGFloat = style == .cappedTick ? 2 : 1
        let rawX = track.minX + track.width * min(marker.ratio, 1)
        let x = pixelAligned(min(
            max(rawX, track.minX + markerInset),
            track.maxX - markerInset
        ))
        switch style {
        case .tick:
            strokeLine(from: NSPoint(x: x, y: track.minY - 1),
                       to: NSPoint(x: x, y: track.maxY + 1), width: 1)
        case .doubleTick:
            strokeLine(from: NSPoint(x: x - 1, y: track.minY - 1),
                       to: NSPoint(x: x - 1, y: track.maxY + 1), width: 1)
            strokeLine(from: NSPoint(x: x + 1, y: track.minY - 1),
                       to: NSPoint(x: x + 1, y: track.maxY + 1), width: 1)
        case .cappedTick:
            let cap: CGFloat = 2
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: x, y: track.minY - 1))
            path.line(to: NSPoint(x: x, y: track.maxY + 1))
            path.move(to: NSPoint(x: x - cap, y: track.minY))
            path.line(to: NSPoint(x: x + cap, y: track.minY))
            path.move(to: NSPoint(x: x - cap, y: track.maxY))
            path.line(to: NSPoint(x: x + cap, y: track.maxY))
            path.stroke()
        }
    }

    private func drawOverflowChevron(in track: NSRect) {
        let x = track.maxX - 1
        let halfHeight = max(1, track.height / 2)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: x - 3, y: track.midY - halfHeight))
        path.line(to: NSPoint(x: x, y: track.midY))
        path.line(to: NSPoint(x: x - 3, y: track.midY + halfHeight))
        path.stroke()
    }

    private func strokeLine(from start: NSPoint, to end: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.move(to: start)
        path.line(to: end)
        path.stroke()
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        guard let scale = window?.backingScaleFactor, scale > 0 else {
            return value.rounded(.toNearestOrAwayFromZero)
        }
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}
