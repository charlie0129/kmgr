import Foundation
import GRPCCore
import Testing
@testable import KmgrCore
@testable import KmgrIPC
import KmgrProto

private actor LogRPCCapture: LogRPC {
    var streamed: [Kmgr_V1_StartLogsRequest] = []
    var cancelled: [Kmgr_V1_CancelLogsRequest] = []
    var resolutions: [Kmgr_V1_ResolveLogSourcesRequest] = []
    var resolutionTimeouts: [Duration] = []
    var resolutionResponse = Kmgr_V1_ResolveLogSourcesResponse()
    var events: [Kmgr_V1_LogEvent] = []

    func setEvents(_ values: [Kmgr_V1_LogEvent]) { events = values }

    func setResolutionResponse(_ value: Kmgr_V1_ResolveLogSourcesResponse) {
        resolutionResponse = value
    }

    func resolveLogSources(
        request: Kmgr_V1_ResolveLogSourcesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ResolveLogSourcesResponse {
        resolutions.append(request)
        resolutionTimeouts.append(timeout)
        var response = resolutionResponse
        if response.requestID.isEmpty { response.requestID = request.context.requestID }
        return response
    }

    func streamLogs(
        request: Kmgr_V1_StartLogsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_LogEvent) throws -> Void
    ) async throws {
        streamed.append(request)
        for event in events { try receive(event) }
    }

    func cancelLogs(
        request: Kmgr_V1_CancelLogsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        cancelled.append(request)
        var result = Kmgr_V1_Acknowledgement()
        result.requestID = request.context.requestID
        result.accepted = true
        return result
    }

    func requests() -> ([Kmgr_V1_StartLogsRequest], [Kmgr_V1_CancelLogsRequest]) {
        (streamed, cancelled)
    }

    func resolutionRequests() -> [Kmgr_V1_ResolveLogSourcesRequest] { resolutions }
    func capturedResolutionTimeouts() -> [Duration] { resolutionTimeouts }
}

@Test func logProviderMapsOpaqueRecordsAndAuthenticatedRequestEnvelope() async throws {
    let rpc = LogRPCCapture()
    var record = Kmgr_V1_LogRecord()
    record.sourceID = "pod-a/main"
    record.data = Data([0xff, 0, 0x61])
    record.endsWithNewline = false
    var batch = Kmgr_V1_LogBatch()
    batch.records = [record]
    batch.totalBytes = 3
    var cursor = Kmgr_V1_StreamCursor()
    cursor.streamID = "logs-1"
    cursor.generation = 3
    cursor.sequence = 8
    var event = Kmgr_V1_LogEvent()
    event.cursor = cursor
    event.batch = batch
    await rpc.setEvents([event])

    let now = Date(timeIntervalSince1970: 1_000)
    let provider = EngineLogStreamProvider(
        rpc: rpc,
        streamTimeout: .seconds(20),
        now: { now },
        requestID: { "request-1" }
    )
    let identity = ResourceIdentity(
        clusterSessionID: "session-1", group: "", version: "v1",
        resource: "pods", namespace: "team", name: "pod-a", uid: "uid-a"
    )
    let request = LogStreamRequest(
        sessionID: "session-1", streamID: "logs-1", generation: 3,
        sources: [LogSource(
            identity: identity, container: "main", sourceID: "pod-a/main", label: "pod-a/main"
        )],
        options: LogOptions(
            follow: true, previous: true, timestamps: true,
            sinceSeconds: 0, tailLines: 42
        )
    )

    var messages: [LogStreamMessage] = []
    for try await message in provider.streamLogs(request: request) { messages.append(message) }
    guard case .records(let mappedCursor, let mappedRecords, let totalBytes) = messages.first else {
        Issue.record("missing mapped record batch")
        return
    }
    #expect(mappedCursor == StreamCursor(generation: 3, sequence: 8))
    #expect(mappedRecords.first?.data == Data([0xff, 0, 0x61]))
    #expect(mappedRecords.first?.endsWithNewline == false)
    #expect(mappedRecords.first?.startsLine == true)
    #expect(totalBytes == 3)

    let (starts, _) = await rpc.requests()
    #expect(starts.first?.context.requestID == "request-1")
    #expect(starts.first?.context.clusterSessionID == "session-1")
    #expect(starts.first?.context.deadlineUnixMs == 1_020_000)
    #expect(starts.first?.sources.first?.identity.uid == "uid-a")
    #expect(starts.first?.options.tailLines == 42)
    #expect(starts.first?.options.hasSinceSeconds == false)
    #expect(starts.first?.options.previous == true)
}

@Test func logProviderMapsStaticUIDPinnedWorkloadResolution() async throws {
    let rpc = LogRPCCapture()
    var pod = Kmgr_V1_ResolvedPodLogSource()
    pod.identity.clusterSessionID = "session-1"
    pod.identity.version = "v1"
    pod.identity.resource = "pods"
    pod.identity.namespace = "team"
    pod.identity.name = "web-abc"
    pod.identity.uid = "pod-uid"
    pod.containers = ["sidecar", "app", "app"]
    var response = Kmgr_V1_ResolveLogSourcesResponse()
    response.pods = [pod]
    response.staticWorkloadSnapshot = true
    await rpc.setResolutionResponse(response)

    let provider = EngineLogStreamProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 1_000) },
        requestID: { "resolve-1" }
    )
    let workload = ResourceIdentity(
        clusterSessionID: "session-1", group: "apps", version: "v1",
        resource: "deployments", namespace: "team", name: "web", uid: "deployment-uid"
    )
    let resolution = try await provider.resolveLogSources(resources: [workload])

    #expect(resolution.staticWorkloadSnapshot)
    #expect(resolution.pods == [PodLogSourceInventory(
        identity: ResourceIdentity(
            clusterSessionID: "session-1", group: "", version: "v1", resource: "pods",
            namespace: "team", name: "web-abc", uid: "pod-uid"
        ),
        containers: ["app", "sidecar"]
    )])
    let requests = await rpc.resolutionRequests()
    #expect(requests.first?.context.requestID == "resolve-1")
    #expect(requests.first?.context.clusterSessionID == "session-1")
    #expect(requests.first?.context.deadlineUnixMs == 1_030_000)
    #expect(requests.first?.resources.first?.uid == "deployment-uid")
    #expect(await rpc.capturedResolutionTimeouts() == [.seconds(30)])
}

@Test func logProviderRejectsCrossStreamEvents() async {
    let rpc = LogRPCCapture()
    var event = Kmgr_V1_LogEvent()
    event.cursor.streamID = "wrong"
    event.cursor.generation = 1
    event.cursor.sequence = 1
    event.batch = Kmgr_V1_LogBatch()
    await rpc.setEvents([event])
    let provider = EngineLogStreamProvider(rpc: rpc)
    let request = LogStreamRequest(
        sessionID: "session", streamID: "expected", generation: 1,
        sources: [LogSource(
            identity: ResourceIdentity(
                clusterSessionID: "session", group: "", version: "v1", resource: "pods",
                namespace: "default", name: "pod", uid: "uid"
            ),
            container: "main", sourceID: "pod/main", label: "pod/main"
        )]
    )
    do {
        for try await _ in provider.streamLogs(request: request) {}
        Issue.record("cross-stream event was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "LogStreamCursorMismatch")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func logProviderRejectsPreviousGenerationAndNonMonotonicEvents() async {
    for cursor in [
        (generation: UInt64(6), sequence: UInt64(1)),
        (generation: UInt64(8), sequence: UInt64(1)),
        (generation: UInt64(7), sequence: UInt64(0)),
    ] {
        let rpc = LogRPCCapture()
        var event = Kmgr_V1_LogEvent()
        event.cursor.streamID = "logs"
        event.cursor.generation = cursor.generation
        event.cursor.sequence = cursor.sequence
        event.batch = Kmgr_V1_LogBatch()
        await rpc.setEvents([event])

        let provider = EngineLogStreamProvider(rpc: rpc)
        let request = LogStreamRequest(
            sessionID: "session", streamID: "logs", generation: 7,
            sources: [LogSource(
                identity: ResourceIdentity(
                    clusterSessionID: "session", group: "", version: "v1", resource: "pods",
                    namespace: "default", name: "pod", uid: "uid"
                ),
                container: "main", sourceID: "pod/main", label: "pod/main"
            )]
        )
        do {
            for try await _ in provider.streamLogs(request: request) {}
            Issue.record("invalid log cursor was accepted: \(cursor)")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.reason == "LogStreamCursorMismatch")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Test func logProviderRejectsDuplicateSequence() async {
    let rpc = LogRPCCapture()
    var event = Kmgr_V1_LogEvent()
    event.cursor.streamID = "logs"
    event.cursor.generation = 7
    event.cursor.sequence = 1
    event.batch = Kmgr_V1_LogBatch()
    await rpc.setEvents([event, event])

    let provider = EngineLogStreamProvider(rpc: rpc)
    let request = LogStreamRequest(
        sessionID: "session", streamID: "logs", generation: 7,
        sources: [LogSource(
            identity: ResourceIdentity(
                clusterSessionID: "session", group: "", version: "v1", resource: "pods",
                namespace: "default", name: "pod", uid: "uid"
            ),
            container: "main", sourceID: "pod/main", label: "pod/main"
        )]
    )
    do {
        for try await _ in provider.streamLogs(request: request) {}
        Issue.record("duplicate log cursor was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "LogStreamCursorMismatch")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func logProviderSendsExplicitGenerationCancel() async {
    let rpc = LogRPCCapture()
    let provider = EngineLogStreamProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 50) },
        requestID: { "cancel-1" }
    )
    await provider.cancelLogs(sessionID: "session", streamID: "logs", generation: 9)
    let (_, cancels) = await rpc.requests()
    #expect(cancels.first?.context.requestID == "cancel-1")
    #expect(cancels.first?.context.clusterSessionID == "session")
    #expect(cancels.first?.logStreamID == "logs")
    #expect(cancels.first?.generation == 9)
}
