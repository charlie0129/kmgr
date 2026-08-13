import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

/// Narrow seam for verifying protobuf mapping without starting the helper.
public protocol PortForwardRPC: Sendable {
    func start(
        request: Kmgr_V1_StartPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartPortForwardResponse

    func stop(
        request: Kmgr_V1_StopPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement

    func restart(
        request: Kmgr_V1_RestartPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement

    func list(
        request: Kmgr_V1_ListPortForwardsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListPortForwardsResponse

    func watch(
        request: Kmgr_V1_WatchPortForwardsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_PortForwardEvent) throws -> Void
    ) async throws
}

public struct EnginePortForwardRPC: PortForwardRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func start(
        request: Kmgr_V1_StartPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_StartPortForwardResponse {
        try await connection.portForwardClient().start(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func stop(
        request: Kmgr_V1_StopPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.portForwardClient().stop(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func restart(
        request: Kmgr_V1_RestartPortForwardRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        try await connection.portForwardClient().restart(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func list(
        request: Kmgr_V1_ListPortForwardsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListPortForwardsResponse {
        try await connection.portForwardClient().list(
            request,
            options: callOptions(timeout: timeout)
        )
    }

    public func watch(
        request: Kmgr_V1_WatchPortForwardsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_PortForwardEvent) throws -> Void
    ) async throws {
        try await connection.portForwardClient().watch(
            request,
            options: callOptions(timeout: timeout)
        ) { response in
            for try await event in response.messages {
                try receive(event)
            }
        }
    }

    private func callOptions(timeout: Duration) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return options
    }
}

public struct EnginePortForwardProvider: PortForwardProviding {
    private let rpc: any PortForwardRPC
    private let unaryTimeout: Duration
    private let streamTimeout: Duration
    private let maximumBufferedMessages: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        unaryTimeout: Duration = .seconds(10),
        streamTimeout: Duration = .seconds(86_400),
        maximumBufferedMessages: Int = 128
    ) {
        self.init(
            rpc: EnginePortForwardRPC(connection: connection),
            unaryTimeout: unaryTimeout,
            streamTimeout: streamTimeout,
            maximumBufferedMessages: maximumBufferedMessages
        )
    }

    public init(
        rpc: any PortForwardRPC,
        unaryTimeout: Duration = .seconds(10),
        streamTimeout: Duration = .seconds(86_400),
        maximumBufferedMessages: Int = 128,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        precondition(maximumBufferedMessages > 0)
        self.rpc = rpc
        self.unaryTimeout = unaryTimeout
        self.streamTimeout = streamTimeout
        self.maximumBufferedMessages = maximumBufferedMessages
        self.now = now
        self.requestID = requestID
    }

    public func listPortForwards(
        sessionID: String,
        includeStopped: Bool
    ) async throws -> [PortForwardRecord] {
        var request = Kmgr_V1_ListPortForwardsRequest()
        request.context = makeRequestContext(sessionID: sessionID, timeout: unaryTimeout)
        request.includeStopped = includeStopped
        do {
            try Self.validateSessionID(sessionID, operation: "list port-forwards")
            let response = try await rpc.list(request: request, timeout: unaryTimeout)
            try validateResponseID(
                response.requestID,
                expected: request.context.requestID,
                operation: "list port-forwards"
            )
            if response.hasError {
                throw EngineClusterContextProvider.issue(from: response.error)
            }
            return response.portForwards.compactMap(Self.record(from:))
        } catch {
            throw Self.issue(from: error, operation: "list port-forwards")
        }
    }

    public func watchPortForwards(
        request: PortForwardWatchRequest
    ) -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        do {
            try Self.validateSessionID(request.sessionID, operation: "watch port-forwards")
            guard !request.streamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Self.validationIssue(
                    reason: "MissingStreamID",
                    message: "A port-forward stream ID is required.",
                    operation: "watch port-forwards"
                )
            }
            guard request.generation > 0 else {
                throw Self.validationIssue(
                    reason: "InvalidGeneration",
                    message: "The port-forward stream generation must be greater than zero.",
                    operation: "watch port-forwards"
                )
            }
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        var rpcRequest = Kmgr_V1_WatchPortForwardsRequest()
        rpcRequest.context = makeRequestContext(
            sessionID: request.sessionID,
            timeout: streamTimeout
        )
        rpcRequest.streamID = request.streamID
        rpcRequest.generation = request.generation
        rpcRequest.includeStopped = request.includeStopped
        let requestValue = rpcRequest
        let rpc = self.rpc
        let timeout = streamTimeout
        let limit = maximumBufferedMessages

        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.watch(request: requestValue, timeout: timeout) { event in
                        let value = Self.event(from: event, expectedStreamID: request.streamID)
                        switch continuation.yield(value) {
                        case .enqueued:
                            break
                        case .dropped:
                            throw PortForwardStreamBridgeError.bufferExceeded(limit)
                        case .terminated:
                            throw CancellationError()
                        @unknown default:
                            throw PortForwardStreamBridgeError.bufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else if case PortForwardStreamBridgeError.bufferExceeded(let limit) = error {
                        continuation.finish(throwing: ClusterManagerIssue(
                            category: .resourceExhausted,
                            reason: "PortForwardStreamBufferExceeded",
                            message: "Port-forward updates arrived faster than the UI could apply them. The manager will relist safely.",
                            retryable: true,
                            operation: "watch port-forwards",
                            safeDetails: ["buffered_message_limit": String(limit)]
                        ))
                    } else {
                        continuation.finish(throwing: Self.issue(
                            from: error,
                            operation: "watch port-forwards"
                        ))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        let sessionID = request.target.clusterSessionID
        do {
            try Self.validateSessionID(sessionID, operation: "start port-forward")
            guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Self.validationIssue(
                    reason: "MissingPortForwardID",
                    message: "A port-forward ID is required.",
                    operation: "start port-forward"
                )
            }
            guard request.remotePort > 0 else {
                throw Self.validationIssue(
                    reason: "MissingRemotePort",
                    message: "A remote port is required.",
                    operation: "start port-forward"
                )
            }
            var rpcRequest = Kmgr_V1_StartPortForwardRequest()
            rpcRequest.context = makeRequestContext(sessionID: sessionID, timeout: unaryTimeout)
            rpcRequest.portForwardID = request.id
            rpcRequest.target = Self.identity(from: request.target)
            rpcRequest.remotePort = UInt32(request.remotePort)
            rpcRequest.localPort = UInt32(request.localPort)
            rpcRequest.bindAddress = request.bindAddress.isEmpty ? "127.0.0.1" : request.bindAddress
            rpcRequest.label = request.label
            rpcRequest.allowNonLoopback = request.allowNonLoopback

            let response = try await rpc.start(request: rpcRequest, timeout: unaryTimeout)
            try validateResponseID(
                response.requestID,
                expected: rpcRequest.context.requestID,
                operation: "start port-forward"
            )
            if response.hasError {
                throw EngineClusterContextProvider.issue(from: response.error)
            }
            guard response.accepted else {
                throw Self.rejectedIssue(operation: "start port-forward")
            }
            guard !response.portForwardID.isEmpty else {
                throw Self.validationIssue(
                    reason: "MissingPortForwardID",
                    message: "The engine accepted the listener without returning its identity.",
                    operation: "start port-forward",
                    category: .internalFailure
                )
            }
            return response.portForwardID
        } catch {
            throw Self.issue(from: error, operation: "start port-forward")
        }
    }

    public func stopPortForward(id: String, sessionID: String) async throws {
        var request = Kmgr_V1_StopPortForwardRequest()
        request.context = makeRequestContext(sessionID: sessionID, timeout: unaryTimeout)
        request.portForwardID = id
        do {
            try Self.validateControl(id: id, sessionID: sessionID, operation: "stop port-forward")
            let response = try await rpc.stop(request: request, timeout: unaryTimeout)
            try validateAcknowledgement(response, requestID: request.context.requestID, operation: "stop port-forward")
        } catch {
            throw Self.issue(from: error, operation: "stop port-forward")
        }
    }

    public func restartPortForward(id: String, sessionID: String) async throws {
        var request = Kmgr_V1_RestartPortForwardRequest()
        request.context = makeRequestContext(sessionID: sessionID, timeout: unaryTimeout)
        request.portForwardID = id
        do {
            try Self.validateControl(id: id, sessionID: sessionID, operation: "restart port-forward")
            let response = try await rpc.restart(request: request, timeout: unaryTimeout)
            try validateAcknowledgement(response, requestID: request.context.requestID, operation: "restart port-forward")
        } catch {
            throw Self.issue(from: error, operation: "restart port-forward")
        }
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

    private func validateResponseID(
        _ responseID: String,
        expected: String,
        operation: String
    ) throws {
        guard !expected.isEmpty, responseID == expected else {
            throw Self.validationIssue(
                reason: "RequestIDMismatch",
                message: "The engine returned a response for a different port-forward request.",
                operation: operation,
                category: .internalFailure
            )
        }
    }

    private func validateAcknowledgement(
        _ response: Kmgr_V1_Acknowledgement,
        requestID: String,
        operation: String
    ) throws {
        try validateResponseID(response.requestID, expected: requestID, operation: operation)
        guard response.accepted else { throw Self.rejectedIssue(operation: operation) }
    }

    private static func validateControl(
        id: String,
        sessionID: String,
        operation: String
    ) throws {
        try validateSessionID(sessionID, operation: operation)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationIssue(
                reason: "MissingPortForwardID",
                message: "A port-forward ID is required.",
                operation: operation
            )
        }
    }

    private static func validateSessionID(_ value: String, operation: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationIssue(
                reason: "MissingSessionID",
                message: "A cluster session is required to manage app-wide port-forwards.",
                operation: operation
            )
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

    private static func rejectedIssue(operation: String) -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .conflict,
            reason: "PortForwardRequestRejected",
            message: "The port-forward request was not accepted because its state changed or it no longer exists.",
            operation: operation
        )
    }

    private static func issue(from error: Error, operation: String) -> ClusterManagerIssue {
        EngineClusterContextProvider.issue(
            from: error,
            contextName: "",
            operation: operation
        )
    }

    private static func event(
        from event: Kmgr_V1_PortForwardEvent,
        expectedStreamID: String
    ) -> PortForwardWatchEvent {
        let cursor = StreamCursor(
            generation: event.cursor.generation,
            sequence: event.cursor.sequence
        )
        guard event.hasCursor, event.cursor.streamID == expectedStreamID else {
            return .failure(cursor: cursor, issue: validationIssue(
                reason: "StreamIDMismatch",
                message: "The engine returned an event for a different port-forward stream.",
                operation: "watch port-forwards",
                category: .internalFailure
            ))
        }
        if event.hasError {
            var issue = EngineClusterContextProvider.issue(from: event.error)
            if issue.operation.isEmpty { issue.operation = "watch port-forwards" }
            return .failure(cursor: cursor, issue: issue)
        }
        guard event.hasDelta else {
            return .failure(cursor: cursor, issue: validationIssue(
                reason: "MissingPortForwardEventPayload",
                message: "The engine returned a port-forward event without a delta.",
                operation: "watch port-forwards",
                category: .internalFailure
            ))
        }
        return .delta(
            cursor: cursor,
            value: PortForwardDelta(
                upserts: event.delta.upserts.compactMap(record(from:)),
                removedIDs: Set(event.delta.removedPortForwardIds)
            )
        )
    }

    private static func record(from value: Kmgr_V1_PortForward) -> PortForwardRecord? {
        guard !value.portForwardID.isEmpty, value.hasTarget else { return nil }
        let sessionID = value.clusterSessionID.isEmpty
            ? value.target.clusterSessionID : value.clusterSessionID
        guard !sessionID.isEmpty else { return nil }
        let issue = value.hasLastError
            ? EngineClusterContextProvider.issue(from: value.lastError) : nil
        let exposure = value.hasLastError
            && value.lastError.safeDetails["exposure_warning"] == "non_loopback_bind"
        return PortForwardRecord(
            id: value.portForwardID,
            clusterSessionID: sessionID,
            contextName: value.contextName,
            target: identity(from: value.target, defaultSessionID: sessionID),
            resolvedPod: value.hasResolvedPod
                ? identity(from: value.resolvedPod, defaultSessionID: sessionID) : nil,
            remotePort: UInt16(clamping: value.remotePort),
            localPort: UInt16(clamping: value.localPort),
            bindAddress: value.bindAddress,
            label: value.label,
            state: state(from: value.state),
            startedAt: date(fromUnixMilliseconds: value.startedAtUnixMs),
            updatedAt: date(fromUnixMilliseconds: value.updatedAtUnixMs),
            lastIssue: issue,
            exposesBeyondLocalMachine: exposure
        )
    }

    private static func identity(
        from value: Kmgr_V1_ResourceIdentity,
        defaultSessionID: String = ""
    ) -> ResourceIdentity {
        ResourceIdentity(
            clusterSessionID: value.clusterSessionID.isEmpty
                ? defaultSessionID : value.clusterSessionID,
            group: value.group,
            version: value.version,
            resource: value.resource,
            namespace: value.namespace,
            name: value.name,
            uid: ResourceUID(value.uid)
        )
    }

    private static func identity(from value: ResourceIdentity) -> Kmgr_V1_ResourceIdentity {
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

    private static func state(from value: Kmgr_V1_PortForwardState) -> PortForwardState {
        switch value {
        case .starting: .starting
        case .listening: .listening
        case .reconnecting: .reconnecting
        case .failed: .failed
        case .stopped: .stopped
        case .unspecified, .UNRECOGNIZED: .failed
        }
    }

    private static func date(fromUnixMilliseconds value: Int64) -> Date? {
        value > 0 ? Date(timeIntervalSince1970: Double(value) / 1_000) : nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum PortForwardStreamBridgeError: Error {
    case bufferExceeded(Int)
}
