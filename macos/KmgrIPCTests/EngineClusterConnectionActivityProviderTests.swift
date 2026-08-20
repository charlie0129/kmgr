import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

private actor ClusterConnectionActivityRPCCapture: ClusterConnectionActivityRPC {
    enum Mode: Sendable {
        case events([Kmgr_V1_ConnectionEvent])
        case burst(Int)
    }

    private let mode: Mode
    private var capturedRequest: Kmgr_V1_WatchConnectionRequest?
    private var capturedTimeout: Duration?

    init(mode: Mode) {
        self.mode = mode
    }

    func watchConnection(
        request: Kmgr_V1_WatchConnectionRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ConnectionEvent) throws -> Void
    ) async throws {
        capturedRequest = request
        capturedTimeout = timeout
        switch mode {
        case .events(let events):
            for event in events { try receive(event) }
        case .burst(let count):
            for sequence in 1...count {
                try receive(Self.event(streamID: request.streamID, sequence: UInt64(sequence)))
            }
        }
    }

    func request() -> Kmgr_V1_WatchConnectionRequest? { capturedRequest }
    func timeout() -> Duration? { capturedTimeout }

    nonisolated static func event(
        streamID: String,
        sequence: UInt64,
        state: Kmgr_V1_ConnectionState = .connected,
        received: UInt64 = 0,
        sent: UInt64 = 0
    ) -> Kmgr_V1_ConnectionEvent {
        var event = Kmgr_V1_ConnectionEvent()
        event.cursor.streamID = streamID
        event.cursor.generation = 3
        event.cursor.sequence = sequence
        event.state = state
        event.observedAtUnixMs = 12_345
        event.apiBytesReceived = received
        event.apiBytesSent = sent
        return event
    }
}

private actor BlockingClusterConnectionActivityRPC: ClusterConnectionActivityRPC {
    private var started = false
    private var cancelled = false

    func watchConnection(
        request: Kmgr_V1_WatchConnectionRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ConnectionEvent) throws -> Void
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

@Test func connectionActivityProviderBuildsEnvelopeAndMapsTotals() async throws {
    var event = ClusterConnectionActivityRPCCapture.event(
        streamID: "activity-1",
        sequence: 7,
        state: .reconnecting,
        received: 2_048,
        sent: 512
    )
    event.authorityWarmCache.retainedViews = 2
    event.authorityWarmCache.retainedObjects = 300
    event.authorityWarmCache.retainedBytes = 4_096
    event.authorityWarmCache.evictableViews = 1
    event.authorityWarmCache.evictableObjects = 120
    event.authorityWarmCache.evictableBytes = 2_048
    event.authorityWarmCache.viewLimit = 8
    event.authorityWarmCache.objectLimit = 100_000
    event.authorityWarmCache.byteLimit = 1 << 30
    event.authorityWarmCache.budgetEvictions = 3
    event.globalWarmCache.retainedViews = 4
    event.globalWarmCache.retainedObjects = 900
    event.globalWarmCache.retainedBytes = 16_384
    event.globalWarmCache.evictableViews = 2
    event.globalWarmCache.evictableObjects = 320
    event.globalWarmCache.evictableBytes = 8_192
    event.globalWarmCache.viewLimit = 24
    event.globalWarmCache.objectLimit = 250_000
    event.globalWarmCache.byteLimit = 2 << 30
    event.globalWarmCache.budgetEvictions = 5
    let rpc = ClusterConnectionActivityRPCCapture(mode: .events([event]))
    let provider = EngineClusterConnectionActivityProvider(
        rpc: rpc,
        timeout: .seconds(20),
        now: { Date(timeIntervalSince1970: 100) },
        requestID: { "request-1" }
    )

    var samples: [ClusterConnectionActivitySample] = []
    for try await sample in provider.watchConnectionActivity(
        sessionID: "session-1",
        streamID: "activity-1"
    ) {
        samples.append(sample)
    }

    let request = await rpc.request()
    #expect(request?.context.requestID == "request-1")
    #expect(request?.context.clusterSessionID == "session-1")
    #expect(request?.context.deadlineUnixMs == 120_000)
    #expect(request?.streamID == "activity-1")
    #expect(await rpc.timeout() == .seconds(20))
    #expect(samples.count == 1)
    #expect(samples.first?.cursor == StreamCursor(generation: 3, sequence: 7))
    #expect(samples.first?.state == .reconnecting)
    #expect(samples.first?.observedAt == Date(timeIntervalSince1970: 12.345))
    #expect(samples.first?.bytesReceived == 2_048)
    #expect(samples.first?.bytesSent == 512)
    #expect(samples.first?.authorityWarmCache == WarmCacheUsage(
        retainedViews: 2,
        retainedObjects: 300,
        retainedBytes: 4_096,
        evictableViews: 1,
        evictableObjects: 120,
        evictableBytes: 2_048,
        viewLimit: 8,
        objectLimit: 100_000,
        byteLimit: 1 << 30,
        budgetEvictions: 3
    ))
    #expect(samples.first?.globalWarmCache == WarmCacheUsage(
        retainedViews: 4,
        retainedObjects: 900,
        retainedBytes: 16_384,
        evictableViews: 2,
        evictableObjects: 320,
        evictableBytes: 8_192,
        viewLimit: 24,
        objectLimit: 250_000,
        byteLimit: 2 << 30,
        budgetEvictions: 5
    ))
}

@Test func connectionActivityProviderRejectsCrossStreamEvent() async {
    let event = ClusterConnectionActivityRPCCapture.event(streamID: "wrong", sequence: 1)
    let rpc = ClusterConnectionActivityRPCCapture(mode: .events([event]))
    let provider = EngineClusterConnectionActivityProvider(rpc: rpc)

    do {
        for try await _ in provider.watchConnectionActivity(
            sessionID: "session",
            streamID: "expected"
        ) {}
        Issue.record("cross-stream connection event was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "ConnectionActivityCursorInvalid")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func connectionActivityProviderFailsWhenBoundedBufferOverflows() async {
    let rpc = ClusterConnectionActivityRPCCapture(mode: .burst(64))
    let provider = EngineClusterConnectionActivityProvider(
        rpc: rpc,
        maximumBufferedSamples: 1
    )
    let stream = provider.watchConnectionActivity(sessionID: "session", streamID: "activity")
    try? await Task.sleep(for: .milliseconds(20))

    do {
        for try await _ in stream {}
        Issue.record("connection activity buffer overflow was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "ConnectionActivityBufferExceeded")
        #expect(issue.category == .resourceExhausted)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func connectionActivityProviderCancelsRPCWhenConsumerStops() async {
    let rpc = BlockingClusterConnectionActivityRPC()
    let provider = EngineClusterConnectionActivityProvider(rpc: rpc)
    let stream = provider.watchConnectionActivity(
        sessionID: "session",
        streamID: "activity"
    )
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
