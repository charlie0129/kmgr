import Testing
@testable import KmgrCore

@Test func operationHistoryRetainsEveryActiveAndBoundsOnlyCompletions() async {
    let store = ClusterOperationHistoryStore(completedLimit: 2)
    var change = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 1),
        active: [operation(id: 1, state: .active)],
        completed: [
            operation(id: 10, state: .finished, finished: 100),
            operation(id: 11, state: .failed, finished: 110),
        ]
    ))
    #expect(change.active.map(\.id) == [1])
    #expect(change.completed.map(\.id) == [10, 11])
    #expect(change.evictedCompletedIDs.isEmpty)

    change = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 2),
        active: [
            operation(id: 1, state: .active),
            operation(id: 2, state: .active),
            operation(id: 3, state: .active),
        ],
        completed: [operation(id: 12, state: .finished, finished: 120)],
        droppedCompleted: 3
    ))
    #expect(change.active.count == 3)
    #expect(change.completed.map(\.id) == [12])
    #expect(change.evictedCompletedIDs == [10])
    #expect(change.droppedCompleted == 3)

    let snapshot = await store.snapshot()
    #expect(Set(snapshot.active.map(\.id)) == [1, 2, 3])
    #expect(snapshot.completed.map(\.id) == [11, 12])
    #expect(snapshot.droppedCompleted == 3)
}

@Test func operationHistoryLimitChangesTakeEffectImmediately() async {
    let store = ClusterOperationHistoryStore(completedLimit: 3)
    _ = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 1),
        active: [operation(id: 1, state: .active)],
        completed: [
            operation(id: 10, state: .finished, finished: 100),
            operation(id: 11, state: .finished, finished: 110),
            operation(id: 12, state: .finished, finished: 120),
        ]
    ))

    let change = await store.setCompletedLimit(1)
    #expect(change.active.map(\.id) == [1])
    #expect(change.evictedCompletedIDs == [10, 11])
    #expect(await store.snapshot().completed.map(\.id) == [12])

    let disabled = await store.setCompletedLimit(0)
    #expect(disabled.evictedCompletedIDs == [12])
    _ = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 2),
        active: [operation(id: 2, state: .active)],
        completed: [operation(id: 13, state: .finished, finished: 130)]
    ))
    let snapshot = await store.snapshot()
    #expect(snapshot.completed.isEmpty)
    #expect(snapshot.active.map(\.id) == [2])
}

@Test func operationHistoryDeduplicatesReplayedRetainedCompletion() async {
    let store = ClusterOperationHistoryStore(completedLimit: 4)
    let record = operation(id: 10, state: .finished, finished: 100)
    _ = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 1),
        active: [],
        completed: [record]
    ))
    let replay = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 2, sequence: 1),
        active: [],
        completed: [record]
    ))
    #expect(replay.completed.isEmpty)
    #expect(await store.snapshot().completed == [record])
}

@Test func operationHistoryReplacesCompletionWhenLateWatchErrorAddsServerDetails() async {
    let store = ClusterOperationHistoryStore(completedLimit: 4)
    let transportOnly = ClusterOperationRecord(
        id: 10,
        state: .failed,
        operation: "WATCH",
        resource: "nodes",
        startedAtUnixNanos: 10,
        finishedAtUnixNanos: 100,
        errorMessage: "http2: response body closed"
    )
    _ = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 1),
        active: [],
        completed: [transportOnly]
    ))
    var corrected = transportOnly
    corrected.errorMessage = "Kubernetes server (InternalError, HTTP 500): storage feature RequestWatchProgress is disabled\nGo: http2: response body closed"
    let change = await store.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 2),
        active: [],
        completed: [corrected]
    ))
    #expect(change.completed == [corrected])
    #expect(await store.snapshot().completed == [corrected])

    let oneBatchStore = ClusterOperationHistoryStore(completedLimit: 4)
    let oneBatchChange = await oneBatchStore.apply(ClusterOperationBatch(
        cursor: StreamCursor(generation: 1, sequence: 1),
        active: [],
        completed: [transportOnly, corrected]
    ))
    #expect(oneBatchChange.completed == [corrected])
    #expect(await oneBatchStore.snapshot().completed == [corrected])
}

private func operation(
    id: UInt64,
    state: ClusterOperationState,
    finished: Int64? = nil
) -> ClusterOperationRecord {
    ClusterOperationRecord(
        id: id,
        state: state,
        operation: state == .active ? "WATCH" : "LIST",
        resource: "pods",
        startedAtUnixNanos: Int64(id),
        finishedAtUnixNanos: finished
    )
}
