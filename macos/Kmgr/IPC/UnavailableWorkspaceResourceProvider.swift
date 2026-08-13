import Foundation
import KmgrCore

struct UnavailableWorkspaceResourceProvider: WorkspaceResourceProviding {
    func discoverResources(sessionID: String, refresh: Bool) async throws -> [DiscoveredResource] {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "WorkspaceIPCUnavailable",
            message: "Resource discovery is not connected to the Kubernetes engine yet.",
            retryable: true,
            operation: "discover resources"
        )
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(
        request: ResourceViewRequest
    ) -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ClusterManagerIssue(
                category: .unavailable,
                reason: "WorkspaceIPCUnavailable",
                message: "Resource streaming is not connected to the Kubernetes engine yet.",
                retryable: true,
                operation: "open resource view"
            ))
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}
