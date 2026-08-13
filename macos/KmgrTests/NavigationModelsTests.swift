import Testing
@testable import KmgrCore

@Test func navigationHistoryRestoresPreciseResourceState() {
    let pods = ResourceNavigationState(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaceSelection: .namespace("team-a"),
        filter: "status:running",
        sortColumnID: "restarts",
        sortDescending: true,
        columns: [
            ColumnPresentationState(columnID: "name", width: 310),
            ColumnPresentationState(columnID: "restarts", width: 88, isVisible: false),
        ],
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

@Test func objectHistoryReturnsToExactTablePresentation() {
    let table = ResourceNavigationState(
        group: "", version: "v1", resource: "pods", kind: "Pod",
        namespaceSelection: .namespace("team-a"), filter: "name:api",
        sortColumnID: "restarts", sortDescending: true,
        columns: [
            ColumnPresentationState(columnID: "name", width: 333),
            ColumnPresentationState(columnID: "status", width: 120, isVisible: false),
        ],
        selectedUIDs: ["pod-uid"],
        scrollAnchor: ScrollAnchor(uid: "pod-uid", pixelOffsetFromTop: 4, priorRowIndex: 50)
    )
    let identity = ResourceIdentity(
        clusterSessionID: "session", group: "", version: "v1",
        resource: "pods", namespace: "team-a", name: "api", uid: "pod-uid"
    )
    var history = WorkspaceNavigationHistory(initial: .resource(table))
    history.navigate(to: .object(identity, returnState: table))

    #expect(history.goBack() == .resource(table))
    #expect(history.goForward() == .object(identity, returnState: table))
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

@Test func sidebarPinsAreStableGVRsNotDisplayNames() {
    #expect(DefaultSidebarPins.values.count == 9)
    #expect(DefaultSidebarPins.values.map(\.id).contains("apps/v1/deployments"))
    #expect(Set(DefaultSidebarPins.values.map(\.id)).count == DefaultSidebarPins.values.count)
}
