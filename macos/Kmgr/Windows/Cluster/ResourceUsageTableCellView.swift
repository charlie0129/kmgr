import AppKit
import KmgrCore

/// Native text-only renderer for `CellTypedValue.usage`. The exact
/// usage/request/limit or usage/capacity sequence is kept unobstructed; richer
/// accounting detail remains available through the tooltip and accessibility
/// value.
@MainActor
final class ResourceUsageTableCellView: HighlightableResourceTableCellView {
    func configure(
        presentation: ResourceUsageCellPresentation,
        toolTip: String?,
        alignment: NSTextAlignment,
        textColor: NSColor,
        emphasizedTerm: String? = nil,
        changeHighlight: ResourceCellHighlightPresentation? = nil
    ) {
        let baseFont: NSFont
        let effectiveTextColor: NSColor
        switch presentation.effectiveSeverity {
        case .warning:
            effectiveTextColor = .systemOrange
            baseFont = .systemFont(
                ofSize: NSFont.systemFontSize,
                weight: .semibold
            )
        case .critical:
            effectiveTextColor = .systemRed
            baseFont = .systemFont(
                ofSize: NSFont.systemFontSize,
                weight: .semibold
            )
        default:
            effectiveTextColor = textColor
            baseFont = .systemFont(ofSize: NSFont.systemFontSize)
        }
        configureText(
            presentation.text,
            baseFont: baseFont,
            textColor: effectiveTextColor,
            alignment: alignment,
            toolTip: toolTip,
            emphasizedTerm: emphasizedTerm,
            changeHighlight: changeHighlight
        )
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(presentation.accessibilityValue)
    }
}
