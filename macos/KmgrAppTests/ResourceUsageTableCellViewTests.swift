import AppKit
import Testing
@testable import Kmgr
import KmgrCore

extension AppKitTestHarness {
@MainActor
@Suite("Resource usage AppKit cell")
struct ResourceUsageTableCellViewTests {
    @Test("configures warning text tooltip and accessibility")
    func configuresCell() {
        let presentation = ResourceUsageCellPresentation(
            displayText: "420m / 500m / 1",
            value: ResourceUsageValue(
                usage: 0.42,
                request: 0.5,
                limit: 1,
                unit: "cores",
                resourceName: "cpu"
            )
        )
        let cell = ResourceUsageTableCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        cell.configure(
            presentation: presentation,
            toolTip: "Resource: cpu",
            alignment: .right,
            textColor: .labelColor
        )

        #expect(cell.textField?.stringValue == "420m / 500m / 1")
        #expect(cell.textField?.alignment == .right)
        #expect(cell.textField?.textColor == .systemOrange)
        #expect(cell.textField?.font == .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        ))
        #expect(cell.toolTip == "Resource: cpu")
        #expect(cell.subviews.count == 1)
        #expect(cell.subviews.first === cell.textField)
        #expect(cell.accessibilityLabel() == "CPU resource usage")
        #expect(cell.accessibilityValue() as? String ==
            "Warning, CPU, usage 420 millicores, request 500 millicores, limit 1 core")
    }

    @Test("critical pressure overrides the base style and normal reuse restores it")
    func criticalAndNormalStyles() {
        let cell = ResourceUsageTableCellView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 24)
        )
        cell.configure(
            presentation: ResourceUsageCellPresentation(
                displayText: "90 / 100",
                value: ResourceUsageValue(
                    usage: 90,
                    capacity: 100,
                    unit: "count",
                    resourceName: "pods"
                )
            ),
            toolTip: nil,
            alignment: .left,
            textColor: .secondaryLabelColor
        )

        #expect(cell.textField?.textColor == .systemRed)
        #expect(cell.textField?.font == .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        ))
        #expect(cell.accessibilityValue() as? String ==
            "Critical, Pods, usage 90 pods, capacity 100 pods")

        cell.configure(
            presentation: ResourceUsageCellPresentation(
                displayText: "10 / 100",
                value: ResourceUsageValue(
                    usage: 10,
                    capacity: 100,
                    unit: "count",
                    resourceName: "pods"
                )
            ),
            toolTip: nil,
            alignment: .left,
            textColor: .secondaryLabelColor
        )

        #expect(cell.textField?.textColor == .secondaryLabelColor)
        #expect(cell.textField?.font == .systemFont(ofSize: NSFont.systemFontSize))
        #expect(cell.accessibilityValue() as? String ==
            "Pods, usage 10 pods, capacity 100 pods")
    }

    @Test("usage search emphasis keeps pressure color and base weight")
    func emphasisPreservesPressureStyle() throws {
        let cell = ResourceUsageTableCellView()
        cell.configure(
            presentation: ResourceUsageCellPresentation(
                displayText: "420m / 500m / 1",
                value: ResourceUsageValue(
                    usage: 0.42,
                    request: 0.5,
                    limit: 1,
                    unit: "cores",
                    resourceName: "cpu"
                )
            ),
            toolTip: nil,
            alignment: .right,
            textColor: .labelColor,
            emphasizedTerm: "500M",
            changeHighlight: ResourceCellHighlightPresentation(
                emphasis: .neutral,
                strength: 0.5
            )
        )

        let attributed = try #require(cell.textField?.attributedStringValue)
        let match = (attributed.string as NSString).range(
            of: "500m",
            options: .caseInsensitive
        )
        let matchedFont = try #require(
            attributed.attribute(.font, at: match.location, effectiveRange: nil)
                as? NSFont
        )
        let baseFont = try #require(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        #expect(NSFontManager.shared.traits(of: matchedFont).contains(.boldFontMask))
        #expect(baseFont == .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        ))
        for index in 0..<attributed.length {
            #expect(attributed.attribute(
                .foregroundColor,
                at: index,
                effectiveRange: nil
            ) as? NSColor == .systemOrange)
        }
        #expect(cell.renderedHighlightColor != nil)
    }

}
}
