import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

public protocol ClusterRPC: Sendable {
    func listContexts(
        request: Kmgr_V1_ListContextsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListContextsResponse

    func openSession(
        request: Kmgr_V1_OpenSessionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_OpenSessionResponse
}

public struct EngineClusterRPC: ClusterRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func listContexts(
        request: Kmgr_V1_ListContextsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListContextsResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return try await connection.clusterClient().listContexts(request, options: options)
    }

    public func openSession(
        request: Kmgr_V1_OpenSessionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_OpenSessionResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return try await connection.clusterClient().openSession(request, options: options)
    }
}

public struct EngineClusterContextProvider: ClusterContextProviding {
    private let readiness: @Sendable () async throws -> Void
    private let rpc: any ClusterRPC
    private let listTimeout: Duration
    private let openTimeout: Duration
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        listTimeout: Duration = .seconds(5),
        openTimeout: Duration = .seconds(10)
    ) {
        self.init(
            rpc: EngineClusterRPC(connection: connection),
            listTimeout: listTimeout,
            openTimeout: openTimeout
        )
    }

    @MainActor
    public init(
        supervisor: EngineSupervisor,
        listTimeout: Duration = .seconds(5),
        openTimeout: Duration = .seconds(10)
    ) {
        let connection = supervisor.connection
        self.init(
            rpc: EngineClusterRPC(connection: connection),
            listTimeout: listTimeout,
            openTimeout: openTimeout,
            readiness: {
                _ = try await supervisor.waitUntilReady(timeout: openTimeout)
            }
        )
    }

    public init(
        rpc: any ClusterRPC,
        listTimeout: Duration = .seconds(5),
        openTimeout: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        },
        readiness: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.readiness = readiness
        self.rpc = rpc
        self.listTimeout = listTimeout
        self.openTimeout = openTimeout
        self.now = now
        self.requestID = requestID
    }

    public func listContexts(reload: Bool) async throws -> [ClusterContextSummary] {
        var request = Kmgr_V1_ListContextsRequest()
        request.context = makeRequestContext(timeout: listTimeout)
        request.reload = reload

        do {
            try await readiness()
            let response = try await rpc.listContexts(request: request, timeout: listTimeout)
            guard response.requestID == request.context.requestID else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "RequestIDMismatch",
                    message: "The engine returned a response for a different context request.",
                    operation: "list kubeconfig contexts"
                )
            }
            if response.hasError { throw Self.issue(from: response.error) }
            return response.contexts.map(Self.summary(from:))
        } catch {
            throw Self.issue(
                from: error,
                contextName: "",
                operation: reload ? "reload kubeconfig" : "list kubeconfig contexts"
            )
        }
    }

    public func openContext(reference: String) async throws -> OpenedClusterSession {
        var request = Kmgr_V1_OpenSessionRequest()
        request.context = makeRequestContext(timeout: openTimeout)
        request.contextName = reference

        do {
            try await readiness()
            let response = try await rpc.openSession(request: request, timeout: openTimeout)
            guard response.requestID == request.context.requestID else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "RequestIDMismatch",
                    message: "The engine returned a response for a different open request.",
                    contextName: reference,
                    operation: "open cluster session"
                )
            }
            if response.hasError { throw Self.issue(from: response.error) }
            guard !response.clusterSessionID.isEmpty else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "MissingSessionID",
                    message: "The engine connected but did not return a cluster session identity.",
                    contextName: reference,
                    operation: "open cluster session"
                )
            }
            return OpenedClusterSession(
                sessionID: response.clusterSessionID,
                contextName: response.contextName.isEmpty ? reference : response.contextName,
                clusterName: response.clusterName,
                serverHostname: response.serverHostname,
                defaultNamespace: response.defaultNamespace,
                contextReference: reference
            )
        } catch {
            throw Self.issue(
                from: error,
                contextName: reference,
                operation: "open cluster session"
            )
        }
    }

    private func makeRequestContext(timeout: Duration) -> Kmgr_V1_RequestContext {
        var context = Kmgr_V1_RequestContext()
        context.requestID = requestID()
        context.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000
        )
        return context
    }

    public static func summary(
        from context: Kmgr_V1_KubeconfigContext
    ) -> ClusterContextSummary {
        let authentication: ClusterAuthenticationAvailability
        if context.authenticationSupported {
            authentication = .supported(hint: context.authenticationHint)
        } else {
            let issue: ClusterManagerIssue
            if context.hasUnsupportedAuthenticationError {
                issue = Self.issue(from: context.unsupportedAuthenticationError)
            } else {
                issue = .unsupportedAuthentication(
                    contextName: context.name,
                    mechanism: context.authenticationHint
                )
            }
            let mechanism = issue.safeDetails["mechanism"]
                ?? issue.safeDetails["mechanisms"]
                ?? context.authenticationHint
            authentication = .unsupported(mechanism: mechanism, issue: issue)
        }
        return ClusterContextSummary(
            id: context.contextID,
            name: context.name,
            clusterName: context.clusterName,
            serverHostname: context.serverHostname,
            defaultNamespace: context.defaultNamespace,
            sourcePaths: context.sourcePaths,
            isCurrent: context.current,
            authentication: authentication
        )
    }

    public static func issue(from error: Kmgr_V1_StructuredError) -> ClusterManagerIssue {
        let status = error.hasKubernetesStatus ? error.kubernetesStatus : nil
        return ClusterManagerIssue(
            category: category(from: error.category),
            reason: error.reason,
            message: error.message.isEmpty ? "The engine reported an unspecified error." : error.message,
            httpStatusCode: error.httpStatusCode == 0 ? nil : Int(error.httpStatusCode),
            retryable: error.retryable,
            retryAfterMilliseconds: error.retryAfterMs == 0 ? nil : error.retryAfterMs,
            fieldPath: error.fieldPath,
            contextName: error.contextName,
            operation: error.operation,
            safeDetails: error.safeDetails,
            kubernetesStatus: status.map {
                ClusterManagerIssue.KubernetesStatus(
                    name: $0.name,
                    group: $0.group,
                    kind: $0.kind,
                    uid: $0.uid,
                    reason: $0.reason,
                    message: $0.message,
                    retryAfterSeconds: $0.retryAfterSeconds,
                    causes: $0.causes.map {
                        .init(reason: $0.reason, message: $0.message, field: $0.field)
                    }
                )
            }
        )
    }

    public static func issue(
        from error: Error,
        contextName: String,
        operation: String
    ) -> ClusterManagerIssue {
        if var issue = error as? ClusterManagerIssue {
            if issue.contextName.isEmpty { issue.contextName = contextName }
            if issue.operation.isEmpty { issue.operation = operation }
            return issue
        }
        if error is CancellationError {
            return ClusterManagerIssue(
                category: .cancelled,
                reason: "Cancelled",
                message: "The operation was cancelled.",
                retryable: true,
                contextName: contextName,
                operation: operation
            )
        }
        if let rpc = error as? RPCError {
            return ClusterManagerIssue(
                category: category(from: rpc.code),
                reason: rpc.code.description,
                message: safeRPCMessage(rpc),
                retryable: rpc.code == .unavailable || rpc.code == .deadlineExceeded,
                contextName: contextName,
                operation: operation
            )
        }
        if error is EngineConnectionError {
            return ClusterManagerIssue(
                category: .unavailable,
                reason: "EngineUnavailable",
                message: "The Kubernetes engine is disconnected. Retry after it reconnects.",
                retryable: true,
                contextName: contextName,
                operation: operation
            )
        }
        if let supervisor = error as? EngineSupervisorError {
            let category: ClusterManagerIssue.Category
            let retryable: Bool
            switch supervisor {
            case .incompatibleProtocol:
                category = .unsupported
                retryable = false
            case .helperMissing, .helperExited, .startupTimedOut:
                category = .unavailable
                retryable = true
            case .invalidHandshake:
                category = .internalFailure
                retryable = false
            case .stopped:
                category = .unavailable
                retryable = true
            }
            return ClusterManagerIssue(
                category: category,
                reason: String(describing: supervisor),
                message: supervisor.localizedDescription,
                retryable: retryable,
                contextName: contextName,
                operation: operation
            )
        }
        return ClusterManagerIssue(
            category: .internalFailure,
            reason: String(describing: type(of: error)),
            message: error.localizedDescription,
            contextName: contextName,
            operation: operation
        )
    }

    private static func category(
        from category: Kmgr_V1_ErrorCategory
    ) -> ClusterManagerIssue.Category {
        switch category {
        case .authentication: .authentication
        case .authorization: .authorization
        case .notFound: .notFound
        case .conflict: .conflict
        case .validation: .validation
        case .unavailable: .unavailable
        case .timeout: .timeout
        case .cancelled: .cancelled
        case .tls: .tls
        case .unsupported: .unsupported
        case .resourceExhausted: .resourceExhausted
        case .unspecified, .internal, .UNRECOGNIZED: .internalFailure
        }
    }

    private static func category(from code: RPCError.Code) -> ClusterManagerIssue.Category {
        switch code {
        case .unauthenticated: .authentication
        case .permissionDenied: .authorization
        case .notFound: .notFound
        case .aborted, .alreadyExists: .conflict
        case .invalidArgument, .failedPrecondition, .outOfRange: .validation
        case .unavailable: .unavailable
        case .deadlineExceeded: .timeout
        case .cancelled: .cancelled
        case .unimplemented: .unsupported
        case .resourceExhausted: .resourceExhausted
        default: .internalFailure
        }
    }

    private static func safeRPCMessage(_ error: RPCError) -> String {
        // Local engine transport messages contain no kubeconfig payload. Avoid
        // printing nested causes, metadata, or any caller-supplied data.
        error.message.isEmpty ? "The engine RPC failed (\(error.code))." : error.message
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
