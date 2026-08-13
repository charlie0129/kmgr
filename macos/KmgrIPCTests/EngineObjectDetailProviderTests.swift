import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

private actor ObjectDetailRPCCapture: ObjectDetailRPC {
    var object = Kmgr_V1_GetObjectResponse()
    var watched: [Kmgr_V1_ObjectEvent] = []
    var events = Kmgr_V1_GetEventsResponse()
    var relationships = Kmgr_V1_GetRelationshipsResponse()
    var watchRequest: Kmgr_V1_WatchObjectRequest?

    func getObject(
        _ request: Kmgr_V1_GetObjectRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetObjectResponse {
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

    func getEvents(
        _ request: Kmgr_V1_GetEventsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetEventsResponse {
        var value = events
        value.requestID = request.context.requestID
        return value
    }

    func getRelationships(
        _ request: Kmgr_V1_GetRelationshipsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetRelationshipsResponse {
        var value = relationships
        value.requestID = request.context.requestID
        return value
    }

    func getData(
        _ request: Kmgr_V1_GetDataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetDataResponse { .init() }

    func prepareYAML(
        _ request: Kmgr_V1_PrepareYamlEditRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PrepareYamlEditResponse { .init() }

    func applyYAML(
        _ request: Kmgr_V1_ApplyYamlRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse { .init() }

    func updateData(
        _ request: Kmgr_V1_UpdateDataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse { .init() }

    func watchOperation(
        _ request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) throws -> Void
    ) async throws {}

    func installWatch(_ values: [Kmgr_V1_ObjectEvent]) { watched = values }
    func installEvents(_ value: Kmgr_V1_GetEventsResponse) { events = value }
    func installRelationships(_ value: Kmgr_V1_GetRelationshipsResponse) {
        relationships = value
    }
    func capturedWatch() -> Kmgr_V1_WatchObjectRequest? { watchRequest }
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

@Test func objectDetailProviderMapsEventsAndAuthoritativeOwners() async throws {
    let rpc = ObjectDetailRPCCapture()
    var eventResponse = Kmgr_V1_GetEventsResponse()
    var event = Kmgr_V1_KubernetesEvent()
    event.identity = protoIdentity(resource: "events", name: "scheduled", uid: "event-1")
    event.type = "Normal"
    event.reason = "Scheduled"
    event.message = "Assigned to node-a"
    event.lastObservedUnixMs = 1_500
    event.count = 2
    eventResponse.events = [event]
    await rpc.installEvents(eventResponse)

    var relationshipResponse = Kmgr_V1_GetRelationshipsResponse()
    var owner = Kmgr_V1_ResourceRelationship()
    owner.kind = .owner
    owner.identity = protoIdentity(resource: "deployments", name: "api", uid: "deploy-1")
    owner.label = "Deployment/api"
    relationshipResponse.relationships = [owner]
    await rpc.installRelationships(relationshipResponse)

    let provider = EngineObjectDetailProvider(rpc: rpc, identifier: { "request" })
    let target = identity(name: "api-abc", uid: "pod-1")
    let events = try await provider.getEvents(identity: target, limit: 100)
    let relationships = try await provider.getRelationships(
        identity: target,
        includeChildren: false
    )

    #expect(events.first?.reason == "Scheduled")
    #expect(events.first?.lastObservedAt == Date(timeIntervalSince1970: 1.5))
    #expect(relationships.first?.kind == .owner)
    #expect(relationships.first?.identity.uid == "deploy-1")
}

private func identity(name: String, uid: ResourceUID) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session", group: "", version: "v1",
        resource: "pods", namespace: "apps", name: name, uid: uid
    )
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
