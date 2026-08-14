import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine operation provider")
struct EngineOperationProviderTests {
    @Test("maps UID-pinned bulk delete and preserves skipped progress")
    func mapsDeleteAndProgress() async throws {
        let rpc = FakeOperationRPC(events: [Self.progressEvent()])
        let provider = deterministicProvider(rpc: rpc)
        let first = Self.identity(name: "api-a", uid: "uid-a")
        let second = Self.identity(name: "api-b", uid: "uid-b")

        let stream = try await provider.deleteResources(
            targets: [
                ResourceDeleteTarget(identity: first),
                ResourceDeleteTarget(identity: second, hiddenByFilter: true),
            ],
            options: ResourceDeleteOptions(
                propagationPolicy: .foreground,
                gracePeriodSeconds: 0,
                maxConcurrency: 3
            )
        )
        var progress: [OperationProgress] = []
        for try await value in stream { progress.append(value) }

        let request = try #require(await rpc.capturedDelete())
        #expect(request.context.requestID == "operation-token")
        #expect(request.context.clusterSessionID == "session-one")
        #expect(request.context.deadlineUnixMs == 87_400_000)
        #expect(request.operationID == "operation-token")
        #expect(request.propagationPolicy == .foreground)
        #expect(request.hasGracePeriodSeconds)
        #expect(request.gracePeriodSeconds == 0)
        #expect(request.maxConcurrency == 3)
        #expect(request.targets.map(\.identity.uid) == ["uid-a", "uid-b"])
        #expect(request.targets.map(\.hiddenByFilter) == [false, true])

        let watch = try #require(await rpc.capturedWatch())
        #expect(watch.context.clusterSessionID == "session-one")
        #expect(watch.context.deadlineUnixMs == 87_400_000)
        #expect(watch.streamID == "operation-token")
        #expect(watch.generation == 1)
        #expect(watch.operationID == "operation-token")

        #expect(progress.count == 1)
        #expect(progress[0].cursor == StreamCursor(generation: 1, sequence: 1))
        #expect(progress[0].operationID == "operation-token")
        #expect(progress[0].state == .partiallySucceeded)
        #expect(progress[0].completedItems == 2)
        #expect(progress[0].totalItems == 2)
        #expect(progress[0].itemResults[0].state == .succeeded)
        #expect(progress[0].itemResults[0].newResourceVersion == "rv-2")
        #expect(progress[0].itemResults[1].state == .skipped)
        #expect(progress[0].itemResults[1].issue?.reason == "DeleteSkipped")
        #expect(progress[0].issue?.category == .conflict)
    }

    @Test("uploads large delete selections through bounded streaming RPC")
    func streamsLargeDeleteSelection() async throws {
        let rpc = FakeOperationRPC()
        let provider = deterministicProvider(rpc: rpc)
        let targets = (0..<513).map { index in
            ResourceDeleteTarget(identity: Self.identity(
                name: "api-\(index)",
                uid: ResourceUID("uid-\(index)")
            ))
        }

        let stream = try await provider.deleteResources(
            targets: targets,
            options: ResourceDeleteOptions(maxConcurrency: 4)
        )
        for try await _ in stream {}

        #expect(await rpc.capturedDelete() == nil)
        let start = try #require(await rpc.capturedDeleteManyStart())
        #expect(start.context.clusterSessionID == "session-one")
        #expect(start.operationID == "operation-token")
        #expect(start.totalTargets == 513)
        #expect(start.propagationPolicy == .background)
        #expect(start.maxConcurrency == 4)
        #expect(await rpc.capturedDeleteManyChunkSize() == 128)
        #expect(
            await rpc.capturedDeleteManyTargets().map { $0.identity.uid }
                == targets.map { $0.identity.uid.rawValue }
        )
    }

    @Test("backpressures bounded progress without dropping terminal item deltas")
    func backpressuresProgressWithoutDropping() async throws {
        let events = (1...40).map { sequence in
            var event = Self.progressEvent()
            event.cursor.sequence = UInt64(sequence)
            return event
        }
        let rpc = FakeOperationRPC(events: events)
        let provider = EngineOperationProvider(
            rpc: rpc,
            unaryTimeout: .seconds(10),
            streamTimeout: .seconds(86_400),
            controlTimeout: .seconds(5),
            maximumBufferedMessages: 1,
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "operation-token" }
        )
        let stream = try await provider.deleteResources(
            targets: [
                ResourceDeleteTarget(identity: Self.identity(name: "api-a", uid: "uid-a")),
                ResourceDeleteTarget(identity: Self.identity(name: "api-b", uid: "uid-b")),
            ],
            options: ResourceDeleteOptions()
        )

        try await Task.sleep(for: .milliseconds(20))
        var sequences: [UInt64] = []
        for try await value in stream {
            sequences.append(value.cursor.sequence)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(sequences == Array(1...40).map(UInt64.init))
    }

    @Test("cancels accepted work when its progress owner disappears early")
    func cancelsUnobservedAcceptedOperation() async throws {
        let rpc = FakeOperationRPC()
        let provider = deterministicProvider(rpc: rpc)
        let stream = try await provider.scaleResource(
            identity: Self.identity(),
            replicas: 2,
            expectedResourceVersion: "rv-current"
        )
        for try await _ in stream {}

        var attempts = 0
        while await rpc.capturedCancel() == nil, attempts < 100 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        let cancellation = try #require(await rpc.capturedCancel())
        #expect(cancellation.context.clusterSessionID == "session-one")
        #expect(cancellation.operationID == "operation-token")
        #expect(!cancellation.cancelNotStartedOnly)
    }

    @Test("maps scale, rollout restart, and deterministic metadata entries")
    func mapsSingleResourceOperations() async throws {
        let rpc = FakeOperationRPC()
        let provider = deterministicProvider(rpc: rpc)
        let identity = Self.identity()

        _ = try await provider.scaleResource(
            identity: identity,
            replicas: 7,
            expectedResourceVersion: "rv-scale"
        )
        _ = try await provider.rolloutRestart(
            identity: identity,
            expectedResourceVersion: "rv-restart"
        )
        _ = try await provider.updateMetadata(
            identity: identity,
            expectedResourceVersion: "rv-metadata",
            changes: ResourceMetadataChanges(
                labels: ["team": "platform", "app": "api"],
                annotations: ["example.com/owner": "alice"],
                removeLabelKeys: ["old-label"],
                removeAnnotationKeys: ["old.example.com/note"]
            )
        )

        let scale = try #require(await rpc.capturedScale())
        #expect(scale.identity.uid == "uid-api")
        #expect(scale.replicas == 7)
        #expect(scale.expectedResourceVersion == "rv-scale")

        let restart = try #require(await rpc.capturedRestart())
        #expect(restart.identity.group == "apps")
        #expect(restart.identity.resource == "deployments")
        #expect(restart.expectedResourceVersion == "rv-restart")

        let metadata = try #require(await rpc.capturedMetadata())
        #expect(metadata.expectedResourceVersion == "rv-metadata")
        #expect(metadata.labels.map(\.key) == ["app", "team"])
        #expect(metadata.labels.map(\.value) == ["api", "platform"])
        #expect(metadata.annotations.map(\.key) == ["example.com/owner"])
        #expect(metadata.removeLabelKeys == ["old-label"])
        #expect(metadata.removeAnnotationKeys == ["old.example.com/note"])
    }

    @Test("rejects unsafe operation inputs before any mutation RPC")
    func validatesInputsLocally() async {
        let rpc = FakeOperationRPC()
        let provider = deterministicProvider(rpc: rpc)
        let first = Self.identity(name: "api", uid: "uid-api")
        var otherSession = Self.identity(name: "worker", uid: "uid-worker")
        otherSession.clusterSessionID = "session-two"

        await expectValidation {
            _ = try await provider.deleteResources(
                targets: [ResourceDeleteTarget(identity: first), ResourceDeleteTarget(identity: otherSession)],
                options: ResourceDeleteOptions()
            )
        }
        await expectValidation {
            _ = try await provider.scaleResource(
                identity: first,
                replicas: -1,
                expectedResourceVersion: "rv"
            )
        }
        await expectValidation {
            _ = try await provider.scaleResource(
                identity: first,
                replicas: 1,
                expectedResourceVersion: ""
            )
        }
        var pod = first
        pod.group = ""
        pod.resource = "pods"
        await expectValidation {
            _ = try await provider.rolloutRestart(
                identity: pod,
                expectedResourceVersion: "rv"
            )
        }
        await expectValidation {
            _ = try await provider.updateMetadata(
                identity: first,
                expectedResourceVersion: "rv",
                changes: ResourceMetadataChanges(
                    labels: ["team": "a"],
                    removeLabelKeys: ["team"]
                )
            )
        }

        #expect(await rpc.mutationCallCount() == 0)
    }

    @Test("start requires exact request and operation identities")
    func rejectsStartEnvelopeMismatch() async {
        for mode in [FakeOperationRPC.StartMode.wrongRequest, .wrongOperation] {
            let rpc = FakeOperationRPC(startMode: mode)
            let provider = deterministicProvider(rpc: rpc)
            do {
                _ = try await provider.scaleResource(
                    identity: Self.identity(),
                    replicas: 2,
                    expectedResourceVersion: "rv"
                )
                Issue.record("Expected operation start envelope mismatch")
            } catch let issue as ClusterManagerIssue {
                #expect(issue.category == .internalFailure)
                #expect(["RequestIDMismatch", "OperationIDMismatch"].contains(issue.reason))
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test("structured start failures retain safe Kubernetes metadata")
    func mapsStructuredStartFailure() async {
        let rpc = FakeOperationRPC(startMode: .structuredFailure)
        let provider = deterministicProvider(rpc: rpc)
        do {
            _ = try await provider.scaleResource(
                identity: Self.identity(),
                replicas: 2,
                expectedResourceVersion: "stale-rv"
            )
            Issue.record("Expected structured conflict")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .conflict)
            #expect(issue.reason == "ResourceVersionConflict")
            #expect(issue.httpStatusCode == 409)
            #expect(issue.operation == "scale")
            #expect(issue.safeDetails["current_resource_version"] == "rv-current")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("progress rejects cross-stream and non-target identities")
    func rejectsProgressEnvelopeMismatch() async throws {
        for mode in [FakeOperationRPC.WatchMode.wrongStream, .crossSessionItem] {
            let rpc = FakeOperationRPC(
                events: [Self.progressEvent()],
                watchMode: mode
            )
            let provider = deterministicProvider(rpc: rpc)
            let stream = try await provider.scaleResource(
                identity: Self.identity(),
                replicas: 2,
                expectedResourceVersion: "rv"
            )
            do {
                for try await _ in stream {}
                Issue.record("Expected progress envelope failure")
            } catch let issue as ClusterManagerIssue {
                #expect(issue.category == .internalFailure)
                #expect(issue.reason == "OperationProgressEnvelopeMismatch")
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test("progress rejects zero, duplicate, and out-of-order sequences")
    func rejectsNonMonotonicProgress() async throws {
        for sequences in [[0], [1, 1], [2, 1]] {
            let events = sequences.map { sequence in
                var event = Kmgr_V1_OperationEvent()
                event.cursor.sequence = UInt64(sequence)
                event.state = .running
                event.totalItems = 1
                return event
            }
            let rpc = FakeOperationRPC(events: events)
            let provider = deterministicProvider(rpc: rpc)
            let stream = try await provider.scaleResource(
                identity: Self.identity(),
                replicas: 2,
                expectedResourceVersion: "rv"
            )
            do {
                for try await _ in stream {}
                Issue.record("Expected invalid progress sequence for \(sequences)")
            } catch let issue as ClusterManagerIssue {
                #expect(issue.category == .internalFailure)
                #expect(issue.reason == "OperationProgressEnvelopeMismatch")
            }
        }
    }

    @Test("cancel maps scoped request and rejected acknowledgement")
    func mapsCancellation() async throws {
        let acceptedRPC = FakeOperationRPC()
        let accepted = deterministicProvider(rpc: acceptedRPC)
        try await accepted.cancelOperation(
            sessionID: "session-one",
            operationID: "operation-running",
            cancelNotStartedOnly: true
        )
        let request = try #require(await acceptedRPC.capturedCancel())
        #expect(request.context.clusterSessionID == "session-one")
        #expect(request.context.deadlineUnixMs == 1_005_000)
        #expect(request.operationID == "operation-running")
        #expect(request.cancelNotStartedOnly)

        let rejectedRPC = FakeOperationRPC(cancelAccepted: false)
        let rejected = deterministicProvider(rpc: rejectedRPC)
        do {
            try await rejected.cancelOperation(
                sessionID: "session-one",
                operationID: "operation-running",
                cancelNotStartedOnly: false
            )
            Issue.record("Expected rejected cancellation")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .conflict)
            #expect(issue.reason == "OperationCancellationRejected")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private func deterministicProvider(rpc: FakeOperationRPC) -> EngineOperationProvider {
        EngineOperationProvider(
            rpc: rpc,
            unaryTimeout: .seconds(10),
            streamTimeout: .seconds(86_400),
            controlTimeout: .seconds(5),
            maximumBufferedMessages: 16,
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "operation-token" }
        )
    }

    private func expectValidation(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected local validation failure")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .validation)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private static func identity(
        name: String = "api",
        uid: ResourceUID = "uid-api"
    ) -> ResourceIdentity {
        ResourceIdentity(
            clusterSessionID: "session-one",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "production",
            name: name,
            uid: uid
        )
    }

    private static func progressEvent() -> Kmgr_V1_OperationEvent {
        var first = Kmgr_V1_OperationItemResult()
        first.identity = protoIdentity(name: "api-a", uid: "uid-a")
        first.state = .succeeded
        first.newResourceVersion = "rv-2"

        var second = Kmgr_V1_OperationItemResult()
        second.identity = protoIdentity(name: "api-b", uid: "uid-b")
        second.state = .skipped
        second.error.category = .cancelled
        second.error.reason = "DeleteSkipped"
        second.error.message = "The target was skipped after cancellation."

        var event = Kmgr_V1_OperationEvent()
        event.cursor.sequence = 1
        event.state = .partiallySucceeded
        event.completedItems = 2
        event.totalItems = 2
        event.itemResults = [first, second]
        event.error.category = .conflict
        event.error.reason = "PartialFailure"
        event.error.message = "One or more resources were not deleted."
        return event
    }

    private static func protoIdentity(
        name: String,
        uid: String
    ) -> Kmgr_V1_ResourceIdentity {
        var value = Kmgr_V1_ResourceIdentity()
        value.clusterSessionID = "session-one"
        value.group = "apps"
        value.version = "v1"
        value.resource = "deployments"
        value.namespace = "production"
        value.name = name
        value.uid = uid
        return value
    }
}

private actor FakeOperationRPC: OperationRPC {
    enum StartMode {
        case accepted
        case wrongRequest
        case wrongOperation
        case structuredFailure
    }

    enum WatchMode {
        case valid
        case wrongStream
        case crossSessionItem
    }

    private let startMode: StartMode
    private let events: [Kmgr_V1_OperationEvent]
    private let watchMode: WatchMode
    private let cancelAccepted: Bool
    private var deleteRequest: Kmgr_V1_DeleteRequest?
    private var deleteManyStart: Kmgr_V1_DeleteManyStart?
    private var deleteManyTargets: [Kmgr_V1_DeleteTarget] = []
    private var deleteManyChunkSize = 0
    private var scaleRequest: Kmgr_V1_ScaleRequest?
    private var restartRequest: Kmgr_V1_RolloutRestartRequest?
    private var metadataRequest: Kmgr_V1_UpdateMetadataRequest?
    private var watchRequest: Kmgr_V1_WatchOperationRequest?
    private var cancelRequest: Kmgr_V1_CancelOperationRequest?

    init(
        startMode: StartMode = .accepted,
        events: [Kmgr_V1_OperationEvent] = [],
        watchMode: WatchMode = .valid,
        cancelAccepted: Bool = true
    ) {
        self.startMode = startMode
        self.events = events
        self.watchMode = watchMode
        self.cancelAccepted = cancelAccepted
    }

    func capturedDelete() -> Kmgr_V1_DeleteRequest? { deleteRequest }
    func capturedDeleteManyStart() -> Kmgr_V1_DeleteManyStart? { deleteManyStart }
    func capturedDeleteManyTargets() -> [Kmgr_V1_DeleteTarget] { deleteManyTargets }
    func capturedDeleteManyChunkSize() -> Int { deleteManyChunkSize }
    func capturedScale() -> Kmgr_V1_ScaleRequest? { scaleRequest }
    func capturedRestart() -> Kmgr_V1_RolloutRestartRequest? { restartRequest }
    func capturedMetadata() -> Kmgr_V1_UpdateMetadataRequest? { metadataRequest }
    func capturedWatch() -> Kmgr_V1_WatchOperationRequest? { watchRequest }
    func capturedCancel() -> Kmgr_V1_CancelOperationRequest? { cancelRequest }

    func mutationCallCount() -> Int {
        [deleteRequest != nil, deleteManyStart != nil, scaleRequest != nil, restartRequest != nil, metadataRequest != nil]
            .filter { $0 }.count
    }

    func delete(
        request: Kmgr_V1_DeleteRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        deleteRequest = request
        return startResponse(requestID: request.context.requestID, operationID: request.operationID)
    }

    func deleteMany(
        start: Kmgr_V1_DeleteManyStart,
        targets: [Kmgr_V1_DeleteTarget],
        chunkSize: Int,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        deleteManyStart = start
        deleteManyTargets = targets
        deleteManyChunkSize = chunkSize
        return startResponse(requestID: start.context.requestID, operationID: start.operationID)
    }

    func scale(
        request: Kmgr_V1_ScaleRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        scaleRequest = request
        return startResponse(requestID: request.context.requestID, operationID: request.operationID)
    }

    func rolloutRestart(
        request: Kmgr_V1_RolloutRestartRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        restartRequest = request
        return startResponse(requestID: request.context.requestID, operationID: request.operationID)
    }

    func updateMetadata(
        request: Kmgr_V1_UpdateMetadataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        metadataRequest = request
        return startResponse(requestID: request.context.requestID, operationID: request.operationID)
    }

    func watch(
        request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) async throws -> Void
    ) async throws {
        watchRequest = request
        for original in events {
            var event = original
            event.cursor.streamID = watchMode == .wrongStream
                ? "another-stream" : request.streamID
            event.cursor.generation = request.generation
            event.operationID = request.operationID
            if watchMode == .crossSessionItem, !event.itemResults.isEmpty {
                event.itemResults[0].identity.clusterSessionID = "session-two"
            }
            try await receive(event)
        }
    }

    func cancel(
        request: Kmgr_V1_CancelOperationRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        cancelRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = request.context.requestID
        response.accepted = cancelAccepted
        return response
    }

    private func startResponse(
        requestID: String,
        operationID: String
    ) -> Kmgr_V1_StartOperationResponse {
        var response = Kmgr_V1_StartOperationResponse()
        response.requestID = startMode == .wrongRequest ? "wrong-request" : requestID
        response.operationID = startMode == .wrongOperation ? "wrong-operation" : operationID
        switch startMode {
        case .structuredFailure:
            response.error.category = .conflict
            response.error.reason = "ResourceVersionConflict"
            response.error.message = "The resource changed before the mutation was applied."
            response.error.httpStatusCode = 409
            response.error.operation = "scale"
            response.error.safeDetails = ["current_resource_version": "rv-current"]
        case .accepted, .wrongRequest, .wrongOperation:
            response.accepted = true
        }
        return response
    }
}
