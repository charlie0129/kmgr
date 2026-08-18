import Foundation
import GRPCCore
import GRPCProtobuf
import KmgrCore
import KmgrProto
import OSLog

/// Narrow RPC seam used to test protobuf mapping without launching the helper.
public protocol WorkspaceRPC: Sendable {
    func discover(
        request: Kmgr_V1_DiscoverRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_DiscoverResponse

    func listNamespaces(
        request: Kmgr_V1_ListNamespacesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListNamespacesResponse

    func streamView(
        request: Kmgr_V1_OpenViewRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ViewEvent) throws -> Void
    ) async throws

    func cancelView(
        request: Kmgr_V1_CancelViewRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement

    func closeSession(
        request: Kmgr_V1_CloseSessionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement
}

public struct EngineWorkspaceRPC: WorkspaceRPC {
    private let connection: EngineConnection
    private let streamSignposter = OSSignposter(
        subsystem: PerformanceSignpostCatalog.subsystem,
        category: PerformanceSignpostCatalog.workspaceStreamCategory
    )

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func discover(
        request: Kmgr_V1_DiscoverRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_DiscoverResponse {
        try await connection.clusterClient().discover(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func listNamespaces(
        request: Kmgr_V1_ListNamespacesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListNamespacesResponse {
        try await connection.clusterClient().listNamespaces(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func streamView(
        request: Kmgr_V1_OpenViewRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ViewEvent) throws -> Void
    ) async throws {
        let client = try connection.viewClient()
        let clientRequest = ClientRequest(message: request)
        try await client.streamView(
            request: clientRequest,
            serializer: ProtobufSerializer<Kmgr_V1_OpenViewRequest>(),
            deserializer: SignpostedViewEventDeserializer(signposter: streamSignposter),
            options: callOptions(timeout: timeout)
        ) { response in
            for try await event in response.messages {
                try receive(event)
            }
        }
    }

    public func cancelView(
        request: Kmgr_V1_CancelViewRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.viewClient().cancelView(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func closeSession(
        request: Kmgr_V1_CloseSessionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.clusterClient().closeSession(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    private func callOptions(timeout: Duration) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return options
    }
}

private struct SignpostedViewEventDeserializer: MessageDeserializer {
    let signposter: OSSignposter

    func deserialize<Bytes: GRPCContiguousBytes>(
        _ serializedMessageBytes: Bytes
    ) throws -> Kmgr_V1_ViewEvent {
        let interval = signposter.beginInterval(
            PerformanceSignpostCatalog.viewEventDecode,
            "protobuf_bytes=\(serializedMessageBytes.count)"
        )
        do {
            let event = try ProtobufDeserializer<Kmgr_V1_ViewEvent>()
                .deserialize(serializedMessageBytes)
            signposter.endInterval(
                PerformanceSignpostCatalog.viewEventDecode,
                interval,
                "generation=\(event.cursor.generation) sequence=\(event.cursor.sequence)"
            )
            return event
        } catch {
            signposter.endInterval(
                PerformanceSignpostCatalog.viewEventDecode,
                interval,
                "outcome=failed"
            )
            throw error
        }
    }
}

public struct EngineWorkspaceResourceProvider: WorkspaceResourceProviding {
    private let rpc: any WorkspaceRPC
    private let unaryTimeout: Duration
    private let streamTimeout: Duration
    private let controlTimeout: Duration
    private let maximumBufferedMessages: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        unaryTimeout: Duration = .seconds(30),
        streamTimeout: Duration = .seconds(86_400),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 256
    ) {
        self.init(
            rpc: EngineWorkspaceRPC(connection: connection),
            unaryTimeout: unaryTimeout,
            streamTimeout: streamTimeout,
            controlTimeout: controlTimeout,
            maximumBufferedMessages: maximumBufferedMessages
        )
    }

    public init(
        rpc: any WorkspaceRPC,
        unaryTimeout: Duration = .seconds(30),
        streamTimeout: Duration = .seconds(86_400),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 256,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        precondition(maximumBufferedMessages > 0)
        self.rpc = rpc
        self.unaryTimeout = unaryTimeout
        self.streamTimeout = streamTimeout
        self.controlTimeout = controlTimeout
        self.maximumBufferedMessages = maximumBufferedMessages
        self.now = now
        self.requestID = requestID
    }

    public func discoverResources(
        sessionID: String,
        refresh: Bool
    ) async throws -> ResourceDiscoveryResult {
        var request = Kmgr_V1_DiscoverRequest()
        request.context = makeRequestContext(
            sessionID: sessionID,
            timeout: unaryTimeout
        )
        request.refresh = refresh

        do {
            let response = try await rpc.discover(
                request: request,
                timeout: unaryTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: "discover resources"
            )
            if response.hasError {
                throw EngineClusterContextProvider.issue(from: response.error)
            }
            let warning: ClusterManagerIssue?
            if response.hasWarning {
                warning = EngineClusterContextProvider.issue(from: response.warning)
            } else if response.potentiallyIncomplete {
                warning = ClusterManagerIssue(
                    category: .unavailable,
                    reason: "DiscoveryPartiallyFailed",
                    message: "Some Kubernetes API groups could not be discovered. The available resource list may be incomplete.",
                    retryable: true,
                    operation: "discover-resources"
                )
            } else {
                warning = nil
            }
            return ResourceDiscoveryResult(
                resources: response.resources.compactMap(Self.resource(from:)),
                revision: response.discoveryRevision,
                potentiallyIncomplete: response.potentiallyIncomplete || warning != nil,
                warning: warning
            )
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "discover resources"
            )
        }
    }

    public func listNamespaces(sessionID: String) async throws -> [String] {
        var request = Kmgr_V1_ListNamespacesRequest()
        request.context = makeRequestContext(
            sessionID: sessionID,
            timeout: unaryTimeout
        )

        do {
            let response = try await rpc.listNamespaces(
                request: request,
                timeout: unaryTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: "list namespaces"
            )
            if response.hasError {
                throw EngineClusterContextProvider.issue(from: response.error)
            }
            return response.namespaces
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "list namespaces"
            )
        }
    }

    public func streamView(
        request: ResourceViewRequest
    ) -> AsyncThrowingStream<ResourceViewMessage, Error> {
        let rpcRequest = makeOpenViewRequest(from: request)
        let rpc = self.rpc
        let timeout = streamTimeout
        let maximumBufferedMessages = maximumBufferedMessages

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedMessages)
        ) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.streamView(
                        request: rpcRequest,
                        timeout: timeout
                    ) { event in
                        let message = Self.message(
                            from: event,
                            expectedViewID: request.viewID
                        )
                        switch continuation.yield(message) {
                        case .enqueued:
                            break
                        case .dropped:
                            throw WorkspaceStreamBridgeError.bufferExceeded(
                                maximumBufferedMessages
                            )
                        case .terminated:
                            throw CancellationError()
                        @unknown default:
                            throw WorkspaceStreamBridgeError.bufferExceeded(
                                maximumBufferedMessages
                            )
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else if case WorkspaceStreamBridgeError.bufferExceeded(let limit) = error {
                        continuation.finish(throwing: ClusterManagerIssue(
                            category: .resourceExhausted,
                            reason: "WorkspaceStreamBufferExceeded",
                            message: "The resource view produced updates faster than the UI could apply them. Reopen the view to relist safely.",
                            retryable: true,
                            operation: "stream resource view",
                            safeDetails: ["buffered_message_limit": String(limit)]
                        ))
                    } else {
                        continuation.finish(throwing: EngineClusterContextProvider.issue(
                            from: error,
                            contextName: "",
                            operation: "stream resource view"
                        ))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func cancelView(
        sessionID: String,
        viewID: String,
        generation: UInt64
    ) async {
        var request = Kmgr_V1_CancelViewRequest()
        request.context = makeRequestContext(
            sessionID: sessionID,
            timeout: controlTimeout
        )
        request.viewID = viewID
        request.generation = generation
        _ = try? await rpc.cancelView(request: request, timeout: controlTimeout)
    }

    public func closeSession(sessionID: String) async {
        var request = Kmgr_V1_CloseSessionRequest()
        request.context = makeRequestContext(
            sessionID: sessionID,
            timeout: controlTimeout
        )
        // Log, exec, and port-forward windows have independent lifetimes.
        request.keepIndependentStreams = true
        _ = try? await rpc.closeSession(request: request, timeout: controlTimeout)
    }

    private func makeRequestContext(
        sessionID: String,
        timeout: Duration
    ) -> Kmgr_V1_RequestContext {
        var context = Kmgr_V1_RequestContext()
        context.requestID = requestID()
        context.clusterSessionID = sessionID
        context.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000
        )
        return context
    }

    private func makeOpenViewRequest(
        from request: ResourceViewRequest
    ) -> Kmgr_V1_OpenViewRequest {
        var rpcRequest = Kmgr_V1_OpenViewRequest()
        rpcRequest.context = makeRequestContext(
            sessionID: request.sessionID,
            timeout: streamTimeout
        )
        rpcRequest.viewID = request.viewID
        rpcRequest.generation = request.generation

        var resource = Kmgr_V1_ResourceType()
        resource.group = request.resource.group
        resource.version = request.resource.version
        resource.resource = request.resource.resource
        resource.kind = request.resource.kind
        resource.namespaced = request.resource.namespaced
        rpcRequest.spec.resource = resource
        rpcRequest.spec.namespaceScope.allNamespaces = request.allNamespaces
        rpcRequest.spec.namespaceScope.namespaces = request.namespaces
        rpcRequest.spec.filterExpression = request.filterExpression
        rpcRequest.spec.filterRevision = request.filterRevision
        rpcRequest.spec.columnIds = request.columnIDs
        rpcRequest.spec.sort = request.sort.map { descriptor in
            var result = Kmgr_V1_SortDescriptor()
            result.columnID = descriptor.columnID
            result.direction = descriptor.direction == .ascending
                ? .ascending : .descending
            result.nullsFirst = descriptor.nullsFirst
            return result
        }
        return rpcRequest
    }

    private func validateResponseID(
        _ responseID: String,
        expected: String,
        operation: String
    ) throws {
        guard responseID == expected else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "RequestIDMismatch",
                message: "The engine returned a response for a different workspace request.",
                operation: operation
            )
        }
    }

    private static func resource(
        from resource: Kmgr_V1_ApiResource
    ) -> DiscoveredResource? {
        guard resource.hasType, !resource.type.version.isEmpty,
            !resource.type.resource.isEmpty
        else { return nil }
        return DiscoveredResource(
            group: resource.type.group,
            version: resource.type.version,
            resource: resource.type.resource,
            kind: resource.type.kind,
            namespaced: resource.type.namespaced,
            verbs: Set(resource.verbs),
            shortNames: resource.shortNames,
            categories: resource.categories,
            preferredVersion: resource.preferredVersion
        )
    }

    private static func message(
        from event: Kmgr_V1_ViewEvent,
        expectedViewID: String
    ) -> ResourceViewMessage {
        let cursor = StreamCursor(
            generation: event.cursor.generation,
            sequence: event.cursor.sequence
        )
        guard event.cursor.streamID == expectedViewID else {
            return .failure(
                cursor: cursor,
                issue: ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "StreamIDMismatch",
                    message: "The engine returned an event for a different resource view.",
                    operation: "stream resource view"
                )
            )
        }

        switch event.payload {
        case .status(let status):
            return .status(cursor: cursor, status: statusValue(from: status))
        case .snapshot(let snapshot):
            return .snapshot(
                cursor: cursor,
                chunk: ResourceSnapshotChunk(
                    rows: snapshot.rows.map(row(from:)),
                    first: snapshot.firstChunk,
                    last: snapshot.lastChunk,
                    index: snapshot.chunkIndex,
                    estimatedTotalRows: snapshot.estimatedTotalRows,
                    observedOptionalResourceKeys: Set(
                        snapshot.observedOptionalResourceKeys
                    ),
                    observedOptionalResourceKeysTruncated:
                        snapshot.observedOptionalResourceKeysTruncated
                )
            )
        case .delta(let delta):
            return .delta(
                cursor: cursor,
                delta: ResourceRowDelta(
                    upserts: delta.upserts.map(row(from:)),
                    removedUIDs: Set(delta.removedUids.map { ResourceUID($0) }),
                    orderedUIDs: delta.orderedUids.map { ResourceUID($0) },
                    orderIsComplete: delta.orderIsComplete,
                    observedOptionalResourceKeys: Set(
                        delta.observedOptionalResourceKeys
                    ),
                    observedOptionalResourceKeysTruncated:
                        delta.observedOptionalResourceKeysTruncated
                )
            )
        case .error(let error):
            var issue = EngineClusterContextProvider.issue(from: error)
            if issue.operation.isEmpty {
                issue.operation = "stream resource view"
            }
            return .failure(
                cursor: cursor,
                issue: issue
            )
        case nil:
            return .failure(
                cursor: cursor,
                issue: ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "MissingViewEventPayload",
                    message: "The engine returned a resource-view event without a payload.",
                    operation: "stream resource view"
                )
            )
        }
    }

    private static func statusValue(
        from status: Kmgr_V1_ViewStatus
    ) -> ResourceViewStatus {
        let freshness: ResourceViewStatus.Freshness = switch status.freshness {
        case .loading: .loading
        case .stale: .stale
        case .resuming: .resuming
        case .relisting: .relisting
        case .watching: .watching
        case .reconnecting: .reconnecting
        case .failed: .failed
        case .complete: .complete
        case .unspecified, .UNRECOGNIZED: .failed
        }
        let synchronizedAt = status.lastSynchronizedUnixMs > 0
            ? Date(timeIntervalSince1970: Double(status.lastSynchronizedUnixMs) / 1_000)
            : nil
        return ResourceViewStatus(
            freshness: freshness,
            objectsExamined: status.objectsExamined,
            rowsVisible: status.rowsVisible,
            lastSynchronizedAt: synchronizedAt,
            fromWarmCache: status.fromWarmCache
        )
    }

    private static func row(from row: Kmgr_V1_ResourceRow) -> ResourceRow {
        ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: row.identity.clusterSessionID,
                group: row.identity.group,
                version: row.identity.version,
                resource: row.identity.resource,
                namespace: row.identity.namespace,
                name: row.identity.name,
                uid: ResourceUID(row.identity.uid)
            ),
            cells: row.cells.map(cell(from:))
        )
    }

    private static func cell(from cell: Kmgr_V1_Cell) -> Cell {
        let typedValue: CellTypedValue? = switch cell.typedValue {
        case .stringValue(let value): .string(value)
        case .numberValue(let value): .number(value)
        case .integerValue(let value): .integer(value)
        case .quantityValue(let value): .quantity(KubernetesQuantityValue(
            exact: value.exact,
            display: value.display,
            sortValue: value.sortValue
        ))
        case .timestampUnixMs(let value): .timestampUnixMilliseconds(value)
        case .usage(let value): .usage(ResourceUsageValue(
            usage: value.usageAvailable ? value.used : nil,
            request: value.hasRequested ? value.requested : nil,
            limit: value.hasLimit ? value.limit : nil,
            capacity: value.hasCapacity ? value.capacity : nil,
            sortValue: usageSortValue(value),
            unit: value.unit,
            resourceName: value.resourceName,
            measuredAtUnixMilliseconds: value.measuredAtUnixMs > 0
                ? value.measuredAtUnixMs : nil,
            provider: value.provider,
            measurementScope: value.measurementScope
        ))
        case .boolValue(let value): .boolean(value)
        case .opaqueSortValue(let value): .opaqueSortValue(value)
        case nil: nil
        }
        let severity: CellSeverity = switch cell.severity {
        case .info: .informational
        case .warning: .warning
        case .error: .critical
        case .muted: .muted
        case .unspecified, .normal, .UNRECOGNIZED: .normal
        }
        return Cell(
            columnID: cell.columnID,
            displayText: cell.displayText,
            typedValue: typedValue,
            tooltip: cell.tooltip,
            severity: severity
        )
    }

    private static func usageSortValue(
        _ value: Kmgr_V1_ResourceUsageValue
    ) -> Double? {
        value.hasSortValue ? value.sortValue : nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum WorkspaceStreamBridgeError: Error {
    case bufferExceeded(Int)
}
