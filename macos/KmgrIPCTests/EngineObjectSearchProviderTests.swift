import Foundation
import KmgrCore
@testable import KmgrIPC
import KmgrProto
import Testing

private actor ObjectSearchRPCCapture: ObjectSearchRPC {
    var response = Kmgr_V1_SearchCachedObjectsResponse()
    var cachedRequest: Kmgr_V1_SearchCachedObjectsRequest?
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
    ) async throws {}

    func cancel(
        _ request: Kmgr_V1_CancelSearchRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement { .init() }

    func install(_ value: Kmgr_V1_SearchCachedObjectsResponse) { response = value }
    func useResponseRequestID(_ value: String?) { overrideResponseRequestID = value }
    func request() -> Kmgr_V1_SearchCachedObjectsRequest? { cachedRequest }
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
        examinationLimit: 50_000
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
