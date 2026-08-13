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

@Test func connectionActivityProviderBuildsEnvelopeAndMapsTotals() async throws {
    let event = ClusterConnectionActivityRPCCapture.event(
        streamID: "activity-1",
        sequence: 7,
        state: .reconnecting,
        received: 2_048,
        sent: 512
    )
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
