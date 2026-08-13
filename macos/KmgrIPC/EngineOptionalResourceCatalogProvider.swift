import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

/// Narrow RPC seam for verifying catalog protobuf mapping without starting an
/// engine process or contacting a Kubernetes cluster.
public protocol OptionalResourceCatalogRPC: Sendable {
    func discoverOptionalResources(
        request: Kmgr_V1_DiscoverOptionalResourcesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_DiscoverOptionalResourcesResponse
}

public struct EngineOptionalResourceCatalogRPC: OptionalResourceCatalogRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func discoverOptionalResources(
        request: Kmgr_V1_DiscoverOptionalResourcesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_DiscoverOptionalResourcesResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        // EngineConnection's interceptor attaches the per-launch bearer token
        // to this RPC just as it does for every other helper request.
        return try await connection.viewClient().discoverOptionalResources(
            request,
            options: options
        )
    }
}

public struct EngineOptionalResourceCatalogProvider: OptionalResourceCatalogProviding {
    private let rpc: any OptionalResourceCatalogRPC
    private let timeout: Duration
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        timeout: Duration = .seconds(5)
    ) {
        self.init(
            rpc: EngineOptionalResourceCatalogRPC(connection: connection),
            timeout: timeout
        )
    }

    public init(
        rpc: any OptionalResourceCatalogRPC,
        timeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.rpc = rpc
        self.timeout = timeout
        self.now = now
        self.requestID = requestID
    }

    public func discoverOptionalResources(
        _ request: OptionalResourceCatalogRequest
    ) async throws -> OptionalResourceCatalog {
        let rpcRequest = makeRequest(from: request)
        do {
            let response = try await rpc.discoverOptionalResources(
                request: rpcRequest,
                timeout: timeout
            )
            guard response.requestID == rpcRequest.context.requestID else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "RequestIDMismatch",
                    message: "The engine returned a response for a different optional-resource catalog request.",
                    operation: "discover optional scheduler resources"
                )
            }
            if response.hasError {
                throw EngineClusterContextProvider.issue(from: response.error)
            }

            let resources = try response.resources.map(Self.resource(from:))
            guard Set(resources.map(\.id)).count == resources.count else {
                throw Self.invalidResponse(
                    "The engine returned duplicate exact resource identities."
                )
            }
            return OptionalResourceCatalog(
                requestID: response.requestID,
                resources: resources,
                nodesCacheAvailable: response.nodesCacheAvailable,
                podsCacheAvailable: response.podsCacheAvailable,
                nodesSnapshotComplete: response.nodesSnapshotComplete,
                podsSnapshotComplete: response.podsSnapshotComplete,
                potentiallyIncomplete: response.potentiallyIncomplete
            )
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "discover optional scheduler resources"
            )
        }
    }

    private func makeRequest(
        from request: OptionalResourceCatalogRequest
    ) -> Kmgr_V1_DiscoverOptionalResourcesRequest {
        var result = Kmgr_V1_DiscoverOptionalResourcesRequest()
        result.context.requestID = requestID()
        result.context.clusterSessionID = request.sessionID
        result.context.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000
        )
        result.applicableResource = Self.resource(from: request.applicableResource)
        return result
    }

    private static func resource(
        from value: DiscoveredResource
    ) -> Kmgr_V1_ResourceType {
        var result = Kmgr_V1_ResourceType()
        result.group = value.group
        result.version = value.version
        result.resource = value.resource
        result.kind = value.kind
        result.namespaced = value.namespaced
        return result
    }

    private static func resource(
        from value: Kmgr_V1_OptionalResource
    ) throws -> OptionalResourceCatalogEntry {
        guard !value.exactKey.isEmpty else {
            throw invalidResponse(
                "The engine returned an optional resource without an exact key."
            )
        }
        guard value.hasApplicableResource else {
            throw invalidResponse(
                "The engine returned an optional resource without an applicable GVR."
            )
        }
        return OptionalResourceCatalogEntry(
            exactKey: value.exactKey,
            category: try category(from: value.category),
            isPresent: value.present,
            displayName: value.displayName,
            applicableResource: resource(from: value.applicableResource),
            isExplicitlyConfigured: value.explicitlyConfigured
        )
    }

    private static func resource(
        from value: Kmgr_V1_ResourceType
    ) -> DiscoveredResource {
        DiscoveredResource(
            group: value.group,
            version: value.version,
            resource: value.resource,
            kind: value.kind,
            namespaced: value.namespaced
        )
    }

    private static func category(
        from value: Kmgr_V1_OptionalResourceCategory
    ) throws -> OptionalResourceCategory {
        switch value {
        case .ephemeralStorage: .ephemeralStorage
        case .hugePage: .hugePage
        case .accelerator: .accelerator
        case .unspecified, .UNRECOGNIZED:
            throw invalidResponse(
                "The engine returned an unrecognized optional resource category."
            )
        }
    }

    private static func invalidResponse(_ message: String) -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .internalFailure,
            reason: "InvalidOptionalResourceCatalog",
            message: message,
            operation: "discover optional scheduler resources"
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
