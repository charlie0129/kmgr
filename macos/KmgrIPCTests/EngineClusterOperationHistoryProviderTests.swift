import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

private actor ClusterOperationHistoryRPCCapture: ClusterOperationHistoryRPC {
    enum Mode: Sendable {
        case batches([Kmgr_V1_ClusterOperationBatch])
        case burst(Int)
    }

    private let mode: Mode
    private var capturedRequest: Kmgr_V1_WatchOperationsRequest?
    private var capturedTimeout: Duration?

    init(mode: Mode) {
        self.mode = mode
    }

    func watchOperations(
        request: Kmgr_V1_WatchOperationsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ClusterOperationBatch) throws -> Void
    ) async throws {
        capturedRequest = request
        capturedTimeout = timeout
        switch mode {
        case .batches(let batches):
            for batch in batches { try receive(batch) }
        case .burst(let count):
            for sequence in 1...count {
                try receive(Self.batch(
                    streamID: request.streamID,
                    sequence: UInt64(sequence)
                ))
            }
        }
    }

    func request() -> Kmgr_V1_WatchOperationsRequest? { capturedRequest }
    func timeout() -> Duration? { capturedTimeout }

    nonisolated static func batch(
        streamID: String,
        sequence: UInt64
    ) -> Kmgr_V1_ClusterOperationBatch {
        var batch = Kmgr_V1_ClusterOperationBatch()
        batch.cursor.streamID = streamID
        batch.cursor.generation = 4
        batch.cursor.sequence = sequence
        return batch
    }
}

private actor BlockingClusterOperationHistoryRPC: ClusterOperationHistoryRPC {
    private var started = false
    private var cancelled = false

    func watchOperations(
        request: Kmgr_V1_WatchOperationsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ClusterOperationBatch) throws -> Void
    ) async throws {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func hasStarted() -> Bool { started }
    func wasCancelled() -> Bool { cancelled }
}

@Test func operationHistoryProviderBuildsEnvelopeAndPreservesNanoseconds() async throws {
    var event = ClusterOperationHistoryRPCCapture.batch(
        streamID: "operations-1",
        sequence: 7
    )
    var active = Kmgr_V1_KubernetesAPIOperation()
    active.id = 10
    active.state = .active
    active.operation = "WATCH"
    active.group = "apps"
    active.version = "v1"
    active.resource = "deployments"
    active.namespace = "default"
    active.httpStatusCode = 200
    active.bytesReceived = 2_048
    active.bytesSent = 512
    active.startedAtUnixNanos = 1_234_567_890_123_456_789
    event.active = [active]
    var completed = active
    completed.id = 11
    completed.state = .failed
    completed.operation = "DELETE"
    completed.name = "api"
    completed.httpStatusCode = 403
    completed.finishedAtUnixNanos = 1_234_567_890_223_456_789
    event.completed = [completed]
    event.droppedCompleted = 3
    let rpc = ClusterOperationHistoryRPCCapture(mode: .batches([event]))
    let provider = EngineClusterOperationHistoryProvider(
        rpc: rpc,
        timeout: .seconds(20),
        now: { Date(timeIntervalSince1970: 100) },
        requestID: { "request-1" }
    )

    var batches: [ClusterOperationBatch] = []
    for try await batch in provider.watchOperations(
        sessionID: "session-1",
        streamID: "operations-1"
    ) {
        batches.append(batch)
    }

    let request = await rpc.request()
    #expect(request?.context.requestID == "request-1")
    #expect(request?.context.clusterSessionID == "session-1")
    #expect(request?.context.deadlineUnixMs == 120_000)
    #expect(request?.streamID == "operations-1")
    #expect(await rpc.timeout() == .seconds(20))
    #expect(batches.count == 1)
    #expect(batches[0].cursor == StreamCursor(generation: 4, sequence: 7))
    #expect(batches[0].droppedCompleted == 3)
    #expect(batches[0].active[0] == ClusterOperationRecord(
        id: 10,
        state: .active,
        operation: "WATCH",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "default",
        httpStatusCode: 200,
        bytesReceived: 2_048,
        bytesSent: 512,
        startedAtUnixNanos: 1_234_567_890_123_456_789
    ))
    #expect(batches[0].completed[0].id == 11)
    #expect(batches[0].completed[0].state == .failed)
    #expect(batches[0].completed[0].finishedAtUnixNanos == 1_234_567_890_223_456_789)
}

@Test func operationHistoryProviderRejectsCrossStreamBatch() async {
    let event = ClusterOperationHistoryRPCCapture.batch(streamID: "wrong", sequence: 1)
    let rpc = ClusterOperationHistoryRPCCapture(mode: .batches([event]))
    let provider = EngineClusterOperationHistoryProvider(rpc: rpc)

    do {
        for try await _ in provider.watchOperations(
            sessionID: "session",
            streamID: "expected"
        ) {}
        Issue.record("cross-stream operation batch was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "OperationHistoryCursorInvalid")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func operationHistoryProviderRejectsUnspecifiedOperationState() async {
    var event = ClusterOperationHistoryRPCCapture.batch(
        streamID: "operations",
        sequence: 1
    )
    var operation = Kmgr_V1_KubernetesAPIOperation()
    operation.id = 1
    operation.operation = "LIST"
    operation.resource = "pods"
    operation.startedAtUnixNanos = 1
    event.completed = [operation]
    let rpc = ClusterOperationHistoryRPCCapture(mode: .batches([event]))
    let provider = EngineClusterOperationHistoryProvider(rpc: rpc)

    do {
        for try await _ in provider.watchOperations(
            sessionID: "session",
            streamID: "operations"
        ) {}
        Issue.record("unspecified operation state was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "OperationHistoryRecordInvalid")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func operationHistoryProviderFailsWhenBoundedBufferOverflows() async {
    let rpc = ClusterOperationHistoryRPCCapture(mode: .burst(64))
    let provider = EngineClusterOperationHistoryProvider(
        rpc: rpc,
        maximumBufferedBatches: 1
    )
    let stream = provider.watchOperations(sessionID: "session", streamID: "operations")
    try? await Task.sleep(for: .milliseconds(20))

    do {
        for try await _ in stream {}
        Issue.record("operation-history buffer overflow was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "OperationHistoryBufferExceeded")
        #expect(issue.category == .resourceExhausted)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func operationHistoryProviderCancelsRPCWhenConsumerStops() async {
    let rpc = BlockingClusterOperationHistoryRPC()
    let provider = EngineClusterOperationHistoryProvider(rpc: rpc)
    let stream = provider.watchOperations(sessionID: "session", streamID: "operations")
    let consumer = Task {
        do {
            for try await _ in stream {}
        } catch {
            // Cancellation is the expected terminal state for this fixture.
        }
    }

    for _ in 0..<200 {
        if await rpc.hasStarted() { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(await rpc.hasStarted())
    consumer.cancel()
    for _ in 0..<200 {
        if await rpc.wasCancelled() { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(await rpc.wasCancelled())
}
