import Testing
@testable import Kmgr
import KmgrCore

@Suite("Optional resource AppKit overlay lifetime")
struct OptionalResourceOverlayLifetimeStateTests {
    @Test("same-GVR generation rollover retains overlay and rejects old completion")
    func sameGVRGenerationRollover() throws {
        let transient = ColumnDefinition(
            id: "resource:nvidia.com/gpu",
            title: "GPU",
            source: .metric,
            value: "resource:nvidia.com/gpu",
            type: .resourceUsage
        )
        var lifetime = OptionalResourceOverlayLifetimeState()
        lifetime.install(
            OptionalResourceColumnOverlay(definitions: [transient]),
            sessionID: "session-one",
            gvr: Self.podsGVR
        )

        var gate = OptionalResourceCatalogDiscoveryGate()
        gate.select(Self.target(generation: 1))
        gate.markBaseViewUsable()
        let startedOld = gate.beginDiscovery()
        let oldTicket = try #require(startedOld)

        let clearedForSameScope = lifetime.clearIfScopeChanged(
            sessionID: "session-one",
            gvr: Self.podsGVR
        )
        #expect(!clearedForSameScope)
        gate.select(Self.target(generation: 2))
        gate.markBaseViewUsable()
        let startedCurrent = gate.beginDiscovery()
        let currentTicket = try #require(startedCurrent)

        #expect(lifetime.applies(sessionID: "session-one", gvr: Self.podsGVR))
        #expect(lifetime.overlay.definitions == [transient])
        let oldApplied = gate.finishSuccess(oldTicket)
        let currentApplied = gate.finishSuccess(currentTicket)
        #expect(!oldApplied)
        #expect(currentApplied)
    }

    @Test("session or GVR change clears the installed overlay")
    func scopeChangeClearsOverlay() {
        let transient = ColumnDefinition(
            id: "resource:hugepages-2Mi",
            title: "Huge Pages (2Mi)",
            source: .metric,
            value: "resource:hugepages-2Mi",
            type: .resourceUsage
        )
        var lifetime = OptionalResourceOverlayLifetimeState()
        let overlay = OptionalResourceColumnOverlay(definitions: [transient])
        lifetime.install(overlay, sessionID: "session-one", gvr: Self.podsGVR)

        let clearedForSession = lifetime.clearIfScopeChanged(
            sessionID: "session-two",
            gvr: Self.podsGVR
        )
        #expect(clearedForSession)
        #expect(lifetime.overlay.definitions.isEmpty)

        lifetime.install(overlay, sessionID: "session-two", gvr: Self.podsGVR)
        let clearedForGVR = lifetime.clearIfScopeChanged(
            sessionID: "session-two",
            gvr: Self.nodesGVR
        )
        #expect(clearedForGVR)
        #expect(lifetime.overlay.definitions.isEmpty)
    }

    private static func target(
        generation: UInt64
    ) -> OptionalResourceCatalogDiscoveryTarget {
        OptionalResourceCatalogDiscoveryTarget(
            sessionID: "session-one",
            applicableResource: pods,
            viewGeneration: generation
        )
    }

    private static let pods = DiscoveredResource(
        group: "",
        version: "v1",
        resource: "pods",
        kind: "Pod",
        namespaced: true
    )
    private static let podsGVR = GVR(group: "", version: "v1", resource: "pods")
    private static let nodesGVR = GVR(group: "", version: "v1", resource: "nodes")
}
