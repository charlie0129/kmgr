import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol ClusterOperationHistoryRPC: Sendable {
    func watchOperations(
        request: Kmgr_V1_WatchOperationsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ClusterOperationBatch) throws -> Void
    ) async throws
}

public struct EngineClusterOperationHistoryRPC: ClusterOperationHistoryRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func watchOperations(
        request: Kmgr_V1_WatchOperationsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ClusterOperationBatch) throws -> Void
    ) async throws {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        try await connection.clusterClient().watchOperations(
            request,
            options: options
        ) { response in
            for try await batch in response.messages {
                try receive(batch)
            }
        }
    }
}

public struct EngineClusterOperationHistoryProvider: ClusterOperationHistoryProviding {
    private let rpc: any ClusterOperationHistoryRPC
    private let timeout: Duration
    private let maximumBufferedBatches: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        timeout: Duration = .seconds(86_400),
        maximumBufferedBatches: Int = 16
    ) {
        self.init(
            rpc: EngineClusterOperationHistoryRPC(connection: connection),
            timeout: timeout,
            maximumBufferedBatches: maximumBufferedBatches
        )
    }

    public init(
        rpc: any ClusterOperationHistoryRPC,
        timeout: Duration = .seconds(86_400),
        maximumBufferedBatches: Int = 16,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        precondition(maximumBufferedBatches > 0)
        self.rpc = rpc
        self.timeout = timeout
        self.maximumBufferedBatches = maximumBufferedBatches
        self.now = now
        self.requestID = requestID
    }

    public func watchOperations(
        sessionID: String,
        streamID: String
    ) -> AsyncThrowingStream<ClusterOperationBatch, Error> {
        let rpc = self.rpc
        let timeout = self.timeout
        let limit = maximumBufferedBatches
        let expectedStreamID = streamID
        var request = Kmgr_V1_WatchOperationsRequest()
        request.context.requestID = requestID()
        request.context.clusterSessionID = sessionID
        request.context.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000
        )
        request.streamID = streamID
        let rpcRequest = request
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(limit)
        ) { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try await rpc.watchOperations(
                        request: rpcRequest,
                        timeout: timeout
                    ) { event in
                        guard event.hasCursor,
                            event.cursor.streamID == expectedStreamID,
                            event.cursor.generation > 0,
                            event.cursor.sequence > 0
                        else {
                            throw ClusterManagerIssue(
                                category: .internalFailure,
                                reason: "OperationHistoryCursorInvalid",
                                message: "The engine returned an invalid operation-history cursor.",
                                operation: "watch Kubernetes API operations"
                            )
                        }
                        let result = continuation.yield(try Self.batch(from: event))
                        if case .dropped = result {
                            throw ClusterManagerIssue(
                                category: .resourceExhausted,
                                reason: "OperationHistoryBufferExceeded",
                                message: "Kubernetes API operation updates arrived faster than the application could retain them.",
                                retryable: true,
                                operation: "watch Kubernetes API operations"
                            )
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: EngineClusterContextProvider.issue(
                        from: error,
                        contextName: "",
                        operation: "watch Kubernetes API operations"
                    ))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func batch(
        from event: Kmgr_V1_ClusterOperationBatch
    ) throws -> ClusterOperationBatch {
        ClusterOperationBatch(
            cursor: StreamCursor(
                generation: event.cursor.generation,
                sequence: event.cursor.sequence
            ),
            active: try event.active.map { try record(from: $0, expectsActive: true) },
            completed: try event.completed.map { try record(from: $0, expectsActive: false) },
            droppedCompleted: event.droppedCompleted
        )
    }

    private static func record(
        from operation: Kmgr_V1_KubernetesAPIOperation,
        expectsActive: Bool
    ) throws -> ClusterOperationRecord {
        guard let state = state(from: operation.state),
            operation.id > 0,
            operation.startedAtUnixNanos > 0,
            expectsActive ? state == .active : state != .active
        else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "OperationHistoryRecordInvalid",
                message: "The engine returned invalid Kubernetes API operation metadata.",
                operation: "watch Kubernetes API operations"
            )
        }
        return ClusterOperationRecord(
            id: operation.id,
            state: state,
            operation: operation.operation,
            group: operation.group,
            version: operation.version,
            resource: operation.resource,
            namespace: operation.namespace,
            name: operation.name,
            subresource: operation.subresource,
            httpStatusCode: Int(operation.httpStatusCode),
            bytesReceived: operation.bytesReceived,
            bytesSent: operation.bytesSent,
            startedAtUnixNanos: operation.startedAtUnixNanos,
            finishedAtUnixNanos: operation.finishedAtUnixNanos == 0
                ? nil
                : operation.finishedAtUnixNanos,
            errorMessage: operation.errorMessage.isEmpty
                ? nil
                : operation.errorMessage
        )
    }

    private static func state(
        from value: Kmgr_V1_KubernetesAPIOperationState
    ) -> ClusterOperationState? {
        switch value {
        case .active: .active
        case .finished: .finished
        case .failed: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .unspecified, .UNRECOGNIZED: nil
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
