import Foundation

public struct ResourceDrillDownQuery: Hashable, Sendable {
    public var group: String
    public var version: String
    public var resource: String
    public var namespaceScope: NamespaceSelection
    public var labelSelector: String
    public var fieldSelector: String
    public var filterExpression: String

    public init(
        group: String,
        version: String,
        resource: String,
        namespaceScope: NamespaceSelection,
        labelSelector: String = "",
        fieldSelector: String = "",
        filterExpression: String = ""
    ) {
        self.group = group
        self.version = version
        self.resource = resource
        self.namespaceScope = namespaceScope
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
        self.filterExpression = filterExpression
    }
}

public enum ResourceDrillDownPlan: Hashable, Sendable {
    case resource(ResourceDrillDownQuery)
    case containers(pod: ResourceIdentity, values: [PodContainerDetail])
}

/// Maps a freshly fetched, UID-authoritative object to the useful child view
/// entered by Return. Kubernetes-native relationship selectors stay separate
/// from the editable display filter so the complete server-side semantics are
/// retained even when kmgr's smaller filter grammar cannot express them.
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
            guard let filter = fieldFilter(path: "spec.nodeName", value: identity.name) else {
                return nil
            }
            return .resource(podQuery(
                scope: NamespaceSelection(),
                filterExpression: filter
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
                labelSelector: detail.podLabelSelector,
                filterExpression: selectorDisplayFilter(from: detail.summaryFields)
            ))
        default:
            return nil
        }
    }

    private static func podQuery(
        scope: NamespaceSelection,
        labelSelector: String = "",
        fieldSelector: String = "",
        filterExpression: String = ""
    ) -> ResourceDrillDownQuery {
        ResourceDrillDownQuery(
            group: "",
            version: "v1",
            resource: "pods",
            namespaceScope: scope,
            labelSelector: labelSelector,
            fieldSelector: fieldSelector,
            filterExpression: filterExpression
        )
    }

    /// Match-label terms remain useful, readable local correctness checks.
    /// Match expressions and omitted display rows are intentionally ignored
    /// here because `podLabelSelector` carries the complete canonical query.
    private static func selectorDisplayFilter(from fields: [ObjectSummaryField]) -> String {
        fields.compactMap { field -> String? in
            guard field.sectionID == "selectors",
                field.fieldID.hasPrefix("selector:"),
                safeFilterToken(field.label), safeFilterToken(field.displayText)
            else { return nil }
            return "label:\(field.label)==\(field.displayText)"
        }.joined(separator: " ")
    }

    private static func fieldFilter(path: String, value: String) -> String? {
        guard safeFilterToken(path), safeFilterToken(value) else { return nil }
        return "field:\(path)==\(value)"
    }

    private static func safeFilterToken(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains(where: { $0.isWhitespace })
            && !value.contains("=")
            && !value.contains("\\")
            && !value.contains("\"")
            && !value.contains("'")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
