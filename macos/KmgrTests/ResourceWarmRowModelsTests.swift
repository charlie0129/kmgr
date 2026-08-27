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
        previousFreshness: .watching,
        nextContext: pods
    ))
    #expect(ResourceWarmRowPolicy.canRetain(
        existingRowCount: 1_000_000,
        previousContext: pods,
        previousFreshness: .complete,
        nextContext: pods
    ))
    #expect(!ResourceWarmRowPolicy.canRetain(
        existingRowCount: 0,
        previousContext: pods,
        previousFreshness: .watching,
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
            previousFreshness: .watching,
            nextContext: differentContext
        ))
    }
}

@Test func warmRowsRequireAPreviouslySynchronizedView() {
    let pods = ResourceWarmRowContext(
        sessionID: "session-a",
        gvr: GVR(group: "", version: "v1", resource: "pods"),
        namespaceSelection: NamespaceSelection()
    )

    for freshness in [
        ResourceViewStatus.Freshness.watching,
        .complete,
    ] {
        #expect(ResourceWarmRowPolicy.canRetain(
            existingRowCount: 50_000,
            previousContext: pods,
            previousFreshness: freshness,
            nextContext: pods
        ))
    }
    for freshness in [
        ResourceViewStatus.Freshness.loading,
        .stale,
        .resuming,
        .relisting,
        .reconnecting,
        .failed,
    ] {
        #expect(!ResourceWarmRowPolicy.canRetain(
            existingRowCount: 50_000,
            previousContext: pods,
            previousFreshness: freshness,
            nextContext: pods
        ))
    }
    #expect(!ResourceWarmRowPolicy.canRetain(
        existingRowCount: 50_000,
        previousContext: pods,
        previousFreshness: nil,
        nextContext: pods
    ))
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
        previousFreshness: .watching,
        nextContext: pods
    )
    #expect(accepted.canRetain)
    #expect(accepted.hasExistingRows)
    #expect(accepted.previousRowsWereSynchronized)
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
        previousFreshness: .watching,
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
        previousFreshness: .watching,
        nextContext: pods
    )
    #expect(!firstOpen.canRetain)
    #expect(!firstOpen.hasPreviousContext)
}

@Test func retainedRowsPresentAsResumingUntilRangeReconciliation() {
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

@Test func metricRefinementCanPromoteTheFirstUsableRange() {
    #expect(ResourceWarmRowPolicy.shouldPromoteProvisionalMetricRange(
        isRetainingWarmRows: true,
        hasReachedInitialReconciliation: false,
        backendStatus: ResourceViewStatus(
            freshness: .watching,
            metricsReconciling: true
        )
    ))
    #expect(!ResourceWarmRowPolicy.shouldPromoteProvisionalMetricRange(
        isRetainingWarmRows: true,
        hasReachedInitialReconciliation: false,
        backendStatus: ResourceViewStatus(freshness: .watching)
    ))
    #expect(!ResourceWarmRowPolicy.shouldPromoteProvisionalMetricRange(
        isRetainingWarmRows: true,
        hasReachedInitialReconciliation: true,
        backendStatus: ResourceViewStatus(
            freshness: .watching,
            metricsReconciling: true
        )
    ))
}
