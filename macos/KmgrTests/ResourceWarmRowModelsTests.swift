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

@Test func stagedReconciliationKeepsRenderedRowsThroughRepeatedEmptyAndPartialPayloads() {
    let oldRows = (0..<4).map { warmRow(index: $0, revision: "old") }
    let replacementRows = (0..<4).map { warmRow(index: $0, revision: "new") }
    var rendered = ResourceTableModel(rows: oldRows)
    var staged = ResourceStagedReconciliation()
    let empty = ResourceSnapshotChunk(
        rows: [],
        first: true,
        last: true,
        index: 0,
        estimatedTotalRows: 0
    )

    staged.receive(empty)
    staged.receive(empty)
    #expect(staged.visibleRowCount == 0)
    #expect(rendered.orderedVisibleUIDs.count == 4)

    staged.receive(ResourceRowDelta(
        upserts: Array(replacementRows.prefix(2)),
        orderedUIDs: replacementRows.prefix(2).map(\.identity.uid),
        orderIsComplete: true
    ))
    #expect(staged.visibleRowCount == 2)
    #expect(rendered.orderedVisibleUIDs.count == 4)
    #expect(rendered.rowByUID["pod-0"]?["name"]?.displayText == "old-0")

    staged.receive(ResourceRowDelta(
        upserts: Array(replacementRows.suffix(2)),
        orderedUIDs: replacementRows.map(\.identity.uid),
        orderIsComplete: true
    ))
    let reconciliation = ResourceViewReconciliation(rowsVisible: 4)
    #expect(staged.matches(reconciliation))
    rendered.apply(staged.promotionBatch)
    #expect(rendered.orderedVisibleUIDs.count == 4)
    #expect(rendered.rowByUID["pod-0"]?["name"]?.displayText == "new-0")
}

@Test func authoritativeEmptyReconciliationClearsRetainedRowsAndSelection() {
    let oldRows = (0..<2).map { warmRow(index: $0, revision: "old") }
    var rendered = ResourceTableModel(
        rows: oldRows,
        selectedUIDs: ["pod-0"],
        selectionAnchorUID: "pod-0"
    )
    var staged = ResourceStagedReconciliation()
    staged.receive(ResourceSnapshotChunk(
        rows: [],
        first: true,
        last: true,
        index: 0,
        estimatedTotalRows: 0
    ))
    staged.receive(ResourceRowDelta(
        removedUIDs: Set(oldRows.map(\.identity.uid)),
        orderedUIDs: [],
        orderIsComplete: true
    ))

    #expect(staged.matches(ResourceViewReconciliation(rowsVisible: 0)))
    #expect(rendered.orderedVisibleUIDs.count == 2)
    rendered.apply(staged.promotionBatch)
    #expect(rendered.orderedVisibleUIDs.isEmpty)
    #expect(rendered.rowByUID.isEmpty)
    #expect(rendered.selectedUIDs.isEmpty)
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

}

private func warmRow(index: Int = 0, revision: String = "old") -> ResourceRow {
    ResourceRow(
        identity: ResourceIdentity(
            clusterSessionID: "session-a",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "default",
            name: "pod-\(index)",
            uid: ResourceUID("pod-\(index)")
        ),
        cells: [Cell(columnID: "name", displayText: "\(revision)-\(index)")]
    )
}
