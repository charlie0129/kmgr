import Testing
@testable import KmgrCore

@Test func restoredWorkspaceShellContainsOnlyPresentationTarget() {
    let record = ClusterWindowRestorationRecord(
        id: "saved-window",
        state: ClusterWindowRestorationState(
            contextName: "production",
            contextReference: "/configs/production.yaml#production-admin",
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceScope: .namespace("payments"),
            filter: "name:api"
        )
    )

    let shell = RestoredWorkspaceShell(record: record)

    #expect(shell.session.sessionID == "restoring-saved-window")
    #expect(shell.session.contextName == "production")
    #expect(shell.session.contextReference == "/configs/production.yaml#production-admin")
    #expect(shell.session.defaultNamespace == "payments")
    #expect(shell.targetResource == DiscoveredResource(
        group: "apps",
        version: "v1",
        resource: "deployments",
        kind: "Deployment",
        namespaced: true
    ))
    #expect(shell.targetResource?.verbs.isEmpty == true)
}

@Test func restoredWorkspaceShellKeepsUnknownExactGVRAndClusterScope() {
    let custom = RestoredWorkspaceShell(record: ClusterWindowRestorationRecord(
        id: "custom",
        state: ClusterWindowRestorationState(
            contextName: "custom",
            gvr: GVR(group: "example.io", version: "v1alpha1", resource: "widgets")
        )
    ))
    #expect(custom.targetResource?.id == "example.io/v1alpha1/widgets")
    #expect(custom.targetResource?.kind == "widgets")

    let nodes = RestoredWorkspaceShell(record: ClusterWindowRestorationRecord(
        id: "nodes",
        state: ClusterWindowRestorationState(
            contextName: "cluster",
            gvr: GVR(group: "", version: "v1", resource: "nodes")
        )
    ))
    #expect(nodes.targetResource?.kind == "Node")
    #expect(nodes.targetResource?.namespaced == false)
}
