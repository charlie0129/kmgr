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
        namespaceSelection: NamespaceSelection()
    )
    var history = WorkspaceNavigationHistory(initial: .resource(pods))
    history.navigate(to: .resource(nodes))
    #expect(history.canGoBack)
    #expect(history.goBack() == .resource(pods))
    #expect(history.canGoForward)
    #expect(history.goForward() == .resource(nodes))
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
