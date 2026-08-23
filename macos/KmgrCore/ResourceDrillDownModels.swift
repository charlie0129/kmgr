import Foundation

public struct ResourceDrillDownQuery: Hashable, Sendable {
    public var group: String
    public var version: String
    public var resource: String
    public var namespaceScope: NamespaceSelection
    public var filterExpression: String

    public init(
        group: String,
        version: String,
        resource: String,
        namespaceScope: NamespaceSelection,
        filterExpression: String
    ) {
        self.group = group
        self.version = version
        self.resource = resource
        self.namespaceScope = namespaceScope
        self.filterExpression = filterExpression
    }
}

public enum ResourceDrillDownPlan: Hashable, Sendable {
    case resource(ResourceDrillDownQuery)
    case containers(pod: ResourceIdentity, values: [PodContainerDetail])
}

/// Formats explicit Kubernetes clauses embedded in the visible resource
/// query. Kubernetes field-selector values retain Kubernetes' own escaping;
/// the outer query quote is only used to preserve whitespace in the clause.
public enum ResourceQueryExpression {
    public static func nativeLabelSelector(_ selector: String) -> String {
        quotedClause(prefix: "labelSelector", value: selector)
    }

    public static func nativeFieldSelector(path: String, equals value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "=", with: "\\=")
        return quotedClause(
            prefix: "fieldSelector",
            value: "\(path)=\(escapedValue)"
        )
    }

    private static func quotedClause(prefix: String, value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(prefix):\"\(escaped)\""
    }
}

/// Maps a freshly fetched, UID-authoritative object to the useful child view
/// entered by Return. Relationship selectors are written directly into the
/// editable query so the field remains the only source of truth.
public enum ResourceDrillDownPlanner {
    public static func hasPotentialTarget(_ identity: ResourceIdentity) -> Bool {
        switch (identity.group, identity.version, identity.resource) {
        case ("", "v1", "pods"),
            ("", "v1", "nodes"),
            ("", "v1", "namespaces"),
            ("", "v1", "configmaps"),
            ("", "v1", "secrets"),
            ("", "v1", "services"),
            ("", "v1", "replicationcontrollers"),
            ("apps", "v1", "deployments"),
            ("apps", "v1", "statefulsets"),
            ("apps", "v1", "daemonsets"),
            ("apps", "v1", "replicasets"),
            ("batch", "v1", "jobs"):
            true
        default:
            false
        }
    }

    public static func plan(for detail: ObjectDetail) -> ResourceDrillDownPlan? {
        let identity = detail.identity
        switch (identity.group, identity.version, identity.resource) {
        case ("", "v1", "pods"):
            guard !detail.summaryFields.contains(where: {
                $0.sectionID == "containers" && $0.fieldID == "containersOmitted"
            }) else { return nil }
            let containers = ExecContainerCatalog.orderedDetails(from: detail.containers)
            return containers.isEmpty ? nil : .containers(pod: identity, values: containers)
        case ("", "v1", "nodes"):
            return .resource(podQuery(
                scope: NamespaceSelection(),
                filterExpression: ResourceQueryExpression.nativeFieldSelector(
                    path: "spec.nodeName", equals: identity.name
                )
            ))
        case ("", "v1", "namespaces"):
            guard !identity.name.isEmpty else { return nil }
            return .resource(podQuery(
                scope: .namespace(identity.name),
                filterExpression: ""
            ))
        case ("", "v1", "services"),
            ("", "v1", "replicationcontrollers"),
            ("apps", "v1", "deployments"),
            ("apps", "v1", "statefulsets"),
            ("apps", "v1", "daemonsets"),
            ("apps", "v1", "replicasets"),
            ("batch", "v1", "jobs"):
            guard !detail.podLabelSelector.isEmpty else { return nil }
            let scope = identity.namespace.isEmpty
                ? NamespaceSelection() : .namespace(identity.namespace)
            return .resource(podQuery(
                scope: scope,
                filterExpression: ResourceQueryExpression.nativeLabelSelector(
                    detail.podLabelSelector
                )
            ))
        default:
            return nil
        }
    }

    private static func podQuery(
        scope: NamespaceSelection,
        filterExpression: String
    ) -> ResourceDrillDownQuery {
        ResourceDrillDownQuery(
            group: "",
            version: "v1",
            resource: "pods",
            namespaceScope: scope,
            filterExpression: filterExpression
        )
    }
}
