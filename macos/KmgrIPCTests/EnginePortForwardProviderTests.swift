import Foundation
import KmgrCore
import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine port-forward provider")
struct EnginePortForwardProviderTests {
    @Test("maps app-wide list and exposure metadata")
    func mapsList() async throws {
        var forward = Self.forward()
        forward.lastError.reason = "NonLoopbackBind"
        forward.lastError.message = "Accessible beyond this Mac."
        forward.lastError.safeDetails = ["exposure_warning": "non_loopback_bind"]
        let rpc = FakePortForwardRPC(forwards: [forward])
        let provider = deterministicProvider(rpc: rpc)

        let records = try await provider.listPortForwards(
            sessionID: "session-origin",
            includeStopped: true
        )

        #expect(records.count == 1)
        #expect(records[0].id == "pf-api")
        #expect(records[0].state == .listening)
        #expect(records[0].target.resource == "services")
        #expect(records[0].resolvedPod?.name == "api-7c9")
        #expect(records[0].address == "0.0.0.0:49152")
        #expect(records[0].exposesBeyondLocalMachine)
        #expect(records[0].lastIssue?.reason == "NonLoopbackBind")

        let request = await rpc.capturedList()
        #expect(request?.context.requestID == "pf-request")
        #expect(request?.context.clusterSessionID == "session-origin")
        #expect(request?.context.deadlineUnixMs == 1_010_000)
        #expect(request?.includeStopped == true)
    }

    @Test("maps start options and validates accepted response identity")
    func mapsStart() async throws {
        let rpc = FakePortForwardRPC()
        let provider = deterministicProvider(rpc: rpc)
        let request = StartPortForwardRequest(
            id: "pf-manual",
            target: Self.target(),
            remotePort: 8443,
            localPort: 0,
            bindAddress: "0.0.0.0",
            label: "development API",
            allowNonLoopback: true
        )

        let id = try await provider.startPortForward(request)
        #expect(id == "pf-manual")
        let captured = await rpc.capturedStart()
        #expect(captured?.context.clusterSessionID == "session-one")
        #expect(captured?.portForwardID == "pf-manual")
        #expect(captured?.target.uid == "uid-api-service")
        #expect(captured?.remotePort == 8443)
        #expect(captured?.localPort == 0)
        #expect(captured?.bindAddress == "0.0.0.0")
        #expect(captured?.label == "development API")
        #expect(captured?.allowNonLoopback == true)
    }

    @Test("maps watch cursor, deltas, structured errors, and app-wide context")
    func mapsWatch() async throws {
        var delta = Kmgr_V1_PortForwardEvent()
        delta.cursor.streamID = "forwards-stream"
        delta.cursor.generation = 3
        delta.cursor.sequence = 1
        delta.delta.upserts = [Self.forward()]
        delta.delta.removedPortForwardIds = ["pf-old"]

        var failure = Kmgr_V1_PortForwardEvent()
        failure.cursor.streamID = "forwards-stream"
        failure.cursor.generation = 3
        failure.cursor.sequence = 2
        failure.error.category = .unavailable
        failure.error.reason = "WatchUnavailable"
        failure.error.message = "The manager watch was interrupted."
        failure.error.retryable = true

        let rpc = FakePortForwardRPC(events: [delta, failure])
        let provider = deterministicProvider(rpc: rpc)
        let request = PortForwardWatchRequest(
            sessionID: "session-anchor",
            streamID: "forwards-stream",
            generation: 3,
            includeStopped: false
        )
        var values: [PortForwardWatchEvent] = []
        for try await event in provider.watchPortForwards(request: request) {
            values.append(event)
        }

        #expect(values.count == 2)
        guard case .delta(let cursor, let value) = values[0] else {
            Issue.record("Expected mapped delta")
            return
        }
        #expect(cursor == StreamCursor(generation: 3, sequence: 1))
        #expect(value.upserts.first?.id == "pf-api")
        #expect(value.removedIDs == ["pf-old"])
        guard case .failure(_, let issue) = values[1] else {
            Issue.record("Expected mapped structured failure")
            return
        }
        #expect(issue.category == .unavailable)
        #expect(issue.reason == "WatchUnavailable")
        #expect(issue.operation == "watch port-forwards")

        let captured = await rpc.capturedWatch()
        #expect(captured?.context.clusterSessionID == "session-anchor")
        #expect(captured?.context.deadlineUnixMs == 87_400_000)
        #expect(captured?.streamID == "forwards-stream")
        #expect(captured?.generation == 3)
        #expect(captured?.includeStopped == false)
    }

    @Test("stop and restart require exact request IDs and accepted acknowledgements")
    func mapsControls() async throws {
        let rpc = FakePortForwardRPC()
        let provider = deterministicProvider(rpc: rpc)

        try await provider.stopPortForward(id: "pf-api", sessionID: "session-one")
        try await provider.restartPortForward(id: "pf-api", sessionID: "session-one")

        #expect(await rpc.capturedStop()?.portForwardID == "pf-api")
        #expect(await rpc.capturedRestart()?.portForwardID == "pf-api")
    }

    @Test("watch rejects missing session, stream ID, and generation before RPC")
    func validatesWatchIdentity() async {
        let rpc = FakePortForwardRPC()
        let provider = deterministicProvider(rpc: rpc)
        let requests = [
            PortForwardWatchRequest(sessionID: "", streamID: "stream", generation: 1),
            PortForwardWatchRequest(sessionID: "session", streamID: "", generation: 1),
            PortForwardWatchRequest(sessionID: "session", streamID: "stream", generation: 0),
        ]

        for request in requests {
            do {
                for try await _ in provider.watchPortForwards(request: request) {}
                Issue.record("Expected validation issue")
            } catch let issue as ClusterManagerIssue {
                #expect(issue.category == .validation)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
        #expect(await rpc.capturedWatch() == nil)
    }

    @Test("mismatched unary response identity fails safely")
    func rejectsResponseMismatch() async {
        let rpc = FakePortForwardRPC(responseID: "wrong-request")
        let provider = deterministicProvider(rpc: rpc)
        do {
            _ = try await provider.listPortForwards(
                sessionID: "session-one",
                includeStopped: true
            )
            Issue.record("Expected request ID mismatch")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
            #expect(issue.reason == "RequestIDMismatch")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private func deterministicProvider(rpc: FakePortForwardRPC) -> EnginePortForwardProvider {
        EnginePortForwardProvider(
            rpc: rpc,
            unaryTimeout: .seconds(10),
            streamTimeout: .seconds(86_400),
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "pf-request" }
        )
    }

    private static func target() -> ResourceIdentity {
        ResourceIdentity(
            clusterSessionID: "session-one",
            group: "",
            version: "v1",
            resource: "services",
            namespace: "apps",
            name: "api",
            uid: "uid-api-service"
        )
    }

    private static func forward() -> Kmgr_V1_PortForward {
        var value = Kmgr_V1_PortForward()
        value.portForwardID = "pf-api"
        value.clusterSessionID = "session-one"
        value.contextName = "production"
        value.target.clusterSessionID = "session-one"
        value.target.version = "v1"
        value.target.resource = "services"
        value.target.namespace = "apps"
        value.target.name = "api"
        value.target.uid = "uid-api-service"
        value.resolvedPod.clusterSessionID = "session-one"
        value.resolvedPod.version = "v1"
        value.resolvedPod.resource = "pods"
        value.resolvedPod.namespace = "apps"
        value.resolvedPod.name = "api-7c9"
        value.resolvedPod.uid = "uid-api-pod"
        value.remotePort = 80
        value.localPort = 49_152
        value.bindAddress = "0.0.0.0"
        value.label = "API"
        value.state = .listening
        value.startedAtUnixMs = 1_000_000
        value.updatedAtUnixMs = 1_001_000
        return value
    }
}

private actor FakePortForwardRPC: PortForwardRPC {
    private let forwards: [Kmgr_V1_PortForward]
    private let events: [Kmgr_V1_PortForwardEvent]
    private let responseID: String?
    private var startRequest: Kmgr_V1_StartPortForwardRequest?
    private var stopRequest: Kmgr_V1_StopPortForwardRequest?
    private var restartRequest: Kmgr_V1_RestartPortForwardRequest?
    private var listRequest: Kmgr_V1_ListPortForwardsRequest?
    private var watchRequest: Kmgr_V1_WatchPortForwardsRequest?

    init(
        forwards: [Kmgr_V1_PortForward] = [],
        events: [Kmgr_V1_PortForwardEvent] = [],
        responseID: String? = nil
    ) {
        self.forwards = forwards
        self.events = events
        self.responseID = responseID
    }

    func capturedStart() -> Kmgr_V1_StartPortForwardRequest? { startRequest }
    func capturedStop() -> Kmgr_V1_StopPortForwardRequest? { stopRequest }
    func capturedRestart() -> Kmgr_V1_RestartPortForwardRequest? { restartRequest }
    func capturedList() -> Kmgr_V1_ListPortForwardsRequest? { listRequest }
    func capturedWatch() -> Kmgr_V1_WatchPortForwardsRequest? { watchRequest }

    func start(
        request: Kmgr_V1_StartPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartPortForwardResponse {
        startRequest = request
        var response = Kmgr_V1_StartPortForwardResponse()
        response.requestID = responseID ?? request.context.requestID
        response.portForwardID = request.portForwardID
        response.accepted = true
        return response
    }

    func stop(
        request: Kmgr_V1_StopPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        stopRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = responseID ?? request.context.requestID
        response.accepted = true
        return response
    }

    func restart(
        request: Kmgr_V1_RestartPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        restartRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = responseID ?? request.context.requestID
        response.accepted = true
        return response
    }

    func list(
        request: Kmgr_V1_ListPortForwardsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListPortForwardsResponse {
        listRequest = request
        var response = Kmgr_V1_ListPortForwardsResponse()
        response.requestID = responseID ?? request.context.requestID
        response.portForwards = forwards
        return response
    }

    func watch(
        request: Kmgr_V1_WatchPortForwardsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_PortForwardEvent) throws -> Void
    ) async throws {
        watchRequest = request
        for event in events { try receive(event) }
    }
}
