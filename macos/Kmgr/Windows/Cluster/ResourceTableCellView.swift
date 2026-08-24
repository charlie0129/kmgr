import AppKit
import KmgrCore

@MainActor
struct ResourceTableTextAccent {
    var utf16Range: Range<Int>
    var font: NSFont
    var color: NSColor
}

/// AppKit policy for transient resource-table effects. The cell never starts
/// an animation: callers supply the current monotonic highlight presentation
/// and decide when to repaint. Reduced motion converts the supplied fade into
/// one steady highlight that can be removed at the normal expiry boundary.
@MainActor
struct ResourceTableCellEffectsPolicy {
    var reducesMotion: Bool
    var neutralTint: NSColor
    var warningTint: NSColor
    var regressionTint: NSColor
    var neutralMaximumOpacity: CGFloat
    var warningMaximumOpacity: CGFloat
    var regressionMaximumOpacity: CGFloat

    init(
        reducesMotion: Bool,
        neutralTint: NSColor = .controlAccentColor,
        warningTint: NSColor = .systemYellow,
        regressionTint: NSColor = .systemRed,
        neutralMaximumOpacity: CGFloat = 0.28,
        warningMaximumOpacity: CGFloat = 0.30,
        regressionMaximumOpacity: CGFloat = 0.32
    ) {
        self.reducesMotion = reducesMotion
        self.neutralTint = neutralTint
        self.warningTint = warningTint
        self.regressionTint = regressionTint
        self.neutralMaximumOpacity = min(max(neutralMaximumOpacity, 0), 1)
        self.warningMaximumOpacity = min(max(warningMaximumOpacity, 0), 1)
        self.regressionMaximumOpacity = min(max(regressionMaximumOpacity, 0), 1)
    }

    static var systemDefault: Self {
        Self(
            reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    var usesContinuousFade: Bool { !reducesMotion }

    func backgroundColor(
        for presentation: ResourceCellHighlightPresentation?
    ) -> NSColor? {
        guard let presentation else { return nil }
        let suppliedStrength = min(max(CGFloat(presentation.strength), 0), 1)
        guard suppliedStrength > 0 else { return nil }
        let effectiveStrength = reducesMotion ? 1 : suppliedStrength
        let tint: NSColor
        let maximumOpacity: CGFloat
        switch presentation.emphasis {
        case .neutral:
            tint = neutralTint
            maximumOpacity = neutralMaximumOpacity
        case .warning:
            tint = warningTint
            maximumOpacity = warningMaximumOpacity
        case .regression:
            tint = regressionTint
            maximumOpacity = regressionMaximumOpacity
        }
        let opacity = maximumOpacity * effectiveStrength
        guard opacity > 0 else { return nil }
        return tint.withAlphaComponent(opacity)
    }
}

/// Shared text and transient-background renderer for virtualized resource
/// cells. The only persistent state is reusable AppKit view structure; every
/// presentation attribute is replaced on configure and cleared on reuse.
@MainActor
class HighlightableResourceTableCellView: NSTableCellView {
    private let valueLabel = NSTextField(labelWithString: "")
    private var currentChangeHighlight: ResourceCellHighlightPresentation?

    var effectsPolicy = ResourceTableCellEffectsPolicy.systemDefault {
        didSet { applyChangeHighlight(currentChangeHighlight) }
    }

    private(set) var renderedHighlightColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.cell?.usesSingleLineMode = true
        valueLabel.cell?.wraps = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setAccessibilityElement(false)
        addSubview(valueLabel)
        textField = valueLabel
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    /// Installs complete text state. Terms are already parsed and scoped by
    /// the query presentation layer; the AppKit renderer only applies the
    /// bounded list of case-insensitive bold ranges it receives.
    func configureText(
        _ text: String,
        baseFont: NSFont,
        textColor: NSColor,
        alignment: NSTextAlignment,
        toolTip: String?,
        emphasizedTerms: [String],
        changeHighlight: ResourceCellHighlightPresentation?,
        textAccent: ResourceTableTextAccent? = nil
    ) {
        valueLabel.font = baseFont
        valueLabel.textColor = textColor
        valueLabel.attributedStringValue = Self.attributedText(
            text,
            baseFont: baseFont,
            textColor: textColor,
            emphasizedTerms: emphasizedTerms,
            textAccent: textAccent
        )
        valueLabel.alignment = alignment
        valueLabel.toolTip = toolTip
        self.toolTip = toolTip
        setAccessibilityLabel(nil)
        setAccessibilityValue(text)
        setAccessibilityHelp(toolTip)
        setChangeHighlight(changeHighlight)
    }

    /// Repaints the transient tint without rebuilding the cell or resetting
    /// its tooltip tracking area. Highlight fade frames use this lightweight
    /// path so an active hover remains attached to the same native view.
    func setChangeHighlight(
        _ presentation: ResourceCellHighlightPresentation?
    ) {
        currentChangeHighlight = presentation
        applyChangeHighlight(presentation)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let renderedHighlightColor {
            renderedHighlightColor.setFill()
            let highlightRect = bounds.insetBy(dx: 1, dy: 1)
            NSBezierPath(
                roundedRect: highlightRect,
                xRadius: 3,
                yRadius: 3
            ).fill()
        }
        // Keep text and the focus/selection presentation crisp above the
        // translucent change tint.
        super.draw(dirtyRect)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        valueLabel.attributedStringValue = NSAttributedString(string: "")
        valueLabel.stringValue = ""
        valueLabel.textColor = .labelColor
        valueLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        valueLabel.alignment = .left
        valueLabel.toolTip = nil
        toolTip = nil
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
        setChangeHighlight(nil)
    }

    private func applyChangeHighlight(
        _ presentation: ResourceCellHighlightPresentation?
    ) {
        renderedHighlightColor = effectsPolicy.backgroundColor(for: presentation)
        needsDisplay = true
    }

    private static func attributedText(
        _ text: String,
        baseFont: NSFont,
        textColor: NSColor,
        emphasizedTerms: [String],
        textAccent: ResourceTableTextAccent?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: textColor,
            ]
        )
        if let textAccent {
            let lowerBound = max(0, textAccent.utf16Range.lowerBound)
            let upperBound = min(result.length, textAccent.utf16Range.upperBound)
            if lowerBound < upperBound {
                result.addAttributes(
                    [
                        .font: textAccent.font,
                        .foregroundColor: textAccent.color,
                    ],
                    range: NSRange(
                        location: lowerBound,
                        length: upperBound - lowerBound
                    )
                )
            }
        }
        guard !emphasizedTerms.isEmpty, !text.isEmpty else {
            return result
        }

        let source = text as NSString
        var remaining = NSRange(location: 0, length: source.length)
        let boldFont = NSFont.systemFont(
            ofSize: baseFont.pointSize,
            weight: .bold
        )
        for emphasizedTerm in emphasizedTerms {
            guard !emphasizedTerm.isEmpty else { continue }
            let term = emphasizedTerm as NSString
            remaining = NSRange(location: 0, length: source.length)
            while remaining.length > 0 {
                let match = source.range(
                    of: term as String,
                    options: [.caseInsensitive, .literal],
                    range: remaining
                )
                guard match.location != NSNotFound else { break }
                result.addAttribute(.font, value: boldFont, range: match)
                let nextLocation = NSMaxRange(match)
                remaining = NSRange(
                    location: nextLocation,
                    length: source.length - nextLocation
                )
            }
        }
        return result
    }
}

/// Ordinary compact resource cell used for non-usage typed values and missing
/// values. Severity styling is centralized here so transient search emphasis
/// changes only matching font ranges and never replaces semantic text color.
@MainActor
final class ResourceTextTableCellView: HighlightableResourceTableCellView {
    func configure(
        cell: Cell?,
        placeholder: String = "—",
        alignment: NSTextAlignment,
        emphasizedTerms: [String] = [],
        changeHighlight: ResourceCellHighlightPresentation? = nil
    ) {
        let text = cell?.displayText ?? placeholder
        let style = Self.style(for: cell?.severity)
        let toolTip = cell?.tooltip.isEmpty == false ? cell?.tooltip : nil
        configureText(
            text,
            baseFont: style.font,
            textColor: style.color,
            alignment: alignment,
            toolTip: toolTip,
            emphasizedTerms: emphasizedTerms,
            changeHighlight: changeHighlight
        )
    }

    private static func style(
        for severity: CellSeverity?
    ) -> (font: NSFont, color: NSColor) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color: NSColor = switch severity {
        case .warning: .systemOrange
        case .critical: .systemRed
        case .informational: .systemBlue
        case .muted: .secondaryLabelColor
        case .terminating: .systemPurple
        default: .labelColor
        }
        return (font, color)
    }
}
