import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol ExecRPC: Sendable {
    func exec(
        outbound: AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ExecServerMessage) throws -> Void
    ) async throws
}

public struct EngineExecRPC: ExecRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func exec(
        outbound: AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ExecServerMessage) throws -> Void
    ) async throws {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        try await connection.execClient().exec(
            options: options,
            requestProducer: { writer in
                for try await message in outbound {
                    try await writer.write(message)
                }
            },
            onResponse: { response in
                for try await message in response.messages {
                    try receive(message)
                }
            }
        )
    }
}

public struct EngineExecSessionProvider: ExecSessionProviding {
    private let rpc: any ExecRPC
    private let streamTimeout: Duration
    private let outboundMessageLimit: Int
    private let eventMessageLimit: Int
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        streamTimeout: Duration = .seconds(86_400),
        outboundMessageLimit: Int = 256,
        eventMessageLimit: Int = 256
    ) {
        self.init(
            rpc: EngineExecRPC(connection: connection),
            streamTimeout: streamTimeout,
            outboundMessageLimit: outboundMessageLimit,
            eventMessageLimit: eventMessageLimit
        )
    }

    public init(
        rpc: any ExecRPC,
        streamTimeout: Duration = .seconds(86_400),
        outboundMessageLimit: Int = 256,
        eventMessageLimit: Int = 256,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        precondition(outboundMessageLimit > 0 && eventMessageLimit > 0)
        self.rpc = rpc
        self.streamTimeout = streamTimeout
        self.outboundMessageLimit = outboundMessageLimit
        self.eventMessageLimit = eventMessageLimit
        self.now = now
        self.requestID = requestID
    }

    public func startExec(request: ExecSessionRequest) async throws -> any ExecSession {
        try Self.validate(request)
        let channel = ExecOutboundChannel(
            request: request,
            requestContext: makeContext(sessionID: request.sessionID),
            messageLimit: outboundMessageLimit
        )
        let eventPair = AsyncThrowingStream<ExecServerEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(eventMessageLimit)
        )
        let rpc = self.rpc
        let timeout = streamTimeout
        let eventLimit = eventMessageLimit
        let cursorValidator = ExecServerCursorValidator(request: request)
        let task = Task.detached(priority: .userInitiated) {
            do {
                try await rpc.exec(outbound: channel.stream, timeout: timeout) { message in
                    try cursorValidator.validate(message.cursor)
                    let event = try Self.event(from: message)
                    switch eventPair.continuation.yield(event) {
                    case .enqueued:
                        break
                    case .dropped:
                        throw ExecStreamBridgeError.eventBufferExceeded(eventLimit)
                    case .terminated:
                        throw CancellationError()
                    @unknown default:
                        throw ExecStreamBridgeError.eventBufferExceeded(eventLimit)
                    }
                }
                eventPair.continuation.finish()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    eventPair.continuation.finish()
                } else {
                    eventPair.continuation.finish(throwing: Self.issue(
                        from: error,
                        operation: request.target.operationDescription
                    ))
                }
            }
        }
        let session = EngineExecSession(
            request: request,
            events: eventPair.stream,
            channel: channel,
            task: task
        )
        eventPair.continuation.onTermination = { @Sendable [weak session] _ in
            Task { await session?.cancel() }
        }
        return session
    }

    private func makeContext(sessionID: String) -> Kmgr_V1_RequestContext {
        var result = Kmgr_V1_RequestContext()
        result.requestID = requestID()
        result.clusterSessionID = sessionID
        result.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(streamTimeout)) * 1_000
        )
        return result
    }

    private static func validate(_ request: ExecSessionRequest) throws {
        guard !request.sessionID.isEmpty,
            !request.execSessionID.isEmpty,
            request.generation > 0,
            !request.command.isEmpty,
            !request.command.contains(where: \.isEmpty)
        else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "InvalidExecRequest",
                message: "A complete target, command, and exec session identity are required.",
                contextName: request.contextName,
                operation: request.target.operationDescription
            )
        }
        switch request.target {
        case .pod(let destination):
            let pod = destination.pod
            guard pod.clusterSessionID == request.sessionID,
                pod.group.isEmpty,
                pod.version == "v1",
                pod.resource == "pods",
                !pod.namespace.isEmpty,
                !pod.name.isEmpty,
                !pod.uid.rawValue.isEmpty,
                !destination.container.isEmpty
            else {
                throw ClusterManagerIssue(
                    category: .validation,
                    reason: "InvalidExecRequest",
                    message: "A complete Pod and container from this cluster session are required.",
                    contextName: request.contextName,
                    operation: request.target.operationDescription
                )
            }
        case .nodeShell(let destination):
            let node = destination.node
            guard node.clusterSessionID == request.sessionID,
                node.group.isEmpty,
                node.version == "v1",
                node.resource == "nodes",
                node.namespace.isEmpty,
                !node.name.isEmpty,
                !node.uid.rawValue.isEmpty,
                NodeShellPreferences.isValidImage(destination.image),
                NodeShellLaunchPlanner.isValidNamespace(destination.namespace)
            else {
                throw ClusterManagerIssue(
                    category: .validation,
                    reason: "InvalidNodeShellRequest",
                    message: "A complete Node, helper namespace, and image from this cluster session are required.",
                    contextName: request.contextName,
                    operation: request.target.operationDescription
                )
            }
        }
        if request.initialSize != nil && !request.tty {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "InvalidTerminalSize",
                message: "An initial terminal size requires TTY mode.",
                contextName: request.contextName,
                operation: request.target.operationDescription
            )
        }
    }

    private static func event(
        from message: Kmgr_V1_ExecServerMessage
    ) throws -> ExecServerEvent {
        let cursor = message.cursor
        let value = StreamCursor(generation: cursor.generation, sequence: cursor.sequence)
        switch message.payload {
        case .stdout(let data):
            return .stdout(cursor: value, data: data)
        case .stderr(let data):
            return .stderr(cursor: value, data: data)
        case .status(let status):
            return .status(cursor: value, status: ExecStatus(
                state: state(from: status.state),
                exitCode: status.hasExitCode ? status.exitCode : nil,
                statusReason: status.statusReason,
                issue: status.hasError
                    ? EngineClusterContextProvider.issue(from: status.error) : nil
            ))
        case .error(let error):
            return .failure(
                cursor: value,
                issue: EngineClusterContextProvider.issue(from: error)
            )
        case nil:
            throw ExecStreamBridgeError.missingPayload
        }
    }

    private static func state(from value: Kmgr_V1_ExecConnectionState) -> ExecConnectionState {
        switch value {
        case .connecting, .unspecified, .UNRECOGNIZED: .connecting
        case .running: .running
        case .exited: .exited
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    private static func issue(
        from error: Error,
        operation: String
    ) -> ClusterManagerIssue {
        switch error {
        case ExecStreamBridgeError.outboundBufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "ExecInputBufferExceeded",
                message: "Terminal input arrived faster than it could be sent. The exec session was stopped safely.",
                retryable: true,
                operation: operation,
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        case ExecStreamBridgeError.eventBufferExceeded(let limit):
            return ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "ExecOutputBufferExceeded",
                message: "Terminal output arrived faster than the window could render it. Reconnect to start a new process.",
                retryable: true,
                operation: operation,
                safeDetails: ["buffered_message_limit": String(limit)]
            )
        case ExecStreamBridgeError.cursorMismatch:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "ExecCursorMismatch",
                message: "The engine returned output for a different exec generation.",
                operation: operation
            )
        case ExecStreamBridgeError.missingPayload:
            return ClusterManagerIssue(
                category: .internalFailure,
                reason: "MissingExecPayload",
                message: "The engine returned an exec event without a payload.",
                operation: operation
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
        let value = duration.components
        return TimeInterval(value.seconds)
            + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}

public final class EngineExecSession: ExecSession, @unchecked Sendable {
    public let events: AsyncThrowingStream<ExecServerEvent, Error>

    private let request: ExecSessionRequest
    private let channel: ExecOutboundChannel
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(
        request: ExecSessionRequest,
        events: AsyncThrowingStream<ExecServerEvent, Error>,
        channel: ExecOutboundChannel,
        task: Task<Void, Never>
    ) {
        self.request = request
        self.events = events
        self.channel = channel
        self.task = task
    }

    deinit {
        task.cancel()
        channel.finish()
    }

    public func sendStdin(_ data: Data) async throws {
        guard request.stdin else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "ExecStdinDisabled",
                message: "This exec session was started without stdin.",
                operation: "send terminal input"
            )
        }
        try channel.send(.stdin(data))
    }

    public func resize(_ size: TerminalSize) async throws {
        guard request.tty else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "ExecResizeWithoutTTY",
                message: "Terminal resize requires TTY mode.",
                operation: "resize terminal"
            )
        }
        try channel.send(.resize(size))
    }

    public func closeStdin() async throws {
        try channel.send(.closeStdin)
    }

    public func cancel() async {
        let shouldCancel = lock.withLock {
            if cancelled { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        try? channel.send(.cancel)
        channel.finish()
    }
}

private final class ExecOutboundChannel: @unchecked Sendable {
    enum Payload {
        case stdin(Data)
        case resize(TerminalSize)
        case closeStdin
        case cancel
    }

    let stream: AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>

    private let request: ExecSessionRequest
    private let messageLimit: Int
    private let continuation: AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>.Continuation
    private let lock = NSLock()
    private var sequence: UInt64 = 1
    private var finished = false

    init(
        request: ExecSessionRequest,
        requestContext: Kmgr_V1_RequestContext,
        messageLimit: Int
    ) {
        self.request = request
        self.messageLimit = messageLimit
        let pair = AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(messageLimit)
        )
        stream = pair.stream
        continuation = pair.continuation
        continuation.yield(Self.startMessage(request: request, context: requestContext))
    }

    func send(_ payload: Payload) throws {
        let result: AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>.Continuation.YieldResult = try lock.withLock {
            guard !finished else { throw CancellationError() }
            sequence &+= 1
            var message = envelope(sequence: sequence)
            switch payload {
            case .stdin(let data): message.stdin = data
            case .resize(let size):
                message.resize.columns = size.columns
                message.resize.rows = size.rows
            case .closeStdin: message.closeStdin = true
            case .cancel: message.cancel = true
            }
            return continuation.yield(message)
        }
        switch result {
        case .enqueued:
            return
        case .dropped:
            finish(throwing: ExecStreamBridgeError.outboundBufferExceeded(messageLimit))
            throw ExecStreamBridgeError.outboundBufferExceeded(messageLimit)
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw ExecStreamBridgeError.outboundBufferExceeded(messageLimit)
        }
    }

    func finish(throwing error: Error? = nil) {
        let shouldFinish = lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    private func envelope(sequence: UInt64) -> Kmgr_V1_ExecClientMessage {
        var message = Kmgr_V1_ExecClientMessage()
        message.execSessionID = request.execSessionID
        message.generation = request.generation
        message.sequence = sequence
        return message
    }

    private static func startMessage(
        request: ExecSessionRequest,
        context: Kmgr_V1_RequestContext
    ) -> Kmgr_V1_ExecClientMessage {
        var start = Kmgr_V1_ExecStart()
        start.context = context
        start.execSessionID = request.execSessionID
        start.generation = request.generation
        switch request.target {
        case .pod(let destination):
            start.pod = identity(from: destination.pod)
            start.container = destination.container
        case .nodeShell(let destination):
            var nodeShell = Kmgr_V1_NodeShellStart()
            nodeShell.node = identity(from: destination.node)
            nodeShell.namespace = destination.namespace
            nodeShell.image = destination.image
            start.nodeShell = nodeShell
        }
        start.command = request.command
        start.tty = request.tty
        start.stdin = request.stdin
        if let size = request.initialSize {
            start.initialColumns = size.columns
            start.initialRows = size.rows
        }
        var message = Kmgr_V1_ExecClientMessage()
        message.execSessionID = request.execSessionID
        message.generation = request.generation
        message.sequence = 1
        message.start = start
        return message
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
}

private enum ExecStreamBridgeError: Error {
    case outboundBufferExceeded(Int)
    case eventBufferExceeded(Int)
    case cursorMismatch
    case missingPayload
}

private final class ExecServerCursorValidator: @unchecked Sendable {
    private let streamID: String
    private let generation: UInt64
    private let lock = NSLock()
    private var lastSequence: UInt64 = 0

    init(request: ExecSessionRequest) {
        streamID = request.execSessionID
        generation = request.generation
    }

    func validate(_ cursor: Kmgr_V1_StreamCursor) throws {
        try lock.withLock {
            guard cursor.streamID == streamID,
                cursor.generation == generation,
                cursor.sequence > lastSequence
            else {
                throw ExecStreamBridgeError.cursorMismatch
            }
            lastSequence = cursor.sequence
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
