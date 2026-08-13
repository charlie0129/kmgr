import Foundation
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

@Test func palettePreservesSameUIDAcrossDifferentGVRs() {
    let pod = ObjectSearchResult(
        identity: paletteIdentity("api", uid: "shared"),
        displayText: "api",
        detailText: "team · Pod",
        rank: 1_000,
        stale: true
    )
    var widgetIdentity = pod.identity
    widgetIdentity.group = "example.io"
    widgetIdentity.resource = "widgets"
    let widget = ObjectSearchResult(
        identity: widgetIdentity,
        displayText: "api",
        detailText: "team · widgets",
        rank: 999,
        stale: true
    )

    let values = PaletteRanking.objects([pod, widget])
    #expect(values.count == 2)
    #expect(Set(values.compactMap { result -> String? in
        guard case .object(let value) = result else { return nil }
        return "\(value.identity.group)/\(value.identity.resource)"
    }) == ["/pods", "example.io/widgets"])
}

@Test func recentObjectStoreEvictsAndMovesReopenedIdentityToFront() async {
    let store = RecentObjectStore(maximumPerSession: 2)
    await store.record(paletteIdentity("one", uid: "one"), openedAt: Date(timeIntervalSince1970: 1))
    await store.record(paletteIdentity("two", uid: "two"), openedAt: Date(timeIntervalSince1970: 2))
    await store.record(paletteIdentity("three", uid: "three"), openedAt: Date(timeIntervalSince1970: 3))
    #expect(await store.recent(sessionID: "session").map(\.identity.name) == ["three", "two"])

    await store.record(paletteIdentity("two", uid: "two"), openedAt: Date(timeIntervalSince1970: 4))
    #expect(await store.recent(sessionID: "session").map(\.identity.name) == ["two", "three"])
}

@Test func recentObjectStoreIsolatesSessionsAndPreservesFullIdentity() async {
    let store = RecentObjectStore(maximumPerSession: 4)
    var other = paletteIdentity("api", uid: "shared")
    other.clusterSessionID = "other-session"
    other.group = "example.io"
    other.resource = "widgets"
    await store.record(paletteIdentity("api", uid: "shared"))
    await store.record(other)

    let first = await store.recent(sessionID: "session")
    let second = await store.recent(sessionID: "other-session")
    #expect(first.count == 1)
    #expect(first[0].identity.group == "")
    #expect(first[0].identity.resource == "pods")
    #expect(second.count == 1)
    #expect(second[0].identity.group == "example.io")
    #expect(second[0].identity.uid == "shared")
}

@Test func recentObjectStoreRebindsHelperSessionWithoutChangingUID() async {
    let store = RecentObjectStore(maximumPerSession: 4)
    await store.record(paletteIdentity("api", uid: "uid-api"))
    await store.rebind(from: "session", to: "recovered")
    #expect(await store.recent(sessionID: "session").isEmpty)
    let rebound = await store.recent(sessionID: "recovered")
    #expect(rebound.first?.identity.clusterSessionID == "recovered")
    #expect(rebound.first?.identity.uid == "uid-api")
}

@Test func paletteMergesRecentAndCachedByFullGVRUIDPreferringRecentLabel() {
    let identity = paletteIdentity("api", uid: "uid-api")
    let recent = PaletteRanking.recentObjects(
        query: "api",
        values: [RecentObject(identity: identity, openedAt: Date())]
    )
    let cached = ObjectSearchResult(
        identity: identity,
        displayText: "api",
        detailText: "team · Pod",
        rank: 1_000,
        stale: true
    )
    let merged = PaletteRanking.mergingObjects(recent: recent, cached: [cached])
    #expect(merged.count == 1)
    guard case .object(let value) = merged.first else {
        Issue.record("Expected merged object")
        return
    }
    #expect(value.detailText.contains("Recent"))
    #expect(value.origin == .recent)
    #expect(value.identity == identity)
}

private func paletteIdentity(_ name: String, uid: String) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "",
        version: "v1",
        resource: "pods",
        namespace: "team",
        name: name,
        uid: ResourceUID(uid)
    )
}
