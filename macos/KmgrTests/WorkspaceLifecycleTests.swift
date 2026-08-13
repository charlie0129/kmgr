import Testing
@testable import KmgrCore

@Test func closingWindowCancelsViewAndCancellableWorkButNotAppForwards() {
    var lifecycle = WorkspaceLifecycleModel(
        activeView: ActiveViewDescriptor(clusterSessionID: "session", viewID: "pods-view"),
        cancellableWorkIDs: ["projection", "details-fetch"],
        pendingMutations: ["delete-request"],
        activeExecSessions: ["shell"],
        activePortForwards: ["forward-1"]
    )

    let effects = lifecycle.windowWillClose()

    #expect(effects == [
        .cancelView(viewID: "pods-view"),
        .cancelAllCancellableWork,
    ])
    #expect(lifecycle.connectivity == .closed)
    #expect(lifecycle.activeView == nil)
    #expect(lifecycle.cancellableWorkIDs.isEmpty)
    #expect(lifecycle.pendingMutations.isEmpty)
    #expect(lifecycle.activeExecSessions.isEmpty)
    #expect(lifecycle.activePortForwards == ["forward-1"])
    #expect(lifecycle.windowWillClose().isEmpty)
}

@Test func helperRestartReopensOnlySafeActiveView() {
    let view = ActiveViewDescriptor(clusterSessionID: "session", viewID: "nodes-view")
    var lifecycle = WorkspaceLifecycleModel(
        activeView: view,
        cancellableWorkIDs: ["list-stream"],
        pendingMutations: ["scale"],
        activeExecSessions: ["exec"],
        activePortForwards: ["forward"]
    )

    lifecycle.helperDidExitUnexpectedly()
    #expect(lifecycle.connectivity == .helperDisconnected)
    #expect(lifecycle.cancellableWorkIDs.isEmpty)
    #expect(lifecycle.pendingMutations.isEmpty)
    #expect(lifecycle.activeExecSessions.isEmpty)
    #expect(lifecycle.activePortForwards.isEmpty)

    let effects = lifecycle.helperDidRestart()
    #expect(effects == [.reopenView(view)])
    #expect(lifecycle.connectivity == .reopeningViews)

    lifecycle.reopenedViewDidConnect()
    #expect(lifecycle.connectivity == .connected)
}

@Test func closedWindowIgnoresHelperLifecycle() {
    var lifecycle = WorkspaceLifecycleModel(activeView: ActiveViewDescriptor(
        clusterSessionID: "session",
        viewID: "pods"
    ))
    _ = lifecycle.windowWillClose()

    lifecycle.helperDidExitUnexpectedly()
    #expect(lifecycle.helperDidRestart().isEmpty)
    #expect(lifecycle.connectivity == .closed)
}
