import Testing
@testable import KmgrCore

@Suite("Resource usage cell presentation")
struct ResourceUsageCellPresentationTests {
    @Test("usage columns expose compact geometry and spoken quantities")
    func usagePresentation() throws {
        let presentation = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "cpu",
            displayText: "420m / 500m / 1",
            typedValue: .usage(ResourceUsageValue(
                usage: 0.42,
                request: 0.5,
                limit: 1,
                unit: "cores",
                resourceName: "cpu"
            ))
        )))

        #expect(presentation.text == "420m / 500m / 1")
        #expect(presentation.primaryComponent == .usage)
        #expect(presentation.fillRatio == 0.42)
        #expect(presentation.markers == [
            .init(component: .request, ratio: 0.5),
            .init(component: .limit, ratio: 1),
        ])
        #expect(presentation.accessibilityLabel == "CPU resource usage")
        #expect(presentation.accessibilityValue ==
            "CPU, usage 420 millicores, request 500 millicores, limit 1 core")
        #expect(!presentation.hasOverflow)
    }

    @Test("allocation-only columns prefer request and describe binary units")
    func allocationPresentation() throws {
        let presentation = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "memory-requests",
            displayText: "1.5Gi / 2Gi",
            typedValue: .usage(ResourceUsageValue(
                request: 1.5 * 1_073_741_824,
                capacity: 2 * 1_073_741_824,
                unit: "bytes",
                resourceName: "memory"
            ))
        )))

        #expect(presentation.primaryComponent == .request)
        #expect(presentation.fillRatio == 0.75)
        #expect(presentation.markers == [
            .init(component: .request, ratio: 0.75),
            .init(component: .capacity, ratio: 1),
        ])
        #expect(presentation.accessibilityLabel == "Memory resource allocation")
        #expect(presentation.accessibilityValue ==
            "Memory, request 1.5 gibibytes, capacity 2 gibibytes")
    }

    @Test("overflow remains explicit and is never clamped")
    func overflowPresentation() throws {
        let presentation = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "cpu",
            displayText: "1.5 / 1 / 2",
            typedValue: .usage(ResourceUsageValue(
                usage: 3,
                request: 2,
                limit: 1,
                unit: "cores",
                resourceName: "cpu"
            ))
        )))

        #expect(presentation.fillRatio == 1.5)
        #expect(presentation.markers == [
            .init(component: .request, ratio: 1),
            .init(component: .limit, ratio: 0.5),
        ])
        #expect(presentation.hasOverflow)
    }

    @Test("explicit zero and absent values remain different")
    func zeroAndAbsence() throws {
        let zero = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "gpu",
            displayText: "0 / 0",
            typedValue: .usage(ResourceUsageValue(
                request: 0,
                capacity: 0,
                unit: "count",
                resourceName: "nvidia.com/gpu"
            ))
        )))
        #expect(zero.fillRatio == 0)
        #expect(zero.markers == [
            .init(component: .request, ratio: 0),
            .init(component: .capacity, ratio: 0),
        ])
        #expect(zero.accessibilityValue ==
            "nvidia.com/gpu, request 0 units, capacity 0 units")

        let absent = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "gpu",
            displayText: "—",
            typedValue: .usage(ResourceUsageValue(
                unit: "count",
                resourceName: "nvidia.com/gpu"
            ))
        )))
        #expect(absent.fillRatio == nil)
        #expect(absent.markers.isEmpty)
        #expect(absent.accessibilityValue == "nvidia.com/gpu, values unavailable")
    }

    @Test("non-usage cells safely use their existing renderer")
    func nonUsageFallback() {
        #expect(ResourceUsageCellPresentation(cell: Cell(
            columnID: "name",
            displayText: "api-0",
            typedValue: .string("api-0")
        )) == nil)
        #expect(ResourceUsageCellPresentation(cell: Cell(
            columnID: "missing",
            displayText: "—"
        )) == nil)
    }
}
