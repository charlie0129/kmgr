import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource table text effects")
struct ResourceTableCellViewTests {
    @Test("long resource values are constrained to one truncated line")
    func longValuesStayOnOneLine() throws {
        let cell = ResourceTextTableCellView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 24)
        )
        cell.configure(
            cell: Cell(
                columnID: "name",
                displayText: "controller-with-a-very-long-generated-pod-name-7b9d6f8c7d-x4k2p"
            ),
            alignment: .left
        )

        let textField = try #require(cell.textField)
        #expect(textField.maximumNumberOfLines == 1)
        #expect(textField.lineBreakMode == .byTruncatingTail)
        #expect(textField.cell?.usesSingleLineMode == true)
        #expect(textField.cell?.wraps == false)
    }

    @Test("simple filter emphasis bolds every case-insensitive literal range")
    func boldsCaseInsensitiveRanges() throws {
        let cell = ResourceTextTableCellView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 24)
        )
        cell.configure(
            cell: Cell(
                columnID: "name",
                displayText: "Api api API-server",
                severity: .critical
            ),
            alignment: .left,
            emphasizedTerm: "aPi"
        )

        let attributed = try #require(cell.textField?.attributedStringValue)
        #expect(attributed.string == "Api api API-server")
        #expect(boldRanges(in: attributed) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
            NSRange(location: 8, length: 3),
        ])
        #expect(font(in: attributed, at: 3) == .systemFont(
            ofSize: NSFont.systemFontSize
        ))
    }

    @Test("bold emphasis preserves semantic severity color")
    func preservesSeverityColor() throws {
        let cell = ResourceTextTableCellView()
        cell.configure(
            cell: Cell(
                columnID: "status",
                displayText: "Failed failed",
                severity: .critical
            ),
            alignment: .center,
            emphasizedTerm: "failed"
        )

        let attributed = try #require(cell.textField?.attributedStringValue)
        for index in 0..<attributed.length where index != 6 {
            #expect(color(in: attributed, at: index) == .systemRed)
        }
        #expect(cell.textField?.alignment == .center)
        #expect(cell.textField?.textColor == .systemRed)
    }

    @Test("neutral and regression highlights use bounded translucent strength")
    func semanticHighlightColorsAndStrength() throws {
        let neutralTint = NSColor(
            calibratedRed: 0.1,
            green: 0.3,
            blue: 0.7,
            alpha: 1
        )
        let regressionTint = NSColor(
            calibratedRed: 0.8,
            green: 0.1,
            blue: 0.2,
            alpha: 1
        )
        let cell = ResourceTextTableCellView()
        cell.effectsPolicy = ResourceTableCellEffectsPolicy(
            reducesMotion: false,
            neutralTint: neutralTint,
            regressionTint: regressionTint,
            neutralMaximumOpacity: 0.4,
            regressionMaximumOpacity: 0.5
        )

        cell.configure(
            cell: Cell(columnID: "cpu", displayText: "120m"),
            alignment: .right,
            changeHighlight: ResourceCellHighlightPresentation(
                emphasis: .neutral,
                strength: 0.25
            )
        )
        try expectColor(
            cell.renderedHighlightColor,
            equals: neutralTint.withAlphaComponent(0.1)
        )

        cell.configure(
            cell: Cell(columnID: "restarts", displayText: "2"),
            alignment: .right,
            changeHighlight: ResourceCellHighlightPresentation(
                emphasis: .regression,
                strength: 0.5
            )
        )
        try expectColor(
            cell.renderedHighlightColor,
            equals: regressionTint.withAlphaComponent(0.25)
        )

        let defaultPolicy = ResourceTableCellEffectsPolicy(
            reducesMotion: false
        )
        let defaultNeutral = defaultPolicy.backgroundColor(
            for: ResourceCellHighlightPresentation(
                emphasis: .neutral,
                strength: 1
            )
        )
        try expectColor(
            defaultNeutral,
            equals: NSColor.controlAccentColor.withAlphaComponent(0.28)
        )
        let defaultRegression = defaultPolicy.backgroundColor(
            for: ResourceCellHighlightPresentation(
                emphasis: .regression,
                strength: 1
            )
        )
        try expectColor(
            defaultRegression,
            equals: NSColor.systemRed.withAlphaComponent(0.32)
        )
    }

    @Test("reduced motion is injectable and renders a steady highlight")
    func reducedMotionPolicy() throws {
        let tint = NSColor(
            calibratedRed: 0.2,
            green: 0.4,
            blue: 0.6,
            alpha: 1
        )
        let policy = ResourceTableCellEffectsPolicy(
            reducesMotion: true,
            neutralTint: tint,
            neutralMaximumOpacity: 0.35
        )
        #expect(!policy.usesContinuousFade)

        let color = policy.backgroundColor(for: ResourceCellHighlightPresentation(
            emphasis: .neutral,
            strength: 0.01
        ))
        try expectColor(color, equals: tint.withAlphaComponent(0.35))
    }

    @Test("reuse clears text emphasis background tooltip and accessibility")
    func reuseClearsTransientState() throws {
        let cell = ResourceTextTableCellView()
        cell.effectsPolicy = ResourceTableCellEffectsPolicy(
            reducesMotion: false,
            neutralTint: .systemBlue,
            neutralMaximumOpacity: 0.4
        )
        cell.configure(
            cell: Cell(
                columnID: "status",
                displayText: "Failed",
                tooltip: "Pod failed",
                severity: .critical
            ),
            alignment: .right,
            emphasizedTerm: "fail",
            changeHighlight: ResourceCellHighlightPresentation(
                emphasis: .neutral,
                strength: 1
            )
        )
        #expect(!boldRanges(in: try #require(
            cell.textField?.attributedStringValue
        )).isEmpty)
        #expect(cell.renderedHighlightColor != nil)
        #expect(cell.toolTip == "Pod failed")

        cell.prepareForReuse()

        #expect(cell.textField?.stringValue.isEmpty == true)
        #expect(cell.textField?.attributedStringValue.length == 0)
        #expect(cell.textField?.font == .systemFont(ofSize: NSFont.systemFontSize))
        #expect(cell.textField?.textColor == .labelColor)
        #expect(cell.textField?.alignment == .left)
        #expect(cell.textField?.toolTip == nil)
        #expect(cell.toolTip == nil)
        #expect(cell.renderedHighlightColor == nil)
        #expect(cell.accessibilityLabel() == nil)
        #expect(cell.accessibilityValue() == nil)
        #expect(cell.accessibilityHelp() == nil)
    }
}
}

@MainActor
private func boldRanges(in value: NSAttributedString) -> [NSRange] {
    var ranges: [NSRange] = []
    value.enumerateAttribute(
        .font,
        in: NSRange(location: 0, length: value.length)
    ) { attribute, range, _ in
        guard let font = attribute as? NSFont,
            NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        else { return }
        ranges.append(range)
    }
    return ranges
}

@MainActor
private func font(in value: NSAttributedString, at index: Int) -> NSFont? {
    value.attribute(.font, at: index, effectiveRange: nil) as? NSFont
}

@MainActor
private func color(in value: NSAttributedString, at index: Int) -> NSColor? {
    value.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
}

@MainActor
private func expectColor(
    _ actual: NSColor?,
    equals expected: NSColor,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let actual = try #require(
        actual?.usingColorSpace(.deviceRGB),
        sourceLocation: sourceLocation
    )
    let expected = try #require(
        expected.usingColorSpace(.deviceRGB),
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.redComponent - expected.redComponent) < 0.000_001,
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.greenComponent - expected.greenComponent) < 0.000_001,
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.blueComponent - expected.blueComponent) < 0.000_001,
        sourceLocation: sourceLocation
    )
    #expect(
        abs(actual.alphaComponent - expected.alphaComponent) < 0.000_001,
        sourceLocation: sourceLocation
    )
}
