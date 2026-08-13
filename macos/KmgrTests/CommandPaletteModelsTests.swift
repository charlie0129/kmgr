import Testing
@testable import KmgrCore

@Test func paletteRanksExactKindThenOffersScopedSearch() {
    let pods = DiscoveredResource(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaced: true, shortNames: ["po"]
    )
    let policies = DiscoveredResource(
        group: "policy", version: "v1", resource: "poddisruptionbudgets",
        kind: "PodDisruptionBudget", namespaced: true
    )
    let values = PaletteRanking.resources(query: "pods", resources: [policies, pods])
    #expect(values.first == .resource(pods))
    #expect(values.dropFirst().first == .searchResource(pods))
}

@Test func paletteRecognizesShortName() {
    let pods = DiscoveredResource(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaced: true, shortNames: ["po"]
    )
    #expect(PaletteRanking.resources(query: "po", resources: [pods]).first == .resource(pods))
}
