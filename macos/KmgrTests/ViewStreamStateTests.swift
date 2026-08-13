import Foundation
import Testing
@testable import KmgrCore

@Test func generationSequenceGateIgnoresStaleAndDuplicateMessages() {
    var gate = GenerationSequenceGate()

    #expect(gate.accept(StreamCursor(generation: 4, sequence: 10)) == .acceptedNewGeneration)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 11)) == .acceptedNextSequence)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 11)) == .ignoredStaleOrDuplicateSequence)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 9)) == .ignoredStaleOrDuplicateSequence)
    #expect(gate.accept(StreamCursor(generation: 3, sequence: 999)) == .ignoredStaleGeneration)
    #expect(gate.lastAccepted == StreamCursor(generation: 4, sequence: 11))
}

@Test func newerGenerationSupersedesPriorSequenceSpace() {
    var gate = GenerationSequenceGate(lastAccepted: StreamCursor(generation: 8, sequence: 50_000))

    #expect(gate.accept(StreamCursor(generation: 9, sequence: 0)) == .acceptedNewGeneration)
    #expect(gate.accept(StreamCursor(generation: 8, sequence: 50_001)) == .ignoredStaleGeneration)
    #expect(gate.accept(StreamCursor(generation: 9, sequence: 1)) == .acceptedNextSequence)
    #expect(gate.lastAccepted == StreamCursor(generation: 9, sequence: 1))
}

@Test func warmViewTransitionsCachedResumingWatching() {
    let cachedAt = Date(timeIntervalSince1970: 1_000)
    let synchronizedAt = Date(timeIntervalSince1970: 1_020)
    var freshness = ViewFreshness.empty

    freshness = freshness.reducing(.warmRowsInstalled(lastSynchronizedAt: cachedAt))
    #expect(freshness == .cached(lastSynchronizedAt: cachedAt))
    #expect(freshness.hasUsableRows)
    #expect(freshness.statusText(now: Date(timeIntervalSince1970: 1_018)) == "Cached · 18s old")

    freshness = freshness.reducing(.resumeStarted)
    #expect(freshness == .resuming(lastSynchronizedAt: cachedAt))
    #expect(freshness.hasUsableRows)

    freshness = freshness.reducing(.watchEstablished(synchronizedAt: synchronizedAt))
    #expect(freshness == .watching(synchronizedAt: synchronizedAt))
    #expect(freshness.statusText() == "Watching")
}

@Test func failedWarmResumeKeepsRowsDuringProgressiveRelist() {
    let cachedAt = Date(timeIntervalSince1970: 2_000)
    var freshness = ViewFreshness.cached(lastSynchronizedAt: cachedAt)

    freshness = freshness.reducing(.resumeStarted)
    freshness = freshness.reducing(.relistStarted())
    #expect(freshness == .relisting(loaded: 0, cachedSince: cachedAt))
    #expect(freshness.hasUsableRows)

    freshness = freshness.reducing(.relistProgress(loaded: 34_000))
    freshness = freshness.reducing(.relistProgress(loaded: 20_000))
    #expect(freshness == .relisting(loaded: 34_000, cachedSince: cachedAt))
    #expect(freshness.statusName == "Relisting")

    let newSync = Date(timeIntervalSince1970: 2_100)
    freshness = freshness.reducing(.watchEstablished(synchronizedAt: newSync))
    #expect(freshness == .watching(synchronizedAt: newSync))
}

@Test func firstOpenRelistHasNoCachedRows() {
    let freshness = ViewFreshness.empty.reducing(.initialListStarted)
    #expect(freshness == .relisting(loaded: 0, cachedSince: nil))
    #expect(freshness.hasUsableRows == false)
}

@Test func staleStreamMessageCannotRegressFreshness() {
    let cachedAt = Date(timeIntervalSince1970: 3_000)
    let liveAt = Date(timeIntervalSince1970: 3_100)
    var stream = ViewStreamModel()

    #expect(stream.receive(
        cursor: StreamCursor(generation: 2, sequence: 1),
        event: .warmRowsInstalled(lastSynchronizedAt: cachedAt)
    ) == .acceptedNewGeneration)
    #expect(stream.receive(
        cursor: StreamCursor(generation: 2, sequence: 2),
        event: .watchEstablished(synchronizedAt: liveAt)
    ) == .acceptedNextSequence)

    #expect(stream.receive(
        cursor: StreamCursor(generation: 1, sequence: 9_999),
        event: .relistStarted(initialLoaded: 0)
    ) == .ignoredStaleGeneration)
    #expect(stream.freshness == .watching(synchronizedAt: liveAt))
}
