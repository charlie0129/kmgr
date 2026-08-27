import Testing
@testable import KmgrCore

@Test func navigationHistoryRestoresPreciseResourceState() {
    let pods = ResourceNavigationState(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaceSelection: .namespace("team-a"),
        filter: "status:running",
        sortColumnID: "restarts",
        sortDescending: true,
        selectedUIDs: ["pod-uid"],
        scrollAnchor: ScrollAnchor(uid: "pod-uid", pixelOffsetFromTop: 7, priorRowIndex: 1_200)
    )
    let nodes = ResourceNavigationState(
        group: "", version: "v1", resource: "nodes", kind: "Node",
        namespaced: false,
        namespaceSelection: NamespaceSelection()
    )
    var history = WorkspaceNavigationHistory(initial: .resource(pods))
    history.navigate(to: .resource(nodes))
    #expect(history.canGoBack)
    #expect(history.goBack() == .resource(pods))
    #expect(history.canGoForward)
    #expect(history.goForward() == .resource(nodes))
}

@Test func navigationRetainsAuthoritativeResourceScope() {
    let nodes = ResourceNavigationState(
        group: "", version: "v1", resource: "nodes", kind: "Node",
        namespaced: false,
        namespaceSelection: NamespaceSelection()
    )
    let pods = ResourceNavigationState(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaced: true,
        namespaceSelection: .namespace("team-a")
    )

    #expect(nodes.namespaced == false)
    #expect(pods.namespaced)
}

@Test func resourceFiltersStartClearAndRestorePerExactGVR() {
    let pods = GVR(group: "", version: "v1", resource: "pods")
    let nodes = GVR(group: "", version: "v1", resource: "nodes")
    var memory = ResourceFilterMemory()

    #expect(memory.switchResource(from: nil, currentFilter: "", to: pods) == "")
    #expect(memory.switchResource(
        from: pods,
        currentFilter: "status:running",
        to: nodes
    ) == "")
    #expect(memory.switchResource(
        from: nodes,
        currentFilter: "name:worker",
        to: pods
    ) == "status:running")
    #expect(memory.filter(for: nodes) == "name:worker")
}

@Test func resourceFilterMemoryDoesNotMixSamePluralAcrossAPIGroupOrVersion() {
    let stable = GVR(group: "example.io", version: "v1", resource: "widgets")
    let beta = GVR(group: "example.io", version: "v1beta1", resource: "widgets")
    let otherGroup = GVR(group: "other.io", version: "v1", resource: "widgets")
    var memory = ResourceFilterMemory()
    memory.remember("status:ready", for: stable)

    #expect(memory.filter(for: stable) == "status:ready")
    #expect(memory.filter(for: beta) == "")
    #expect(memory.filter(for: otherGroup) == "")
}

@Test func navigatingAfterBackDropsOnlyForwardBranch() {
    func state(_ resource: String) -> WorkspaceDestination {
        .resource(ResourceNavigationState(
            group: "", version: "v1", resource: resource, kind: resource,
            namespaceSelection: NamespaceSelection()
        ))
    }
    var history = WorkspaceNavigationHistory(initial: state("pods"))
    history.navigate(to: state("nodes"))
    history.navigate(to: state("services"))
    _ = history.goBack()
    history.navigate(to: state("events"))
    #expect(!history.canGoForward)
    #expect(history.entries == [state("pods"), state("nodes"), state("events")])
}

@Test func helperRecoveryRebindsEveryUIDPinnedHistoryEntryToTheNewSession() {
    let table = ResourceNavigationState(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaceSelection: .namespace("team-a")
    )
    var first = identity("pod-1")
    var second = identity("pod-2")
    first.clusterSessionID = "old-session"
    second.clusterSessionID = "old-session"
    var history = WorkspaceNavigationHistory(initial: .resource(table))
    history.navigate(to: .subresource(second, returnState: table))

    history.rebindClusterSessionID("new-session")

    let subresourceSessions = history.entries.compactMap { destination -> String? in
        switch destination {
        case .subresource(let identity, _):
            identity.clusterSessionID
        case .resource:
            nil
        }
    }
    #expect(subresourceSessions == ["new-session"])
    #expect(history.current == .subresource(
        ResourceIdentity(
            clusterSessionID: "new-session", group: second.group,
            version: second.version, resource: second.resource,
            namespace: second.namespace, name: second.name, uid: second.uid
        ),
        returnState: table
    ))
}

@Test func sidebarPinsAreStableGVRsNotDisplayNames() {
    #expect(DefaultSidebarPins.values.count == 9)
    #expect(DefaultSidebarPins.values.map(\.id).contains("apps/v1/deployments"))
    #expect(Set(DefaultSidebarPins.values.map(\.id)).count == DefaultSidebarPins.values.count)
}
