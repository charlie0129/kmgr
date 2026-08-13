import Foundation
import KmgrCore

/// Temporary composition fallback used only until the supervised engine has a
/// ready RPC connection. Keeping it behind `ClusterContextProviding` lets the
/// chooser render an honest, retryable inline state instead of static data.
struct UnavailableClusterContextProvider: ClusterContextProviding {
    var message: String

    init(message: String = "The Kubernetes engine is still starting. Try again shortly.") {
        self.message = message
    }

    func listContexts(reload: Bool) async throws -> [ClusterContextSummary] {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "EngineUnavailable",
            message: message,
            retryable: true,
            operation: reload ? "reload kubeconfig" : "list kubeconfig contexts"
        )
    }

    func openContext(named contextName: String) async throws -> OpenedClusterSession {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "EngineUnavailable",
            message: message,
            retryable: true,
            contextName: contextName,
            operation: "open cluster session"
        )
    }
}
