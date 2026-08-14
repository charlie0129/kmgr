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

@Test func paletteKindQueryIncludesRecentObjectsWhoseNamesDoNotMatchKind() {
    let pods = DiscoveredResource(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaced: true, shortNames: ["po"]
    )
    let deployments = DiscoveredResource(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment",
        namespaced: true
    )
    let matches = PaletteRanking.matchingResources(
        query: "pods",
        resources: [deployments, pods]
    )
    let recent = PaletteRanking.recentObjects(
        query: "pods",
        values: [
            RecentObject(identity: paletteIdentity("api", uid: "pod-api"), openedAt: Date()),
            RecentObject(identity: {
                var value = paletteIdentity("worker", uid: "deployment-worker")
                value.group = "apps"
                value.resource = "deployments"
                return value
            }(), openedAt: Date()),
        ],
        matchingResources: matches
    )

    #expect(matches == [pods])
    #expect(recent.count == 1)
    guard case .object(let result) = recent.first else {
        Issue.record("Expected a recent Pod result")
        return
    }
    #expect(result.identity.name == "api")
    #expect(result.identity.resource == "pods")
    #expect(result.rank == 600.5)
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

@Test func paletteOperationsUseOnlyCapturedResponderAndSelection() {
    let captured = CommandContext.capturingResourceSelection(
        firstResponder: .resourceTable,
        selectedIdentities: [paletteIdentity("api", uid: "uid-api")]
    )
    let valid = PaletteOperationRanking.operations(query: "", context: captured)

    #expect(valid.contains(.openDetails))
    #expect(valid.contains(.openYAML))
    #expect(valid.contains(.openEvents))
    #expect(valid.contains(.openLogs))
    #expect(valid.contains(.openExec))
    #expect(PaletteOperation.openExec.title == "Open Terminal")
    #expect(valid.contains(.startPortForward))
    #expect(valid.contains(.delete))
    #expect(valid.contains(.copyReference))
    #expect(valid.contains(.scale) == false)
    #expect(valid.contains(.restart) == false)

    let typing = CommandContext.capturingResourceSelection(
        firstResponder: .filterField,
        selectedIdentities: captured.selectedIdentities
    )
    #expect(PaletteOperationRanking.operations(query: "", context: typing).isEmpty)
}

@Test func paletteOperationRankingFiltersAndRanksOnlyValidCommands() {
    var deployment = paletteIdentity("api", uid: "uid-deployment")
    deployment.group = "apps"
    deployment.resource = "deployments"
    let context = CommandContext.capturingResourceSelection(
        firstResponder: .resourceTable,
        selectedIdentities: [deployment]
    )

    #expect(PaletteOperationRanking.operations(query: "restart", context: context) == [.restart])
    #expect(PaletteOperationRanking.operations(query: "replicas", context: context) == [.scale])
    #expect(PaletteOperationRanking.operations(query: "terminal", context: context).isEmpty)
}

@Test func capturedCommandContextDerivesCompatibilityFromFullIdentities() {
    let first = paletteIdentity("api", uid: "uid-api")
    let second = paletteIdentity("worker", uid: "uid-worker")
    let context = CommandContext.capturingResourceSelection(
        firstResponder: .resourceTable,
        selectedIdentities: [first, second],
        hiddenSelectionUIDs: [first.uid, "not-selected"]
    )

    #expect(context.selectedIdentities == [first, second])
    #expect(context.hiddenSelectionUIDs == [first.uid])
    #expect(context.logCompatibleSelection)
    #expect(context.execCompatibleSelection == false)
    #expect(context.portForwardCompatibleSelection == false)
}

@Test func disconnectedSnapshotSuppressesNetworkOperationsButKeepsCopies() {
    let context = CommandContext.capturingResourceSelection(
        firstResponder: .resourceTable,
        selectedIdentities: [paletteIdentity("api", uid: "uid-api")],
        networkActionsAllowed: false
    )
    let valid = PaletteOperationRanking.operations(query: "", context: context)

    #expect(valid == [.copyName, .copyNamespacedName, .copyReference])
}

@Test func resourceListResponderClassificationHonorsFieldEditorsAndDescendants() {
    #expect(ResourceListResponderClassifier.classify(
        tableOwnsResponder: true,
        filterOwnsResponder: false,
        tableHasActiveEditor: false
    ) == .resourceTable)
    #expect(ResourceListResponderClassifier.classify(
        tableOwnsResponder: true,
        filterOwnsResponder: false,
        tableHasActiveEditor: true
    ) == .other)
    #expect(ResourceListResponderClassifier.classify(
        tableOwnsResponder: false,
        filterOwnsResponder: true,
        tableHasActiveEditor: false
    ) == .filterField)
    #expect(ResourceListResponderClassifier.classify(
        tableOwnsResponder: true,
        filterOwnsResponder: true,
        tableHasActiveEditor: false
    ) == .filterField)
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
