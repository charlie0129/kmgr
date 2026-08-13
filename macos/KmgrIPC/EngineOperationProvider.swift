import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

/// Narrow seam for verifying operation protobuf mapping without starting the
/// engine helper.
public protocol OperationRPC: Sendable {
    func delete(
        request: Kmgr_V1_DeleteRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse

    func scale(
        request: Kmgr_V1_ScaleRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse

    func rolloutRestart(
        request: Kmgr_V1_RolloutRestartRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse

    func updateMetadata(
        request: Kmgr_V1_UpdateMetadataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse

    func watch(
        request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) throws -> Void
    ) async throws

    func cancel(
        request: Kmgr_V1_CancelOperationRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement
}

public struct EngineOperationRPC: OperationRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func delete(
        request: Kmgr_V1_DeleteRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().delete(
            request,
            options: callOptions(timeout)
        )
    }

    public func scale(
        request: Kmgr_V1_ScaleRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().scale(
            request,
            options: callOptions(timeout)
        )
    }

    public func rolloutRestart(
        request: Kmgr_V1_RolloutRestartRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().rolloutRestart(
            request,
            options: callOptions(timeout)
        )
    }

    public func updateMetadata(
        request: Kmgr_V1_UpdateMetadataRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().updateMetadata(
            request,
            options: callOptions(timeout)
        )
    }

    public func watch(
        request: Kmgr_V1_WatchOperationRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) throws -> Void
    ) async throws {
        try await connection.operationClient().watchOperation(
            request,
            options: callOptions(timeout)
        ) { response in
            for try await event in response.messages {
                try receive(event)
            }
        }
    }

    public func cancel(
        request: Kmgr_V1_CancelOperationRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.operationClient().cancelOperation(
            request,
            options: callOptions(timeout)
        )
    }

    private func callOptions(_ timeout: Duration) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return options
    }
}

public struct EngineOperationProvider: ResourceOperationProviding {
    private static let maximumDeleteConcurrency: UInt32 = 16

    private let rpc: any OperationRPC
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
        maximumBufferedMessages: Int = 64
    ) {
        self.init(
            rpc: EngineOperationRPC(connection: connection),
            unaryTimeout: unaryTimeout,
            streamTimeout: streamTimeout,
            controlTimeout: controlTimeout,
            maximumBufferedMessages: maximumBufferedMessages
        )
    }

    public init(
        rpc: any OperationRPC,
        unaryTimeout: Duration = .seconds(30),
        streamTimeout: Duration = .seconds(86_400),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 64,
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

    public func deleteResources(
        targets: [ResourceDeleteTarget],
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operation = "delete resources"
        do {
            guard let first = targets.first else {
                throw Self.validationIssue(
                    reason: "MissingDeleteTargets",
                    message: "At least one resource is required for deletion.",
                    operation: operation
                )
            }
            let sessionID = first.identity.clusterSessionID
            try Self.validateIdentity(first.identity, operation: operation)
            var seen: Set<ResourceIdentity> = []
            for target in targets {
                try Self.validateIdentity(target.identity, operation: operation)
                guard target.identity.clusterSessionID == sessionID else {
                    throw Self.validationIssue(
                        reason: "MixedClusterSessions",
                        message: "A bulk deletion cannot contain resources from different cluster sessions.",
                        operation: operation
                    )
                }
                guard seen.insert(target.identity).inserted else {
                    throw Self.validationIssue(
                        reason: "DuplicateDeleteTarget",
                        message: "The delete selection contains the same resource identity more than once.",
                        operation: operation
                    )
                }
            }
            if let grace = options.gracePeriodSeconds, grace < 0 {
                throw Self.validationIssue(
                    reason: "InvalidGracePeriod",
                    message: "The deletion grace period must not be negative.",
                    operation: operation
                )
            }
            guard options.maxConcurrency <= Self.maximumDeleteConcurrency else {
                throw Self.validationIssue(
                    reason: "InvalidDeleteConcurrency",
                    message: "Delete concurrency must be between 0 and \(Self.maximumDeleteConcurrency).",
                    operation: operation
                )
            }

            let operationID = requestID()
            var request = Kmgr_V1_DeleteRequest()
            request.context = makeContext(sessionID: sessionID, timeout: unaryTimeout)
            request.operationID = operationID
            request.targets = targets.map { target in
                var result = Kmgr_V1_DeleteTarget()
                result.identity = Self.protoIdentity(target.identity)
                result.hiddenByFilter = target.hiddenByFilter
                return result
            }
            request.propagationPolicy = Self.propagation(options.propagationPolicy)
            if let grace = options.gracePeriodSeconds {
                request.gracePeriodSeconds = grace
            }
            request.maxConcurrency = options.maxConcurrency
            let response = try await rpc.delete(request: request, timeout: unaryTimeout)
            try Self.validateStart(
                response,
                requestID: request.context.requestID,
                operationID: operationID,
                operation: operation
            )
            return operationStream(
                sessionID: sessionID,
                operationID: operationID,
                expectedIdentities: Set(targets.map(\.identity))
            )
        } catch {
            throw Self.issue(error, operation: operation)
        }
    }

    public func scaleResource(
        identity: ResourceIdentity,
        replicas: Int32,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operation = "scale resource"
        do {
            try Self.validateIdentity(identity, operation: operation)
            guard replicas >= 0 else {
                throw Self.validationIssue(
                    reason: "InvalidReplicaCount",
                    message: "Replica count must not be negative.",
                    operation: operation
                )
            }
            try Self.validateResourceVersion(expectedResourceVersion, operation: operation)
            let operationID = requestID()
            var request = Kmgr_V1_ScaleRequest()
            request.context = makeContext(
                sessionID: identity.clusterSessionID,
                timeout: unaryTimeout
            )
            request.operationID = operationID
            request.identity = Self.protoIdentity(identity)
            request.replicas = replicas
            request.expectedResourceVersion = expectedResourceVersion
            let response = try await rpc.scale(request: request, timeout: unaryTimeout)
            try Self.validateStart(
                response,
                requestID: request.context.requestID,
                operationID: operationID,
                operation: operation
            )
            return operationStream(
                sessionID: identity.clusterSessionID,
                operationID: operationID,
                expectedIdentities: [identity]
            )
        } catch {
            throw Self.issue(error, operation: operation)
        }
    }

    public func rolloutRestart(
        identity: ResourceIdentity,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operation = "rollout restart"
        do {
            try Self.validateIdentity(identity, operation: operation)
            guard identity.group == "apps", identity.version == "v1",
                ["deployments", "statefulsets", "daemonsets"].contains(identity.resource)
            else {
                throw Self.validationIssue(
                    reason: "UnsupportedRestartResource",
                    message: "Rollout restart supports apps/v1 Deployments, StatefulSets, and DaemonSets.",
                    operation: operation
                )
            }
            try Self.validateResourceVersion(expectedResourceVersion, operation: operation)
            let operationID = requestID()
            var request = Kmgr_V1_RolloutRestartRequest()
            request.context = makeContext(
                sessionID: identity.clusterSessionID,
                timeout: unaryTimeout
            )
            request.operationID = operationID
            request.identity = Self.protoIdentity(identity)
            request.expectedResourceVersion = expectedResourceVersion
            let response = try await rpc.rolloutRestart(
                request: request,
                timeout: unaryTimeout
            )
            try Self.validateStart(
                response,
                requestID: request.context.requestID,
                operationID: operationID,
                operation: operation
            )
            return operationStream(
                sessionID: identity.clusterSessionID,
                operationID: operationID,
                expectedIdentities: [identity]
            )
        } catch {
            throw Self.issue(error, operation: operation)
        }
    }

    public func updateMetadata(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operation = "update resource metadata"
        do {
            try Self.validateIdentity(identity, operation: operation)
            try Self.validateResourceVersion(expectedResourceVersion, operation: operation)
            guard !changes.isEmpty else {
                throw Self.validationIssue(
                    reason: "MissingMetadataChanges",
                    message: "At least one label or annotation change is required.",
                    operation: operation
                )
            }
            try Self.validateMetadataChangeKeys(changes, operation: operation)
            let operationID = requestID()
            var request = Kmgr_V1_UpdateMetadataRequest()
            request.context = makeContext(
                sessionID: identity.clusterSessionID,
                timeout: unaryTimeout
            )
            request.operationID = operationID
            request.identity = Self.protoIdentity(identity)
            request.expectedResourceVersion = expectedResourceVersion
            request.labels = Self.mapEntries(changes.labels)
            request.annotations = Self.mapEntries(changes.annotations)
            request.removeLabelKeys = changes.removeLabelKeys
            request.removeAnnotationKeys = changes.removeAnnotationKeys
            let response = try await rpc.updateMetadata(
                request: request,
                timeout: unaryTimeout
            )
            try Self.validateStart(
                response,
                requestID: request.context.requestID,
                operationID: operationID,
                operation: operation
            )
            return operationStream(
                sessionID: identity.clusterSessionID,
                operationID: operationID,
                expectedIdentities: [identity]
            )
        } catch {
            throw Self.issue(error, operation: operation)
        }
    }

    public func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool = false
    ) async throws {
        let operation = "cancel operation"
        do {
            try Self.validateSessionID(sessionID, operation: operation)
            guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Self.validationIssue(
                    reason: "MissingOperationID",
                    message: "An operation ID is required for cancellation.",
                    operation: operation
                )
            }
            var request = Kmgr_V1_CancelOperationRequest()
            request.context = makeContext(sessionID: sessionID, timeout: controlTimeout)
            request.operationID = operationID
            request.cancelNotStartedOnly = cancelNotStartedOnly
            let response = try await rpc.cancel(request: request, timeout: controlTimeout)
            try Self.validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: operation
            )
            guard response.accepted else {
                throw ClusterManagerIssue(
                    category: .conflict,
                    reason: "OperationCancellationRejected",
                    message: "The operation was not found, belongs to another cluster session, or had already started.",
                    operation: operation
                )
            }
        } catch {
            throw Self.issue(error, operation: operation)
        }
    }

    private func operationStream(
        sessionID: String,
        operationID: String,
        expectedIdentities: Set<ResourceIdentity>
    ) -> AsyncThrowingStream<OperationProgress, Error> {
        let streamID = requestID()
        var request = Kmgr_V1_WatchOperationRequest()
        request.context = makeContext(sessionID: sessionID, timeout: streamTimeout)
        request.streamID = streamID
        request.generation = 1
        request.operationID = operationID
        let requestValue = request
        let rpc = self.rpc
        let timeout = streamTimeout
        let limit = maximumBufferedMessages

        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.watch(request: requestValue, timeout: timeout) { event in
                        guard event.cursor.streamID == streamID,
                            event.cursor.generation == requestValue.generation,
                            event.cursor.sequence > 0,
                            event.operationID == operationID,
                            event.itemResults.allSatisfy({ result in
                                result.hasIdentity && expectedIdentities.contains(
                                    Self.identity(result.identity)
                                )
                            })
                        else {
                            throw OperationBridgeError.progressEnvelopeMismatch
                        }
                        switch continuation.yield(Self.progress(event)) {
                        case .enqueued:
                            break
                        case .dropped:
                            throw OperationBridgeError.bufferExceeded(limit)
                        case .terminated:
                            throw CancellationError()
                        @unknown default:
                            throw OperationBridgeError.bufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.issue(
                            error,
                            operation: "watch operation"
                        ))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func makeContext(
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

    private static func validateStart(
        _ response: Kmgr_V1_StartOperationResponse,
        requestID: String,
        operationID: String,
        operation: String
    ) throws {
        try validateResponseID(
            response.requestID,
            expected: requestID,
            operation: operation
        )
        guard response.operationID == operationID else {
            throw validationIssue(
                reason: "OperationIDMismatch",
                message: "The engine returned a response for a different mutation operation.",
                operation: operation,
                category: .internalFailure
            )
        }
        if response.hasError {
            throw EngineClusterContextProvider.issue(from: response.error)
        }
        guard response.accepted else {
            throw validationIssue(
                reason: "OperationRejected",
                message: "The engine did not accept the mutation operation.",
                operation: operation,
                category: .conflict
            )
        }
    }

    private static func validateResponseID(
        _ responseID: String,
        expected: String,
        operation: String
    ) throws {
        guard !expected.isEmpty, responseID == expected else {
            throw validationIssue(
                reason: "RequestIDMismatch",
                message: "The engine returned a response for a different mutation request.",
                operation: operation,
                category: .internalFailure
            )
        }
    }

    private static func validateIdentity(
        _ identity: ResourceIdentity,
        operation: String
    ) throws {
        try validateSessionID(identity.clusterSessionID, operation: operation)
        guard !identity.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !identity.resource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !identity.uid.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw validationIssue(
                reason: "IncompleteResourceIdentity",
                message: "The mutation requires the resource version, resource, name, and exact Kubernetes UID.",
                operation: operation
            )
        }
    }

    private static func validateSessionID(_ value: String, operation: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationIssue(
                reason: "MissingSessionID",
                message: "A cluster session is required for the mutation.",
                operation: operation
            )
        }
    }

    private static func validateResourceVersion(
        _ value: String,
        operation: String
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationIssue(
                reason: "MissingResourceVersion",
                message: "The current resource version is required for optimistic concurrency.",
                operation: operation
            )
        }
    }

    private static func validateMetadataChangeKeys(
        _ changes: ResourceMetadataChanges,
        operation: String
    ) throws {
        let removeLabels = Set(changes.removeLabelKeys)
        let removeAnnotations = Set(changes.removeAnnotationKeys)
        guard removeLabels.count == changes.removeLabelKeys.count,
            removeAnnotations.count == changes.removeAnnotationKeys.count
        else {
            throw validationIssue(
                reason: "DuplicateMetadataRemoval",
                message: "A metadata key cannot be removed more than once.",
                operation: operation
            )
        }
        guard removeLabels.isDisjoint(with: changes.labels.keys),
            removeAnnotations.isDisjoint(with: changes.annotations.keys)
        else {
            throw validationIssue(
                reason: "ConflictingMetadataChange",
                message: "A metadata key cannot be set and removed in the same operation.",
                operation: operation
            )
        }
    }

    private static func protoIdentity(
        _ value: ResourceIdentity
    ) -> Kmgr_V1_ResourceIdentity {
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

    private static func identity(
        _ value: Kmgr_V1_ResourceIdentity
    ) -> ResourceIdentity {
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

    private static func mapEntries(
        _ values: [String: String]
    ) -> [Kmgr_V1_StringMapEntry] {
        values.keys.sorted().map { key in
            var result = Kmgr_V1_StringMapEntry()
            result.key = key
            result.value = values[key] ?? ""
            return result
        }
    }

    private static func propagation(
        _ value: DeletePropagationPolicy
    ) -> Kmgr_V1_PropagationPolicy {
        switch value {
        case .background: .background
        case .foreground: .foreground
        case .orphan: .orphan
        }
    }

    private static func progress(_ value: Kmgr_V1_OperationEvent) -> OperationProgress {
        OperationProgress(
            cursor: StreamCursor(
                generation: value.cursor.generation,
                sequence: value.cursor.sequence
            ),
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
                        ? EngineClusterContextProvider.issue(from: result.error)
                        : nil
                )
            },
            issue: value.hasError
                ? EngineClusterContextProvider.issue(from: value.error)
                : nil
        )
    }

    private static func operationState(
        _ value: Kmgr_V1_OperationState
    ) -> OperationState {
        switch value {
        case .pending, .unspecified, .UNRECOGNIZED: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .partiallySucceeded: .partiallySucceeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    // OperationItemState is intentionally introduced in ObjectDetailModels by
    // the shared-file integrator; unlike the previous mapping it preserves the
    // generated protocol's distinct `skipped` state.
    private static func itemState(
        _ value: Kmgr_V1_OperationItemState
    ) -> OperationItemState {
        switch value {
        case .pending, .unspecified, .UNRECOGNIZED: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .skipped: .skipped
        case .cancelled: .cancelled
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
            operation: operation
        )
    }

    private static func issue(
        _ error: Error,
        operation: String
    ) -> ClusterManagerIssue {
        switch error {
        case OperationBridgeError.progressEnvelopeMismatch:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "OperationProgressEnvelopeMismatch",
                message: "The engine returned progress for a different operation stream.",
                operation: operation
            )
        case OperationBridgeError.bufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "OperationProgressBufferExceeded",
                message: "Operation progress arrived faster than the UI could apply it.",
                retryable: false,
                operation: operation,
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        default:
            return EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: operation
            )
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum OperationBridgeError: Error {
    case progressEnvelopeMismatch
    case bufferExceeded(Int)
}
