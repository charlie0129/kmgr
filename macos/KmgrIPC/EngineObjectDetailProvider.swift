import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol ObjectDetailRPC: Sendable {
    func getObject(_ request: Kmgr_V1_GetObjectRequest, timeout: Duration) async throws
        -> Kmgr_V1_GetObjectResponse
    func watchObject(
        _ request: Kmgr_V1_WatchObjectRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ObjectEvent) throws -> Void
    ) async throws
    func getRelationships(
        _ request: Kmgr_V1_GetRelationshipsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetRelationshipsResponse
    func scanRelationships(
        _ request: Kmgr_V1_ScanRelationshipsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_RelationshipScanEvent) throws -> Void
    ) async throws
    func cancelRelationshipScan(
        _ request: Kmgr_V1_CancelRelationshipScanRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement
    func getData(_ request: Kmgr_V1_GetDataRequest, timeout: Duration) async throws
        -> Kmgr_V1_GetDataResponse
    func prepareYAML(_ request: Kmgr_V1_PrepareYamlEditRequest, timeout: Duration) async throws
        -> Kmgr_V1_PrepareYamlEditResponse
    func applyYAML(_ request: Kmgr_V1_ApplyYamlRequest, timeout: Duration) async throws
        -> Kmgr_V1_StartOperationResponse
    func updateData(_ request: Kmgr_V1_UpdateDataRequest, timeout: Duration) async throws
        -> Kmgr_V1_StartOperationResponse
    func watchOperation(
        _ request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) throws -> Void
    ) async throws
    func cancelOperation(
        _ request: Kmgr_V1_CancelOperationRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement
}

public struct EngineObjectDetailRPC: ObjectDetailRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) { self.connection = connection }

    public func getObject(
        _ request: Kmgr_V1_GetObjectRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetObjectResponse {
        try await connection.objectClient().getObject(request, options: callOptions(timeout))
    }

    public func watchObject(
        _ request: Kmgr_V1_WatchObjectRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ObjectEvent) throws -> Void
    ) async throws {
        try await connection.objectClient().watchObject(
            request,
            options: callOptions(timeout)
        ) { response in
            for try await event in response.messages { try receive(event) }
        }
    }

    public func getRelationships(
        _ request: Kmgr_V1_GetRelationshipsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetRelationshipsResponse {
        try await connection.objectClient().getRelationships(request, options: callOptions(timeout))
    }

    public func scanRelationships(
        _ request: Kmgr_V1_ScanRelationshipsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_RelationshipScanEvent) throws -> Void
    ) async throws {
        try await connection.objectClient().scanRelationships(
            request,
            options: callOptions(timeout)
        ) { response in
            for try await event in response.messages { try receive(event) }
        }
    }

    public func cancelRelationshipScan(
        _ request: Kmgr_V1_CancelRelationshipScanRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.objectClient().cancelRelationshipScan(
            request, options: callOptions(timeout)
        )
    }

    public func getData(
        _ request: Kmgr_V1_GetDataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_GetDataResponse {
        try await connection.objectClient().getData(request, options: callOptions(timeout))
    }

    public func prepareYAML(
        _ request: Kmgr_V1_PrepareYamlEditRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PrepareYamlEditResponse {
        try await connection.operationClient().prepareYamlEdit(request, options: callOptions(timeout))
    }

    public func applyYAML(
        _ request: Kmgr_V1_ApplyYamlRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().applyYaml(request, options: callOptions(timeout))
    }

    public func updateData(
        _ request: Kmgr_V1_UpdateDataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().updateData(request, options: callOptions(timeout))
    }

    public func watchOperation(
        _ request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) throws -> Void
    ) async throws {
        try await connection.operationClient().watchOperation(
            request,
            options: callOptions(timeout)
        ) { response in
            for try await event in response.messages { try receive(event) }
        }
    }

    public func cancelOperation(
        _ request: Kmgr_V1_CancelOperationRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.operationClient().cancelOperation(
            request,
            options: callOptions(timeout)
        )
    }

    private func callOptions(_ timeout: Duration) -> CallOptions {
        var result = CallOptions.defaults
        result.timeout = timeout
        result.waitForReady = false
        return result
    }
}

public struct EngineObjectDetailProvider: ObjectDetailProviding {
    private let rpc: any ObjectDetailRPC
    private let unaryTimeout: Duration
    private let streamTimeout: Duration
    private let controlTimeout: Duration
    private let maximumBufferedMessages: Int
    private let now: @Sendable () -> Date
    private let identifier: @Sendable () -> String

    public init(
        connection: EngineConnection,
        unaryTimeout: Duration = .seconds(30),
        streamTimeout: Duration = .seconds(300),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 64
    ) {
        self.init(
            rpc: EngineObjectDetailRPC(connection: connection),
            unaryTimeout: unaryTimeout,
            streamTimeout: streamTimeout,
            controlTimeout: controlTimeout,
            maximumBufferedMessages: maximumBufferedMessages
        )
    }

    public init(
        rpc: any ObjectDetailRPC,
        unaryTimeout: Duration = .seconds(30),
        streamTimeout: Duration = .seconds(300),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        precondition(maximumBufferedMessages > 0)
        self.rpc = rpc
        self.unaryTimeout = unaryTimeout
        self.streamTimeout = streamTimeout
        self.controlTimeout = controlTimeout
        self.maximumBufferedMessages = maximumBufferedMessages
        self.now = now
        self.identifier = identifier
    }

    public func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        var request = Kmgr_V1_GetObjectRequest()
        request.context = context(identity.clusterSessionID, timeout: unaryTimeout)
        request.identity = Self.protoIdentity(identity)
        request.includeYaml = true
        request.includeSummary = true
        request.includeMetrics = true
        do {
            let response = try await rpc.getObject(request, timeout: unaryTimeout)
            try Self.validate(response.requestID, expected: request.context.requestID)
            if response.hasError { throw EngineClusterContextProvider.issue(from: response.error) }
            guard !response.yamlUtf8.isEmpty else {
                throw ObjectDetailBridgeError.emptyObjectYAML
            }
            return Self.detail(response)
        } catch {
            throw Self.issue(error, operation: "get object details")
        }
    }

    public func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        let streamID = identifier()
        var request = Kmgr_V1_WatchObjectRequest()
        request.context = context(identity.clusterSessionID, timeout: streamTimeout)
        request.objectStreamID = streamID
        request.generation = 1
        request.identity = Self.protoIdentity(identity)
        request.resourceVersion = resourceVersion
        let immutableRequest = request
        let rpc = self.rpc
        let timeout = streamTimeout
        let limit = maximumBufferedMessages
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.watchObject(immutableRequest, timeout: timeout) { value in
                        guard value.cursor.streamID == streamID,
                            value.cursor.generation == immutableRequest.generation
                        else { throw ObjectDetailBridgeError.objectEnvelopeMismatch }
                        let event = Self.objectWatchEvent(value)
                        switch continuation.yield(event) {
                        case .enqueued: break
                        case .dropped:
                            throw ObjectDetailBridgeError.objectBufferExceeded(limit)
                        case .terminated: throw CancellationError()
                        @unknown default:
                            throw ObjectDetailBridgeError.objectBufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.issue(error, operation: "watch object"))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool = true
    ) async throws -> ObjectRelationships {
        var request = Kmgr_V1_GetRelationshipsRequest()
        request.context = context(identity.clusterSessionID, timeout: unaryTimeout)
        request.identity = Self.protoIdentity(identity)
        request.includeOwners = true
        request.includeChildren = includeChildren
        do {
            let response = try await rpc.getRelationships(request, timeout: unaryTimeout)
            try Self.validate(response.requestID, expected: request.context.requestID)
            if response.hasError { throw EngineClusterContextProvider.issue(from: response.error) }
            return ObjectRelationships(
                values: response.relationships.map(Self.relationship),
                childrenPotentiallyIncomplete: response.childrenPotentiallyIncomplete
            )
        } catch {
            throw Self.issue(error, operation: "get object relationships")
        }
    }

    public func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        let scanID = identifier()
        var request = Kmgr_V1_ScanRelationshipsRequest()
        request.context = context(identity.clusterSessionID, timeout: streamTimeout)
        request.scanID = scanID
        request.generation = 1
        request.identity = Self.protoIdentity(identity)
        let immutableRequest = request
        let rpc = self.rpc
        let timeout = streamTimeout
        let cancelTimeout = unaryTimeout
        let limit = maximumBufferedMessages
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let cursor = RelationshipScanCursorValidator(
                streamID: scanID,
                generation: immutableRequest.generation
            )
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.scanRelationships(immutableRequest, timeout: timeout) { value in
                        try cursor.validate(value.cursor)
                        if value.hasError {
                            throw EngineClusterContextProvider.issue(from: value.error)
                        }
                        switch continuation.yield(Self.relationshipScanMessage(value)) {
                        case .enqueued: break
                        case .dropped:
                            throw ObjectDetailBridgeError.relationshipScanBufferExceeded(limit)
                        case .terminated: throw CancellationError()
                        @unknown default:
                            throw ObjectDetailBridgeError.relationshipScanBufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.issue(error, operation: "scan relationships"))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task.detached(priority: .utility) {
                    var cancelRequest = Kmgr_V1_CancelRelationshipScanRequest()
                    cancelRequest.context = immutableRequest.context
                    cancelRequest.context.requestID = identifier()
                    cancelRequest.context.deadlineUnixMs = 0
                    cancelRequest.scanID = immutableRequest.scanID
                    cancelRequest.generation = immutableRequest.generation
                    _ = try? await rpc.cancelRelationshipScan(
                        cancelRequest,
                        timeout: cancelTimeout
                    )
                }
            }
        }
    }

    public func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {
        var request = Kmgr_V1_CancelRelationshipScanRequest()
        request.context = context(sessionID, timeout: unaryTimeout)
        request.scanID = scanID
        request.generation = generation
        _ = try? await rpc.cancelRelationshipScan(request, timeout: unaryTimeout)
    }

    public func getData(identity: ResourceIdentity) async throws -> ObjectData {
        var request = Kmgr_V1_GetDataRequest()
        request.context = context(identity.clusterSessionID, timeout: unaryTimeout)
        request.identity = Self.protoIdentity(identity)
        do {
            let response = try await rpc.getData(request, timeout: unaryTimeout)
            try Self.validate(response.requestID, expected: request.context.requestID)
            if response.hasError { throw EngineClusterContextProvider.issue(from: response.error) }
            return ObjectData(
                identity: Self.identity(response.identity),
                resourceVersion: response.resourceVersion,
                entries: response.entries.map { value in
                    ObjectDataEntry(
                        key: value.key,
                        kind: value.kind == .binary ? .binary : .text,
                        value: value.value,
                        byteSize: value.byteSize,
                        contentHash: value.contentHash
                    )
                },
                secret: response.secret
            )
        } catch {
            throw Self.issue(error, operation: "get key/value data")
        }
    }

    public func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        var request = Kmgr_V1_PrepareYamlEditRequest()
        request.context = context(identity.clusterSessionID, timeout: unaryTimeout)
        request.identity = Self.protoIdentity(identity)
        request.yamlUtf8 = yamlUTF8
        request.expectedResourceVersion = expectedResourceVersion
        request.forceFieldOwnership = forceFieldOwnership
        do {
            let response = try await rpc.prepareYAML(request, timeout: unaryTimeout)
            try Self.validate(response.requestID, expected: request.context.requestID)
            if response.hasError { throw EngineClusterContextProvider.issue(from: response.error) }
            if let error = response.validationErrors.first {
                throw EngineClusterContextProvider.issue(from: error)
            }
            return PreparedYAMLEdit(
                normalizedYAMLUTF8: response.normalizedYamlUtf8,
                currentResourceVersion: response.currentResourceVersion,
                diff: response.diff.map { value in
                    SemanticDiffEntry(
                        path: value.path,
                        beforeSummary: value.beforeSummary,
                        afterSummary: value.afterSummary,
                        severity: Self.severity(value.severity)
                    )
                }
            )
        } catch {
            throw Self.issue(error, operation: "prepare YAML edit")
        }
    }

    public func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operationID = identifier()
        var request = Kmgr_V1_ApplyYamlRequest()
        request.context = context(identity.clusterSessionID, timeout: unaryTimeout)
        request.operationID = operationID
        request.identity = Self.protoIdentity(identity)
        request.yamlUtf8 = yamlUTF8
        request.expectedResourceVersion = expectedResourceVersion
        request.fieldManager = "kmgr"
        request.forceFieldOwnership = forceFieldOwnership
        let response = try await rpc.applyYAML(request, timeout: unaryTimeout)
        try Self.validateStart(response, requestID: request.context.requestID)
        return operationStream(sessionID: identity.clusterSessionID, operationID: operationID)
    }

    public func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operationID = identifier()
        var request = Kmgr_V1_UpdateDataRequest()
        request.context = context(identity.clusterSessionID, timeout: unaryTimeout)
        request.operationID = operationID
        request.identity = Self.protoIdentity(identity)
        request.expectedResourceVersion = expectedResourceVersion
        request.mutations = mutations.map(Self.mutation)
        let response = try await rpc.updateData(request, timeout: unaryTimeout)
        try Self.validateStart(response, requestID: request.context.requestID)
        return operationStream(sessionID: identity.clusterSessionID, operationID: operationID)
    }

    private func operationStream(
        sessionID: String,
        operationID: String
    ) -> AsyncThrowingStream<OperationProgress, Error> {
        let streamID = identifier()
        var rpcRequest = Kmgr_V1_WatchOperationRequest()
        rpcRequest.context = context(sessionID, timeout: streamTimeout)
        rpcRequest.streamID = streamID
        rpcRequest.generation = 1
        rpcRequest.operationID = operationID
        let immutableRequest = rpcRequest
        let rpc = self.rpc
        let timeout = streamTimeout
        let cancellationTimeout = controlTimeout
        let limit = maximumBufferedMessages
        let now = self.now
        let identifier = self.identifier
        let lifetime = DetailOperationWatchLifetime()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.watchOperation(immutableRequest, timeout: timeout) { event in
                        guard event.cursor.streamID == streamID,
                            event.cursor.generation == immutableRequest.generation,
                            lifetime.accept(sequence: event.cursor.sequence),
                            event.operationID == operationID
                        else {
                            throw ObjectDetailBridgeError.operationEnvelopeMismatch
                        }
                        let progress = Self.progress(event)
                        if progress.state.isTerminal {
                            lifetime.markTerminal()
                        }
                        switch continuation.yield(progress) {
                        case .enqueued: break
                        case .dropped: throw ObjectDetailBridgeError.operationBufferExceeded(limit)
                        case .terminated: throw CancellationError()
                        @unknown default: throw ObjectDetailBridgeError.operationBufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.issue(error, operation: "watch operation"))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                guard lifetime.claimPrematureCancellation() else { return }
                Task.detached {
                    var request = Kmgr_V1_CancelOperationRequest()
                    request.context.requestID = identifier()
                    request.context.clusterSessionID = sessionID
                    request.context.deadlineUnixMs = Int64(
                        (now().timeIntervalSince1970 + Self.seconds(cancellationTimeout)) * 1_000
                    )
                    request.operationID = operationID
                    _ = try? await rpc.cancelOperation(request, timeout: cancellationTimeout)
                }
            }
        }
    }

    private func context(_ sessionID: String, timeout: Duration) -> Kmgr_V1_RequestContext {
        var result = Kmgr_V1_RequestContext()
        result.requestID = identifier()
        result.clusterSessionID = sessionID
        result.deadlineUnixMs = Int64((now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000)
        return result
    }

    private static func validate(_ responseID: String, expected: String) throws {
        guard responseID == expected else { throw ObjectDetailBridgeError.requestIDMismatch }
    }

    private static func validateStart(
        _ response: Kmgr_V1_StartOperationResponse,
        requestID: String
    ) throws {
        try validate(response.requestID, expected: requestID)
        if response.hasError { throw EngineClusterContextProvider.issue(from: response.error) }
        guard response.accepted else { throw ObjectDetailBridgeError.operationRejected }
    }

    private static func mutation(_ value: DataMutationKind) -> Kmgr_V1_DataMutation {
        var result = Kmgr_V1_DataMutation()
        switch value {
        case .set(let key, let kind, let bytes, let hash):
            result.type = .set
            result.key = key
            result.entryKind = kind == .binary ? .binary : .text
            result.value = bytes
            result.expectedContentHash = hash
        case .delete(let key, let hash):
            result.type = .delete
            result.key = key
            result.expectedContentHash = hash
        case .rename(let key, let newKey, let hash):
            result.type = .rename
            result.key = key
            result.newKey = newKey
            result.expectedContentHash = hash
        }
        return result
    }

    private static func progress(_ value: Kmgr_V1_OperationEvent) -> OperationProgress {
        OperationProgress(
            cursor: StreamCursor(generation: value.cursor.generation, sequence: value.cursor.sequence),
            operationID: value.operationID,
            state: operationState(value.state),
            completedItems: value.completedItems,
            totalItems: value.totalItems,
            itemResults: value.itemResults.map { result in
                OperationItemResult(
                    identity: identity(result.identity),
                    state: itemState(result.state),
                    newResourceVersion: result.newResourceVersion,
                    issue: result.hasError
                        ? EngineClusterContextProvider.issue(from: result.error) : nil
                )
            },
            issue: value.hasError ? EngineClusterContextProvider.issue(from: value.error) : nil
        )
    }

    private static func detail(_ response: Kmgr_V1_GetObjectResponse) -> ObjectDetail {
        ObjectDetail(
            identity: identity(response.identity),
            resourceVersion: response.resourceVersion,
            yamlUTF8: response.yamlUtf8,
            summaryFields: response.summaryFields.map { field in
                ObjectSummaryField(
                    sectionID: field.sectionID,
                    fieldID: field.fieldID,
                    label: field.label,
                    displayText: field.displayText,
                    tooltip: field.tooltip,
                    severity: severity(field.severity)
                )
            },
            labels: Dictionary(
                response.labels.map { ($0.key, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            annotations: Dictionary(
                response.annotations.map { ($0.key, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            metrics: response.metrics.map(usage),
            containers: response.containers.compactMap(container)
        )
    }

    private static func container(
        _ value: Kmgr_V1_PodContainerDetail
    ) -> PodContainerDetail? {
        guard !value.name.isEmpty else { return nil }
        let kind: ExecContainerKind
        switch value.kind {
        case .regular: kind = .regular
        case .init_: kind = .initContainer
        case .ephemeral: kind = .ephemeral
        case .unspecified, .UNRECOGNIZED: return nil
        }
        return PodContainerDetail(
            name: value.name,
            kind: kind,
            status: value.status,
            statusTooltip: value.statusTooltip,
            statusSeverity: severity(value.statusSeverity),
            ready: value.ready,
            restartCount: max(0, value.restartCount),
            ports: value.ports,
            metrics: value.metrics.map(usage)
        )
    }

    private static func objectWatchEvent(_ value: Kmgr_V1_ObjectEvent) -> ObjectWatchEvent {
        let cursor = StreamCursor(
            generation: value.cursor.generation,
            sequence: value.cursor.sequence
        )
        if value.hasError {
            return .failure(
                cursor: cursor,
                issue: EngineClusterContextProvider.issue(from: value.error)
            )
        }
        switch value.type {
        case .updated:
            return .updated(cursor: cursor, detail: detail(value.object))
        case .deleted:
            return .deleted(cursor: cursor, detail: detail(value.object))
        case .status, .unspecified, .UNRECOGNIZED:
            return .status(cursor: cursor, resourceVersion: value.object.resourceVersion)
        }
    }

    private static func relationshipKind(
        _ value: Kmgr_V1_RelationshipKind
    ) -> ObjectRelationshipKind {
        switch value {
        case .owner: .owner
        case .child: .child
        case .related, .unspecified, .UNRECOGNIZED: .related
        }
    }

    private static func relationship(
        _ value: Kmgr_V1_ResourceRelationship
    ) -> ObjectRelationship {
        ObjectRelationship(
            kind: relationshipKind(value.kind),
            identity: identity(value.identity),
            label: value.label,
            stale: value.stale,
            potentiallyIncomplete: value.potentiallyIncomplete
        )
    }

    private static func relationshipScanMessage(
        _ value: Kmgr_V1_RelationshipScanEvent
    ) -> RelationshipScanMessage {
        let current = value.progress.currentResource
        let currentResource = current.resource.isEmpty
            ? ""
            : ([current.group, current.version, current.resource]
                .filter { !$0.isEmpty }.joined(separator: "/"))
        return RelationshipScanMessage(
            scanID: value.cursor.streamID,
            cursor: StreamCursor(
                generation: value.cursor.generation,
                sequence: value.cursor.sequence
            ),
            relationships: value.relationships.map(relationship),
            progress: RelationshipScanProgress(
                resourcesTotal: value.progress.resourcesTotal,
                resourcesScanned: value.progress.resourcesScanned,
                objectsExamined: value.progress.objectsExamined,
                resourcesFailed: value.progress.resourcesFailed,
                currentResource: currentResource,
                complete: value.progress.complete,
                potentiallyIncomplete: value.progress.potentiallyIncomplete
            ),
            warning: value.hasWarning
                ? EngineClusterContextProvider.issue(from: value.warning) : nil
        )
    }

    private static func date(_ unixMilliseconds: Int64) -> Date? {
        guard unixMilliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1_000)
    }

    private static func operationState(_ value: Kmgr_V1_OperationState) -> OperationState {
        switch value {
        case .pending, .unspecified, .UNRECOGNIZED: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .partiallySucceeded: .partiallySucceeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    private static func itemState(_ value: Kmgr_V1_OperationItemState) -> OperationItemState {
        switch value {
        case .pending, .unspecified, .UNRECOGNIZED: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .skipped: .skipped
        case .cancelled: .cancelled
        }
    }

    private static func protoIdentity(_ value: ResourceIdentity) -> Kmgr_V1_ResourceIdentity {
        var result = Kmgr_V1_ResourceIdentity()
        result.clusterSessionID = value.clusterSessionID
        result.group = value.group
        result.version = value.version
        result.resource = value.resource
        result.namespace = value.namespace
        result.name = value.name
        result.uid = value.uid.rawValue
        return result
    }

    private static func identity(_ value: Kmgr_V1_ResourceIdentity) -> ResourceIdentity {
        ResourceIdentity(
            clusterSessionID: value.clusterSessionID,
            group: value.group,
            version: value.version,
            resource: value.resource,
            namespace: value.namespace,
            name: value.name,
            uid: ResourceUID(value.uid)
        )
    }

    private static func usage(_ value: Kmgr_V1_ResourceUsageValue) -> ResourceUsageValue {
        ResourceUsageValue(
            usage: value.usageAvailable ? value.used : nil,
            request: value.hasRequested ? value.requested : nil,
            limit: value.hasLimit ? value.limit : nil,
            capacity: value.hasCapacity ? value.capacity : nil,
            sortValue: usageSortValue(value),
            unit: value.unit,
            resourceName: value.resourceName,
            measuredAtUnixMilliseconds: value.measuredAtUnixMs == 0 ? nil : value.measuredAtUnixMs,
            provider: value.provider,
            measurementScope: value.measurementScope
        )
    }

    private static func usageSortValue(
        _ value: Kmgr_V1_ResourceUsageValue
    ) -> Double? {
        value.hasSortValue ? value.sortValue : nil
    }

    private static func severity(_ value: Kmgr_V1_CellSeverity) -> CellSeverity {
        switch value {
        case .info: .informational
        case .warning: .warning
        case .error: .critical
        case .muted: .muted
        case .normal, .unspecified, .UNRECOGNIZED: .normal
        }
    }

    private static func issue(_ error: Error, operation: String) -> ClusterManagerIssue {
        switch error {
        case ObjectDetailBridgeError.objectBufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "ObjectWatchBufferExceeded",
                message: "Object updates arrived faster than the detail page could apply them. Reopen the object to resume safely.",
                retryable: true,
                operation: operation,
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        case ObjectDetailBridgeError.operationBufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "OperationBufferExceeded",
                message: "Operation progress arrived faster than the UI could apply it.",
                operation: operation,
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        case ObjectDetailBridgeError.relationshipScanBufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "RelationshipScanBufferExceeded",
                message: "Relationship scan progress arrived faster than the detail page could apply it.",
                operation: operation,
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        case ObjectDetailBridgeError.emptyObjectYAML:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "EmptyObjectYAML",
                message: "The engine returned an empty YAML payload for a successful object request.",
                retryable: true,
                operation: operation,
                safeDetails: ["yaml_bytes": "0"]
            )
        case ObjectDetailBridgeError.requestIDMismatch,
            ObjectDetailBridgeError.objectEnvelopeMismatch,
            ObjectDetailBridgeError.operationEnvelopeMismatch,
            ObjectDetailBridgeError.relationshipScanEnvelopeMismatch:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "OperationEnvelopeMismatch",
                message: "The engine returned a response for a different request.",
                operation: operation
            )
        case ObjectDetailBridgeError.operationRejected:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "OperationRejected",
                message: "The engine did not accept the operation.",
                operation: operation
            )
        default:
            return EngineClusterContextProvider.issue(from: error, contextName: "", operation: operation)
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum ObjectDetailBridgeError: Error {
    case requestIDMismatch
    case emptyObjectYAML
    case objectEnvelopeMismatch
    case objectBufferExceeded(Int)
    case operationRejected
    case operationEnvelopeMismatch
    case operationBufferExceeded(Int)
    case relationshipScanEnvelopeMismatch
    case relationshipScanBufferExceeded(Int)
}

private final class RelationshipScanCursorValidator: @unchecked Sendable {
    private let streamID: String
    private let generation: UInt64
    private let lock = NSLock()
    private var lastSequence: UInt64 = 0

    init(streamID: String, generation: UInt64) {
        self.streamID = streamID
        self.generation = generation
    }

    func validate(_ cursor: Kmgr_V1_StreamCursor) throws {
        lock.lock()
        defer { lock.unlock() }
        guard cursor.streamID == streamID,
            cursor.generation == generation,
            cursor.sequence > lastSequence
        else {
            throw ObjectDetailBridgeError.relationshipScanEnvelopeMismatch
        }
        lastSequence = cursor.sequence
    }
}

private final class DetailOperationWatchLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false
    private var cancellationClaimed = false
    private var lastSequence: UInt64 = 0

    func accept(sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > lastSequence else { return false }
        lastSequence = sequence
        return true
    }

    func markTerminal() {
        lock.lock()
        terminal = true
        lock.unlock()
    }

    func claimPrematureCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, !cancellationClaimed else { return false }
        cancellationClaimed = true
        return true
    }
}
