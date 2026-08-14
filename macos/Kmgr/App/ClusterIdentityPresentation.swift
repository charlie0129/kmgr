import Foundation
import KmgrCore

/// One presentation authority for immutable cluster and Kubernetes target
/// identity. Context names are always rendered exactly and independently from
/// cluster names so similarly named contexts cannot collapse into one label.
struct ClusterIdentityPresentation: Hashable, Sendable {
    let clusterName: String
    let contextName: String

    init(session: OpenedClusterSession) {
        clusterName = session.clusterName
        contextName = session.contextName
    }

    init(clusterName: String, contextName: String) {
        self.clusterName = clusterName
        self.contextName = contextName
    }

    var titlePrefix: String {
        "\(displayedClusterName) — \(displayedContextName)"
    }

    var labeledInline: String {
        "Cluster: \(displayedClusterName) · Context: \(displayedContextName)"
    }

    var labeledCluster: String {
        "Cluster: \(displayedClusterName)"
    }

    var labeledLines: String {
        "Cluster: \(displayedClusterName)\nContext: \(displayedContextName)"
    }

    func targetDetails(
        _ identity: ResourceIdentity,
        includeUID: Bool = true
    ) -> String {
        let namespace = Self.namespaceName(for: identity)
        var lines = [
            "Cluster: \(displayedClusterName)",
            "Context: \(displayedContextName)",
            "Namespace: \(namespace)",
            "Target: \(Self.resourcePath(for: identity)) · \(Self.objectPath(for: identity))",
        ]
        if includeUID, !identity.uid.rawValue.isEmpty {
            lines.append("UID: \(identity.uid.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    static func namespaceName(for identity: ResourceIdentity) -> String {
        identity.namespace.isEmpty ? "(cluster scoped)" : identity.namespace
    }

    static func resourcePath(for identity: ResourceIdentity) -> String {
        [identity.group, identity.version, identity.resource]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    static func objectPath(for identity: ResourceIdentity) -> String {
        identity.namespace.isEmpty
            ? identity.name
            : "\(identity.namespace)/\(identity.name)"
    }

    private var displayedClusterName: String {
        clusterName.isEmpty ? "(unknown cluster)" : clusterName
    }

    private var displayedContextName: String {
        contextName.isEmpty ? "(unknown context)" : contextName
    }
}
