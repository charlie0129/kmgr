import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol LogRPC: Sendable {
    func streamLogs(
        request: Kmgr_V1_StartLogsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_LogEvent) throws -> Void
    ) async throws

    func cancelLogs(
        request: Kmgr_V1_CancelLogsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement
}

public struct EngineLogRPC: LogRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func streamLogs(
        request: Kmgr_V1_StartLogsRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_LogEvent) throws -> Void
    ) async throws {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        let client = Kmgr_V1_LogService.Client(wrapping: try connection.currentClient())
        try await client.streamLogs(request, options: options) { response in
            for try await event in response.messages {
                try receive(event)
            }
        }
    }

    public func cancelLogs(
        request: Kmgr_V1_CancelLogsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        let client = Kmgr_V1_LogService.Client(wrapping: try connection.currentClient())
        return try await client.cancelLogs(request, options: options)
    }
}

public struct EngineLogStreamProvider: LogStreamProviding {
    private let rpc: any LogRPC
    private let streamTimeout: Duration
    private let controlTimeout: Duration
    private let maximumBufferedMessages: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        streamTimeout: Duration = .seconds(86_400),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 128
    ) {
        self.init(
            rpc: EngineLogRPC(connection: connection),
            streamTimeout: streamTimeout,
            controlTimeout: controlTimeout,
            maximumBufferedMessages: maximumBufferedMessages
        )
    }

    public init(
        rpc: any LogRPC,
        streamTimeout: Duration = .seconds(86_400),
        controlTimeout: Duration = .seconds(5),
        maximumBufferedMessages: Int = 128,
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

    public func streamLogs(
        request: LogStreamRequest
    ) -> AsyncThrowingStream<LogStreamMessage, Error> {
        let rpcRequest = makeStartRequest(from: request)
        let rpc = self.rpc
        let timeout = streamTimeout
        let limit = maximumBufferedMessages
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await rpc.streamLogs(request: rpcRequest, timeout: timeout) { event in
                        guard event.cursor.streamID == request.streamID else {
                            throw LogStreamBridgeError.streamIDMismatch
                        }
                        switch continuation.yield(Self.message(from: event)) {
                        case .enqueued:
                            break
                        case .dropped:
                            throw LogStreamBridgeError.bufferExceeded(limit)
                        case .terminated:
                            throw CancellationError()
                        @unknown default:
                            throw LogStreamBridgeError.bufferExceeded(limit)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.issue(from: error))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func cancelLogs(
        sessionID: String,
        streamID: String,
        generation: UInt64
    ) async {
        var request = Kmgr_V1_CancelLogsRequest()
        request.context = makeContext(sessionID: sessionID, timeout: controlTimeout)
        request.logStreamID = streamID
        request.generation = generation
        _ = try? await rpc.cancelLogs(request: request, timeout: controlTimeout)
    }

    private func makeStartRequest(from request: LogStreamRequest) -> Kmgr_V1_StartLogsRequest {
        var result = Kmgr_V1_StartLogsRequest()
        result.context = makeContext(sessionID: request.sessionID, timeout: streamTimeout)
        result.logStreamID = request.streamID
        result.generation = request.generation
        result.sources = request.sources.map { source in
            var value = Kmgr_V1_LogSource()
            value.identity = Self.identity(from: source.identity)
            value.container = source.container
            value.sourceID = source.sourceID
            value.sourceLabel = source.label
            return value
        }
        result.options.follow = request.options.follow
        result.options.previous = request.options.previous
        result.options.timestamps = request.options.timestamps
        if let since = request.options.since {
            result.options.sinceUnixMs = Int64(since.timeIntervalSince1970 * 1_000)
        }
        if let value = request.options.sinceSeconds { result.options.sinceSeconds = value }
        if let value = request.options.tailLines { result.options.tailLines = value }
        if let value = request.options.byteLimit { result.options.byteLimit = value }
        return result
    }

    private func makeContext(sessionID: String, timeout: Duration) -> Kmgr_V1_RequestContext {
        var result = Kmgr_V1_RequestContext()
        result.requestID = requestID()
        result.clusterSessionID = sessionID
        result.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000
        )
        return result
    }

    private static func message(from event: Kmgr_V1_LogEvent) -> LogStreamMessage {
        let cursor = StreamCursor(
            generation: event.cursor.generation,
            sequence: event.cursor.sequence
        )
        switch event.payload {
        case .batch(let batch):
            return .records(
                cursor: cursor,
                records: batch.records.map { record in
                    LogRecord(
                        sourceID: record.sourceID,
                        data: record.data,
                        timestampUnixMilliseconds: record.timestampUnixMs == 0
                            ? nil : record.timestampUnixMs,
                        endsWithNewline: record.endsWithNewline
                    )
                },
                totalBytes: batch.totalBytes
            )
        case .status(let status):
            return .status(cursor: cursor, status: LogStatus(
                state: state(from: status.state),
                sourceID: status.sourceID,
                droppedRecords: status.droppedRecords,
                droppedBytes: status.droppedBytes,
                issue: status.hasError
                    ? EngineClusterContextProvider.issue(from: status.error) : nil
            ))
        case .error(let error):
            return .failure(
                cursor: cursor,
                issue: EngineClusterContextProvider.issue(from: error)
            )
        case nil:
            return .failure(cursor: cursor, issue: ClusterManagerIssue(
                category: .internalFailure,
                reason: "MissingLogEventPayload",
                message: "The engine returned a log event without a payload.",
                operation: "stream Pod logs"
            ))
        }
    }

    private static func state(from value: Kmgr_V1_LogStreamState) -> LogStreamState {
        switch value {
        case .connecting, .unspecified, .UNRECOGNIZED: .connecting
        case .streaming: .streaming
        case .reconnecting: .reconnecting
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
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

    private static func issue(from error: Error) -> ClusterManagerIssue {
        if case LogStreamBridgeError.bufferExceeded(let limit) = error {
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "LogStreamBufferExceeded",
                message: "Log updates arrived faster than the window could apply them. Reopen logs to resume safely.",
                retryable: true,
                operation: "stream Pod logs",
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        }
        if case LogStreamBridgeError.streamIDMismatch = error {
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "LogStreamIDMismatch",
                message: "The engine returned an event for a different log stream.",
                operation: "stream Pod logs"
            )
        }
        return EngineClusterContextProvider.issue(
            from: error,
            contextName: "",
            operation: "stream Pod logs"
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let value = duration.components
        return TimeInterval(value.seconds)
            + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum LogStreamBridgeError: Error {
    case bufferExceeded(Int)
    case streamIDMismatch
}
