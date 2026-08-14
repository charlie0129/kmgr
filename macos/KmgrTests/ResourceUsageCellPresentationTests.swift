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
        #expect(presentation.pressure == .warning)
        #expect(presentation.effectiveSeverity == .warning)
        #expect(presentation.accessibilityLabel == "CPU resource usage")
        #expect(presentation.accessibilityValue ==
            "Warning, CPU, usage 420 millicores, request 500 millicores, limit 1 core")
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
        #expect(presentation.pressure == .normal)
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
        #expect(presentation.pressure == .critical)
        #expect(presentation.effectiveSeverity == .critical)
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

    @Test("Pod pressure uses exact request and limit boundaries")
    func podPressureBoundaries() {
        #expect(pressure(usage: 79.999, request: 100) == .normal)
        #expect(pressure(usage: 80, request: 100) == .warning)
        #expect(pressure(usage: 500, request: 100) == .warning)

        #expect(pressure(usage: 79.999, limit: 100) == .normal)
        #expect(pressure(usage: 80, limit: 100) == .warning)
        #expect(pressure(usage: 89.999, limit: 100) == .warning)
        #expect(pressure(usage: 90, limit: 100) == .critical)
    }

    @Test("Node pressure uses only actual usage and positive allocatable capacity")
    func nodePressureBoundaries() {
        #expect(pressure(usage: 79.999, request: 1, capacity: 100) == .normal)
        #expect(pressure(usage: 80, request: 1, capacity: 100) == .warning)
        #expect(pressure(usage: 89.999, limit: 1, capacity: 100) == .warning)
        #expect(pressure(usage: 90, limit: 1, capacity: 100) == .critical)

        #expect(pressure(request: 99, capacity: 100) == .normal)
        #expect(pressure(limit: 99, capacity: 100) == .normal)
    }

    @Test("invalid pressure quantities are ignored")
    func invalidPressureQuantities() {
        #expect(pressure(usage: 0, request: 1, limit: 1) == .normal)
        #expect(pressure(usage: -1, request: 1, limit: 1) == .normal)
        #expect(pressure(usage: .nan, request: 1, limit: 1) == .normal)
        #expect(pressure(usage: .infinity, request: 1, limit: 1) == .normal)

        #expect(pressure(usage: 1, request: 0, limit: -1) == .normal)
        #expect(pressure(usage: 1, request: .nan, limit: .infinity) == .normal)
        #expect(pressure(usage: 1, capacity: 0) == .normal)
        #expect(pressure(usage: 1, capacity: -.infinity) == .normal)
    }

    @Test("pressure composes with existing cell severity and critical wins")
    func severityComposition() throws {
        let staleAndCritical = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "cpu",
            displayText: "95m / 100m",
            typedValue: .usage(ResourceUsageValue(
                usage: 0.095,
                limit: 0.1,
                unit: "cores",
                resourceName: "cpu"
            )),
            severity: .warning
        )))
        #expect(staleAndCritical.pressure == .critical)
        #expect(staleAndCritical.effectiveSeverity == .critical)
        #expect(staleAndCritical.accessibilityValue.hasPrefix("Critical, "))

        let backendCriticalAndWarning = try #require(ResourceUsageCellPresentation(cell: Cell(
            columnID: "memory",
            displayText: "80 / 100",
            typedValue: .usage(ResourceUsageValue(
                usage: 80,
                request: 100,
                unit: "bytes",
                resourceName: "memory"
            )),
            severity: .critical
        )))
        #expect(backendCriticalAndWarning.pressure == .warning)
        #expect(backendCriticalAndWarning.effectiveSeverity == .critical)

        let backendWarning = ResourceUsageCellPresentation(
            displayText: "10 / 100",
            value: ResourceUsageValue(
                usage: 10,
                request: 100,
                unit: "count"
            ),
            cellSeverity: .warning
        )
        #expect(backendWarning.pressure == .normal)
        #expect(backendWarning.effectiveSeverity == .warning)
        #expect(backendWarning.accessibilityValue.hasPrefix("Warning, "))
    }

    private func pressure(
        usage: Double? = nil,
        request: Double? = nil,
        limit: Double? = nil,
        capacity: Double? = nil
    ) -> ResourceUsageCellPresentation.Pressure {
        ResourceUsageCellPresentation(
            displayText: "typed values only",
            value: ResourceUsageValue(
                usage: usage,
                request: request,
                limit: limit,
                capacity: capacity,
                unit: "count"
            )
        ).pressure
    }
}
