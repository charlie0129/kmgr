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

    func fetchViewRange(
        request: Kmgr_V1_FetchViewRangeRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_FetchViewRangeResponse

    func applySelectionGesture(
        request: Kmgr_V1_ApplySelectionGestureRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ApplySelectionGestureResponse

    func projectSelectionRange(
        request: Kmgr_V1_ProjectSelectionRangeRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ProjectSelectionRangeResponse

    func fetchSelectionPage(
        request: Kmgr_V1_FetchSelectionPageRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_FetchSelectionPageResponse

    func updateMetricInterest(
        request: Kmgr_V1_UpdateMetricInterestRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement

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

    public func fetchViewRange(
        request: Kmgr_V1_FetchViewRangeRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_FetchViewRangeResponse {
        try await connection.viewClient().fetchViewRange(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func applySelectionGesture(
        request: Kmgr_V1_ApplySelectionGestureRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ApplySelectionGestureResponse {
        try await connection.viewClient().applySelectionGesture(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func projectSelectionRange(
        request: Kmgr_V1_ProjectSelectionRangeRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ProjectSelectionRangeResponse {
        try await connection.viewClient().projectSelectionRange(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func fetchSelectionPage(
        request: Kmgr_V1_FetchSelectionPageRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_FetchSelectionPageResponse {
        try await connection.viewClient().fetchSelectionPage(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func updateMetricInterest(
        request: Kmgr_V1_UpdateMetricInterestRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.viewClient().updateMetricInterest(
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

    public func fetchViewRange(
        request: ResourceViewRangeRequest
    ) async throws -> ResourceViewRange {
        do {
            try Self.validateRangeRequest(request)
            var rpcRequest = Kmgr_V1_FetchViewRangeRequest()
            rpcRequest.context = makeRequestContext(
                sessionID: request.sessionID,
                timeout: unaryTimeout
            )
            rpcRequest.viewID = request.viewID
            rpcRequest.generation = request.revision.generation
            rpcRequest.presentationRevision = request.revision.presentation
            rpcRequest.indexRevision = request.revision.index
            rpcRequest.startIndex = request.startIndex
            rpcRequest.length = UInt32(request.length)

            let response = try await rpc.fetchViewRange(
                request: rpcRequest,
                timeout: unaryTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: rpcRequest.context.requestID,
                operation: "fetch resource view range"
            )
            try Self.validateRangeResponse(response, for: request)
            return ResourceViewRange(
                viewID: response.viewID,
                revision: ResourceViewRevision(
                    generation: response.generation,
                    presentation: response.presentationRevision,
                    index: response.indexRevision
                ),
                startIndex: response.startIndex,
                rowsVisible: response.rowsVisible,
                rows: response.rows.map(Self.row(from:))
            )
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "fetch resource view range"
            )
        }
    }

    public func updateMetricInterest(
        request: ResourceMetricInterestRequest
    ) async throws {
        do {
            try Self.validateMetricInterest(request)
            var rpcRequest = Kmgr_V1_UpdateMetricInterestRequest()
            rpcRequest.context = makeRequestContext(
                sessionID: request.sessionID,
                timeout: controlTimeout
            )
            rpcRequest.viewID = request.viewID
            rpcRequest.generation = request.generation
            rpcRequest.indexRevision = request.indexRevision
            rpcRequest.startIndex = request.startIndex
            rpcRequest.length = UInt32(request.length)

            let response = try await rpc.updateMetricInterest(
                request: rpcRequest,
                timeout: controlTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: rpcRequest.context.requestID,
                operation: "update metric interest"
            )
            guard response.accepted else {
                throw Self.validationIssue(
                    reason: "MetricInterestRejected",
                    message: "The engine rejected the metric viewport because the resource view changed.",
                    operation: "update metric interest"
                )
            }
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "update metric interest"
            )
        }
    }

    public func applySelectionGesture(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        previousToken: String,
        gesture: ResourceSelectionGesture
    ) async throws -> ResourceSelectionState {
        do {
            try Self.validateSelectionScope(
                sessionID: sessionID,
                viewID: viewID,
                token: previousToken,
                tokenMayBeEmpty: true
            )
            try Self.validateSelectionRevision(
                generation: generation,
                indexRevision: indexRevision,
                operation: "apply resource selection gesture"
            )
            let rpcGesture = try Self.selectionGesture(from: gesture)

            var request = Kmgr_V1_ApplySelectionGestureRequest()
            request.context = makeRequestContext(
                sessionID: sessionID,
                timeout: unaryTimeout
            )
            request.viewID = viewID
            request.generation = generation
            request.indexRevision = indexRevision
            request.previousToken = previousToken
            request.gesture = rpcGesture

            let response = try await rpc.applySelectionGesture(
                request: request,
                timeout: unaryTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: "apply resource selection gesture"
            )
            let state = try Self.selectionState(from: response.selection)
            guard response.hasSelection,
                state.revision == ResourceSelectionRevision(
                    generation: generation,
                    indexRevision: indexRevision
                )
            else {
                throw Self.validationIssue(
                    reason: "SelectionRevisionMismatch",
                    message: "The engine returned selection state for a different resource-view ordering.",
                    operation: "apply resource selection gesture",
                    category: .internalFailure
                )
            }
            return state
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "apply resource selection gesture"
            )
        }
    }

    public func projectSelectionRange(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        startIndex: UInt64,
        length: Int,
        token: String
    ) async throws -> ResourceSelectionProjection {
        do {
            try Self.validateSelectionScope(
                sessionID: sessionID,
                viewID: viewID,
                token: token
            )
            try Self.validateSelectionRevision(
                generation: generation,
                indexRevision: indexRevision,
                operation: "project resource selection range"
            )
            guard (1...ResourceViewInvalidation.protocolMaximumRangeLength)
                .contains(length)
            else {
                throw Self.validationIssue(
                    reason: "InvalidSelectionProjectionRange",
                    message: "A projection length from 1 through 512 is required.",
                    operation: "project resource selection range"
                )
            }

            var request = Kmgr_V1_ProjectSelectionRangeRequest()
            request.context = makeRequestContext(
                sessionID: sessionID,
                timeout: unaryTimeout
            )
            request.viewID = viewID
            request.generation = generation
            request.indexRevision = indexRevision
            request.startIndex = startIndex
            request.length = UInt32(length)
            request.token = token

            let response = try await rpc.projectSelectionRange(
                request: request,
                timeout: unaryTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: "project resource selection range"
            )
            try Self.validateSelectionProjection(response, for: request)
            return ResourceSelectionProjection(
                viewID: response.viewID,
                revision: ResourceSelectionRevision(
                    generation: response.generation,
                    indexRevision: response.indexRevision
                ),
                startIndex: response.startIndex,
                rowsVisible: response.rowsVisible,
                state: try Self.selectionState(from: response.selection),
                selected: response.selected,
                anchorOffset: response.hasAnchorOffset
                    ? Int(response.anchorOffset) : nil
            )
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "project resource selection range"
            )
        }
    }

    public func fetchSelectionPage(
        sessionID: String,
        viewID: String,
        token: String,
        offset: UInt64,
        limit: Int
    ) async throws -> ResourceSelectionPage {
        do {
            try Self.validateSelectionScope(
                sessionID: sessionID,
                viewID: viewID,
                token: token
            )
            guard (1...ResourceSelectionPage.protocolMaximumPageSize).contains(limit)
            else {
                throw Self.validationIssue(
                    reason: "InvalidSelectionPage",
                    message: "A selection page limit from 1 through 1,024 is required.",
                    operation: "fetch resource selection page"
                )
            }

            var request = Kmgr_V1_FetchSelectionPageRequest()
            request.context = makeRequestContext(
                sessionID: sessionID,
                timeout: unaryTimeout
            )
            request.viewID = viewID
            request.token = token
            request.offset = offset
            request.limit = UInt32(limit)

            let response = try await rpc.fetchSelectionPage(
                request: request,
                timeout: unaryTimeout
            )
            try validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: "fetch resource selection page"
            )
            try Self.validateSelectionPage(response, for: request)
            return ResourceSelectionPage(
                state: try Self.selectionState(from: response.selection),
                offset: response.offset,
                items: response.items.map { item in
                    ResourceSelectionPageItem(
                        pinnedIndex: item.pinnedIndex,
                        identity: Self.identity(from: item.identity)
                    )
                },
                nextOffset: response.nextOffset,
                done: response.done
            )
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "fetch resource selection page"
            )
        }
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
        rpcRequest.stageUntilReconciled = request.stageUntilReconciled

        var resource = Kmgr_V1_ResourceType()
        resource.group = request.resource.group
        resource.version = request.resource.version
        resource.resource = request.resource.resource
        resource.kind = request.resource.kind
        resource.namespaced = request.resource.namespaced
        rpcRequest.spec.resource = resource
        rpcRequest.spec.namespaceScope.allNamespaces = request.allNamespaces
        rpcRequest.spec.namespaceScope.namespaces = request.namespaces
        rpcRequest.spec.labelSelector = request.labelSelector
        rpcRequest.spec.fieldSelector = request.fieldSelector
        rpcRequest.spec.filterExpression = request.filterExpression
        rpcRequest.spec.filterRevision = request.filterRevision
        rpcRequest.spec.columnIds = request.columnIDs
        rpcRequest.spec.columnConfigurationVersion = request.columnConfigurationVersion
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
        case .schema(let schema):
            return .schema(
                cursor: cursor,
                schema: ResourceViewSchema(
                    columns: schema.columns.map { column in
                        ColumnDefinition(
                            id: column.id,
                            title: column.title,
                            source: .server,
                            type: ColumnResultType(rawValue: column.resultType) ?? .string,
                            alignment: ColumnAlignment(rawValue: column.alignment),
                            width: column.width > 0 ? column.width : nil,
                            enabled: column.defaultVisible
                        )
                    },
                    serverTable: schema.serverTable,
                    revision: schema.revision
                )
            )
        case .status(let status):
            return .status(cursor: cursor, status: statusValue(from: status))
        case .invalidation(let invalidation):
            return .invalidation(
                cursor: cursor,
                invalidation: ResourceViewInvalidation(
                    presentationRevision: invalidation.presentationRevision,
                    indexRevision: invalidation.indexRevision,
                    rowsVisible: invalidation.rowsVisible,
                    maxRangeLength: Int(invalidation.maxRangeLength),
                    observedOptionalResourceKeys: Set(
                        invalidation.observedOptionalResourceKeys
                    ),
                    observedOptionalResourceKeysTruncated:
                        invalidation.observedOptionalResourceKeysTruncated
                )
            )
        case .reconciled(let reconciliation):
            return .reconciled(
                cursor: cursor,
                reconciliation: ResourceViewReconciliation(
                    rowsVisible: reconciliation.rowsVisible,
                    presentationRevision: reconciliation.presentationRevision,
                    indexRevision: reconciliation.indexRevision
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
            fromWarmCache: status.fromWarmCache,
            metricsReconciling: status.metricsReconciling
        )
    }

    private static func validateRangeRequest(
        _ request: ResourceViewRangeRequest
    ) throws {
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.viewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            request.revision.isValid,
            request.hasValidLength
        else {
            throw validationIssue(
                reason: "InvalidViewRange",
                message: "A session, view, nonzero revisions, and a range length from 1 through 512 are required.",
                operation: "fetch resource view range"
            )
        }
    }

    private static func validateRangeResponse(
        _ response: Kmgr_V1_FetchViewRangeResponse,
        for request: ResourceViewRangeRequest
    ) throws {
        let revisionMatches = response.generation == request.revision.generation
            && response.presentationRevision == request.revision.presentation
            && response.indexRevision == request.revision.index
        guard response.viewID == request.viewID,
            revisionMatches,
            response.startIndex == request.startIndex,
            response.startIndex <= response.rowsVisible
        else {
            throw validationIssue(
                reason: "ViewRangeRevisionMismatch",
                message: "The engine returned rows for a different resource-view presentation.",
                operation: "fetch resource view range",
                category: .internalFailure
            )
        }
        let available = response.rowsVisible - response.startIndex
        let expectedCount = min(UInt64(request.length), available)
        guard UInt64(response.rows.count) == expectedCount else {
            throw validationIssue(
                reason: "ViewRangeLengthMismatch",
                message: "The engine returned an incomplete resource-view range.",
                operation: "fetch resource view range",
                category: .internalFailure
            )
        }
    }

    private static func validateMetricInterest(
        _ request: ResourceMetricInterestRequest
    ) throws {
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.viewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            request.hasValidRange
        else {
            throw validationIssue(
                reason: "InvalidMetricInterest",
                message: "A session, view, nonzero revisions, and a viewport length from 1 through 512 are required.",
                operation: "update metric interest"
            )
        }
    }

    private static func validateSelectionScope(
        sessionID: String,
        viewID: String,
        token: String,
        tokenMayBeEmpty: Bool = false
    ) throws {
        let sessionIsValid = !sessionID.isEmpty
            && sessionID.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
        let viewIsValid = !viewID.isEmpty
            && viewID.trimmingCharacters(in: .whitespacesAndNewlines) == viewID
        let tokenIsValid = (tokenMayBeEmpty && token.isEmpty)
            || (!token.isEmpty
                && token.trimmingCharacters(in: .whitespacesAndNewlines) == token)
        guard sessionIsValid, viewIsValid, tokenIsValid else {
            throw validationIssue(
                reason: "InvalidSelectionScope",
                message: "A trimmed session, view, and selection token are required.",
                operation: "resource selection"
            )
        }
    }

    private static func validateSelectionRevision(
        generation: UInt64,
        indexRevision: UInt64,
        operation: String
    ) throws {
        guard generation > 0, indexRevision > 0 else {
            throw validationIssue(
                reason: "InvalidSelectionRevision",
                message: "Nonzero generation and index revisions are required.",
                operation: operation
            )
        }
    }

    private static func selectionGesture(
        from gesture: ResourceSelectionGesture
    ) throws -> Kmgr_V1_SelectionGesture {
        let kind: Kmgr_V1_SelectionGestureKind
        let index: UInt64
        switch gesture.kind {
        case .replace:
            kind = .replace
            index = try selectionGestureIndex(gesture)
        case .commandToggle:
            kind = .commandToggle
            index = try selectionGestureIndex(gesture)
        case .shiftExtend:
            kind = .shiftExtend
            index = try selectionGestureIndex(gesture)
        case .commandAll:
            kind = .commandAll
            index = 0
        case .clear:
            kind = .clear
            index = 0
        }

        let targetsRow = switch gesture.kind {
        case .replace, .commandToggle, .shiftExtend: true
        case .commandAll, .clear: false
        }
        let hasNumericTarget = gesture.index != nil
        let hasStableTarget = gesture.targetUID != nil
        let stableUIDsAreValid = [gesture.targetUID, gesture.anchorUID]
            .compactMap { $0?.rawValue }
            .allSatisfy {
                !$0.isEmpty
                    && $0.trimmingCharacters(in: .whitespacesAndNewlines) == $0
            }
        guard targetsRow == (hasNumericTarget || hasStableTarget),
            !(hasNumericTarget && hasStableTarget),
            gesture.kind == .shiftExtend || !gesture.additive,
            gesture.anchorUID == nil || (
                gesture.kind == .shiftExtend && hasStableTarget
            ),
            stableUIDsAreValid
        else {
            throw validationIssue(
                reason: "InvalidSelectionGesture",
                message: "Row gestures require exactly one numeric or stable target, and only Shift extension accepts an anchor or additive mode.",
                operation: "apply resource selection gesture"
            )
        }

        var result = Kmgr_V1_SelectionGesture()
        result.kind = kind
        result.index = index
        result.additive = gesture.additive
        result.targetUid = gesture.targetUID?.rawValue ?? ""
        result.anchorUid = gesture.anchorUID?.rawValue ?? ""
        return result
    }

    private static func selectionGestureIndex(
        _ gesture: ResourceSelectionGesture
    ) throws -> UInt64 {
        if let index = gesture.index { return index }
        guard gesture.targetUID != nil else {
            throw validationIssue(
                reason: "InvalidSelectionGesture",
                message: "This selection gesture requires an absolute row index.",
                operation: "apply resource selection gesture"
            )
        }
        // Stable targets are resolved by the engine against the requested
        // revision, so the protobuf's numeric field is deliberately ignored.
        return 0
    }

    private static func selectionState(
        from state: Kmgr_V1_SelectionState
    ) throws -> ResourceSelectionState {
        let revision = ResourceSelectionRevision(
            generation: state.generation,
            indexRevision: state.indexRevision
        )
        let tokenIsValid = !state.token.isEmpty
            && state.token.trimmingCharacters(in: .whitespacesAndNewlines) == state.token
        let anchor: ResourceSelectionAnchor?
        if state.hasAnchor {
            let uid = state.anchor.uid
            guard !uid.isEmpty,
                uid.trimmingCharacters(in: .whitespacesAndNewlines) == uid
            else {
                throw validationIssue(
                    reason: "InvalidSelectionState",
                    message: "The engine returned an invalid selection anchor.",
                    operation: "resource selection",
                    category: .internalFailure
                )
            }
            anchor = ResourceSelectionAnchor(
                index: state.anchor.index,
                uid: ResourceUID(uid)
            )
        } else {
            anchor = nil
        }
        guard tokenIsValid, revision.isValid, state.expiresAtUnixMs > 0 else {
            throw validationIssue(
                reason: "InvalidSelectionState",
                message: "The engine returned invalid selection token metadata.",
                operation: "resource selection",
                category: .internalFailure
            )
        }
        return ResourceSelectionState(
            token: state.token,
            revision: revision,
            selectedCount: state.selectedCount,
            anchor: anchor,
            expiresAt: Date(
                timeIntervalSince1970:
                    Double(state.expiresAtUnixMs) / 1_000
            )
        )
    }

    private static func validateSelectionProjection(
        _ response: Kmgr_V1_ProjectSelectionRangeResponse,
        for request: Kmgr_V1_ProjectSelectionRangeRequest
    ) throws {
        guard response.viewID == request.viewID,
            response.generation == request.generation,
            response.indexRevision == request.indexRevision,
            response.startIndex == request.startIndex,
            response.startIndex <= response.rowsVisible,
            response.hasSelection
        else {
            throw validationIssue(
                reason: "SelectionProjectionRevisionMismatch",
                message: "The engine returned selection membership for a different resource-view ordering.",
                operation: "project resource selection range",
                category: .internalFailure
            )
        }
        let available = response.rowsVisible - response.startIndex
        let expectedCount = min(UInt64(request.length), available)
        guard UInt64(response.selected.count) == expectedCount else {
            throw validationIssue(
                reason: "SelectionProjectionLengthMismatch",
                message: "The engine returned incomplete selection membership.",
                operation: "project resource selection range",
                category: .internalFailure
            )
        }
        let state = try selectionState(from: response.selection)
        guard state.token == request.token,
            !response.hasAnchorOffset
                || Int(response.anchorOffset) < response.selected.count
        else {
            throw validationIssue(
                reason: "InvalidSelectionProjection",
                message: "The engine returned membership for a different token or an invalid anchor offset.",
                operation: "project resource selection range",
                category: .internalFailure
            )
        }
    }

    private static func validateSelectionPage(
        _ response: Kmgr_V1_FetchSelectionPageResponse,
        for request: Kmgr_V1_FetchSelectionPageRequest
    ) throws {
        guard response.hasSelection else {
            throw validationIssue(
                reason: "InvalidSelectionPage",
                message: "The engine returned a selection page without token metadata.",
                operation: "fetch resource selection page",
                category: .internalFailure
            )
        }
        let state = try selectionState(from: response.selection)
        let (expectedNextOffset, overflow) = response.offset.addingReportingOverflow(
            UInt64(response.items.count)
        )
        guard state.token == request.token,
            response.offset == request.offset,
            response.items.count <= Int(request.limit),
            !overflow,
            response.nextOffset == expectedNextOffset,
            response.nextOffset <= state.selectedCount,
            response.done == (response.nextOffset == state.selectedCount),
            response.offset <= state.selectedCount,
            response.offset == state.selectedCount || !response.items.isEmpty
        else {
            throw validationIssue(
                reason: "InvalidSelectionPage",
                message: "The engine returned inconsistent selection page bounds.",
                operation: "fetch resource selection page",
                category: .internalFailure
            )
        }

        var previousIndex: UInt64?
        var seenUIDs: Set<String> = []
        for item in response.items {
            let identity = item.identity
            guard item.hasIdentity,
                identity.clusterSessionID == request.context.clusterSessionID,
                !identity.version.isEmpty,
                !identity.resource.isEmpty,
                !identity.name.isEmpty,
                !identity.uid.isEmpty,
                identity.uid.trimmingCharacters(in: .whitespacesAndNewlines)
                    == identity.uid,
                seenUIDs.insert(identity.uid).inserted,
                previousIndex.map({ $0 < item.pinnedIndex }) ?? true
            else {
                throw validationIssue(
                    reason: "InvalidSelectionPageIdentity",
                    message: "The engine returned an invalid or unordered selected resource identity.",
                    operation: "fetch resource selection page",
                    category: .internalFailure
                )
            }
            previousIndex = item.pinnedIndex
        }
    }

    private static func validationIssue(
        reason: String,
        message: String,
        operation: String,
        category: ClusterManagerIssue.Category = .validation
    ) -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: category,
            reason: reason,
            message: message,
            retryable: false,
            operation: operation
        )
    }

    private static func row(from row: Kmgr_V1_ResourceRow) -> ResourceRow {
        ResourceRow(
            identity: identity(from: row.identity),
            cells: row.cells.map(cell(from:))
        )
    }

    private static func identity(
        from identity: Kmgr_V1_ResourceIdentity
    ) -> ResourceIdentity {
        ResourceIdentity(
            clusterSessionID: identity.clusterSessionID,
            group: identity.group,
            version: identity.version,
            resource: identity.resource,
            namespace: identity.namespace,
            name: identity.name,
            uid: ResourceUID(identity.uid)
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
        case .terminating: .terminating
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
