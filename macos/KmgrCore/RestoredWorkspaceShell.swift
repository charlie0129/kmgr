import Foundation

/// Presentation-only state used while a saved kubeconfig context is being
/// opened. The shell deliberately contains no Kubernetes rows or identities,
/// and its placeholder session ID must never be sent to a provider.
public struct RestoredWorkspaceShell: Hashable, Sendable {
    public var recordID: String
    public var session: OpenedClusterSession
    public var targetResource: DiscoveredResource?

    public init(record: ClusterWindowRestorationRecord) {
        recordID = record.id
        session = OpenedClusterSession(
            sessionID: "restoring-\(record.id)",
            contextName: record.state.contextName,
            clusterName: "",
            serverHostname: "",
            defaultNamespace: record.state.namespaceScope.namespaceSelection.namespaces.first ?? "",
            contextReference: record.state.contextReference
        )
        targetResource = record.state.gvr.map { gvr in
            DiscoveredResource(
                group: gvr.group,
                version: gvr.version,
                resource: gvr.resource,
                kind: Self.kindTitle(for: gvr),
                namespaced: !Self.clusterScopedResources.contains(gvr.resource)
            )
        }
    }

    private static func kindTitle(for gvr: GVR) -> String {
        knownKindTitles["\(gvr.group)/\(gvr.resource)"]
            ?? knownKindTitles[gvr.resource]
            ?? gvr.resource
    }

    private static let knownKindTitles: [String: String] = [
        "pods": "Pod",
        "services": "Service",
        "events": "Event",
        "configmaps": "ConfigMap",
        "secrets": "Secret",
        "nodes": "Node",
        "namespaces": "Namespace",
        "persistentvolumes": "PersistentVolume",
        "persistentvolumeclaims": "PersistentVolumeClaim",
        "apps/deployments": "Deployment",
        "apps/statefulsets": "StatefulSet",
        "apps/daemonsets": "DaemonSet",
        "apps/replicasets": "ReplicaSet",
        "batch/jobs": "Job",
        "batch/cronjobs": "CronJob",
        "networking.k8s.io/ingresses": "Ingress",
        "networking.k8s.io/networkpolicies": "NetworkPolicy",
        "apiextensions.k8s.io/customresourcedefinitions": "CustomResourceDefinition",
        "storage.k8s.io/storageclasses": "StorageClass",
        "rbac.authorization.k8s.io/clusterroles": "ClusterRole",
        "rbac.authorization.k8s.io/clusterrolebindings": "ClusterRoleBinding",
        "rbac.authorization.k8s.io/roles": "Role",
        "rbac.authorization.k8s.io/rolebindings": "RoleBinding",
    ]

    private static let clusterScopedResources: Set<String> = [
        "nodes", "namespaces", "persistentvolumes", "storageclasses",
        "volumeattachments", "csidrivers", "csinodes", "clusterroles",
        "clusterrolebindings", "customresourcedefinitions", "priorityclasses",
        "runtimeclasses", "mutatingwebhookconfigurations",
        "validatingwebhookconfigurations", "apiservices",
    ]
}
