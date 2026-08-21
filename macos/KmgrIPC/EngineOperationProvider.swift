import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

private enum ExpectedOperationItems: Sendable {
    case exact(Set<ResourceIdentity>)
    case aggregate(sessionID: String, gvr: GVR, totalItems: UInt32)
}

/// Narrow seam for verifying operation protobuf mapping without starting the
/// engine helper.
public protocol OperationRPC: Sendable {
    func prepareDeleteSelection(
        request: Kmgr_V1_PrepareDeleteSelectionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PrepareDeleteSelectionResponse

    func deleteSelection(
        request: Kmgr_V1_DeleteSelectionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse

    func delete(
        request: Kmgr_V1_DeleteRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse

    func deleteMany(
        start: Kmgr_V1_DeleteManyStart,
        targets: [Kmgr_V1_DeleteTarget],
        chunkSize: Int,
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
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) async throws -> Void
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

    public func prepareDeleteSelection(
        request: Kmgr_V1_PrepareDeleteSelectionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PrepareDeleteSelectionResponse {
        try await connection.operationClient().prepareDeleteSelection(
            request,
            options: callOptions(timeout)
        )
    }

    public func deleteSelection(
        request: Kmgr_V1_DeleteSelectionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        try await connection.operationClient().deleteSelection(
            request,
            options: callOptions(timeout)
        )
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

    public func deleteMany(
        start: Kmgr_V1_DeleteManyStart,
        targets: [Kmgr_V1_DeleteTarget],
        chunkSize: Int,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartOperationResponse {
        precondition(chunkSize > 0)
        var options = callOptions(timeout)
        options.waitForReady = false
        return try await connection.operationClient().deleteMany(
            options: options,
            requestProducer: { writer in
                var startMessage = Kmgr_V1_DeleteManyRequest()
                startMessage.sequence = 1
                startMessage.start = start
                try await writer.write(startMessage)

                var sequence: UInt64 = 2
                var startIndex = 0
                while startIndex < targets.count {
                    let endIndex = min(startIndex + chunkSize, targets.count)
                    var chunk = Kmgr_V1_DeleteTargetChunk()
                    chunk.startIndex = UInt32(startIndex)
                    chunk.targets = Array(targets[startIndex..<endIndex])
                    var message = Kmgr_V1_DeleteManyRequest()
                    message.sequence = sequence
                    message.targets = chunk
                    try await writer.write(message)
                    sequence += 1
                    startIndex = endIndex
                }
            }
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
        receive: @escaping @Sendable (Kmgr_V1_OperationEvent) async throws -> Void
    ) async throws {
        try await connection.operationClient().watchOperation(
            request,
            options: callOptions(timeout)
        ) { response in
            for try await event in response.messages {
                try await receive(event)
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
    private static let maximumSelectionDeletePreview = 64
    private static let maximumUnaryDeleteTargets = 512
    private static let maximumDeleteTargets = 250_000
    private static let deleteTargetChunkSize = 128

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

    public func prepareDeleteSelection(
        selection: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision,
        previewLimit: Int
    ) async throws -> ResourceSelectionDeletePreparation {
        let operation = "prepare selection deletion"
        do {
            try Self.validateSelectionDeleteReference(selection, operation: operation)
            guard currentRevision.isValid else {
                throw Self.validationIssue(
                    reason: "InvalidSelectionRevision",
                    message: "A current resource-view generation and index revision are required.",
                    operation: operation
                )
            }
            guard (1...Self.maximumSelectionDeletePreview).contains(previewLimit) else {
                throw Self.validationIssue(
                    reason: "InvalidSelectionPreviewLimit",
                    message: "Selection deletion preview must contain between 1 and \(Self.maximumSelectionDeletePreview) resources.",
                    operation: operation
                )
            }
            var request = Kmgr_V1_PrepareDeleteSelectionRequest()
            request.context = makeContext(sessionID: selection.sessionID, timeout: unaryTimeout)
            request.viewID = selection.viewID
            request.selectionToken = selection.token
            request.generation = currentRevision.generation
            request.indexRevision = currentRevision.indexRevision
            request.previewLimit = UInt32(previewLimit)
            let response = try await rpc.prepareDeleteSelection(
                request: request,
                timeout: unaryTimeout
            )
            try Self.validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: operation
            )
            if response.hasError {
                throw EngineClusterContextProvider.issue(from: response.error)
            }
            guard response.viewID == selection.viewID,
                response.selectionToken == selection.token,
                response.generation == currentRevision.generation,
                response.indexRevision == currentRevision.indexRevision,
                response.selectedCount == selection.selectedCount,
                Self.gvr(response.resource) == selection.gvr,
                response.hiddenCount <= response.selectedCount,
                response.preview.count <= previewLimit,
                response.preview.count <= Int(response.selectedCount),
                response.previewTruncated == (UInt64(response.preview.count) < response.selectedCount)
            else {
                throw Self.validationIssue(
                    reason: "SelectionConfirmationEnvelopeMismatch",
                    message: "The engine returned confirmation facts for a different selection or resource view.",
                    operation: operation,
                    category: .internalFailure
                )
            }
            let preview = try response.preview.map { target in
                guard target.hasIdentity else {
                    throw Self.validationIssue(
                        reason: "SelectionConfirmationEnvelopeMismatch",
                        message: "The engine returned a selection preview without an identity.",
                        operation: operation,
                        category: .internalFailure
                    )
                }
                let identity = Self.identity(target.identity)
                try Self.validateIdentity(identity, operation: operation)
                guard identity.clusterSessionID == selection.sessionID,
                    GVR(
                        group: identity.group,
                        version: identity.version,
                        resource: identity.resource
                    ) == selection.gvr
                else {
                    throw Self.validationIssue(
                        reason: "SelectionConfirmationEnvelopeMismatch",
                        message: "The engine returned a preview identity outside the confirmed selection scope.",
                        operation: operation,
                        category: .internalFailure
                    )
                }
                return ResourceDeleteTarget(
                    identity: identity,
                    hiddenByFilter: target.hiddenByFilter
                )
            }
            guard Set(preview.map(\.identity.uid)).count == preview.count else {
                throw Self.validationIssue(
                    reason: "SelectionConfirmationEnvelopeMismatch",
                    message: "The engine returned duplicate identities in the selection preview.",
                    operation: operation,
                    category: .internalFailure
                )
            }
            let expiresAt = Date(
                timeIntervalSince1970: TimeInterval(response.expiresAtUnixMs) / 1_000
            )
            guard response.expiresAtUnixMs > 0, expiresAt > now() else {
                throw ClusterManagerIssue(
                    category: .conflict,
                    reason: "SelectionTokenExpired",
                    message: "The selection expired. Select the resources again before deleting.",
                    operation: operation
                )
            }
            return ResourceSelectionDeletePreparation(
                selection: selection,
                currentRevision: currentRevision,
                hiddenCount: response.hiddenCount,
                expiresAt: expiresAt,
                preview: preview,
                previewTruncated: response.previewTruncated
            )
        } catch {
            throw Self.issue(error, operation: operation)
        }
    }

    public func deleteSelection(
        selection: ResourceSelectionDeleteReference,
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let operation = "delete selection"
        do {
            try Self.validateSelectionDeleteReference(selection, operation: operation)
            try Self.validateDeleteOptions(options, operation: operation)
            let operationID = requestID()
            var request = Kmgr_V1_DeleteSelectionRequest()
            request.context = makeContext(sessionID: selection.sessionID, timeout: streamTimeout)
            request.operationID = operationID
            request.viewID = selection.viewID
            request.selectionToken = selection.token
            request.selectedCount = selection.selectedCount
            request.resource = Self.protoResource(selection.gvr)
            request.propagationPolicy = Self.propagation(options.propagationPolicy)
            if let grace = options.gracePeriodSeconds {
                request.gracePeriodSeconds = grace
            }
            request.maxConcurrency = options.maxConcurrency
            let response = try await rpc.deleteSelection(request: request, timeout: unaryTimeout)
            try Self.validateStart(
                response,
                requestID: request.context.requestID,
                operationID: operationID,
                operation: operation
            )
            return operationStream(
                sessionID: selection.sessionID,
                operationID: operationID,
                expectedItems: .aggregate(
                    sessionID: selection.sessionID,
                    gvr: selection.gvr,
                    totalItems: UInt32(selection.selectedCount)
                )
            )
        } catch {
            throw Self.issue(error, operation: operation)
        }
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
            var seenUIDs: Set<ResourceUID> = []
            for target in targets {
                try Self.validateIdentity(target.identity, operation: operation)
                guard target.identity.clusterSessionID == sessionID else {
                    throw Self.validationIssue(
                        reason: "MixedClusterSessions",
                        message: "A bulk deletion cannot contain resources from different cluster sessions.",
                        operation: operation
                    )
                }
                guard seenUIDs.insert(target.identity.uid).inserted else {
                    throw Self.validationIssue(
                        reason: "DuplicateDeleteTarget",
                        message: "The delete selection contains the same resource UID more than once.",
                        operation: operation
                    )
                }
            }
            guard targets.count <= Self.maximumDeleteTargets else {
                throw Self.validationIssue(
                    reason: "TooManyDeleteTargets",
                    message: "A delete operation supports at most \(Self.maximumDeleteTargets) resources.",
                    operation: operation
                )
            }
            try Self.validateDeleteOptions(options, operation: operation)

            let operationID = requestID()
            // A large, bounded selection can legitimately take much longer
            // than the submission RPC. The accepted operation keeps this
            // application deadline after the client-stream upload completes.
            let context = makeContext(sessionID: sessionID, timeout: streamTimeout)
            let protoTargets = targets.map { target in
                var result = Kmgr_V1_DeleteTarget()
                result.identity = Self.protoIdentity(target.identity)
                result.hiddenByFilter = target.hiddenByFilter
                return result
            }
            let response: Kmgr_V1_StartOperationResponse
            if protoTargets.count <= Self.maximumUnaryDeleteTargets {
                var request = Kmgr_V1_DeleteRequest()
                request.context = context
                request.operationID = operationID
                request.targets = protoTargets
                request.propagationPolicy = Self.propagation(options.propagationPolicy)
                if let grace = options.gracePeriodSeconds {
                    request.gracePeriodSeconds = grace
                }
                request.maxConcurrency = options.maxConcurrency
                response = try await rpc.delete(request: request, timeout: unaryTimeout)
            } else {
                var start = Kmgr_V1_DeleteManyStart()
                start.context = context
                start.operationID = operationID
                start.totalTargets = UInt32(protoTargets.count)
                start.propagationPolicy = Self.propagation(options.propagationPolicy)
                if let grace = options.gracePeriodSeconds {
                    start.gracePeriodSeconds = grace
                }
                start.maxConcurrency = options.maxConcurrency
                response = try await rpc.deleteMany(
                    start: start,
                    targets: protoTargets,
                    chunkSize: Self.deleteTargetChunkSize,
                    timeout: unaryTimeout
                )
            }
            try Self.validateStart(
                response,
                requestID: context.requestID,
                operationID: operationID,
                operation: operation
            )
            return operationStream(
                sessionID: sessionID,
                operationID: operationID,
                expectedItems: .exact(Set(targets.map(\.identity)))
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
                expectedItems: .exact([identity])
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
                expectedItems: .exact([identity])
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
                expectedItems: .exact([identity])
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
        expectedItems: ExpectedOperationItems
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
        let cancellationTimeout = controlTimeout
        let limit = maximumBufferedMessages
        let now = self.now
        let requestID = self.requestID
        let lifetime = OperationWatchLifetime(expectedItems: expectedItems)

        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.watch(request: requestValue, timeout: timeout) { event in
                        guard event.cursor.streamID == streamID,
                            event.cursor.generation == requestValue.generation,
                            event.operationID == operationID,
                            Self.validateOperationItems(event, expected: expectedItems),
                            lifetime.accept(event: event)
                        else {
                            throw OperationBridgeError.progressEnvelopeMismatch
                        }
                        let progress = Self.progress(event)
                        if progress.state.isTerminal {
                            lifetime.markTerminal()
                        }
                        try await Self.yieldWithBackpressure(
                            progress,
                            to: continuation,
                            limit: limit
                        )
                    }
                    guard lifetime.hasTerminal else {
                        throw OperationBridgeError.progressEndedBeforeTerminal
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
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                guard lifetime.claimPrematureCancellation() else { return }
                Task.detached {
                    var request = Kmgr_V1_CancelOperationRequest()
                    request.context.requestID = requestID()
                    request.context.clusterSessionID = sessionID
                    request.context.deadlineUnixMs = Int64(
                        (now().timeIntervalSince1970 + Self.seconds(cancellationTimeout)) * 1_000
                    )
                    request.operationID = operationID
                    _ = try? await rpc.cancel(request: request, timeout: cancellationTimeout)
                }
            }
        }
    }

    private static func yieldWithBackpressure(
        _ value: OperationProgress,
        to continuation: AsyncThrowingStream<OperationProgress, Error>.Continuation,
        limit: Int
    ) async throws {
        while true {
            switch continuation.yield(value) {
            case .enqueued:
                return
            case .dropped:
                // AsyncThrowingStream has no producer suspension primitive.
                // Retrying a dropped newest value provides bounded backpressure
                // while preserving every exact per-item terminal result.
                try await Task.sleep(for: .milliseconds(1))
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw OperationBridgeError.bufferExceeded(limit)
            }
        }
    }

    private static func validateOperationItems(
        _ event: Kmgr_V1_OperationEvent,
        expected: ExpectedOperationItems
    ) -> Bool {
        guard specifiedOperationState(event.state),
            event.totalItems > 0,
            event.completedItems <= event.totalItems,
            event.omittedItemResults <= event.completedItems,
            !operationState(event.state).isTerminal
                || event.completedItems == event.totalItems
        else { return false }
        switch expected {
        case .exact(let identities):
            return !event.aggregateOnly
                && event.totalItems == UInt32(identities.count)
                && event.omittedItemResults == 0
                && UInt64(event.itemResults.count) <= UInt64(event.completedItems)
                && event.itemResults.allSatisfy { result in
                    result.hasIdentity
                        && terminalItemState(result.state)
                        && identities.contains(identity(result.identity))
                }
        case .aggregate(let sessionID, let gvr, let totalItems):
            guard event.aggregateOnly,
                event.totalItems == totalItems,
                UInt64(event.itemResults.count) + UInt64(event.omittedItemResults)
                    <= UInt64(event.completedItems)
            else { return false }
            return event.itemResults.allSatisfy { result in
                guard result.hasIdentity,
                    [.failed, .skipped, .cancelled].contains(result.state)
                else { return false }
                let value = identity(result.identity)
                return value.clusterSessionID == sessionID
                    && !value.name.isEmpty
                    && !value.uid.rawValue.isEmpty
                    && GVR(
                        group: value.group,
                        version: value.version,
                        resource: value.resource
                    ) == gvr
            }
        }
    }

    private static func specifiedOperationState(
        _ value: Kmgr_V1_OperationState
    ) -> Bool {
        switch value {
        case .pending, .running, .succeeded, .partiallySucceeded, .failed, .cancelled:
            return true
        case .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    private static func terminalItemState(
        _ value: Kmgr_V1_OperationItemState
    ) -> Bool {
        switch value {
        case .succeeded, .failed, .skipped, .cancelled:
            return true
        case .pending, .running, .unspecified, .UNRECOGNIZED:
            return false
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

    private static func validateSelectionDeleteReference(
        _ selection: ResourceSelectionDeleteReference,
        operation: String
    ) throws {
        try validateSessionID(selection.sessionID, operation: operation)
        guard !selection.viewID.isEmpty,
            selection.viewID.trimmingCharacters(in: .whitespacesAndNewlines) == selection.viewID,
            !selection.token.isEmpty,
            selection.token.trimmingCharacters(in: .whitespacesAndNewlines) == selection.token
        else {
            throw validationIssue(
                reason: "InvalidSelectionReference",
                message: "A canonical resource-view ID and immutable selection token are required.",
                operation: operation
            )
        }
        guard selection.selectedCount > 0,
            selection.selectedCount <= UInt64(UInt32.max)
        else {
            throw validationIssue(
                reason: "InvalidSelectionCount",
                message: "The selection count is outside the supported aggregate progress range.",
                operation: operation
            )
        }
        guard !selection.gvr.version.isEmpty,
            !selection.gvr.resource.isEmpty,
            selection.gvr.group.trimmingCharacters(in: .whitespacesAndNewlines) == selection.gvr.group,
            selection.gvr.version.trimmingCharacters(in: .whitespacesAndNewlines) == selection.gvr.version,
            selection.gvr.resource.trimmingCharacters(in: .whitespacesAndNewlines) == selection.gvr.resource
        else {
            throw validationIssue(
                reason: "InvalidSelectionResource",
                message: "The selection requires an exact canonical group, version, and resource.",
                operation: operation
            )
        }
    }

    private static func validateDeleteOptions(
        _ options: ResourceDeleteOptions,
        operation: String
    ) throws {
        if let grace = options.gracePeriodSeconds, grace < 0 {
            throw validationIssue(
                reason: "InvalidGracePeriod",
                message: "The deletion grace period must not be negative.",
                operation: operation
            )
        }
        guard options.maxConcurrency <= ResourceDeleteOptions.maximumMaxConcurrency else {
            throw validationIssue(
                reason: "InvalidDeleteConcurrency",
                message: "Delete concurrency must be between 0 and \(ResourceDeleteOptions.maximumMaxConcurrency).",
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

    private static func protoResource(_ value: GVR) -> Kmgr_V1_ResourceType {
        var result = Kmgr_V1_ResourceType()
        result.group = value.group
        result.version = value.version
        result.resource = value.resource
        return result
    }

    private static func gvr(_ value: Kmgr_V1_ResourceType) -> GVR {
        GVR(group: value.group, version: value.version, resource: value.resource)
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
            aggregateOnly: value.aggregateOnly,
            omittedItemResults: value.omittedItemResults,
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
        case OperationBridgeError.progressEndedBeforeTerminal:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "OperationProgressEndedBeforeTerminal",
                message: "The engine ended operation progress before a terminal event.",
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
    case progressEndedBeforeTerminal
    case bufferExceeded(Int)
}

private final class OperationWatchLifetime: @unchecked Sendable {
    private static let maximumAggregateDetails = 256

    private let lock = NSLock()
    private var terminal = false
    private var cancellationClaimed = false
    private var lastSequence: UInt64 = 0
    private var lastCompleted: UInt32 = 0
    private var lastOmitted: UInt32 = 0
    private var totalItems: UInt32?
    private var aggregateDetailUIDs: Set<String> = []
    private let expectedExactUIDs: Set<String>?
    private var seenExactUIDs: Set<String> = []
    private var exactSucceeded = 0
    private var exactFailed = 0
    private var exactCancelled = 0

    init(expectedItems: ExpectedOperationItems) {
        switch expectedItems {
        case .exact(let identities):
            expectedExactUIDs = Set(identities.lazy.map { $0.uid.rawValue })
        case .aggregate:
            expectedExactUIDs = nil
        }
    }

    func accept(event: Kmgr_V1_OperationEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal,
            event.cursor.sequence > lastSequence,
            event.completedItems >= lastCompleted,
            event.omittedItemResults >= lastOmitted,
            totalItems == nil || totalItems == event.totalItems
        else { return false }
        var exactEventUIDs: Set<String> = []
        var eventSucceeded = 0
        var eventFailed = 0
        var eventCancelled = 0
        if let expectedExactUIDs {
            exactEventUIDs.reserveCapacity(event.itemResults.count)
            for result in event.itemResults {
                let uid = result.identity.uid
                guard expectedExactUIDs.contains(uid),
                    !seenExactUIDs.contains(uid),
                    exactEventUIDs.insert(uid).inserted
                else { return false }
                switch result.state {
                case .succeeded:
                    eventSucceeded += 1
                case .failed:
                    eventFailed += 1
                case .skipped, .cancelled:
                    eventCancelled += 1
                case .pending, .running, .unspecified, .UNRECOGNIZED:
                    return false
                }
            }
            guard UInt64(seenExactUIDs.count) + UInt64(exactEventUIDs.count)
                <= UInt64(event.completedItems)
            else { return false }
            guard !Self.isTerminal(event.state)
                || seenExactUIDs.count + exactEventUIDs.count
                    == expectedExactUIDs.count
            else { return false }
            if Self.isTerminal(event.state) {
                guard Self.exactTerminalState(
                    succeeded: exactSucceeded + eventSucceeded,
                    failed: exactFailed + eventFailed,
                    cancelled: exactCancelled + eventCancelled
                ) == event.state
                else { return false }
            }
        }

        var nextAggregateUIDs = aggregateDetailUIDs
        if event.aggregateOnly {
            for result in event.itemResults {
                guard result.hasIdentity,
                    !result.identity.uid.isEmpty,
                    nextAggregateUIDs.insert(result.identity.uid).inserted,
                    nextAggregateUIDs.count <= Self.maximumAggregateDetails
                else { return false }
            }
            let nonSuccess = UInt64(nextAggregateUIDs.count)
                + UInt64(event.omittedItemResults)
            guard nonSuccess <= UInt64(event.completedItems),
                aggregateTerminalCountersAreValid(
                    state: event.state,
                    nonSuccess: nonSuccess,
                    totalItems: event.totalItems
                )
            else { return false }
        }
        lastSequence = event.cursor.sequence
        lastCompleted = event.completedItems
        lastOmitted = event.omittedItemResults
        totalItems = event.totalItems
        if expectedExactUIDs != nil {
            seenExactUIDs.formUnion(exactEventUIDs)
            exactSucceeded += eventSucceeded
            exactFailed += eventFailed
            exactCancelled += eventCancelled
        } else if event.aggregateOnly {
            aggregateDetailUIDs = nextAggregateUIDs
        }
        return true
    }

    var hasTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    private func aggregateTerminalCountersAreValid(
        state: Kmgr_V1_OperationState,
        nonSuccess: UInt64,
        totalItems: UInt32
    ) -> Bool {
        switch state {
        case .succeeded:
            return nonSuccess == 0
        case .partiallySucceeded:
            return nonSuccess > 0 && nonSuccess < UInt64(totalItems)
        case .failed, .cancelled:
            return nonSuccess == UInt64(totalItems)
        case .pending, .running:
            return true
        case .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    private static func isTerminal(_ state: Kmgr_V1_OperationState) -> Bool {
        switch state {
        case .succeeded, .partiallySucceeded, .failed, .cancelled:
            return true
        case .pending, .running, .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    private static func exactTerminalState(
        succeeded: Int,
        failed: Int,
        cancelled: Int
    ) -> Kmgr_V1_OperationState {
        let total = succeeded + failed + cancelled
        if succeeded == total { return .succeeded }
        if succeeded > 0 { return .partiallySucceeded }
        if failed > 0 { return .failed }
        return .cancelled
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
