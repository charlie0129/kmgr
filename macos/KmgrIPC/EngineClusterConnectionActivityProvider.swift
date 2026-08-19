import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol ClusterConnectionActivityRPC: Sendable {
    func watchConnection(
        request: Kmgr_V1_WatchConnectionRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ConnectionEvent) throws -> Void
    ) async throws
}

public struct EngineClusterConnectionActivityRPC: ClusterConnectionActivityRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func watchConnection(
        request: Kmgr_V1_WatchConnectionRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ConnectionEvent) throws -> Void
    ) async throws {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        try await connection.clusterClient().watchConnection(
            request,
            options: options
        ) { response in
            for try await event in response.messages {
                try receive(event)
            }
        }
    }
}

public struct EngineClusterConnectionActivityProvider: ClusterConnectionActivityProviding {
    private let rpc: any ClusterConnectionActivityRPC
    private let timeout: Duration
    private let maximumBufferedSamples: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        timeout: Duration = .seconds(86_400),
        maximumBufferedSamples: Int = 16
    ) {
        self.init(
            rpc: EngineClusterConnectionActivityRPC(connection: connection),
            timeout: timeout,
            maximumBufferedSamples: maximumBufferedSamples
        )
    }

    public init(
        rpc: any ClusterConnectionActivityRPC,
        timeout: Duration = .seconds(86_400),
        maximumBufferedSamples: Int = 16,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        precondition(maximumBufferedSamples > 0)
        self.rpc = rpc
        self.timeout = timeout
        self.maximumBufferedSamples = maximumBufferedSamples
        self.now = now
        self.requestID = requestID
    }

    public func watchConnectionActivity(
        sessionID: String,
        streamID: String
    ) -> AsyncThrowingStream<ClusterConnectionActivitySample, Error> {
        let rpc = self.rpc
        let timeout = self.timeout
        let limit = maximumBufferedSamples
        let expectedStreamID = streamID
        var request = Kmgr_V1_WatchConnectionRequest()
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
                    try await rpc.watchConnection(
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
                                reason: "ConnectionActivityCursorInvalid",
                                message: "The engine returned an invalid connection activity cursor.",
                                operation: "watch Kubernetes API activity"
                            )
                        }
                        let result = continuation.yield(Self.sample(from: event))
                        if case .dropped = result {
                            throw ClusterManagerIssue(
                                category: .resourceExhausted,
                                reason: "ConnectionActivityBufferExceeded",
                                message: "Connection activity updates arrived faster than the UI could apply them.",
                                retryable: true,
                                operation: "watch Kubernetes API activity"
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
                        operation: "watch Kubernetes API activity"
                    ))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func sample(
        from event: Kmgr_V1_ConnectionEvent
    ) -> ClusterConnectionActivitySample {
        ClusterConnectionActivitySample(
            cursor: StreamCursor(
                generation: event.cursor.generation,
                sequence: event.cursor.sequence
            ),
            state: state(from: event.state),
            observedAt: Date(timeIntervalSince1970: Double(event.observedAtUnixMs) / 1_000),
            bytesReceived: event.apiBytesReceived,
            bytesSent: event.apiBytesSent,
            authorityWarmCache: warmCacheUsage(from: event.authorityWarmCache),
            globalWarmCache: warmCacheUsage(from: event.globalWarmCache),
            issue: event.hasError ? EngineClusterContextProvider.issue(from: event.error) : nil
        )
    }

    private static func warmCacheUsage(
        from usage: Kmgr_V1_WarmCacheUsage
    ) -> WarmCacheUsage {
        WarmCacheUsage(
            retainedViews: usage.retainedViews,
            retainedObjects: usage.retainedObjects,
            retainedBytes: usage.retainedBytes,
            viewLimit: usage.viewLimit,
            objectLimit: usage.objectLimit,
            byteLimit: usage.byteLimit,
            budgetEvictions: usage.budgetEvictions
        )
    }

    private static func state(
        from value: Kmgr_V1_ConnectionState
    ) -> ClusterConnectionState {
        switch value {
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        case .unspecified, .UNRECOGNIZED: .disconnected
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
