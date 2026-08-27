import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

private actor ObjectDetailRPCCapture: ObjectDetailRPC {
    var object = Kmgr_V1_GetObjectResponse()
    var objectRequest: Kmgr_V1_GetObjectRequest?
    var watched: [Kmgr_V1_ObjectEvent] = []
    var relationships = Kmgr_V1_GetRelationshipsResponse()
    var relationshipScan: [Kmgr_V1_RelationshipScanEvent] = []
    var watchRequest: Kmgr_V1_WatchObjectRequest?
    var relationshipScanRequest: Kmgr_V1_ScanRelationshipsRequest?
    var relationshipCancelRequest: Kmgr_V1_CancelRelationshipScanRequest?
    var yamlPreparation = Kmgr_V1_PrepareYamlEditResponse()
    var yamlPreparationRequest: Kmgr_V1_PrepareYamlEditRequest?
    var operationCancelRequest: Kmgr_V1_CancelOperationRequest?
    var operationWatchRequest: Kmgr_V1_WatchOperationRequest?
    var operationEvents: [Kmgr_V1_OperationEvent] = []
    var blockOperationWatch = false

    func getObject(
        _ request: Kmgr_V1_GetObjectRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetObjectResponse {
        objectRequest = request
        var value = object
        value.requestID = request.context.requestID
        return value
    }

    func watchObject(
        _ request: Kmgr_V1_WatchObjectRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ObjectEvent) throws -> Void
    ) async throws {
        watchRequest = request
        for value in watched { try receive(value) }
    }

    func getRelationships(
        _ request: Kmgr_V1_GetRelationshipsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetRelationshipsResponse {
        var value = relationships
        value.requestID = request.context.requestID
        return value
    }

    func scanRelationships(
        _ request: Kmgr_V1_ScanRelationshipsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_RelationshipScanEvent) throws -> Void
    ) async throws {
        relationshipScanRequest = request
        for value in relationshipScan { try receive(value) }
    }

    func cancelRelationshipScan(
        _ request: Kmgr_V1_CancelRelationshipScanRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        relationshipCancelRequest = request
        return .init()
    }

    func getData(
        _ request: Kmgr_V1_GetDataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetDataResponse { .init() }

    func prepareYAML(
        _ request: Kmgr_V1_PrepareYamlEditRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PrepareYamlEditResponse {
        yamlPreparationRequest = request
        var value = yamlPreparation
        value.requestID = request.context.requestID
        return value
    }

    func applyYAML(
        _ request: Kmgr_V1_ApplyYamlRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        var response = Kmgr_V1_StartOperationResponse()
        response.requestID = request.context.requestID
        response.operationID = request.operationID
        response.accepted = true
        return response
    }

    func updateData(
        _ request: Kmgr_V1_UpdateDataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse { .init() }

    func watchOperation(
        _ request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) throws -> Void
    ) async throws {
        operationWatchRequest = request
        for var event in operationEvents {
            event.cursor.streamID = request.streamID
            event.cursor.generation = request.generation
            event.operationID = request.operationID
            try receive(event)
        }
        if blockOperationWatch {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func cancelOperation(
        _ request: Kmgr_V1_CancelOperationRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        operationCancelRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = request.context.requestID
        response.accepted = true
        return response
    }

    func installWatch(_ values: [Kmgr_V1_ObjectEvent]) { watched = values }
    func installObject(_ value: Kmgr_V1_GetObjectResponse) { object = value }
    func capturedObject() -> Kmgr_V1_GetObjectRequest? { objectRequest }
    func installRelationships(_ value: Kmgr_V1_GetRelationshipsResponse) {
        relationships = value
    }
    func installRelationshipScan(_ values: [Kmgr_V1_RelationshipScanEvent]) {
        relationshipScan = values
    }
    func capturedWatch() -> Kmgr_V1_WatchObjectRequest? { watchRequest }
    func capturedRelationshipScan() -> Kmgr_V1_ScanRelationshipsRequest? {
        relationshipScanRequest
    }
    func capturedRelationshipCancel() -> Kmgr_V1_CancelRelationshipScanRequest? {
        relationshipCancelRequest
    }
    func installYAMLPreparation(_ value: Kmgr_V1_PrepareYamlEditResponse) {
        yamlPreparation = value
    }
    func capturedYAMLPreparation() -> Kmgr_V1_PrepareYamlEditRequest? {
        yamlPreparationRequest
    }
    func capturedOperationCancel() -> Kmgr_V1_CancelOperationRequest? {
        operationCancelRequest
    }
    func capturedOperationWatch() -> Kmgr_V1_WatchOperationRequest? {
        operationWatchRequest
    }
    func configureOperationWatch(
        events: [Kmgr_V1_OperationEvent] = [],
        block: Bool = false
    ) {
        operationEvents = events
        blockOperationWatch = block
    }
}

@Test func objectDetailsDoNotRequestMetrics() async throws {
    let rpc = ObjectDetailRPCCapture()
    var response = Kmgr_V1_GetObjectResponse()
    response.identity = protoIdentity(name: "api", uid: "uid-api")
    response.yamlUtf8 = Data("kind: Deployment\n".utf8)
    response.podLabelSelector =
        "app=api,debug,!deprecated,track in (canary,stable),zone notin (east,west)"
    var condition = Kmgr_V1_ObjectSummaryField()
    condition.sectionID = "conditions"
    condition.fieldID = "condition:0"
    condition.label = "Ready"
    condition.displayText = "True"
    condition.timestampUnixMs = 1_755_427_785_123
    condition.timestampPresentation = .elapsedSince
    var restart = Kmgr_V1_ObjectSummaryField()
    restart.sectionID = "status"
    restart.fieldID = "lastRestartReason"
    restart.label = "Last Restart Reason"
    restart.displayText = "OOMKilled · Exit code 137"
    restart.timestampUnixMs = 1_755_428_985_000
    restart.timestampPresentation = .occurredAt
    response.summaryFields = [condition, restart]
    await rpc.installObject(response)

    let detail = try await EngineObjectDetailProvider(
        rpc: rpc, identifier: { "request" }
    ).getObject(identity: identity(name: "api", uid: "uid-api"))
    #expect(detail.yamlUTF8 == Data("kind: Deployment\n".utf8))
    #expect(
        detail.podLabelSelector
            == "app=api,debug,!deprecated,track in (canary,stable),zone notin (east,west)"
    )
    #expect(detail.summaryFields.map(\.timestamp) == [
        .elapsedSince(Date(timeIntervalSince1970: 1_755_427_785.123)),
        .occurredAt(Date(timeIntervalSince1970: 1_755_428_985)),
    ])
    let request = await rpc.capturedObject()
    #expect(request?.includeYaml == true)
    #expect(request?.includeSummary == true)
    #expect(request?.includeMetrics == false)
}

@Test func objectDetailProviderMapsTypedContainerPresentationAndMetrics() async throws {
    let rpc = ObjectDetailRPCCapture()
    var response = Kmgr_V1_GetObjectResponse()
    response.identity = protoIdentity(name: "api", uid: "uid-api")
    response.yamlUtf8 = Data("kind: Pod\n".utf8)
    var cpu = Kmgr_V1_ResourceUsageValue()
    cpu.resourceName = "cpu"
    cpu.unit = "cores"
    cpu.used = 0.42
    cpu.usageAvailable = true
    cpu.requested = 0.5
    cpu.limit = 1
    var container = Kmgr_V1_PodContainerDetail()
    container.name = "app"
    container.kind = .regular
    container.status = "Waiting: CrashLoopBackOff"
    container.statusTooltip = "State: Waiting"
    container.statusSeverity = .error
    container.restartCount = 3
    container.ports = ["http: 8080/TCP"]
    container.metrics = [cpu]
    response.containers = [container]
    await rpc.installObject(response)

    let detail = try await EngineObjectDetailProvider(
        rpc: rpc, identifier: { "request" }
    ).getPodContainerDetail(identity: identity(name: "api", uid: "uid-api"))
    let mapped = try #require(detail.containers.first)
    #expect(mapped.name == "app")
    #expect(mapped.kind == .regular)
    #expect(mapped.status == "Waiting: CrashLoopBackOff")
    #expect(mapped.statusSeverity == .critical)
    #expect(!mapped.ready)
    #expect(mapped.restartCount == 3)
    #expect(mapped.ports == ["http: 8080/TCP"])
    #expect(mapped.metric(named: "cpu")?.usage == 0.42)
    #expect(mapped.metric(named: "cpu")?.request == 0.5)
    #expect(mapped.metric(named: "cpu")?.limit == 1)
    #expect(await rpc.capturedObject()?.includeMetrics == true)
}

@Test func objectDetailProviderRejectsSuccessfulEmptyYAML() async {
    let rpc = ObjectDetailRPCCapture()
    var response = Kmgr_V1_GetObjectResponse()
    response.identity = protoIdentity(name: "api", uid: "uid-api")
    response.resourceVersion = "rv-1"
    await rpc.installObject(response)

    do {
        _ = try await EngineObjectDetailProvider(
            rpc: rpc,
            identifier: { "request" }
        ).getObject(identity: identity(name: "api", uid: "uid-api"))
        Issue.record("Expected a successful response with empty YAML to fail")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.category == .internalFailure)
        #expect(issue.reason == "EmptyObjectYAML")
        #expect(issue.safeDetails["yaml_bytes"] == "0")
    } catch {
        Issue.record("Unexpected empty YAML error: \(error)")
    }
}

@Test func objectDetailProviderMapsUIDPinnedWatchEnvelope() async throws {
    let rpc = ObjectDetailRPCCapture()
    var value = Kmgr_V1_ObjectEvent()
    value.cursor.streamID = "stream-1"
    value.cursor.generation = 1
    value.cursor.sequence = 1
    value.type = .updated
    value.object.identity = protoIdentity(name: "api", uid: "uid-api")
    value.object.resourceVersion = "rv-2"
    value.object.yamlUtf8 = Data("kind: Pod".utf8)
    await rpc.installWatch([value])
    let provider = EngineObjectDetailProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 1_000) },
        identifier: { "stream-1" }
    )

    var received: [ObjectWatchEvent] = []
    for try await event in provider.watchObject(
        identity: identity(name: "api", uid: "uid-api"),
        resourceVersion: "rv-1"
    ) { received.append(event) }

    guard case .updated(let cursor, let detail) = received.first else {
        Issue.record("Expected updated object event")
        return
    }
    #expect(cursor == StreamCursor(generation: 1, sequence: 1))
    #expect(detail.identity.uid == "uid-api")
    #expect(detail.resourceVersion == "rv-2")
    let request = await rpc.capturedWatch()
    #expect(request?.identity.uid == "uid-api")
    #expect(request?.resourceVersion == "rv-1")
    #expect(request?.context.clusterSessionID == "session")
}

@Test func objectDetailProviderMapsPreparedYAMLDiffAndTransientSecretValues() async throws {
    let rpc = ObjectDetailRPCCapture()
    var changedSecret = Kmgr_V1_SemanticDiffEntry()
    changedSecret.path = "/data/token"
    changedSecret.beforeSummary = "5 decoded bytes"
    changedSecret.afterSummary = "3 decoded bytes"
    changedSecret.severity = .warning
    changedSecret.beforeDecodedSecretValue = Data()
    changedSecret.hasBeforeDecodedSecretValue_p = true
    changedSecret.afterDecodedSecretValue = Data([0x00, 0x41, 0xff])
    changedSecret.hasAfterDecodedSecretValue_p = true
    var absentSecretValues = Kmgr_V1_SemanticDiffEntry()
    absentSecretValues.path = "/metadata/labels/app"
    absentSecretValues.beforeDecodedSecretValue = Data("ignored".utf8)
    absentSecretValues.afterDecodedSecretValue = Data("ignored".utf8)
    var response = Kmgr_V1_PrepareYamlEditResponse()
    response.normalizedYamlUtf8 = Data("kind: Secret\n".utf8)
    response.currentResourceVersion = "rv-2"
    response.diff = [changedSecret, absentSecretValues]
    response.unifiedDiffUtf8 = Data("@@ -1 +1 @@\n-old\n+new\n".utf8)
    response.unifiedDiffTruncated = true
    await rpc.installYAMLPreparation(response)

    let yaml = Data("kind: Secret\n".utf8)
    let prepared = try await EngineObjectDetailProvider(
        rpc: rpc,
        identifier: { "prepare-request" }
    ).prepareYAML(
        identity: identity(name: "credentials", uid: "secret-1"),
        yamlUTF8: yaml,
        expectedResourceVersion: "rv-1",
        forceFieldOwnership: true
    )

    #expect(prepared.normalizedYAMLUTF8 == yaml)
    #expect(prepared.currentResourceVersion == "rv-2")
    #expect(prepared.unifiedDiffUTF8 == response.unifiedDiffUtf8)
    #expect(prepared.unifiedDiffTruncated)
    #expect(prepared.diff[0].severity == .warning)
    #expect(secretData(prepared.diff[0].beforeDecodedSecretValue) == Data())
    #expect(
        secretData(prepared.diff[0].afterDecodedSecretValue)
            == Data([0x00, 0x41, 0xff])
    )
    #expect(prepared.diff[1].beforeDecodedSecretValue == nil)
    #expect(prepared.diff[1].afterDecodedSecretValue == nil)
    let request = try #require(await rpc.capturedYAMLPreparation())
    #expect(request.context.requestID == "prepare-request")
    #expect(request.identity.uid == "secret-1")
    #expect(request.yamlUtf8 == yaml)
    #expect(request.expectedResourceVersion == "rv-1")
    #expect(request.forceFieldOwnership)
}

@Test func objectDetailOperationStreamCancellationCancelsAcceptedMutation() async throws {
    let rpc = ObjectDetailRPCCapture()
    await rpc.configureOperationWatch(block: true)
    let provider = EngineObjectDetailProvider(
        rpc: rpc,
        controlTimeout: .seconds(1),
        now: { Date(timeIntervalSince1970: 1_000) },
        identifier: { "operation-token" }
    )
    let stream = try await provider.applyYAML(
        identity: identity(name: "api", uid: "uid-api"),
        yamlUTF8: Data("kind: Pod".utf8),
        expectedResourceVersion: "rv-1",
        forceFieldOwnership: false
    )
    let consumer = Task {
        for try await _ in stream {}
    }
    try await waitForObjectDetailCondition {
        await rpc.capturedOperationWatch() != nil
    }
    consumer.cancel()
    _ = await consumer.result
    try await waitForObjectDetailCondition {
        await rpc.capturedOperationCancel() != nil
    }
    let cancellation = try #require(await rpc.capturedOperationCancel())
    #expect(cancellation.context.clusterSessionID == "session")
    #expect(cancellation.operationID == "operation-token")
    #expect(!cancellation.cancelNotStartedOnly)
}

@Test func objectDetailTerminalOperationDoesNotSendCancellation() async throws {
    let rpc = ObjectDetailRPCCapture()
    var terminal = Kmgr_V1_OperationEvent()
    terminal.cursor.sequence = 1
    terminal.state = .succeeded
    terminal.completedItems = 1
    terminal.totalItems = 1
    await rpc.configureOperationWatch(events: [terminal])
    let provider = EngineObjectDetailProvider(
        rpc: rpc,
        identifier: { "terminal-token" }
    )
    let stream = try await provider.applyYAML(
        identity: identity(name: "api", uid: "uid-api"),
        yamlUTF8: Data("kind: Pod".utf8),
        expectedResourceVersion: "rv-1",
        forceFieldOwnership: false
    )
    for try await _ in stream {}
    try await Task.sleep(for: .milliseconds(30))
    #expect(await rpc.capturedOperationCancel() == nil)
}

@Test func objectDetailProviderMapsAuthoritativeOwners() async throws {
    let rpc = ObjectDetailRPCCapture()
    var relationshipResponse = Kmgr_V1_GetRelationshipsResponse()
    var owner = Kmgr_V1_ResourceRelationship()
    owner.kind = .owner
    owner.identity = protoIdentity(resource: "deployments", name: "api", uid: "deploy-1")
    owner.label = "Deployment/api"
    owner.potentiallyIncomplete = false
    owner.controller = true
    relationshipResponse.relationships = [owner]
    relationshipResponse.childrenPotentiallyIncomplete = true
    await rpc.installRelationships(relationshipResponse)

    let provider = EngineObjectDetailProvider(rpc: rpc, identifier: { "request" })
    let target = identity(name: "api-abc", uid: "pod-1")
    let relationships = try await provider.getRelationships(
        identity: target,
        includeChildren: false
    )

    #expect(relationships.values.first?.kind == .owner)
    #expect(relationships.values.first?.identity.uid == "deploy-1")
    #expect(relationships.values.first?.controller == true)
    #expect(relationships.childrenPotentiallyIncomplete)
}

@Test func objectDetailProviderMapsRelationshipScanProgressAndCoverage() async throws {
    let rpc = ObjectDetailRPCCapture()
    var event = Kmgr_V1_RelationshipScanEvent()
    event.cursor.streamID = "scan-1"
    event.cursor.generation = 1
    event.cursor.sequence = 2
    event.progress.resourcesTotal = 10
    event.progress.resourcesScanned = 4
    event.progress.objectsExamined = 1_234
    event.progress.currentResource.group = "apps"
    event.progress.currentResource.version = "v1"
    event.progress.currentResource.resource = "replicasets"
    event.progress.potentiallyIncomplete = true
    var child = Kmgr_V1_ResourceRelationship()
    child.kind = .child
    child.identity = protoIdentity(resource: "replicasets", name: "api-abc", uid: "rs-1")
    event.relationships = [child]
    await rpc.installRelationshipScan([event])
    let provider = EngineObjectDetailProvider(rpc: rpc, identifier: { "scan-1" })

    var values: [RelationshipScanMessage] = []
    for try await message in provider.scanRelationships(
        identity: identity(name: "api", uid: "deploy-1")
    ) { values.append(message) }

    #expect(values.first?.cursor.sequence == 2)
    #expect(values.first?.relationships.first?.identity.uid == "rs-1")
    #expect(values.first?.progress.currentResource == "apps/v1/replicasets")
    #expect(values.first?.progress.objectsExamined == 1_234)
    #expect(values.first?.progress.potentiallyIncomplete == true)
}

@Test func relationshipScanRejectsZeroDuplicateAndOutOfOrderSequences() async {
    for sequences in [[0], [1, 1], [2, 1]] {
        let rpc = ObjectDetailRPCCapture()
        var events: [Kmgr_V1_RelationshipScanEvent] = []
        for sequence in sequences {
            var event = Kmgr_V1_RelationshipScanEvent()
            event.cursor.streamID = "scan-ordered"
            event.cursor.generation = 1
            event.cursor.sequence = UInt64(sequence)
            events.append(event)
        }
        await rpc.installRelationshipScan(events)
        let provider = EngineObjectDetailProvider(
            rpc: rpc,
            identifier: { "scan-ordered" }
        )
        do {
            for try await _ in provider.scanRelationships(
                identity: identity(name: "api", uid: "deploy-1")
            ) {}
            Issue.record("Expected invalid relationship scan cursor for \(sequences)")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
            #expect(issue.reason == "OperationEnvelopeMismatch")
        } catch {
            Issue.record("Unexpected relationship scan error: \(error)")
        }
    }
}

@Test func relationshipScanTerminationSendsExplicitKnownIdentityCancel() async throws {
    let rpc = ObjectDetailRPCCapture()
    let provider = EngineObjectDetailProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 1_000) },
        identifier: { "scan-cancel" }
    )
    let stream = provider.scanRelationships(
        identity: identity(name: "api", uid: "deploy-1")
    )
    for try await _ in stream { break }

    for _ in 0..<100 where await rpc.capturedRelationshipCancel() == nil {
        try await Task.sleep(for: .milliseconds(2))
    }
    let started = await rpc.capturedRelationshipScan()
    let cancelled = await rpc.capturedRelationshipCancel()
    #expect(started?.scanID == "scan-cancel")
    #expect(cancelled?.scanID == "scan-cancel")
    #expect(cancelled?.generation == 1)
    #expect(cancelled?.context.clusterSessionID == "session")
}

private func identity(name: String, uid: ResourceUID) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session", group: "", version: "v1",
        resource: "pods", namespace: "apps", name: name, uid: uid
    )
}

private func waitForObjectDetailCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting for object-detail operation lifecycle")
}

private func secretData(_ value: SensitiveBytes?) -> Data? {
    value?.withUnsafeBytes { Data($0) }
}

private func protoIdentity(
    resource: String = "pods",
    name: String,
    uid: String
) -> Kmgr_V1_ResourceIdentity {
    var value = Kmgr_V1_ResourceIdentity()
    value.clusterSessionID = "session"
    value.version = "v1"
    value.resource = resource
    value.namespace = "apps"
    value.name = name
    value.uid = uid
    return value
}
