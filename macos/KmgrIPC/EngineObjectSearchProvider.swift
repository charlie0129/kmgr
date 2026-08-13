import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol ObjectSearchRPC: Sendable {
    func searchCached(
        _ request: Kmgr_V1_SearchCachedObjectsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_SearchCachedObjectsResponse
    func search(
        _ request: Kmgr_V1_SearchObjectsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_SearchObjectsEvent) throws -> Void
    ) async throws
    func cancel(
        _ request: Kmgr_V1_CancelSearchRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement
}

public struct EngineObjectSearchRPC: ObjectSearchRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) { self.connection = connection }

    public func searchCached(
        _ request: Kmgr_V1_SearchCachedObjectsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_SearchCachedObjectsResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return try await connection.viewClient().searchCachedObjects(request, options: options)
    }

    public func search(
        _ request: Kmgr_V1_SearchObjectsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_SearchObjectsEvent) throws -> Void
    ) async throws {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        try await connection.viewClient().searchObjects(request, options: options) { response in
            for try await event in response.messages { try receive(event) }
        }
    }

    public func cancel(
        _ request: Kmgr_V1_CancelSearchRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return try await connection.viewClient().cancelSearch(request, options: options)
    }
}

public struct EngineObjectSearchProvider: ObjectSearchProviding {
    private let rpc: any ObjectSearchRPC
    private let streamTimeout: Duration
    private let controlTimeout: Duration
    private let maximumBufferedMessages: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        streamTimeout: Duration = .seconds(120),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 32
    ) {
        self.init(
            rpc: EngineObjectSearchRPC(connection: connection),
            streamTimeout: streamTimeout,
            controlTimeout: controlTimeout,
            maximumBufferedMessages: maximumBufferedMessages
        )
    }

    public init(
        rpc: any ObjectSearchRPC,
        streamTimeout: Duration = .seconds(120),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 32,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        precondition(maximumBufferedMessages > 0)
        self.rpc = rpc
        self.streamTimeout = streamTimeout
        self.controlTimeout = controlTimeout
        self.maximumBufferedMessages = maximumBufferedMessages
        self.now = now
        self.requestID = requestID
    }

    public func searchObjects(
        request: ObjectSearchRequest
    ) -> AsyncThrowingStream<ObjectSearchMessage, Error> {
        let rpcRequest = makeRequest(request)
        let rpc = self.rpc
        let timeout = streamTimeout
        let limit = maximumBufferedMessages
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.search(rpcRequest, timeout: timeout) { event in
                        guard event.cursor.streamID == request.searchID,
                            event.queryRevision == request.queryRevision
                        else { throw ObjectSearchBridgeError.envelopeMismatch }
                        switch continuation.yield(Self.message(event)) {
                        case .enqueued: break
                        case .dropped: throw ObjectSearchBridgeError.bufferExceeded(limit)
                        case .terminated: throw CancellationError()
                        @unknown default: throw ObjectSearchBridgeError.bufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.issue(error))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func searchCachedObjects(
        request: CachedObjectSearchRequest
    ) async throws -> CachedObjectSearchResponse {
        var value = Kmgr_V1_SearchCachedObjectsRequest()
        value.context = context(request.sessionID, timeout: controlTimeout)
        value.namespaceScope.allNamespaces = request.namespaceScope.allNamespaces
        value.namespaceScope.namespaces = request.namespaceScope.namespaces
        value.query = request.query
        value.resultLimit = request.resultLimit
        value.examinationLimit = request.examinationLimit
        do {
            let response = try await rpc.searchCached(value, timeout: controlTimeout)
            guard response.requestID == value.context.requestID else {
                throw ObjectSearchBridgeError.envelopeMismatch
            }
            if response.hasError { throw EngineClusterContextProvider.issue(from: response.error) }
            return CachedObjectSearchResponse(
                results: response.results.map(Self.result),
                objectsExamined: response.objectsExamined,
                examinationTruncated: response.examinationTruncated
            )
        } catch {
            throw Self.issue(error)
        }
    }

    public func cancelSearch(
        sessionID: String,
        searchID: String,
        generation: UInt64,
        queryRevision: UInt64
    ) async {
        var request = Kmgr_V1_CancelSearchRequest()
        request.context = context(sessionID, timeout: controlTimeout)
        request.searchID = searchID
        request.generation = generation
        request.queryRevision = queryRevision
        _ = try? await rpc.cancel(request, timeout: controlTimeout)
    }

    private func makeRequest(_ value: ObjectSearchRequest) -> Kmgr_V1_SearchObjectsRequest {
        var result = Kmgr_V1_SearchObjectsRequest()
        result.context = context(value.sessionID, timeout: streamTimeout)
        result.searchID = value.searchID
        result.generation = value.generation
        result.queryRevision = value.queryRevision
        result.resource.group = value.resource.group
        result.resource.version = value.resource.version
        result.resource.resource = value.resource.resource
        result.resource.kind = value.resource.kind
        result.resource.namespaced = value.resource.namespaced
        result.namespaceScope.allNamespaces = value.namespaceScope.allNamespaces
        result.namespaceScope.namespaces = value.namespaceScope.namespaces
        result.query = value.query
        result.resultLimit = value.resultLimit
        result.allowPaginatedList = value.allowPaginatedList
        return result
    }

    private func context(_ sessionID: String, timeout: Duration) -> Kmgr_V1_RequestContext {
        var result = Kmgr_V1_RequestContext()
        result.requestID = requestID()
        result.clusterSessionID = sessionID
        result.deadlineUnixMs = Int64((now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000)
        return result
    }

    private static func message(_ value: Kmgr_V1_SearchObjectsEvent) -> ObjectSearchMessage {
        let progress = value.progress
        return ObjectSearchMessage(
            cursor: StreamCursor(generation: value.cursor.generation, sequence: value.cursor.sequence),
            queryRevision: value.queryRevision,
            results: value.results.map(Self.result),
            progress: ObjectSearchProgress(
                queryRevision: progress.queryRevision,
                objectsExamined: progress.objectsExamined,
                complete: progress.complete,
                usedDirectGet: progress.usedDirectGet,
                reusableSnapshotAvailable: progress.reusableSnapshotAvailable
            ),
            issue: value.hasError
                ? EngineClusterContextProvider.issue(from: value.error) : nil
        )
    }

    private static func result(_ item: Kmgr_V1_SearchResult) -> ObjectSearchResult {
        ObjectSearchResult(
            identity: ResourceIdentity(
                clusterSessionID: item.identity.clusterSessionID,
                group: item.identity.group,
                version: item.identity.version,
                resource: item.identity.resource,
                namespace: item.identity.namespace,
                name: item.identity.name,
                uid: ResourceUID(item.identity.uid)
            ),
            displayText: item.displayText,
            detailText: item.detailText,
            rank: item.rank,
            stale: item.stale
        )
    }

    private static func issue(_ error: Error) -> ClusterManagerIssue {
        switch error {
        case ObjectSearchBridgeError.envelopeMismatch:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "ObjectSearchEnvelopeMismatch",
                message: "The engine returned results for another palette query.",
                operation: "search objects"
            )
        case ObjectSearchBridgeError.bufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "ObjectSearchBufferExceeded",
                message: "Search results arrived faster than the palette could apply them.",
                retryable: true,
                operation: "search objects",
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        default:
            return EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "search objects"
            )
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let value = duration.components
        return TimeInterval(value.seconds)
            + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum ObjectSearchBridgeError: Error {
    case envelopeMismatch
    case bufferExceeded(Int)
}
