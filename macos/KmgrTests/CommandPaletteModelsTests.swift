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

@Test func paletteRanksNamespacePrefixesWithoutDuplicates() {
    let values = PaletteRanking.namespaces(
        query: "namespace prod",
        namespaces: ["production", "product-catalog", "staging", "production"]
    )
    #expect(values == [.namespace("product-catalog"), .namespace("production")])
}

@Test func paletteDeduplicatesProgressiveObjectResultsByUID() {
    func result(_ name: String, uid: String, rank: Double) -> ObjectSearchResult {
        ObjectSearchResult(
            identity: ResourceIdentity(
                clusterSessionID: "session",
                group: "",
                version: "v1",
                resource: "pods",
                namespace: "apps",
                name: name,
                uid: ResourceUID(uid)
            ),
            displayText: name,
            detailText: "apps · Pod",
            rank: rank,
            stale: false
        )
    }
    let values = PaletteRanking.objects([
        result("api-old", uid: "same", rank: 500),
        result("api", uid: "same", rank: 1_000),
        result("worker", uid: "worker", rank: 700),
    ])
    #expect(values.map(\.title) == ["api", "worker"])
}
