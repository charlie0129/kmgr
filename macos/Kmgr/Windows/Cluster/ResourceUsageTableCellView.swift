import AppKit
import KmgrCore

/// Native text-only renderer for `CellTypedValue.usage`. Pressure color and
/// weight apply only to the leading current-usage component; request, limit,
/// and capacity values retain the base text style as accounting context.
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
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let accentColor: NSColor? = switch presentation.effectiveSeverity {
        case .warning: .systemOrange
        case .critical: .systemRed
        default: nil
        }
        let textAccent = accentColor.flatMap { color in
            presentation.currentUsageTextRange.map { range in
                ResourceTableTextAccent(
                    utf16Range: range,
                    font: .systemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: .semibold
                    ),
                    color: color
                )
            }
        }
        configureText(
            presentation.text,
            baseFont: baseFont,
            textColor: textColor,
            alignment: alignment,
            toolTip: toolTip,
            emphasizedTerm: emphasizedTerm,
            changeHighlight: changeHighlight,
            textAccent: textAccent
        )
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(presentation.accessibilityValue)
    }
}
