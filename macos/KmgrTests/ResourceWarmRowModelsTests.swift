import Foundation
import Testing
@testable import KmgrCore

@Test func warmRowsHaveNoSizeBasedEvictionAndRequireExactContext() {
    let pods = ResourceWarmRowContext(
        sessionID: "session-a",
        gvr: GVR(group: "", version: "v1", resource: "pods"),
        namespaceSelection: NamespaceSelection()
    )

    #expect(ResourceWarmRowPolicy.canRetain(
        existingRowCount: 993,
        previousContext: pods,
        nextContext: pods
    ))
    #expect(ResourceWarmRowPolicy.canRetain(
        existingRowCount: 1_000_000,
        previousContext: pods,
        nextContext: pods
    ))
    #expect(!ResourceWarmRowPolicy.canRetain(
        existingRowCount: 0,
        previousContext: pods,
        nextContext: pods
    ))

    for differentContext in [
        ResourceWarmRowContext(
            sessionID: "session-b",
            gvr: pods.gvr,
            namespaceSelection: pods.namespaceSelection
        ),
        ResourceWarmRowContext(
            sessionID: pods.sessionID,
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceSelection: pods.namespaceSelection
        ),
        ResourceWarmRowContext(
            sessionID: pods.sessionID,
            gvr: pods.gvr,
            namespaceSelection: .namespace("payments")
        ),
    ] {
        #expect(!ResourceWarmRowPolicy.canRetain(
            existingRowCount: 993,
            previousContext: pods,
            nextContext: differentContext
        ))
    }
}

@Test func warmRowDecisionReportsEveryRetentionInput() {
    let pods = ResourceWarmRowContext(
        sessionID: "session-a",
        gvr: GVR(group: "", version: "v1", resource: "pods"),
        namespaceSelection: NamespaceSelection()
    )

    let accepted = ResourceWarmRowPolicy.decision(
        existingRowCount: 42,
        previousContext: pods,
        nextContext: pods
    )
    #expect(accepted.canRetain)
    #expect(accepted.hasExistingRows)
    #expect(accepted.hasPreviousContext)
    #expect(accepted.sameSession)
    #expect(accepted.sameResource)
    #expect(accepted.sameNamespaceSelection)

    let rejected = ResourceWarmRowPolicy.decision(
        existingRowCount: 0,
        previousContext: ResourceWarmRowContext(
            sessionID: "session-before-restart",
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceSelection: .namespace("payments")
        ),
        nextContext: pods
    )
    #expect(!rejected.canRetain)
    #expect(!rejected.hasExistingRows)
    #expect(rejected.hasPreviousContext)
    #expect(!rejected.sameSession)
    #expect(!rejected.sameResource)
    #expect(!rejected.sameNamespaceSelection)

    let firstOpen = ResourceWarmRowPolicy.decision(
        existingRowCount: 42,
        previousContext: nil,
        nextContext: pods
    )
    #expect(!firstOpen.canRetain)
    #expect(!firstOpen.hasPreviousContext)
}

@Test func onlyLoadingColdEmptySnapshotPreservesRetainedRows() {
    let empty = ResourceSnapshotChunk(
        rows: [],
        first: true,
        last: true,
        index: 0,
        estimatedTotalRows: 0
    )
    let loading = ResourceViewStatus(freshness: .loading)

    #expect(ResourceWarmRowPolicy.preservesRetainedRows(
        for: empty,
        backendStatus: loading,
        isRetainingWarmRows: true,
        isFirstSnapshotInStream: true
    ))
    #expect(!ResourceWarmRowPolicy.preservesRetainedRows(
        for: empty,
        backendStatus: ResourceViewStatus(freshness: .watching),
        isRetainingWarmRows: true,
        isFirstSnapshotInStream: true
    ))
    #expect(!ResourceWarmRowPolicy.preservesRetainedRows(
        for: ResourceSnapshotChunk(
            rows: [warmRow()],
            first: true,
            last: true,
            index: 0,
            estimatedTotalRows: 1
        ),
        backendStatus: loading,
        isRetainingWarmRows: true,
        isFirstSnapshotInStream: true
    ))
    #expect(!ResourceWarmRowPolicy.preservesRetainedRows(
        for: empty,
        backendStatus: loading,
        isRetainingWarmRows: false,
        isFirstSnapshotInStream: true
    ))
    #expect(!ResourceWarmRowPolicy.preservesRetainedRows(
        for: empty,
        backendStatus: loading,
        isRetainingWarmRows: true,
        isFirstSnapshotInStream: false
    ))
}

@Test func retainedRowsPresentAsResumingUntilSnapshotReconciliation() {
    let synchronizedAt = Date(timeIntervalSince1970: 1_000)
    let result = ResourceWarmRowPolicy.refreshingStatus(
        backendStatus: ResourceViewStatus(
            freshness: .watching,
            rowsVisible: 0
        ),
        retainedRowCount: 993,
        lastSynchronizedAt: synchronizedAt
    )

    #expect(result.freshness == .resuming)
    #expect(result.rowsVisible == 993)
    #expect(result.lastSynchronizedAt == synchronizedAt)
    #expect(result.fromWarmCache)
    #expect(result.showsProgress)

    #expect(ResourceWarmRowPolicy.statusConfirmsAuthoritativeReconciliation(
        ResourceViewStatus(freshness: .watching)
    ))
    #expect(ResourceWarmRowPolicy.statusConfirmsAuthoritativeReconciliation(
        ResourceViewStatus(freshness: .complete)
    ))
    #expect(!ResourceWarmRowPolicy.statusConfirmsAuthoritativeReconciliation(
        ResourceViewStatus(freshness: .loading)
    ))
}

private func warmRow() -> ResourceRow {
    ResourceRow(
        identity: ResourceIdentity(
            clusterSessionID: "session-a",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "default",
            name: "api",
            uid: "pod-api"
        ),
        cells: [Cell(columnID: "name", displayText: "api")]
    )
}
