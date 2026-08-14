import AppKit
import KmgrCore

/// Native text-only renderer for `CellTypedValue.usage`. The exact
/// usage/request/limit or usage/capacity sequence is kept unobstructed; richer
/// accounting detail remains available through the tooltip and accessibility
/// value.
@MainActor
final class ResourceUsageTableCellView: NSTableCellView {
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.lineBreakMode = .byTruncatingTail
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
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(presentation.accessibilityValue)
        setAccessibilityHelp(toolTip)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        valueLabel.stringValue = ""
        valueLabel.toolTip = nil
        toolTip = nil
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
    }
}
