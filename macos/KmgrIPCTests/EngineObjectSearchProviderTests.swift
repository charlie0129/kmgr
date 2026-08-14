import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

private actor ObjectSearchRPCCapture: ObjectSearchRPC {
    var response = Kmgr_V1_SearchCachedObjectsResponse()
    var searchEvents: [Kmgr_V1_SearchObjectsEvent] = []
    var cachedRequest: Kmgr_V1_SearchCachedObjectsRequest?
    var streamedRequest: Kmgr_V1_SearchObjectsRequest?
    var overrideResponseRequestID: String?

    func searchCached(
        _ request: Kmgr_V1_SearchCachedObjectsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_SearchCachedObjectsResponse {
        cachedRequest = request
        var value = response
        value.requestID = overrideResponseRequestID ?? request.context.requestID
        return value
    }

    func search(
        _ request: Kmgr_V1_SearchObjectsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_SearchObjectsEvent) throws -> Void
    ) async throws {
        streamedRequest = request
        for event in searchEvents { try receive(event) }
    }

    func cancel(
        _ request: Kmgr_V1_CancelSearchRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement { .init() }

    func install(_ value: Kmgr_V1_SearchCachedObjectsResponse) { response = value }
    func install(_ values: [Kmgr_V1_SearchObjectsEvent]) { searchEvents = values }
    func useResponseRequestID(_ value: String?) { overrideResponseRequestID = value }
    func request() -> Kmgr_V1_SearchCachedObjectsRequest? { cachedRequest }
    func searchRequest() -> Kmgr_V1_SearchObjectsRequest? { streamedRequest }
}

@Test func streamedObjectSearchErrorInheritsEnvelopeRevisionWhenProgressIsOmitted() async throws {
    let rpc = ObjectSearchRPCCapture()
    var event = Kmgr_V1_SearchObjectsEvent()
    event.cursor.streamID = "palette-search"
    event.cursor.generation = 4
    event.cursor.sequence = 1
    event.queryRevision = 9
    event.error.category = .authentication
    event.error.reason = "Unauthorized"
    event.error.message = "Authentication failed (401)."
    await rpc.install([event])
    let provider = EngineObjectSearchProvider(rpc: rpc)
    let request = ObjectSearchRequest(
        sessionID: "session",
        searchID: "palette-search",
        generation: 4,
        queryRevision: 9,
        resource: DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list"]
        ),
        namespaceScope: .namespace("team"),
        query: "api"
    )

    var messages: [ObjectSearchMessage] = []
    for try await message in provider.searchObjects(request: request) {
        messages.append(message)
    }

    #expect(messages.count == 1)
    let message = try #require(messages.first)
    #expect(!event.hasProgress)
    #expect(message.queryRevision == 9)
    #expect(message.progress.queryRevision == 9)
    #expect(message.issue?.category == .authentication)
    #expect(message.issue?.reason == "Unauthorized")
    #expect(message.issue?.message == "Authentication failed (401).")
    let captured = await rpc.searchRequest()
    #expect(captured?.searchID == "palette-search")
    #expect(captured?.queryRevision == 9)
}

@Test func cachedObjectSearchProviderMapsBoundedLocalQuery() async throws {
    let rpc = ObjectSearchRPCCapture()
    var response = Kmgr_V1_SearchCachedObjectsResponse()
    var result = Kmgr_V1_SearchResult()
    result.identity.clusterSessionID = "session"
    result.identity.group = "apps"
    result.identity.version = "v1"
    result.identity.resource = "deployments"
    result.identity.namespace = "team"
    result.identity.name = "api"
    result.identity.uid = "uid-api"
    result.displayText = "api"
    result.detailText = "team · Deployment"
    result.rank = 1_000
    result.stale = true
    response.results = [result]
    response.objectsExamined = 12_345
    response.examinationTruncated = true
    await rpc.install(response)
    let provider = EngineObjectSearchProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 1_000) },
        requestID: { "cached-request" }
    )

    let value = try await provider.searchCachedObjects(request: .init(
        sessionID: "session",
        namespaceScope: .namespace("team"),
        query: "api",
        resultLimit: 20,
        examinationLimit: 50_000,
        resourceFilters: [DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true
        )]
    ))

    #expect(value.results.first?.identity.uid == "uid-api")
    #expect(value.results.first?.identity.group == "apps")
    #expect(value.results.first?.stale == true)
    #expect(value.objectsExamined == 12_345)
    #expect(value.examinationTruncated)
    let request = await rpc.request()
    #expect(request?.context.requestID == "cached-request")
    #expect(request?.context.clusterSessionID == "session")
    #expect(request?.namespaceScope.namespaces == ["team"])
    #expect(request?.query == "api")
    #expect(request?.resultLimit == 20)
    #expect(request?.examinationLimit == 50_000)
    #expect(request?.resourceFilters.count == 1)
    #expect(request?.resourceFilters.first?.version == "v1")
    #expect(request?.resourceFilters.first?.resource == "pods")
    #expect(request?.resourceFilters.first?.kind == "Pod")
    #expect(request?.resourceFilters.first?.namespaced == true)
}

@Test func cachedObjectSearchProviderRejectsMismatchedEnvelope() async {
    let rpc = ObjectSearchRPCCapture()
    await rpc.useResponseRequestID("another-request")
    let provider = EngineObjectSearchProvider(
        rpc: rpc,
        requestID: { "cached-request" }
    )

    await #expect(throws: ClusterManagerIssue.self) {
        _ = try await provider.searchCachedObjects(request: .init(
            sessionID: "session",
            namespaceScope: .namespace("team"),
            query: "api"
        ))
    }
}

@Test func cachedObjectSearchProviderMapsStructuredErrors() async {
    let rpc = ObjectSearchRPCCapture()
    var response = Kmgr_V1_SearchCachedObjectsResponse()
    response.error.category = .notFound
    response.error.reason = "ClusterSessionNotFound"
    response.error.message = "The cluster session was not found."
    await rpc.install(response)
    let provider = EngineObjectSearchProvider(
        rpc: rpc,
        requestID: { "cached-request" }
    )

    do {
        _ = try await provider.searchCachedObjects(request: .init(
            sessionID: "missing",
            namespaceScope: NamespaceSelection(),
            query: "api"
        ))
        Issue.record("Expected structured cached-search error")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.category == .notFound)
        #expect(issue.reason == "ClusterSessionNotFound")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
