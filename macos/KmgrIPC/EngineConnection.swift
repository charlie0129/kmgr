import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import KmgrProto

public enum EngineConnectionError: Error, LocalizedError, Sendable {
    case unavailable
    case stopped

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The Kubernetes engine is not connected."
        case .stopped: "The Kubernetes engine has stopped."
        }
    }
}

struct BearerTokenInterceptor: ClientInterceptor {
    let authorizationValue: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        // Assignment deliberately replaces any caller-supplied values, so the
        // engine receives exactly one launch credential on every RPC.
        request.metadata.replaceOrAddString(authorizationValue, forKey: "authorization")
        return try await next(request, context)
    }
}

/// Thread-safe handle to the current supervised gRPC generation. RPC callers
/// do not retain a dead client across helper restarts; every operation asks for
/// the latest generation.
public final class EngineConnection: @unchecked Sendable {
    public typealias Transport = HTTP2ClientTransport.Posix
    typealias Client = GRPCClient<Transport>

    private struct State {
        var client: Client?
        var stopped = false
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    func install(_ client: Client) {
        lock.withLock {
            guard !state.stopped else { return }
            state.client = client
        }
    }

    func clear(_ client: Client) {
        lock.withLock {
            if state.client === client { state.client = nil }
        }
    }

    func stop() {
        lock.withLock {
            state.stopped = true
            state.client = nil
        }
    }

    func currentClient() throws -> Client {
        try lock.withLock {
            if state.stopped { throw EngineConnectionError.stopped }
            guard let client = state.client else { throw EngineConnectionError.unavailable }
            return client
        }
    }

    public func engineClient() throws -> Kmgr_V1_EngineService.Client<Transport> {
        Kmgr_V1_EngineService.Client(wrapping: try currentClient())
    }

    public func clusterClient() throws -> Kmgr_V1_ClusterService.Client<Transport> {
        Kmgr_V1_ClusterService.Client(wrapping: try currentClient())
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
