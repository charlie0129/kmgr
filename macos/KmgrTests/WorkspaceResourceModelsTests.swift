import Foundation
import Testing
@testable import KmgrCore

@Test func discoveredResourceIdentityIncludesGVR() {
    let resource = DiscoveredResource(
        group: "apps",
        version: "v1",
        resource: "deployments",
        kind: "Deployment",
        namespaced: true
    )
    #expect(resource.id == "apps/v1/deployments")
}

@Test func resourceStatusUsesHonestProgressText() {
    let synchronizedAt = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_018)
    let relisting = ResourceViewStatus(freshness: .relisting, objectsExamined: 24_000)
    #expect(relisting.presentation.contains("24,000"))
    #expect(ResourceViewStatus(
        freshness: .stale,
        lastSynchronizedAt: synchronizedAt
    ).presentation(now: now) == "Cached · 18s old")
    #expect(ResourceViewStatus(
        freshness: .reconnecting,
        lastSynchronizedAt: synchronizedAt
    ).presentation(now: now) == "Reconnecting… · last synchronized 18s old")
    #expect(ResourceViewStatus(freshness: .watching).presentation == "Watching")
}

@Test func resourceStatusProgressAndAgeRefreshPolicyMatchesContinuityWork() {
    let synchronizedAt = Date(timeIntervalSince1970: 1_000)
    for freshness in [
        ResourceViewStatus.Freshness.loading, .resuming, .relisting, .reconnecting,
    ] {
        #expect(ResourceViewStatus(freshness: freshness).showsProgress)
    }
    for freshness in [
        ResourceViewStatus.Freshness.stale, .watching, .failed, .complete,
    ] {
        #expect(!ResourceViewStatus(freshness: freshness).showsProgress)
    }

    #expect(ResourceViewStatus(
        freshness: .relisting,
        lastSynchronizedAt: synchronizedAt
    ).needsAgeRefresh)
    #expect(ResourceViewStatus(
        freshness: .failed,
        lastSynchronizedAt: synchronizedAt
    ).needsAgeRefresh)
    #expect(!ResourceViewStatus(
        freshness: .watching,
        lastSynchronizedAt: synchronizedAt
    ).needsAgeRefresh)
    #expect(ResourceViewStatus(freshness: .stale).presentation(
        now: Date(timeIntervalSince1970: 2_000)
    ) == "Cached · age unavailable")
}

@Test func resourceAgeRefreshWaitsForTheNextVisibleBoundary() {
    let synchronizedAt = Date(timeIntervalSince1970: 1_000)
    let status = ResourceViewStatus(
        freshness: .stale,
        lastSynchronizedAt: synchronizedAt
    )

    #expect(status.nextAgeRefreshDelay(
        now: synchronizedAt.addingTimeInterval(12.25)
    ) == .milliseconds(750))
    #expect(status.nextAgeRefreshDelay(
        now: synchronizedAt.addingTimeInterval(90.25)
    ) == .milliseconds(29_750))
    #expect(status.nextAgeRefreshDelay(
        now: synchronizedAt.addingTimeInterval(3_723.25)
    ) == .milliseconds(3_476_750))
    #expect(status.nextAgeRefreshDelay(
        now: synchronizedAt.addingTimeInterval(172_923.25)
    ) == .milliseconds(86_276_750))
    #expect(ResourceViewStatus(
        freshness: .watching,
        lastSynchronizedAt: synchronizedAt
    ).nextAgeRefreshDelay(now: synchronizedAt) == nil)
    #expect(ResourceViewStatus(freshness: .stale).nextAgeRefreshDelay(
        now: synchronizedAt
    ) == nil)
}

@Test func everyResourceViewMessageCarriesGenerationCursor() {
    let cursor = StreamCursor(generation: 7, sequence: 31)
    let message = ResourceViewMessage.invalidation(
        cursor: cursor,
        invalidation: ResourceViewInvalidation(
            presentationRevision: 9,
            indexRevision: 4,
            rowsVisible: 800_000,
            maxRangeLength: 512
        )
    )
    #expect(message.cursor == cursor)
}

@Test func resourceStatusCarriesGlobalMetricReconciliationState() {
    let status = ResourceViewStatus(
        freshness: .watching,
        rowsVisible: 42,
        metricsReconciling: true
    )
    #expect(status.metricsReconciling)
    #expect(!status.showsProgress)
}
