import AppKit
import Testing
@testable import Kmgr
import KmgrCore

extension AppKitTestHarness {
@MainActor
@Suite("Resource usage AppKit cell")
struct ResourceUsageTableCellViewTests {
    @Test("configures compact text geometry tooltip and accessibility")
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
        #expect(cell.usageTrackView.presentation == presentation)
        #expect(cell.accessibilityLabel() == "CPU resource usage")
        #expect(cell.accessibilityValue() as? String ==
            "CPU, usage 420 millicores, request 500 millicores, limit 1 core")
    }

    @Test("marker shapes remain distinct without relying on color")
    func markerStyles() {
        #expect(ResourceUsageTrackView.markerStyle(for: .usage) == nil)
        #expect(ResourceUsageTrackView.markerStyle(for: .request) == .tick)
        #expect(ResourceUsageTrackView.markerStyle(for: .limit) == .doubleTick)
        #expect(ResourceUsageTrackView.markerStyle(for: .capacity) == .cappedTick)
    }
}
}
