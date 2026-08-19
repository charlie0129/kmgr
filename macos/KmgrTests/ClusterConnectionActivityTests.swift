import Foundation
import Testing
@testable import KmgrCore

@Test func connectionRateTrackerUsesMonotonicTotalDeltas() {
    var tracker = ClusterConnectionRateTracker()
    let baseline = connectionSample(at: 10, received: 100, sent: 40)
    #expect(tracker.receive(baseline) == nil)

    let rate = tracker.receive(connectionSample(at: 12, received: 2_148, sent: 1_064))
    #expect(rate?.bytesReceivedPerSecond == 1_024)
    #expect(rate?.bytesSentPerSecond == 512)
    #expect(rate?.receivedActive == true)
    #expect(rate?.sentActive == true)
}

@Test func connectionRateTrackerIgnoresCacheOnlySamplesWithoutMovingItsBaseline() {
    var tracker = ClusterConnectionRateTracker()
    #expect(tracker.receive(connectionSample(at: 10, received: 100, sent: 40)) == nil)
    #expect(tracker.receive(connectionSample(at: 11, received: 100, sent: 40)) == nil)

    let rate = tracker.receive(connectionSample(at: 12, received: 2_148, sent: 1_064))
    #expect(rate?.bytesReceivedPerSecond == 1_024)
    #expect(rate?.bytesSentPerSecond == 512)
    #expect(rate?.receivedActive == true)
    #expect(rate?.sentActive == true)
}

@Test func connectionRateTrackerTreatsCounterResetAsNewBaseline() {
    var tracker = ClusterConnectionRateTracker()
    _ = tracker.receive(connectionSample(at: 10, received: 1_000, sent: 2_000))
    #expect(tracker.receive(connectionSample(at: 11, received: 2, sent: 3)) == ClusterConnectionRate())

    let rate = tracker.receive(connectionSample(at: 13, received: 202, sent: 103))
    #expect(rate?.bytesReceivedPerSecond == 100)
    #expect(rate?.bytesSentPerSecond == 50)
}

@Test func connectionRateTrackerRejectsNonIncreasingTime() {
    var tracker = ClusterConnectionRateTracker()
    _ = tracker.receive(connectionSample(at: 10, received: 1, sent: 1))
    #expect(tracker.receive(connectionSample(at: 10, received: 5, sent: 5)) == ClusterConnectionRate())
    let rate = tracker.receive(connectionSample(at: 12, received: 9, sent: 7))
    #expect(rate?.bytesReceivedPerSecond == 2)
    #expect(rate?.bytesSentPerSecond == 1)
}

@Test func connectionActivitySampleCarriesLocalAndGlobalWarmCacheAggregates() {
    let authority = WarmCacheUsage(
        retainedViews: 2,
        retainedObjects: 300,
        retainedBytes: 4_096,
        viewLimit: 8,
        objectLimit: 100_000,
        byteLimit: 1 << 30,
        budgetEvictions: 3
    )
    let global = WarmCacheUsage(
        retainedViews: 4,
        retainedObjects: 900,
        retainedBytes: 16_384,
        viewLimit: 24,
        objectLimit: 250_000,
        byteLimit: 2 << 30,
        budgetEvictions: 5
    )
    let sample = ClusterConnectionActivitySample(
        cursor: StreamCursor(generation: 1, sequence: 2),
        state: .connected,
        observedAt: Date(timeIntervalSince1970: 10),
        bytesReceived: 0,
        bytesSent: 0,
        authorityWarmCache: authority,
        globalWarmCache: global
    )

    #expect(sample.authorityWarmCache == authority)
    #expect(sample.globalWarmCache == global)
}

private func connectionSample(
    at timestamp: TimeInterval,
    received: UInt64,
    sent: UInt64
) -> ClusterConnectionActivitySample {
    ClusterConnectionActivitySample(
        cursor: StreamCursor(generation: 1, sequence: 1),
        state: .connected,
        observedAt: Date(timeIntervalSince1970: timestamp),
        bytesReceived: received,
        bytesSent: sent
    )
}
