import AppKit
import Testing
@testable import Kmgr
import KmgrCore

extension AppKitTestHarness {
@MainActor
@Suite("Resource usage AppKit cell")
struct ResourceUsageTableCellViewTests {
    @Test("configures unobstructed text tooltip and accessibility")
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
        #expect(cell.toolTip == "Resource: cpu")
        #expect(cell.subviews.count == 1)
        #expect(cell.subviews.first === cell.textField)
        #expect(cell.accessibilityLabel() == "CPU resource usage")
        #expect(cell.accessibilityValue() as? String ==
            "CPU, usage 420 millicores, request 500 millicores, limit 1 core")
    }

}
}
